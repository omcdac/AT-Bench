#!/usr/bin/env python3
"""
job_debug_analyzer.py
======================

AT-Bench Job Debug / Fault Analyzer for C-DAC HPC Application Runs
--------------------------------------------------------------------

Where atbench_analyzer.py (CRON/graph/) summarizes the *numbers*
verify-results.sh already computed (successful / slow / incomplete counts
from a day's LOGS), this tool goes one level deeper: it reads the RAW per-job
output directories directly (SLURM .err files, app logs, WRF per-rank rsl
files, ...) for GROMACS, NAMD, OPENFOAM and WRF, and answers *why* the
non-successful jobs failed, so failures don't all collapse into an opaque
"incomplete" bucket.

Usage
-----
    python3 job_debug_analyzer.py --run-dir /path/to/bk-06August2026 \\
        --output-dir /path/to/output \\
        [--apps GROMACS NAMD OPENFOAM WRF] \\
        [--top-nodes 15] [--mass-cancel-threshold 5]

`--run-dir` is a day's application-output tree containing GROMACS/, NAMD/,
OPENFOAM/, WRF/ subdirectories (the same layout $OUTDIR points at for
SCRIPTS/verification/*/*-verify-results.sh) -- e.g. a dated backup under
scratch/AT-RUN/, or $OUTDIR itself for a live run.

Design notes
------------
* Directory-naming quirk (see SCRIPTS/verification/*-verify-results.sh for
  the same issue and its fix): GROMACS/NAMD/OPENFOAM submission scripts
  reuse a fixed pool of "RUN-N" slot directories where N is a slot number
  unrelated to the job ID -- the job ID only appears in *filenames* inside
  ("<jobid>.err", "err.<jobid>", "job.<jobid>.err"). This tool indexes each
  app's run directory by BOTH dirname-embedded job IDs (covers WRF, and the
  GROMACS/NAMD jobs that do land in numerically-named dirs) AND by
  error-filename-embedded job IDs (covers every RUN-N slot job), same
  two-pass approach used to fix the verify-results.sh scripts.
* Only ever reads small text files (*.err, *.out, log/summary files, one
  rsl.error.NNNN at a time) -- never the large binary/restart artifacts
  (.tpr, .coor, wrfrst_*, etc.) that dominate on-disk size.
* For WRF, only rank 0's rsl.error.0000 is read for a job that completed
  cleanly ("wrf: SUCCESS COMPLETE WRF"); the full per-rank scan (looking for
  which rank/node actually crashed) only runs for jobs that didn't.
* Error taxonomy is intentionally app-agnostic (SLURM cancellation reasons,
  network/IB fabric faults, segfaults, MPI aborts, app-level fatal errors,
  environment/setup errors, OOM, unknown-incomplete) so the two charts can
  compare failure composition across apps directly.
* "Additional intelligence": mass-cancellation clustering (many jobs
  CANCELLED at the exact same timestamp -> one systemic event, not N
  independent incidents) and cross-app faulty-node ranking (which compute
  nodes show up repeatedly across failed jobs of ANY app).

Can also be imported and driven programmatically via `run_analysis(...)`.
"""

from __future__ import annotations

import argparse
import csv
import logging
import re
import subprocess
import sys
import textwrap
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import matplotlib
matplotlib.use("Agg")
import matplotlib.colors as mcolors
import matplotlib.pyplot as plt
import numpy as np

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("job_debug_analyzer")

DEFAULT_APPS = ["GROMACS", "NAMD", "OPENFOAM", "WRF"]
READ_LIMIT = 300_000  # chars; generous for these text logs, guards against surprises

# Stamped on every generated artifact: a "#"-prefixed comment line at the
# top of text/CSV output (filtered out by every reader that parses one of
# these files back, e.g. read_failed_jobs_csv), small print at the bottom
# of every PNG chart.
DISCLAIMER = "Disclaimer: Internal testing, not publication ready. Contact: omjadhav@cdac.in"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# --------------------------------------------------------------------------
# Error taxonomy: name -> (regex, display color). Order matters -- the
# cascade in classify_from_text() stops at the first match, most specific
# / most actionable causes first.
# --------------------------------------------------------------------------
NO_OUTPUT_YET = "NO_OUTPUT_YET"
TIMEOUT = "TIMEOUT"
EXTERNAL_CANCEL = "EXTERNAL_CANCEL"
NODE_FAULT_NETWORK = "NODE_FAULT_NETWORK"
MPI_LAUNCH_FAILURE = "MPI_LAUNCH_FAILURE"   # hydra/bstrap couldn't even start ranks -- requested
                                             # node(s) unavailable at launch time, not an IB fault
SEGFAULT = "SEGFAULT"
MPI_ABORT = "MPI_ABORT"
APP_FATAL_ERROR = "APP_FATAL_ERROR"
ENV_SETUP_ERROR = "ENV_SETUP_ERROR"
OOM = "OOM"
OTHER_ERROR = "OTHER_ERROR"          # generic scan found an error/fail/fatal line the
                                      # specific cascade patterns don't recognize
UNKNOWN_INCOMPLETE = "UNKNOWN_INCOMPLETE"  # generic scan found nothing at all
SLOW = "SLOW"
OK = "OK"

CATEGORY_COLORS = {
    OK: "#4C9A4C",
    SLOW: "#D4A72C",
    NO_OUTPUT_YET: "#B0B0B0",
    TIMEOUT: "#E0A458",
    EXTERNAL_CANCEL: "#C9A15A",
    NODE_FAULT_NETWORK: "#8B3A3A",
    MPI_LAUNCH_FAILURE: "#D2691E",
    SEGFAULT: "#C0504D",
    MPI_ABORT: "#9A5B9A",
    APP_FATAL_ERROR: "#D6707A",
    ENV_SETUP_ERROR: "#6F9FC9",
    OOM: "#5A6FBF",
    OTHER_ERROR: "#A0522D",
    UNKNOWN_INCOMPLETE: "#7F7F7F",
}
FAILURE_CATEGORIES = [
    TIMEOUT, EXTERNAL_CANCEL, NODE_FAULT_NETWORK, MPI_LAUNCH_FAILURE, SEGFAULT,
    MPI_ABORT, APP_FATAL_ERROR, ENV_SETUP_ERROR, OOM, OTHER_ERROR, UNKNOWN_INCOMPLETE,
]
# SLOW isn't a failure (the job completed) -- it's its own bucket, listed
# separately from FAILURE_CATEGORIES everywhere (accounting, node-fault
# ranking, mass-cancel detection) but shown alongside failures on the charts
# and in the error report since it's still something to go debug.
NON_OK_CATEGORIES = [SLOW] + FAILURE_CATEGORIES
NODE_ATTRIBUTABLE_CATEGORIES = {NODE_FAULT_NETWORK, MPI_LAUNCH_FAILURE, SEGFAULT, MPI_ABORT, APP_FATAL_ERROR}

# --------------------------------------------------------------------------
# "Slow" detection: same acceptable ns/day (or cds) + walltime ranges each
# SCRIPTS/verification/*/*-verify-results.sh already hardcodes for its app
# (see nsperday_min/max, cds_min/max, walltime_min/max in those scripts) --
# duplicated here so a job that *completed* but posted results outside the
# expected performance envelope gets flagged instead of silently counting
# as OK. Keeping this analyzer self-contained (reading the same raw files
# it already reads for classification) avoids depending on those scripts'
# SuccesfullJobIDs/ResultOutOffRengeJobIDs files, which only ever hold the
# *last* verify-results.sh run and may not correspond to the --run-dir
# snapshot being analyzed here.
# --------------------------------------------------------------------------
PERF_THRESHOLDS: Dict[str, Dict[str, Tuple[float, float]]] = {
    "GROMACS": {"nsperday": (18, 27), "walltime": (300, 480)},
    "NAMD": {"nsperday": (6.5, 11.5), "walltime": (300, 480)},
    "OPENFOAM": {"cds": (0.006, 0.030), "walltime": (300, 480)},
    "WRF": {"walltime": (300, 480)},
}
_REAL_TIME_RE = re.compile(r"real\s+(\d+)m([\d.]+)s")


def parse_real_walltime_seconds(text: str) -> Optional[float]:
    """Parse a bash `time` builtin's "real  0m23.456s" line into seconds."""
    m = _REAL_TIME_RE.search(text)
    if not m:
        return None
    return int(m.group(1)) * 60 + float(m.group(2))


def check_slow(app: str, metrics: Dict[str, Optional[float]]) -> Optional[str]:
    """Compare a completed job's parsed metrics against the app's acceptable
    range. Returns a human-readable detail string if any metric parsed
    successfully and fell outside range, else None (including when a
    metric couldn't be parsed at all -- that's a parsing gap, not evidence
    of slowness, so it's left as OK rather than guessed at)."""
    bounds = PERF_THRESHOLDS.get(app, {})
    bad = []
    for name, value in metrics.items():
        b = bounds.get(name)
        if b is None or value is None:
            continue
        if not (b[0] <= value <= b[1]):
            bad.append(f"{name}={value:.6g} (expected {b[0]}-{b[1]})")
    return "; ".join(bad) if bad else None


def _parse_tail_first_field(text: str, n: int, field_idx: int) -> Optional[float]:
    """Mirrors bash's `tail -N file | head -1 | awk '{print $N}'` (1-indexed
    field_idx becomes 0-indexed here): last n lines, take the first of
    those, split on whitespace, pick a field."""
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return None
    fields = lines[-n:][0].split()
    if len(fields) <= field_idx:
        return None
    try:
        return float(fields[field_idx])
    except ValueError:
        return None


def parse_namd_metrics(output_tail: str) -> Tuple[Optional[float], Optional[float]]:
    """nsperday = 1 / (last "Benchmark time" line's 8th field); walltime =
    first "WallClock" line's 2nd field. Mirrors namd-verify-results.sh."""
    nsperday = None
    bench_lines = [ln for ln in output_tail.splitlines() if "Benchmark time" in ln]
    if bench_lines:
        fields = bench_lines[-1].split()
        if len(fields) >= 8:
            try:
                bench_time = float(fields[7])
                if bench_time > 0:
                    nsperday = 1.0 / bench_time
            except ValueError:
                pass

    walltime = None
    wallclock_lines = [ln for ln in output_tail.splitlines() if "WallClock" in ln]
    if wallclock_lines:
        fields = wallclock_lines[0].split()
        if len(fields) >= 2:
            try:
                walltime = float(fields[1])
            except ValueError:
                pass
    return nsperday, walltime


def parse_openfoam_metrics(result_tail: str) -> Tuple[Optional[float], Optional[float]]:
    """cds = 3rd-from-last "Cd" line's 3rd field; walltime from the "real"
    line. Mirrors openfoam-verify-results.sh's `grep Cd | tail -3 | head -1`."""
    cds = None
    cd_lines = [ln for ln in result_tail.splitlines() if "Cd" in ln]
    if cd_lines:
        fields = cd_lines[-3:][0].split()
        if len(fields) >= 3:
            try:
                cds = float(fields[2])
            except ValueError:
                pass
    walltime = parse_real_walltime_seconds(result_tail)
    return cds, walltime

_CASCADE: List[Tuple[str, re.Pattern]] = [
    (TIMEOUT, re.compile(r"CANCELLED AT \S+ DUE TO TIME LIMIT", re.IGNORECASE)),
    (EXTERNAL_CANCEL, re.compile(r"CANCELLED AT \S+ DUE (?:to|TO)", re.IGNORECASE)),
    (NODE_FAULT_NETWORK, re.compile(
        r"Transport retry count exceeded|ib_mlx5_log|UCX\s+ERROR|"
        r"PSM2 has caught|out of memory.*(?:ib|rdma)|IBV_WC_|"
        r"opal_common_ucx", re.IGNORECASE)),
    (MPI_LAUNCH_FAILURE, re.compile(
        r"Unable to run bstrap_proxy|HYD_bstrap_setup|"
        r"error setting up the bootstrap proxies|"
        r"Unable to create step for job|"
        r"Requested node configuration is not available",
        re.IGNORECASE)),
    (SEGFAULT, re.compile(
        r"forrtl: error \(76\)|Segmentation fault|signal 11|core dumped|"
        r"SIGSEGV", re.IGNORECASE)),
    (OOM, re.compile(r"oom.?kill|Out of memory|Killed process \d+", re.IGNORECASE)),
    (MPI_ABORT, re.compile(r"MPI_ABORT|MPI_Abort|application called MPI_Abort", re.IGNORECASE)),
    (APP_FATAL_ERROR, re.compile(
        r"FOAM FATAL ERROR|^Fatal error:|FATAL ERROR|ERROR: Periodic cell|"
        r"Charm\+\+ fatal error", re.IGNORECASE | re.MULTILINE)),
    (ENV_SETUP_ERROR, re.compile(
        r"matches multiple packages|command not found|"
        r"cannot open case directory|error while loading shared libraries|"
        r"No such file or directory", re.IGNORECASE)),
]

_SLURM_CANCEL_RE = re.compile(
    r"JOB\s+\d+\s+ON\s+(\S+)\s+CANCELLED AT (\S+)\s+DUE (?:to|TO)\s+(.+?)\s*\*+\s*$",
    re.IGNORECASE | re.MULTILINE)
_IB_NODE_RE = re.compile(r"\[(\S+?):\d+(?::\d+)*\]")
_MPIEXEC_HOST_RE = re.compile(r"\[mpiexec@(\S+?)\]")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def read_text(path: Path, limit: int = READ_LIMIT) -> str:
    try:
        with path.open("r", errors="replace") as f:
            return strip_ansi(f.read(limit))
    except (OSError, IOError):
        return ""


def read_tail(path: Path, limit: int) -> str:
    """Read the LAST `limit` bytes of a file.

    Several of these logs are "verbose progress first, terminal
    success/failure line last" (GROMACS runtime.txt, NAMD's
    namd-cpu.output, OpenFOAM's openfoamResult.txt, WRF's rsl.error.*),
    and some are genuinely large (openfoamResult.txt can run ~8MB from a
    solver that logs every iteration) -- a head-read of any reasonable
    size silently misses the one line that actually matters. Seeking from
    the end keeps the read cheap regardless of total file size.
    """
    try:
        size = path.stat().st_size
        with path.open("rb") as f:
            if size > limit:
                f.seek(size - limit)
            data = f.read()
        return strip_ansi(data.decode("utf-8", errors="replace"))
    except (OSError, IOError):
        return ""


def read_nodelist(rundir: Optional[Path]) -> Optional[str]:
    """The job's full SLURM nodelist (e.g. "cbcn[0833-0835,0837-0839]"),
    written by every app's job template as `echo "$SLURM_NODELIST" >
    nodelist.txt` -- captured for every job regardless of outcome so the
    success/slow/failed node-list reports can show it."""
    if rundir is None:
        return None
    f = rundir / "nodelist.txt"
    if not f.is_file():
        return None
    text = read_text(f, limit=2_000).strip()
    return text or None


_HOSTLIST_EXPAND_CACHE: Dict[str, Tuple[str, ...]] = {}


def expand_hostlist(hostlist: str) -> Tuple[str, ...]:
    """Expand a SLURM hostlist expression (e.g. "cbcn[0298,0300,0310-0314]")
    into individual hostnames via `scontrol show hostnames` -- the exact
    mechanism SCRIPTS/extract-nodes already uses. Shelling out to the real
    SLURM tool here (rather than reimplementing its range-expansion syntax
    in Python) guarantees identical behavior to that script and to
    `scontrol` itself. Cached since the same nodelist string recurs across
    many jobs in a run (identical node allocation reused job to job)."""
    hostlist = hostlist.strip()
    if not hostlist:
        return ()
    if hostlist in _HOSTLIST_EXPAND_CACHE:
        return _HOSTLIST_EXPAND_CACHE[hostlist]
    try:
        proc = subprocess.run(["scontrol", "show", "hostnames", hostlist],
                               capture_output=True, text=True, timeout=10, check=True)
        names = tuple(ln.strip() for ln in proc.stdout.splitlines() if ln.strip())
    except (OSError, subprocess.SubprocessError) as exc:
        log.warning("scontrol show hostnames failed for %r: %s", hostlist, exc)
        names = ()
    _HOSTLIST_EXPAND_CACHE[hostlist] = names
    return names


def classify_from_text(text: str) -> Optional[str]:
    for name, pattern in _CASCADE:
        if pattern.search(text):
            return name
    return None


# --------------------------------------------------------------------------
# Context extraction -- a single grepped line (e.g. just "Requested node
# configuration is not available") often reads as a totally different, more
# innocuous problem than what actually happened. Real example (NAMD job
# 274132's namd-cpu.output): the srun line by itself looks like a plain
# SLURM scheduling hiccup, but the lines right above it are
# "[mpiexec@cbcn2065] Error: Unable to run bstrap_proxy ..." / "Error
# setting up the bootstrap proxies" -- an MPI/hydra launch failure, not a
# scheduling one. Pulling a window of surrounding lines instead of the bare
# match line is what makes that visible instead of misleading.
# --------------------------------------------------------------------------
_CONTEXT_LINES_BEFORE = 2
_CONTEXT_LINES_AFTER = 15
_CONTEXT_MAX_CHARS = 1500


def _extract_context(text: str, match_start: int, match_end: int,
                      lines_before: int = _CONTEXT_LINES_BEFORE,
                      lines_after: int = _CONTEXT_LINES_AFTER) -> str:
    """The matched line plus lines_before/lines_after lines of surrounding
    context, capped at _CONTEXT_MAX_CHARS total. Biased toward MORE lines
    AFTER the match than before: these logs are a linear execution
    transcript where a fault cascades forward (the first sign of trouble,
    then follow-on messages, then a final summary line), so what explains
    a match is usually what comes after it, not before."""
    lines = text.splitlines()
    pos = 0
    match_line_idx = len(lines) - 1 if lines else 0
    for i, ln in enumerate(lines):
        line_end = pos + len(ln)
        if pos <= match_start <= line_end:
            match_line_idx = i
            break
        pos = line_end + 1  # +1 for the newline splitlines() strips
    start_idx = max(0, match_line_idx - lines_before)
    end_idx = min(len(lines), match_line_idx + lines_after + 1)
    context = "\n".join(lines[start_idx:end_idx]).strip()
    if len(context) > _CONTEXT_MAX_CHARS:
        context = context[:_CONTEXT_MAX_CHARS].rstrip() + "\n  ...(truncated)"
    return context


def extract_detail_and_node(category: str, text: str) -> Tuple[str, Optional[str]]:
    """detail: several lines of context around the matched error (see
    _extract_context), not just the single matched line -- node: best-effort
    node name attributable to a matched category, found independently of
    however much context ends up in detail."""
    m = _SLURM_CANCEL_RE.search(text)
    if m and category in (TIMEOUT, EXTERNAL_CANCEL):
        node, ts, reason = m.group(1), m.group(2), m.group(3).strip()
        header = f"{reason} @ {ts}"
        context = _extract_context(text, m.start(), m.end())
        detail = header if context == header.strip() else f"{header}\n{context}"
        return detail, node

    node = None
    if category == NODE_FAULT_NETWORK:
        m2 = _IB_NODE_RE.search(text)
        node = m2.group(1) if m2 else None
    elif category == MPI_LAUNCH_FAILURE:
        m4 = _MPIEXEC_HOST_RE.search(text)
        node = m4.group(1) if m4 else None

    for name, pattern in _CASCADE:
        if name == category:
            m3 = pattern.search(text)
            if m3:
                return _extract_context(text, m3.start(), m3.end()), node

    fallback_detail = {
        NODE_FAULT_NETWORK: "network/IB fabric error",
        MPI_LAUNCH_FAILURE: "MPI/SLURM launch failure",
    }
    return fallback_detail.get(category, ""), node


# --------------------------------------------------------------------------
# Generic whole-run-directory error search -- a fallback for jobs the
# targeted per-app cascade (which only reads the one or two files each app
# is known to write its result to) couldn't pin down. Walks every text file
# actually sitting in the job's run directory and looks for the same kind
# of language a human would grep for ("error", "failed", "fatal", ...),
# so a fault that landed in a file we don't specifically know to check
# doesn't just fall through to an opaque "unknown" bucket.
# --------------------------------------------------------------------------
_GENERIC_ERROR_RE = re.compile(
    r"\berror\b|\bfail(?:ed|ure)?\b|\bfatal\b|\babort(?:ed)?\b|\bexception\b|"
    r"\btraceback\b|core dumped|segmentation fault|\bpanic\b|\bcrash(?:ed)?\b",
    re.IGNORECASE)
# Known benign uses of "error" that are normal, expected solver/diagnostic
# output rather than a fault -- without this, a naive keyword search would
# flag essentially every OpenFOAM job (which prints a "time step continuity
# errors" line every single iteration as routine, non-fatal diagnostics).
_GENERIC_ERROR_DENYLIST_RE = re.compile(
    r"time step continuity error|continuity errors|estimated error|"
    r"round-?off error|relative error|no error", re.IGNORECASE)
# Large binary/restart artifacts this tool must never read (see module
# docstring) -- skipped by suffix/prefix rather than size alone, since a
# half-written restart file can still be small.
_BINARY_SKIP_SUFFIXES = {
    ".tpr", ".trr", ".xtc", ".edr", ".cpt", ".gro", ".ndx",       # GROMACS
    ".dcd", ".coor", ".vel", ".xsc", ".psf",                       # NAMD
    ".nc", ".rst",                                                 # WRF/general
}
_BINARY_SKIP_PREFIXES = ("wrfrst_", "wrfbdy_", "wrfinput_", "wrfout_", "core.")
_GENERIC_SCAN_MAX_FILES = 40
_GENERIC_SCAN_TAIL_LIMIT = 100_000


def _is_generically_scannable(path: Path) -> bool:
    if path.suffix.lower() in _BINARY_SKIP_SUFFIXES:
        return False
    if path.name.startswith(_BINARY_SKIP_PREFIXES):
        return False
    return True


def scan_rundir_for_error_lines(rundir: Path) -> List[Tuple[str, str]]:
    """Every (filename, context) pair found by grepping for error/failed/
    fatal/... language across the job's run directory, skipping known-binary
    files. One representative match per file (the first), returned WITH a
    window of surrounding lines (see _extract_context) rather than the bare
    matching line, so the OTHER_ERROR fallback below isn't stuck with a
    single out-of-context line either."""
    found: List[Tuple[str, str]] = []
    try:
        files = sorted(
            (f for f in rundir.iterdir() if f.is_file() and _is_generically_scannable(f)),
            key=lambda f: f.name)
    except (OSError, NotADirectoryError):
        return found
    for f in files[:_GENERIC_SCAN_MAX_FILES]:
        text = read_tail(f, _GENERIC_SCAN_TAIL_LIMIT)
        if not text:
            continue
        for m in _GENERIC_ERROR_RE.finditer(text):
            line_start = text.rfind("\n", 0, m.start()) + 1
            line_end = text.find("\n", m.end())
            line_end = line_end if line_end != -1 else len(text)
            if _GENERIC_ERROR_DENYLIST_RE.search(text[line_start:line_end]):
                continue
            found.append((f.name, _extract_context(text, m.start(), m.end())))
            break
    return found


def generic_reclassify(rundir: Path) -> Optional[Tuple[str, str, Optional[str]]]:
    """Last-resort classification for a job the per-app classifier couldn't
    place: search the whole run directory, and if anything turns up, try
    the SAME specific cascade against it first (a real fault that just
    happened to be written somewhere other than the usual file) before
    falling back to OTHER_ERROR with the actual matched context as detail --
    always real quotes from that job's own output, never a guess."""
    hits = scan_rundir_for_error_lines(rundir)
    if not hits:
        return None
    for filename, context in hits:
        cat = classify_from_text(context)
        if cat:
            detail, node = extract_detail_and_node(cat, context)
            return cat, detail or context, node
    filename, context = hits[0]
    return OTHER_ERROR, f"{context}\n  (in {filename})", None


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------

@dataclass
class JobRecord:
    app: str
    job_id: str
    status: str          # OK / SLOW / FAILED / PENDING
    category: str
    detail: str = ""
    node: Optional[str] = None       # single node attributed to a failure (from error text)
    rundir: Optional[str] = None
    nodelist: Optional[str] = None   # the job's full SLURM nodelist (from nodelist.txt), any status


@dataclass
class AppResult:
    app: str
    records: List[JobRecord] = field(default_factory=list)
    manifest_warning: Optional[str] = None

    @property
    def total(self) -> int:
        return len(self.records)

    def count(self, category: str) -> int:
        return sum(1 for r in self.records if r.category == category)


# --------------------------------------------------------------------------
# Directory indexing (dirname pass + filename pass, mirrors the fix applied
# to SCRIPTS/verification/{gromacs,namd,openfoam}-verify-results.sh)
# --------------------------------------------------------------------------

_DIRNAME_JOBID_RE = re.compile(r"(?:^|[^0-9])([0-9]+)(?:[^0-9]|$)")


def build_index(app_dir: Path, err_filename_re: Optional[re.Pattern]) -> Dict[str, Path]:
    index: Dict[str, Path] = {}
    try:
        subdirs = [d for d in app_dir.iterdir() if d.is_dir()]
    except FileNotFoundError:
        return index

    for d in subdirs:
        # Only trust dirname-embedded IDs when the *whole* dirname is
        # numeric (true job-id-named dirs) -- "RUN-741" would otherwise
        # falsely index under "741".
        if d.name.isdigit():
            index[d.name] = d

    if err_filename_re is not None:
        for d in subdirs:
            try:
                names = [f.name for f in d.iterdir() if f.is_file()]
            except (OSError, NotADirectoryError):
                continue
            for name in names:
                m = err_filename_re.match(name)
                if m:
                    index.setdefault(m.group(1), d)
    return index


def read_job_ids(app_dir: Path, app: str) -> List[str]:
    manifest = app_dir / f"{app}_JobIDs.txt"
    if manifest.is_file():
        return [l.strip() for l in manifest.read_text(errors="replace").splitlines() if l.strip()]
    # Fallback: no manifest -> derive from whatever the index can see.
    log.warning("%s: no %s manifest, falling back to directory scan", app, manifest.name)
    return []


def read_failed_jobs_csv(path: Path) -> Dict[str, List[str]]:
    """Parse SCRIPTS/extract-nodes + run-verification.sh's combined
    failed-jobs.txt ("app,job_id" CSV, header row, app already whichever
    case extract-nodes derived it in -- lowercase from the *.txt summary
    basenames) into {APP: [job_id, ...]} keyed the way APP_CLASSIFIERS
    expects (upper-case). The file's first line is a "#"-prefixed
    disclaimer comment (see run-verification.sh's DISCLAIMER), not part of
    the CSV -- filtered out before csv.DictReader sees it, same convention
    every other reader of these generated files follows."""
    by_app: Dict[str, List[str]] = defaultdict(list)
    with path.open(newline="") as f:
        for row in csv.DictReader(line for line in f if not line.startswith("#")):
            app = (row.get("app") or "").strip().upper()
            job_id = (row.get("job_id") or "").strip()
            if app and job_id:
                by_app[app].append(job_id)
    return dict(by_app)


# --------------------------------------------------------------------------
# Per-app classifiers
# --------------------------------------------------------------------------

def classify_gromacs(rundir: Optional[Path], job_id: str, known_failed: bool = False) -> JobRecord:
    if rundir is None:
        return JobRecord("GROMACS", job_id, "PENDING", NO_OUTPUT_YET, "no run directory found")
    errfile = rundir / f"{job_id}.err"
    if not errfile.is_file():
        return JobRecord("GROMACS", job_id, "PENDING", NO_OUTPUT_YET,
                          "job slot exists but no .err produced yet", rundir=str(rundir))
    text = read_text(errfile)
    cat = classify_from_text(text)
    if cat:
        detail, node = extract_detail_and_node(cat, text)
        return JobRecord("GROMACS", job_id, "FAILED", cat, detail, node, str(rundir))

    # known_failed: verify-results.sh already decided this job is not OK,
    # so don't re-derive OK/SLOW here (that's the perf-range check
    # verification already ran) -- just fall through to UNKNOWN_INCOMPLETE
    # so analyze_app()'s generic whole-rundir scan gets a chance to pin the
    # actual cause down instead.
    runtime_txt = rundir / "runtime.txt"
    md_log = rundir / "md.log"
    if not known_failed and runtime_txt.is_file() and md_log.is_file():
        runtime_tail = read_tail(runtime_txt, 5_000)
        if "real" in runtime_tail:
            # Mirrors gromacs-verify-results.sh's `tail -2 md.log | head -1 | awk '{print $2}'`.
            nsperday = _parse_tail_first_field(read_tail(md_log, 5_000), n=2, field_idx=1)
            walltime = parse_real_walltime_seconds(runtime_tail)
            slow_detail = check_slow("GROMACS", {"nsperday": nsperday, "walltime": walltime})
            if slow_detail:
                return JobRecord("GROMACS", job_id, "SLOW", SLOW, slow_detail, rundir=str(rundir))
            return JobRecord("GROMACS", job_id, "OK", OK, rundir=str(rundir))
    return JobRecord("GROMACS", job_id, "FAILED", UNKNOWN_INCOMPLETE,
                      "ran but no recognizable success or error marker", rundir=str(rundir))


def classify_namd(rundir: Optional[Path], job_id: str, known_failed: bool = False) -> JobRecord:
    if rundir is None:
        return JobRecord("NAMD", job_id, "PENDING", NO_OUTPUT_YET, "no run directory found")
    errfile = rundir / f"err.{job_id}"
    output_file = rundir / "namd-cpu.output"
    text = read_text(errfile) if errfile.is_file() else ""
    cat = classify_from_text(text)
    output_tail = read_tail(output_file, 150_000) if output_file.is_file() else ""
    if not cat and output_tail:
        cat = classify_from_text(output_tail)
        text = text or output_tail
    if cat:
        detail, node = extract_detail_and_node(cat, text)
        return JobRecord("NAMD", job_id, "FAILED", cat, detail, node, str(rundir))

    # See classify_gromacs()'s known_failed comment -- same reasoning here.
    if not known_failed and "WallClock" in output_tail:
        nsperday, walltime = parse_namd_metrics(output_tail)
        slow_detail = check_slow("NAMD", {"nsperday": nsperday, "walltime": walltime})
        if slow_detail:
            return JobRecord("NAMD", job_id, "SLOW", SLOW, slow_detail, rundir=str(rundir))
        return JobRecord("NAMD", job_id, "OK", OK, rundir=str(rundir))
    if not errfile.is_file() and not output_file.is_file():
        return JobRecord("NAMD", job_id, "PENDING", NO_OUTPUT_YET,
                          "job slot exists but no output produced yet", rundir=str(rundir))
    return JobRecord("NAMD", job_id, "FAILED", UNKNOWN_INCOMPLETE,
                      "ran but no recognizable success or error marker", rundir=str(rundir))


def classify_openfoam(rundir: Optional[Path], job_id: str, known_failed: bool = False) -> JobRecord:
    if rundir is None:
        return JobRecord("OPENFOAM", job_id, "PENDING", NO_OUTPUT_YET, "no run directory found")
    errfile = rundir / f"job.{job_id}.err"
    # openfoamResult.txt can run into several MB for a solver that logs
    # every iteration (observed up to ~8.4MB) -- only its tail (the final
    # "real"/walltime line, or a late FATAL/Abort) is ever relevant here.
    result_file = rundir / "openfoamResult.txt"
    text = read_text(errfile) if errfile.is_file() else ""
    cat = classify_from_text(text)
    result_tail = read_tail(result_file, 100_000) if result_file.is_file() else ""
    if not cat and result_tail:
        cat2 = classify_from_text(result_tail)
        if cat2:
            cat, text = cat2, result_tail
    if cat:
        detail, node = extract_detail_and_node(cat, text)
        return JobRecord("OPENFOAM", job_id, "FAILED", cat, detail, node, str(rundir))

    # See classify_gromacs()'s known_failed comment -- same reasoning here.
    if not known_failed and "real" in result_tail:
        cds, walltime = parse_openfoam_metrics(result_tail)
        slow_detail = check_slow("OPENFOAM", {"cds": cds, "walltime": walltime})
        if slow_detail:
            return JobRecord("OPENFOAM", job_id, "SLOW", SLOW, slow_detail, rundir=str(rundir))
        return JobRecord("OPENFOAM", job_id, "OK", OK, rundir=str(rundir))
    if not errfile.is_file():
        return JobRecord("OPENFOAM", job_id, "PENDING", NO_OUTPUT_YET,
                          "job slot exists but no output produced yet", rundir=str(rundir))
    return JobRecord("OPENFOAM", job_id, "FAILED", UNKNOWN_INCOMPLETE,
                      "ran but no recognizable success or error marker", rundir=str(rundir))


_WRF_MAX_RANK_SCAN = 300


def classify_wrf(rundir: Optional[Path], job_id: str, known_failed: bool = False) -> JobRecord:
    if rundir is None:
        return JobRecord("WRF", job_id, "PENDING", NO_OUTPUT_YET, "no run directory found")
    rank0 = rundir / "rsl.error.0000"
    if not rank0.is_file():
        return JobRecord("WRF", job_id, "PENDING", NO_OUTPUT_YET,
                          "job slot exists but no rsl.error.0000 yet", rundir=str(rundir))
    # rsl.error.0000 runs ~150KB+ for a real domain; the "SUCCESS COMPLETE
    # WRF" marker is the very last line written, so a tail read is both
    # correct (a head-read would silently never see it) and cheap.
    text0 = read_tail(rank0, 50_000)
    # See classify_gromacs()'s known_failed comment -- same reasoning here.
    if not known_failed and "SUCCESS COMPLETE WRF" in text0:
        # WRF.result is a copy of the job's `time mpiexec...` capture (see
        # wrf.job.sh), same file wrf-verify-results.sh reads for walltime.
        result_file = rundir / "WRF.result"
        walltime = parse_real_walltime_seconds(read_tail(result_file, 5_000)) if result_file.is_file() else None
        slow_detail = check_slow("WRF", {"walltime": walltime})
        if slow_detail:
            return JobRecord("WRF", job_id, "SLOW", SLOW, slow_detail, rundir=str(rundir))
        return JobRecord("WRF", job_id, "OK", OK, rundir=str(rundir))

    hosts_file = rundir / "hosts.txt"
    hosts = hosts_file.read_text(errors="replace").splitlines() if hosts_file.is_file() else []

    # A crashing rank dies right after printing its error/backtrace, so
    # that's at (or very near) EOF too -- tail reads catch it just as
    # reliably as a full read while being far cheaper across ~100+ ranks.
    rank_files = sorted(rundir.glob("rsl.error.*"))[:_WRF_MAX_RANK_SCAN]
    for rf in rank_files:
        text = read_tail(rf, 50_000)
        cat = classify_from_text(text)
        if cat:
            detail, node = extract_detail_and_node(cat, text)
            if node is None:
                try:
                    rank = int(rf.suffix.lstrip("."))
                    node = hosts[rank] if rank < len(hosts) else None
                except (ValueError, IndexError):
                    node = None
            return JobRecord("WRF", job_id, "FAILED", cat, detail, node, str(rundir))

    return JobRecord("WRF", job_id, "FAILED", UNKNOWN_INCOMPLETE,
                      "no rank reached SUCCESS and no recognizable error pattern found",
                      rundir=str(rundir))


APP_CLASSIFIERS = {
    "GROMACS": (classify_gromacs, re.compile(r"^([0-9]+)\.err$")),
    "NAMD": (classify_namd, re.compile(r"^err\.([0-9]+)$")),
    "OPENFOAM": (classify_openfoam, re.compile(r"^job\.([0-9]+)\.err$")),
    "WRF": (classify_wrf, None),  # WRF dirs are always named exactly the job id
}


# --------------------------------------------------------------------------
# Orchestration
# --------------------------------------------------------------------------

def analyze_app(run_dir: Path, app: str, job_ids_override: Optional[List[str]] = None,
                 known_failed: bool = False) -> AppResult:
    """job_ids_override, when given (targeted/--failed-jobs-csv mode), skips
    the manifest-vs-directory reconciliation below entirely and analyzes
    exactly those job IDs -- verification (verify-results.sh, then
    extract-nodes) already decided which jobs are failed, so there's no
    "which jobs exist" question left to answer here, only "why did each one
    fail". known_failed is threaded into the classifiers so they trust that
    same verdict instead of re-deriving OK/SLOW themselves."""
    classifier, err_re = APP_CLASSIFIERS[app]
    app_dir = run_dir / app
    if not app_dir.is_dir():
        log.warning("%s: directory not found under %s, skipping", app, run_dir)
        return AppResult(app=app)

    t0 = time.time()
    index = build_index(app_dir, err_re)

    if job_ids_override is not None:
        job_ids = sorted(set(job_ids_override), key=lambda s: (len(s), s))
        manifest_warning = None
    else:
        manifest_ids = read_job_ids(app_dir, app)
        dir_ids = set(index.keys())

        # A manifest that doesn't match the run directories actually present
        # in this snapshot must never silently hide real output sitting on
        # disk -- found 2026-08-06 against bk-06August2026: NAMD_JobIDs.txt
        # listed 410 job IDs from a LATER submission batch (266682-267091)
        # with ZERO overlap against the 1157 NAMD run dirs actually backed
        # up in that snapshot (262255-266426), so every "known" NAMD job in
        # the manifest pointed at nothing while the directory tree held real
        # (unscanned) results the whole time. Scan the union of both; only
        # warn loudly when they diverge so a mismatch is never silently
        # absorbed.
        manifest_id_set = set(manifest_ids)
        overlap = manifest_id_set & dir_ids
        manifest_warning = None
        if manifest_ids and dir_ids and not overlap:
            manifest_warning = (
                f"{app}_JobIDs.txt manifest ({len(manifest_ids):,} IDs, "
                f"{min(manifest_ids)}..{max(manifest_ids)}) has ZERO overlap with "
                f"the {len(dir_ids):,} run directories actually indexed under "
                f"{app_dir} ({min(dir_ids, key=lambda s: (len(s), s))}.."
                f"{max(dir_ids, key=lambda s: (len(s), s))}) -- manifest looks "
                f"stale/out of sync with this run-dir snapshot. Scanning BOTH "
                f"so real output on disk isn't skipped; treat 'total' below as "
                f"the union, not the manifest's own count.")
            log.warning("%s", manifest_warning)
        job_ids = sorted(manifest_id_set | dir_ids, key=lambda s: (len(s), s)) if (manifest_ids or dir_ids) else []

    result = AppResult(app=app, manifest_warning=manifest_warning)
    generic_rescues = 0
    for job_id in job_ids:
        rundir = index.get(job_id)
        record = classifier(rundir, job_id, known_failed=known_failed)
        record.nodelist = read_nodelist(rundir)
        # The targeted per-app cascade only reads the one or two files this
        # app is known to write results to. If it couldn't place the job
        # (no recognized error, no success marker either) but a run
        # directory does exist, fall back to a generic error/failed/fatal
        # search across every file actually in it -- catches faults that
        # landed somewhere the targeted check doesn't look, instead of
        # silently collapsing into an opaque "unknown"/"pending" bucket.
        if rundir is not None and record.category in (UNKNOWN_INCOMPLETE, NO_OUTPUT_YET):
            generic = generic_reclassify(rundir)
            if generic:
                cat, detail, node = generic
                record.status = "FAILED"
                record.category = cat
                record.detail = detail
                record.node = node
                generic_rescues += 1
        result.records.append(record)

    log.info("%s: classified %d jobs (%d indexed dirs, %d via generic directory scan) in %.1fs",
              app, len(result.records), len(index), generic_rescues, time.time() - t0)
    return result


def detect_mass_cancel_events(all_results: Dict[str, AppResult], threshold: int) -> List[Tuple[str, str, int]]:
    """Group EXTERNAL_CANCEL records by (app, timestamp) to tell a single
    systemic cancellation event apart from many independent incidents."""
    groups: Dict[Tuple[str, str], int] = defaultdict(int)
    # extract_detail_and_node() always puts "{reason} @ {ts}" as detail's
    # first line, with any extra context lines (if present) after it -- not
    # anchored to end-of-string since detail is no longer guaranteed to end
    # with the timestamp.
    ts_re = re.compile(r"@ (\S+)")
    for app, res in all_results.items():
        for r in res.records:
            if r.category == EXTERNAL_CANCEL:
                m = ts_re.search(r.detail)
                ts = m.group(1) if m else "unknown-time"
                groups[(app, ts)] += 1
    return sorted([(app, ts, n) for (app, ts), n in groups.items() if n >= threshold],
                  key=lambda x: -x[2])


def rank_faulty_nodes(all_results: Dict[str, AppResult], top_n: int) -> List[Tuple[str, int, Counter]]:
    node_counts: Counter = Counter()
    node_categories: Dict[str, Counter] = defaultdict(Counter)
    for res in all_results.values():
        for r in res.records:
            if r.node and r.category in NODE_ATTRIBUTABLE_CATEGORIES:
                node_counts[r.node] += 1
                node_categories[r.node][r.category] += 1
    return [(node, n, node_categories[node]) for node, n in node_counts.most_common(top_n)]


def detect_retry_slots(run_dir: Path, apps: List[str]) -> Dict[str, int]:
    """Count RUN-N slot directories that contain more than one job's error
    file -- evidence the slot was reused after a failed/short-lived attempt
    within the same snapshot."""
    retries: Dict[str, int] = {}
    for app in apps:
        _, err_re = APP_CLASSIFIERS[app]
        if err_re is None:
            continue
        app_dir = run_dir / app
        if not app_dir.is_dir():
            continue
        count = 0
        for d in app_dir.iterdir():
            if not d.is_dir():
                continue
            try:
                hits = sum(1 for f in d.iterdir() if f.is_file() and err_re.match(f.name))
            except (OSError, NotADirectoryError):
                continue
            if hits > 1:
                count += 1
        retries[app] = count
    return retries


# --------------------------------------------------------------------------
# Plot 1: Overall error stats
# --------------------------------------------------------------------------

_PIE_MAX_SLICES = 6  # part-to-whole only reads at a glance up to ~6 segments;
                     # smaller categories fold into "Other" -- the full,
                     # uncapped breakdown lives in the detail panel + txt report.


def _first_example(res_by_app: Dict[str, AppResult], category: str) -> Optional[Tuple[str, str, str]]:
    """First (app, job_id, detail) record found in this category, in a
    stable app-then-job-id order, for the "e.g." line under each category."""
    for app in sorted(res_by_app):
        for r in res_by_app[app].records:
            if r.category == category and r.detail:
                return app, r.job_id, r.detail
    return None


def plot_overall_stats(all_results: Dict[str, AppResult], output_path: Path,
                        run_label: Optional[str] = None) -> None:
    """Pure error composition: only real, identified failure types
    (FAILURE_CATEGORIES) -- no OK, no SLOW, no NO_OUTPUT_YET. Those three
    are job STATUSES, not errors -- overall success/slow/failed counts are
    already covered by the verification-side plot (CRON/graph/
    atbench_analyzer.py), so this tool stays focused on its actual job:
    what exactly failed, and how often."""
    run_label = run_label or datetime.now().strftime("%d %B %Y")

    total = sum(r.total for r in all_results.values())

    cat_counts = Counter()
    for res in all_results.values():
        for r in res.records:
            if r.category in FAILURE_CATEGORIES:
                cat_counts[r.category] += 1

    total_failed = sum(cat_counts.values())
    if total_failed == 0:
        log.warning("No errors to plot for overall stats.")
        return

    ordered_cats = [c for c, _ in cat_counts.most_common()]

    # ---- Pie slices: every problem category (top N by count, tail folded
    # into "Other"). Category identity keeps its fixed CATEGORY_COLORS hue
    # everywhere; only "Other" uses a neutral gray since it's not a single
    # error type.
    pie_labels, pie_values, pie_colors = [], [], []
    head_cats = ordered_cats[:_PIE_MAX_SLICES]
    tail_cats = ordered_cats[_PIE_MAX_SLICES:]
    for c in head_cats:
        pie_labels.append(c.replace("_", " ").title())
        pie_values.append(cat_counts[c])
        pie_colors.append(CATEGORY_COLORS.get(c, "#999999"))
    if tail_cats:
        other_n = sum(cat_counts[c] for c in tail_cats)
        pie_labels.append(f"Other ({len(tail_cats)} types)")
        pie_values.append(other_n)
        pie_colors.append("#5A5A5A")

    # ---- Detail panel: EVERY failure category gets a row -- count, % of
    # all failures, and one real example ("e.g. APP job 12345: <snippet>")
    # pulled straight from that job's actual error text, so nothing is
    # summarized away.
    n_rows = len(ordered_cats)
    fig_h = max(7.5, 2.6 + n_rows * 1.3)
    fig, (ax_pie, ax_detail) = plt.subplots(
        1, 2, figsize=(17, fig_h), gridspec_kw={"width_ratios": [1, 1.5]})

    def _autopct(pct: float) -> str:
        return f"{pct:.1f}%" if pct >= 3 else ""

    wedges, _, _ = ax_pie.pie(
        pie_values, colors=pie_colors, autopct=_autopct, pctdistance=0.78,
        startangle=90, counterclock=False,
        wedgeprops={"edgecolor": "white", "linewidth": 1.5},
        textprops={"fontsize": 9.5, "color": "white", "fontweight": "bold"})
    ax_pie.legend(
        wedges, [f"{l}  —  {v:,}" for l, v in zip(pie_labels, pie_values)],
        loc="upper center", bbox_to_anchor=(0.5, -0.02), fontsize=9.5,
        frameon=False, ncol=1)
    ax_pie.set_title(f"Error Types  (n = {total_failed:,} failed jobs)", fontsize=14.5, fontweight="bold")

    ax_detail.axis("off")
    ax_detail.text(0.0, 1.0, "Errors & Frequency", fontsize=15, fontweight="bold",
                    transform=ax_detail.transAxes, va="top")
    ax_detail.text(0.0, 1.0 - 0.55 / fig_h,
                    "Every error type below with how many jobs it hit and one real "
                    "example pulled from that job's own output:",
                    fontsize=9.5, color="dimgrey", style="italic",
                    transform=ax_detail.transAxes, va="top")

    row_h = 1.30 / fig_h  # axes-fraction consumed per detail row
    y = 1.0 - 1.15 / fig_h
    for c in ordered_cats:
        n = cat_counts[c]
        pct = n / total_failed * 100 if total_failed else 0.0
        ax_detail.text(0.0, y, f"{c.replace('_', ' ').title()}", fontsize=11.5,
                        fontweight="bold", color=CATEGORY_COLORS.get(c, "#333333"),
                        transform=ax_detail.transAxes, va="top")
        ax_detail.text(1.0, y, f"{n:,} jobs  ({pct:.1f}%)", fontsize=10.5, fontweight="bold",
                        color="#333333", ha="right", transform=ax_detail.transAxes, va="top")
        y -= row_h * 0.30
        example = _first_example(all_results, c)
        if example:
            app, job_id, detail = example
            snippet = textwrap.shorten(detail, width=98, placeholder=" ...")
            ax_detail.text(0.02, y, f'e.g. {app} job {job_id}: "{snippet}"',
                            fontsize=9.2, color="dimgrey", style="italic",
                            transform=ax_detail.transAxes, va="top")
        y -= row_h * 0.32
        # "More description" than count+example alone: which app(s) this
        # category actually hit and how many distinct nodes it's spread
        # across -- tells apart "one bad node, one app" from "a systemic
        # issue touching many nodes and/or many apps" at a glance.
        apps_hit = sorted(app for app, res in all_results.items() if res.count(c) > 0)
        nodes_hit = {r.node for res in all_results.values()
                     for r in res.records if r.category == c and r.node}
        extra_bits = [f"apps: {', '.join(apps_hit)}"]
        if nodes_hit:
            extra_bits.append(f"{len(nodes_hit)} distinct node(s)")
        ax_detail.text(0.02, y, "  •  ".join(extra_bits), fontsize=8.8, color="#8A8A8A",
                        transform=ax_detail.transAxes, va="top")
        y -= row_h * 0.38

    fail_rate = total_failed / total * 100 if total else 0.0
    fig.suptitle(
        f"AT-Bench Job Debug Analysis  —  {run_label}\n"
        f"{total_failed:,} failed of {total:,} jobs scanned  ({fail_rate:.1f}%)",
        fontsize=12, color="dimgrey", y=1.03)
    fig.text(0.5, -0.02, DISCLAIMER, ha="center", va="top", fontsize=7, color="grey")
    fig.tight_layout()
    fig.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    log.info("Saved overall stats chart -> %s", output_path)


# --------------------------------------------------------------------------
# Plot 2: Application-wise error breakdown
# --------------------------------------------------------------------------

def plot_app_breakdown(all_results: Dict[str, AppResult], output_path: Path,
                        run_label: Optional[str] = None) -> None:
    """Pure error breakdown per app -- FAILURE_CATEGORIES only. SLOW and
    NO_OUTPUT_YET are job statuses, not errors, and have no place here; each
    has its own node-list .txt file instead. An app with zero identified
    errors simply doesn't appear on this chart -- that's a true, useful
    fact, not something to paper over with an empty bar."""
    run_label = run_label or datetime.now().strftime("%d %B %Y")

    def _error_count(res: AppResult) -> int:
        return sum(res.count(c) for c in FAILURE_CATEGORIES)

    apps = [a for a in all_results if _error_count(all_results[a]) > 0]
    if not apps:
        log.warning("No errors recorded for any app; skipping app-wise breakdown.")
        return

    present_cats = [c for c in FAILURE_CATEGORIES
                    if any(all_results[a].count(c) > 0 for a in apps)]

    x = np.arange(len(apps))
    bar_width = 0.6
    fig, ax = plt.subplots(figsize=(13, 9.5))

    bottoms = np.zeros(len(apps))
    for cat in present_cats:
        values = np.array([all_results[a].count(cat) for a in apps], dtype=float)
        bars = ax.bar(x, values, width=bar_width, bottom=bottoms,
                      label=cat.replace("_", " ").title(),
                      color=CATEGORY_COLORS.get(cat, "#999999"), edgecolor="white", linewidth=0.8)
        for rect, v, base in zip(bars, values, bottoms):
            if v > 0 and v / max(bottoms.max() + values.max(), 1) > 0.03:
                ax.text(rect.get_x() + rect.get_width() / 2, base + v / 2, f"{int(v):,}",
                        ha="center", va="center", fontsize=9, color="white", fontweight="bold")
        bottoms += values

    # Per app: who's the #1 issue and how many jobs did it hit -- computed
    # once here, then used both for the prominent headline above the bar
    # and the exact-text caption below (dominant error requested to be
    # printed for each application, not buried in the legend).
    top_issue: Dict[str, Tuple[Optional[str], int]] = {}
    for a in apps:
        res = all_results[a]
        top_cat, top_n = None, 0
        for cat in present_cats:
            n = res.count(cat)
            if n > top_n:
                top_cat, top_n = cat, n
        top_issue[a] = (top_cat, top_n)

    for xi, a in enumerate(apps):
        res = all_results[a]
        top_cat, top_n = top_issue[a]
        base_y = bottoms[xi] + max(bottoms) * 0.02
        ax.text(xi, base_y, f"Errored: {_error_count(res):,} / {res.total:,}",
                ha="center", va="bottom", fontsize=10.5, fontweight="bold", color="#222222")
        if top_cat:
            # Dark-enough variant of the category color for legibility as
            # text (some category colors, e.g. NO_OUTPUT_YET's light gray,
            # are too low-contrast used directly on white).
            face_color = CATEGORY_COLORS.get(top_cat, "#222222")
            r, g, b = mcolors.to_rgb(face_color)
            luminance = 0.299 * r + 0.587 * g + 0.114 * b
            text_color = face_color if luminance < 0.65 else "#555555"
            # "More description" than just the raw count: what share of
            # THIS app's own jobs the dominant cause hit, plus how many
            # distinct nodes it's spread across -- one node repeatedly
            # failing reads very differently from 41 different nodes all
            # hitting the same launch error.
            pct_of_app = top_n / res.total * 100 if res.total else 0.0
            dominant_nodes = {r.node for r in res.records if r.category == top_cat and r.node}
            node_bit = f", {len(dominant_nodes)} node(s)" if dominant_nodes else ""
            ax.text(xi, base_y + max(bottoms) * 0.05,
                    f"Dominant: {top_cat.replace('_', ' ').title()} "
                    f"({top_n:,}, {pct_of_app:.0f}% of app{node_bit})",
                    ha="center", va="bottom", fontsize=10.5, fontweight="bold", color=text_color)

    ax.set_xticks(x)
    ax.set_xticklabels(apps, fontsize=13)
    ax.set_ylabel("Number of Failed Jobs", fontsize=13)
    ax.set_ylim(0, max(bottoms) * 1.24 if bottoms.max() > 0 else 1)
    ax.set_title("Error Types by Application", fontsize=16, fontweight="bold", pad=30)
    ax.text(0.5, 1.02, f"AT-Bench Job Debug Analysis  —  {run_label}",
            transform=ax.transAxes, ha="center", va="bottom", fontsize=11, color="dimgrey")
    ax.legend(loc="upper right", frameon=True, fontsize=9, ncol=1)
    ax.grid(axis="y", linestyle=":", alpha=0.5)

    # The dominant issue + count is already announced above the bar; this
    # boxed caption below the x-tick label supplies the exact quoted text
    # (data-x, axes-y blended transform so it tracks the bar regardless of
    # y-scale; the box keeps neighboring apps' captions from bleeding into
    # each other at 4-wide). Wide enough (and enough lines) that the actual
    # error text is readable rather than truncated -- this quoted example
    # is the whole point of the caption. Computed in two passes: gather
    # every app's wrapped caption first so the figure only reserves as much
    # bottom margin as the LONGEST one actually needs, instead of a fixed
    # margin that's mostly empty space for a short caption (or still too
    # cramped for a long one).
    captions: Dict[str, List[str]] = {}
    for a in apps:
        res = all_results[a]
        top_cat, top_n = top_issue[a]
        if top_cat is None:
            continue
        example = _first_example({a: res}, top_cat)
        if not example:
            continue
        _, job_id, detail = example
        example_node = next((r.node for r in res.records
                              if r.category == top_cat and r.job_id == job_id and r.node), None)
        job_bit = f"job {job_id} ({example_node})" if example_node else f"job {job_id}"
        wrapped = textwrap.wrap(f'{job_bit}: "{detail}"', width=46)
        caption_lines = wrapped[:7]
        if len(wrapped) > 7:
            caption_lines[-1] = caption_lines[-1].rstrip() + " ..."
        captions[a] = caption_lines

    max_caption_lines = max((len(c) for c in captions.values()), default=0)
    xaxis_trans = ax.get_xaxis_transform()
    for xi, a in enumerate(apps):
        caption_lines = captions.get(a)
        if not caption_lines:
            continue
        ax.text(xi, -0.10, "\n".join(caption_lines), transform=xaxis_trans,
                ha="center", va="top", fontsize=9.5, color="#333333",
                bbox={"boxstyle": "round,pad=0.5", "fc": "#F5F5F5", "ec": "#D0D0D0", "lw": 0.6})

    fig.text(0.5, -0.02, DISCLAIMER, ha="center", va="top", fontsize=7, color="grey")
    fig.subplots_adjust(bottom=min(0.55, max(0.20, 0.14 + 0.045 * max_caption_lines)))
    fig.savefig(output_path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    log.info("Saved app-wise breakdown chart -> %s", output_path)


# --------------------------------------------------------------------------
# CSV + console report
# --------------------------------------------------------------------------

def write_csv(all_results: Dict[str, AppResult], csv_path: Path) -> None:
    """FAILED jobs only. OK/SLOW/PENDING rows are job statuses, not
    failures, and just dilute the file this tool's actual users (debugging
    why jobs died) have to filter through -- successful/slow/pending job
    IDs already get their own clean lists from write_job_status_lists()."""
    n_written = 0
    with csv_path.open("w", newline="") as f:
        f.write(f"# {DISCLAIMER}\n")
        writer = csv.writer(f)
        writer.writerow(["app", "job_id", "status", "category", "node", "detail", "rundir"])
        for res in all_results.values():
            for r in res.records:
                if r.status != "FAILED":
                    continue
                writer.writerow([r.app, r.job_id, r.status, r.category, r.node or "", r.detail, r.rundir or ""])
                n_written += 1
    log.info("Saved %d failed-job record(s) -> %s", n_written, csv_path)


_ERROR_REPORT_WRAP = 78
_DETAIL_NORMALIZE_RE = re.compile(r"\d+")


def _normalize_detail(detail: str) -> str:
    """Collapse a per-job detail string down to its underlying error
    PATTERN by masking out embedded numbers (job IDs, ranks, ports, PIDs,
    line numbers, ...) -- e.g. 41 NAMD jobs each produce their own "Unable
    to create step for job 274132: ..." / "...274136: ..." message that
    differ ONLY by that job's own ID; without this they'd report as 41
    separate one-off errors instead of the single real cause they are."""
    return _DETAIL_NORMALIZE_RE.sub("#", detail)


def write_error_report(all_results: Dict[str, AppResult], txt_path: Path,
                        run_label: Optional[str] = None) -> None:
    """Crisp, error-TYPE-first summary: what kinds of errors happened, how
    often, which apps and which nodes they hit -- the "why" verification
    itself never determines. This is intentionally not a per-job transcript
    (job_debug_records.csv already has one row per failed job for that);
    distinct messages within a category are grouped by NORMALIZED pattern
    (see _normalize_detail) so jobs failing the exact same way collapse
    into one entry instead of fragmenting into near-duplicates."""
    run_label = run_label or datetime.now().strftime("%d %B %Y")
    total = sum(r.total for r in all_results.values())

    overall_counts = Counter()
    for res in all_results.values():
        for r in res.records:
            if r.category in FAILURE_CATEGORIES:
                overall_counts[r.category] += 1
    total_failed = sum(overall_counts.values())

    lines: List[str] = []
    lines.append(f"# {DISCLAIMER}")
    lines.append("=" * 78)
    lines.append("AT-BENCH JOB DEBUG ANALYSIS -- ERROR SUMMARY")
    lines.append(f"Run: {run_label}   |   Total jobs analyzed: {total:,}")
    lines.append("=" * 78)

    if overall_counts:
        lines.append("")
        lines.append("FREQUENCY BY ERROR TYPE")
        lines.append("-" * 78)
        for cat, n in overall_counts.most_common():
            pct = n / total_failed * 100 if total_failed else 0.0
            lines.append(f"  {cat.replace('_', ' ').title():<24s} {n:>6,}  ({pct:5.1f}%)")

    for cat in FAILURE_CATEGORIES:
        cat_records = [r for res in all_results.values() for r in res.records if r.category == cat]
        if not cat_records:
            continue
        n = len(cat_records)
        pct = n / total_failed * 100 if total_failed else 0.0

        lines.append("")
        lines.append("=" * 78)
        lines.append(f"[{cat.replace('_', ' ').title()}]  --  {n:,} job(s)  ({pct:.1f}% of all failures)")
        lines.append("=" * 78)

        apps_hit = sorted({r.app for r in cat_records})
        lines.append(f"Apps affected  : {', '.join(apps_hit)}")

        nodes = sorted({r.node for r in cat_records if r.node})
        if nodes:
            wrapped_nodes = textwrap.wrap(", ".join(nodes), width=_ERROR_REPORT_WRAP - 17) or [""]
            lines.append(f"Affected nodes : {len(nodes)} -- {wrapped_nodes[0]}")
            for extra in wrapped_nodes[1:]:
                lines.append(" " * 17 + extra)
        else:
            lines.append("Affected nodes : (none attributable)")

        # Distinct error PATTERNS within this category (see
        # _normalize_detail), most frequent first -- the actual "brief
        # summary of errors and their frequency".
        by_pattern: Dict[str, List[JobRecord]] = defaultdict(list)
        for r in cat_records:
            key = _normalize_detail(r.detail) if r.detail else "(no further detail captured)"
            by_pattern[key].append(r)

        lines.append("")
        for recs in sorted(by_pattern.values(), key=len, reverse=True):
            example_rec = next((r for r in recs if r.detail), None)
            lines.append(f"  Example (job {example_rec.job_id}):" if example_rec
                         else "  (no further detail captured)")
            if example_rec:
                # Preserve the real line breaks in the captured context
                # (see _extract_context) instead of flattening it into one
                # wrapped paragraph -- that structure (which line said what)
                # is exactly what a single-line summary was losing.
                for cline in example_rec.detail.splitlines() or [example_rec.detail]:
                    for wline in (textwrap.wrap(cline, width=_ERROR_REPORT_WRAP - 4) or [""]):
                        lines.append(f"    {wline}")
            lines.append(f"  -- {len(recs):,} job(s) affected by this pattern")
            lines.append("")

    txt_path.write_text("\n".join(lines) + "\n")
    log.info("Saved error summary -> %s", txt_path)


_JOB_STATUS_LIST_LABELS = [("successful", "OK"), ("slow", "SLOW"), ("failed", "FAILED")]


def write_job_status_lists(all_results: Dict[str, AppResult], out_dir: Path) -> None:
    """Plain job-ID-only lists, one file per app per status (successful /
    slow / failed) under job_id_lists/, one job ID per line -- no nodelist,
    no error text, nothing to parse. Straight from this run's own
    classification (the job IDs were already resolved while scanning), so
    each list is ready to drop straight into another script: loop over
    <APP>_failed.txt to resubmit only what actually failed, or diff/exclude
    against <APP>_successful.txt to skip jobs already known good."""
    lists_dir = out_dir / "job_id_lists"
    lists_dir.mkdir(parents=True, exist_ok=True)
    for app, res in all_results.items():
        if res.total == 0:
            continue
        for label, status in _JOB_STATUS_LIST_LABELS:
            ids = sorted((r.job_id for r in res.records if r.status == status),
                         key=lambda s: (len(s), s))
            out_path = lists_dir / f"{app}_{label}.txt"
            out_path.write_text("\n".join(ids) + ("\n" if ids else ""))
            log.info("Saved %d %s %s job ID(s) -> %s", len(ids), app, label, out_path)


_NODE_STATUS_LABELS = [("success", "OK"), ("slow", "SLOW"), ("failed", "FAILED")]


def write_node_status_lists(all_results: Dict[str, AppResult], out_dir: Path) -> None:
    """Individual compute-node lists per status (success / slow / failed),
    under node_lists/ -- same technique as SCRIPTS/extract-nodes (expand
    each job's SLURM Nodelist range via `scontrol show hostnames`, dedupe,
    sort) but driven directly off this run's own already-classified job
    records instead of re-parsing a 'A.SUCCESSFULL JOBS' / 'B.SLOW JOBS' /
    'C.INCOMPLETE JOBS' summary.txt.

    Written both ways:
      * per app  -- <APP>_success-nodes.txt / _slow-nodes.txt / _failed-nodes.txt
                     (tells a NAMD node problem apart from an OpenFOAM one)
      * combined -- success-nodes.txt / slow-nodes.txt / failed-nodes.txt
                     (matches extract-nodes' own flat, cross-app output)
    """
    lists_dir = out_dir / "node_lists"
    lists_dir.mkdir(parents=True, exist_ok=True)

    combined: Dict[str, set] = {label: set() for label, _ in _NODE_STATUS_LABELS}
    missing_nodelist = 0

    for app, res in all_results.items():
        if res.total == 0:
            continue
        for label, status in _NODE_STATUS_LABELS:
            nodes: set = set()
            for r in res.records:
                if r.status != status:
                    continue
                if not r.nodelist:
                    missing_nodelist += 1
                    continue
                nodes.update(expand_hostlist(r.nodelist))
            combined[label].update(nodes)
            out_path = lists_dir / f"{app}_{label}-nodes.txt"
            out_path.write_text("\n".join(sorted(nodes)) + ("\n" if nodes else ""))
            log.info("Saved %d %s %s node(s) -> %s", len(nodes), app, label, out_path)

    for label, _ in _NODE_STATUS_LABELS:
        nodes = combined[label]
        out_path = lists_dir / f"{label}-nodes.txt"
        out_path.write_text("\n".join(sorted(nodes)) + ("\n" if nodes else ""))
        log.info("Saved %d combined %s node(s) -> %s", len(nodes), label, out_path)

    if missing_nodelist:
        log.warning("%d job(s) had no captured nodelist.txt -- excluded from node lists", missing_nodelist)


def print_report(all_results: Dict[str, AppResult], mass_events: List[Tuple[str, str, int]],
                  top_nodes: List[Tuple[str, int, Counter]], retries: Dict[str, int]) -> None:
    print("\n" + "=" * 72)
    print("AT-BENCH JOB DEBUG ANALYSIS")
    print("=" * 72)

    for app, res in all_results.items():
        if res.total == 0:
            continue
        print(f"\n[{app}]  total={res.total}  OK={res.count(OK)}  "
              f"slow={res.count(SLOW)}  "
              f"pending={res.count(NO_OUTPUT_YET)}  "
              f"failed={res.total - res.count(OK) - res.count(SLOW) - res.count(NO_OUTPUT_YET)}")
        if res.manifest_warning:
            print(f"    !! MANIFEST/DIRECTORY MISMATCH: {res.manifest_warning}")
        for cat in NON_OK_CATEGORIES:
            n = res.count(cat)
            if n:
                pct = n / res.total * 100
                print(f"    {cat:<20s} {n:>5d}  ({pct:5.1f}%)")
        if app in retries and retries[app]:
            print(f"    -> {retries[app]} run slot(s) show a prior retry/resubmission in this snapshot")

    if mass_events:
        print("\n[Mass cancellation events]  (>= threshold jobs cancelled at the exact same instant)")
        for app, ts, n in mass_events:
            print(f"    {app}: {n} jobs cancelled simultaneously at {ts} "
                  f"-- treat as ONE systemic event (reservation end / scancel), not {n} separate faults")

    if top_nodes:
        print("\n[Top suspect compute nodes]  (appear across NODE_FAULT/SEGFAULT/MPI_ABORT/APP_FATAL failures)")
        for node, n, cats in top_nodes:
            cat_str = ", ".join(f"{c}={v}" for c, v in cats.most_common())
            print(f"    {node:<14s} {n:>3d} failure(s)  [{cat_str}]")

    print("\n" + "=" * 72 + "\n")


# --------------------------------------------------------------------------
# Public entry point
# --------------------------------------------------------------------------

def run_analysis(
    run_dir: str,
    output_dir: str,
    apps: Optional[List[str]] = None,
    top_nodes: int = 15,
    mass_cancel_threshold: int = 5,
    run_label: Optional[str] = None,
    failed_jobs_csv: Optional[str] = None,
) -> Dict[str, AppResult]:
    """failed_jobs_csv (targeted mode): an "app,job_id" CSV -- the combined
    failed-jobs.txt run-verification.sh's own verification stage (Section
    1c) already produced from each verify-results.sh's C.INCOMPLETE/
    C.UNSUCCESFULL section. When given, this tool trusts that job list and
    verdict completely instead of re-deriving "which jobs failed" itself
    (see analyze_app()/classify_*()'s known_failed): it only scans exactly
    those jobs, skips the OK/SLOW perf-range re-check verify-results.sh
    already did, and skips writing the successful/slow job-ID and node
    lists (write_job_status_lists/write_node_status_lists) since those
    would just restate what SCRIPTS/extract-nodes' nodes/ dir already has --
    the whole point of this tool becomes purely the deep dive verification
    doesn't do: WHY each already-known-failed job failed.
    """
    run_dir_p = Path(run_dir).expanduser().resolve()
    out_dir_p = Path(output_dir).expanduser().resolve()
    out_dir_p.mkdir(parents=True, exist_ok=True)

    if not run_dir_p.is_dir():
        raise FileNotFoundError(f"Run directory not found: {run_dir_p}")

    run_label = run_label or datetime.now().strftime("%d %B %Y")

    targeted_mode = failed_jobs_csv is not None
    failed_jobs_by_app: Dict[str, List[str]] = {}
    if targeted_mode:
        csv_path = Path(failed_jobs_csv).expanduser().resolve()
        if not csv_path.is_file():
            raise FileNotFoundError(f"failed-jobs CSV not found: {csv_path}")
        failed_jobs_by_app = read_failed_jobs_csv(csv_path)
        apps = apps or list(failed_jobs_by_app.keys())
        apps = [a for a in apps if a in failed_jobs_by_app]
        log.info("Targeted mode: analyzing %d already-known-failed job(s) from %s across: %s",
                 sum(len(v) for v in failed_jobs_by_app.values()), csv_path, ", ".join(apps) or "(none)")
    else:
        apps = apps or DEFAULT_APPS
        log.info("Scanning %s for apps: %s", run_dir_p, ", ".join(apps))

    all_results: Dict[str, AppResult] = {}
    for app in apps:
        if app not in APP_CLASSIFIERS:
            log.warning("No classifier for app '%s', skipping", app)
            continue
        job_ids_override = failed_jobs_by_app.get(app) if targeted_mode else None
        all_results[app] = analyze_app(run_dir_p, app, job_ids_override=job_ids_override,
                                        known_failed=targeted_mode)

    mass_events = detect_mass_cancel_events(all_results, mass_cancel_threshold)
    top_node_list = rank_faulty_nodes(all_results, top_nodes)
    retries = detect_retry_slots(run_dir_p, list(all_results.keys()))

    print_report(all_results, mass_events, top_node_list, retries)
    write_csv(all_results, out_dir_p / "job_debug_records.csv")
    write_error_report(all_results, out_dir_p / "error_report.txt", run_label=run_label)
    if not targeted_mode:
        # Plain successful/slow/failed job-ID and node lists duplicate what
        # SCRIPTS/extract-nodes + run-verification.sh's Section 1b/1c already
        # write into LOGS/<date>/nodes/ -- only produce them here in the
        # untargeted (full-scan) mode where nothing upstream already has.
        write_job_status_lists(all_results, out_dir_p)
        write_node_status_lists(all_results, out_dir_p)
    plot_overall_stats(all_results, out_dir_p / "overall_error_stats.png", run_label=run_label)
    plot_app_breakdown(all_results, out_dir_p / "app_wise_error_breakdown.png", run_label=run_label)

    return all_results


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze raw AT-Bench job-output directories to find and "
                    "chart WHY jobs failed (not just how many).")
    parser.add_argument("--run-dir", required=True,
                        help="Path to a day's application-output tree, e.g. "
                             "scratch/AT-RUN/bk-06August2026 (contains GROMACS/, NAMD/, "
                             "OPENFOAM/, WRF/ subdirectories)")
    parser.add_argument("--output-dir", required=True,
                        help="Directory to write the CSV + PNG charts into")
    parser.add_argument("--apps", nargs="*", default=None,
                        help=f"App names to analyze (default: {DEFAULT_APPS})")
    parser.add_argument("--top-nodes", type=int, default=15,
                        help="How many top suspect compute nodes to report (default: 15)")
    parser.add_argument("--mass-cancel-threshold", type=int, default=5,
                        help="Minimum simultaneous cancellations to flag as one "
                             "systemic event rather than independent faults (default: 5)")
    parser.add_argument("--run-label", default=None,
                        help="Label printed on the charts (default: today's date)")
    parser.add_argument("--failed-jobs-csv", default=None,
                        help="Targeted mode: an 'app,job_id' CSV (e.g. "
                             "run-verification.sh's LOGS/<date>/nodes/failed-jobs.txt) "
                             "listing exactly the jobs verification already determined "
                             "failed. When given, only those jobs are analyzed -- no "
                             "full-run scan, no re-deriving OK/SLOW -- and the plain "
                             "job-ID/node-list outputs are skipped since they'd just "
                             "duplicate what verification already wrote.")
    args = parser.parse_args()

    try:
        run_analysis(
            run_dir=args.run_dir,
            output_dir=args.output_dir,
            apps=args.apps,
            top_nodes=args.top_nodes,
            mass_cancel_threshold=args.mass_cancel_threshold,
            run_label=args.run_label,
            failed_jobs_csv=args.failed_jobs_csv,
        )
    except Exception as exc:
        log.error("Analysis failed: %s", exc)
        sys.exit(1)


if __name__ == "__main__":
    main()
