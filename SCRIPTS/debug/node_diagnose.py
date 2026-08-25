#!/usr/bin/env python3
"""
node_diagnose.py
=================

AT-Bench Suspect-Node Diagnostic Analysis

Two subcommands, both driven by SCRIPTS/diagnose-nodes.sh:

  select  - Decide WHICH of today's slow/failed nodes are actually worth
            re-testing with HPL/STREAM/OSU, and pick a known-good reference
            node for OSU's point-to-point comparison.
  report  - After diagnose-nodes.sh has run HPL+STREAM (reference + every
            candidate) and OSU (reference vs. every candidate), parse all
            the raw output and produce a plain report.txt + records.csv --
            deliberately just those two, no charts: only nodes that
            actually miss a benchmark's standard criteria are listed at
            all, each with the real number observed and the standard it
            fell short of.

Design notes
------------
* "select" deliberately does NOT just retest everything in slow-nodes.txt /
  failed-nodes.txt (see AT-Bench conversation history): a node is only a
  useful HPL/STREAM/OSU candidate if there's a real chance the NODE itself
  (not a known software bug) is at fault.
    - FAILED nodes: job_debug_analyzer.py's debug/job_debug_records.csv
      already classifies WHY each failed job failed. Only categories where
      the node itself is a plausible cause (network/IB fault, MPI launch
      failure, segfault, or a genuinely unexplained incomplete run) keep
      that node as a candidate; categories that are clearly software
      (env setup errors, app-level fatal errors, OOM, external
      cancellation, timeout) don't.
    - SLOW nodes: there's no per-job root-cause classifier for these (the
      debug pipeline only ever analyzes FAILED jobs). Instead, per app: if
      that app's own slow-rate today is ~systemic (>= --systemic-threshold,
      default 90%), every node it touched looks "slow" regardless of the
      node's own health -- that's signal about the APP, not about any one
      node -- so that app's slow-node attribution is excluded. Apps with a
      partial slow-rate keep contributing real candidates.
* "report" avoids hardcoding absolute expected values wherever a same-run
  baseline can be computed instead:
    - HPL: compared against the fixed 2400-2600 Gflops / 450-580s range
      hpl-verify-results.sh already uses for this exact HPL.dat problem
      size on this cluster (independently confirmed accurate against a
      real single-node run on 2026-08-10: 2470.77 Gflops / 569.27s).
    - STREAM: no pre-existing threshold exists anywhere in this repo.
      Compared against the REFERENCE node's own Triad rate from the same
      diagnostic run (self-calibrating, not a guessed constant).
    - OSU: compared against the MEDIAN small-message latency / peak
      bandwidth across every (reference, candidate) pair actually tested
      this run (also self-calibrating).
"""

from __future__ import annotations

import argparse
import csv
import logging
import re
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("node_diagnose")

DISCLAIMER = "Disclaimer: Internal testing, not publication ready. Contact: omjadhav@cdac.in"

# job_debug_analyzer.py's FAILURE_CATEGORIES that plausibly implicate the
# node itself rather than a software/environment bug. Kept as plain strings
# (not imported) so this tool has no import-time dependency on
# job_debug_analyzer.py's internals -- only on the stable CSV column values
# it writes.
HARDWARE_CATEGORIES = {"NODE_FAULT_NETWORK", "MPI_LAUNCH_FAILURE", "SEGFAULT", "UNKNOWN_INCOMPLETE"}

HPL_GFLOPS_RANGE = (2400.0, 2600.0)
HPL_WALLTIME_RANGE = (450.0, 580.0)
STREAM_MIN_FRACTION_OF_REFERENCE = 0.85  # candidate's Triad must be >= 85% of the reference's
OSU_LATENCY_MAX_FACTOR = 2.0             # candidate flagged if 1-byte latency > 2x today's median
OSU_BW_MIN_FRACTION = 0.5                # candidate flagged if peak BW < 50% of today's median


def _read_lines_no_comments(path: Path) -> List[str]:
    if not path.is_file():
        return []
    return [ln.rstrip("\n") for ln in path.read_text(errors="replace").splitlines() if not ln.startswith("#")]


def _read_node_csv_line(path: Path) -> List[str]:
    """A combined/per-app *-nodes.txt: one real (non-#) line, comma-separated."""
    lines = [ln for ln in _read_lines_no_comments(path) if ln.strip()]
    if not lines:
        return []
    return [n.strip() for n in lines[0].split(",") if n.strip()]


def _read_by_job_file(path: Path) -> Dict[str, List[str]]:
    """"<jobid>: node1,node2,..." lines -> {jobid: [nodes]}."""
    result: Dict[str, List[str]] = {}
    for line in _read_lines_no_comments(path):
        if ":" not in line:
            continue
        jobid, rest = line.split(":", 1)
        nodes = [n.strip() for n in rest.split(",") if n.strip()]
        if jobid.strip():
            result[jobid.strip()] = nodes
    return result


# --------------------------------------------------------------------------
# select
# --------------------------------------------------------------------------

def select_candidates(nodes_dir: Path, debug_dir: Path, systemic_threshold: float) -> Tuple[List[str], Optional[str]]:
    candidates: set = set()

    # -- Failed nodes: keep only hardware-attributable categories, straight
    #    from job_debug_analyzer.py's own classification.
    records_csv = debug_dir / "job_debug_records.csv"
    n_failed_seen = 0
    if records_csv.is_file():
        with records_csv.open(newline="") as f:
            reader = csv.DictReader(line for line in f if not line.startswith("#"))
            for row in reader:
                n_failed_seen += 1
                node = (row.get("node") or "").strip()
                category = (row.get("category") or "").strip()
                if node and category in HARDWARE_CATEGORIES:
                    candidates.add(node)
    else:
        log.warning("%s not found -- no failed-node candidates from this source", records_csv)
    log.info("Failed jobs seen: %d, hardware-attributable candidate nodes so far: %d", n_failed_seen, len(candidates))

    # -- Slow nodes: per app, skip if that app's slow-rate today is systemic.
    for by_job_path in sorted(nodes_dir.glob("*-slow-nodes-by-job.txt")):
        app = by_job_path.name[: -len("-slow-nodes-by-job.txt")]
        slow_jobs = _read_by_job_file(by_job_path)
        success_jobs = _read_by_job_file(nodes_dir / f"{app}-success-nodes-by-job.txt")
        failed_jobs = _read_by_job_file(nodes_dir / f"{app}-failed-nodes-by-job.txt")
        total = len(slow_jobs) + len(success_jobs) + len(failed_jobs)
        slow_rate = (len(slow_jobs) / total) if total else 0.0
        if total and slow_rate >= systemic_threshold:
            log.info("%s: slow-rate %.0f%% (%d/%d) looks systemic (>= %.0f%%) -- excluding its slow-node "
                      "attribution as noise, not evidence about any one node",
                      app, slow_rate * 100, len(slow_jobs), total, systemic_threshold * 100)
            continue
        app_nodes = {n for nodes in slow_jobs.values() for n in nodes}
        if app_nodes:
            log.info("%s: slow-rate %.0f%% (%d/%d) -- keeping %d node(s) as candidates",
                      app, slow_rate * 100, len(slow_jobs), total, len(app_nodes))
        candidates.update(app_nodes)

    reference_nodes = _read_node_csv_line(nodes_dir / "success-nodes.txt")
    reference = reference_nodes[0] if reference_nodes else None
    if reference is None:
        log.warning("No success-nodes.txt / no successful nodes today -- no OSU reference node available")

    # A candidate can't also be the reference.
    candidates.discard(reference)
    return sorted(candidates), reference


def cmd_select(args: argparse.Namespace) -> None:
    nodes_dir = Path(args.nodes_dir)
    debug_dir = Path(args.debug_dir)
    candidates, reference = select_candidates(nodes_dir, debug_dir, args.systemic_threshold)

    Path(args.candidates_out).write_text("\n".join(candidates) + ("\n" if candidates else ""))
    Path(args.reference_out).write_text((reference or "") + "\n")

    log.info("Selected %d candidate node(s); reference node: %s", len(candidates), reference or "(none)")
    for n in candidates:
        print(n)


# --------------------------------------------------------------------------
# report: parsing raw benchmark output
# --------------------------------------------------------------------------

@dataclass
class HplResult:
    node: str
    gflops: Optional[float] = None
    walltime: Optional[float] = None
    residual_passed: Optional[bool] = None
    status: str = "NO_OUTPUT"  # NO_OUTPUT / OK / ANOMALY


@dataclass
class StreamResult:
    node: str
    triad_mbs: Optional[float] = None
    status: str = "NO_OUTPUT"


@dataclass
class OsuResult:
    reference: str
    node: str
    latency_1b_us: Optional[float] = None
    bw_peak_mbs: Optional[float] = None
    status: str = "NO_OUTPUT"


# The leading "WC" is HPL's T/V label reflecting HPL.dat's PMAP setting
# (SRC/BENCH/HPL/hpl-1n/HPL.dat: PMAP=1, Column-major -> "C"; the "W" is the
# fixed row/col-threshold-broadcast label). If HPL.dat's PMAP is ever
# changed to 0 (Row-major), this regex stops matching real HPL.out lines
# entirely -- every result would then silently parse as NO_OUTPUT rather
# than erroring, misreporting every diagnosed node as a shortfall.
_HPL_LINE_RE = re.compile(r"^WC\S+\s+\d+\s+\d+\s+\d+\s+\d+\s+([\d.]+)\s+([\deE.+-]+)", re.MULTILINE)


def parse_hpl(run_dir: Path, node: str) -> HplResult:
    r = HplResult(node=node)
    out_files = list(run_dir.glob("HPL.out.*"))
    if not out_files:
        return r
    text = out_files[0].read_text(errors="replace")
    m = _HPL_LINE_RE.search(text)
    if m:
        r.walltime = float(m.group(1))
        r.gflops = float(m.group(2))
    # This HPL.dat has exactly one test case (one N/NB/P/Q combination), so
    # there's at most one PASSED/FAILED residual-check line to look for.
    r.residual_passed = "PASSED" in text and "FAILED" not in text
    if r.gflops is None or r.walltime is None:
        r.status = "NO_OUTPUT"
    elif (HPL_GFLOPS_RANGE[0] <= r.gflops <= HPL_GFLOPS_RANGE[1]
          and HPL_WALLTIME_RANGE[0] <= r.walltime <= HPL_WALLTIME_RANGE[1]
          and r.residual_passed):
        r.status = "OK"
    else:
        r.status = "ANOMALY"
    return r


_STREAM_TRIAD_RE = re.compile(r"^Triad:\s+([\d.]+)", re.MULTILINE)


def parse_stream(run_dir: Path, node: str) -> StreamResult:
    r = StreamResult(node=node)
    rates: List[float] = []
    for f in sorted(run_dir.glob("STREAM.out-*")):
        text = f.read_text(errors="replace")
        m = _STREAM_TRIAD_RE.search(text)
        if m:
            rates.append(float(m.group(1)))
    if rates:
        r.triad_mbs = max(rates)
        r.status = "OK"  # thresholding against the reference happens in cmd_report
    return r


_OSU_LAT_ROW_RE = re.compile(r"^1\s+([\d.]+)\s*$", re.MULTILINE)
_OSU_BW_ROW_RE = re.compile(r"^(\d+)\s+([\d.]+)\s*$", re.MULTILINE)


def parse_osu(run_dir: Path, reference: str, node: str) -> OsuResult:
    r = OsuResult(reference=reference, node=node)
    lat_files = list(run_dir.glob("osu_latency.*"))
    bw_files = list(run_dir.glob("osu_bw.*"))
    if lat_files:
        text = lat_files[0].read_text(errors="replace")
        m = _OSU_LAT_ROW_RE.search(text)
        if m:
            r.latency_1b_us = float(m.group(1))
    if bw_files:
        text = bw_files[0].read_text(errors="replace")
        rows = _OSU_BW_ROW_RE.findall(text)
        if rows:
            r.bw_peak_mbs = max(float(v) for _, v in rows)
    if r.latency_1b_us is not None or r.bw_peak_mbs is not None:
        r.status = "OK"
    return r


def _find_run_dir(base: Path, *name_parts: str) -> Optional[Path]:
    """HPL/STREAM/OSU job.sh renames its run dir to the node name (or
    NODE1-NODE2 for OSU) only after the job finishes; a still-running or
    never-scheduled job leaves the original RUN-<n> dir instead. Look for
    the final name first, fall back to None (caller reports NO_OUTPUT)."""
    candidate = base / "-".join(name_parts)
    return candidate if candidate.is_dir() else None


# --------------------------------------------------------------------------
# report: shortfalls (only the nodes that actually miss the standard
# criteria) -> text report + CSV. No charts -- kept deliberately simple:
# a node either meets HPL/STREAM/OSU's standard criteria or it doesn't, and
# the only nodes worth a human's attention are the ones that don't.
# --------------------------------------------------------------------------

@dataclass
class Shortfall:
    node: str
    benchmark: str    # "HPL" / "STREAM" / "OSU-latency" / "OSU-bandwidth"
    observed: str      # the real number (or "NO OUTPUT") from this node's own run
    standard: str       # the standard/expected criteria it fell short of


def _no_output_str(timed_out: Dict[Tuple[str, str], str], node: str, benchmark: str) -> str:
    """"NO OUTPUT" alone doesn't say why -- if diagnose-nodes.sh had to
    cancel this (node, benchmark) after its wait timeout, say what SLURM
    state it was last seen in (e.g. still PENDING -- the node genuinely
    never became available -- vs RUNNING) instead of leaving it opaque."""
    state = timed_out.get((node, benchmark))
    return f"NO OUTPUT (timed out, was {state})" if state else "NO OUTPUT"


def compute_shortfalls(hpl: List[HplResult], stream: List[StreamResult], osu: List[OsuResult],
                        reference: Optional[str], candidates: List[str],
                        timed_out: Optional[Dict[Tuple[str, str], str]] = None
                        ) -> Tuple[List[Shortfall], List[str], Dict[str, Optional[float]]]:
    """Returns (shortfalls, all_nodes_tested, baseline_values_used). Only
    nodes that actually miss a benchmark's standard criteria produce a
    Shortfall -- a clean node contributes nothing here."""
    timed_out = timed_out or {}
    hpl_by_node = {r.node: r for r in hpl}
    stream_by_node = {r.node: r for r in stream}
    osu_by_node = {r.node: r for r in osu}
    all_nodes = sorted(set(hpl_by_node) | set(stream_by_node) | set(osu_by_node))

    ref_triad = stream_by_node.get(reference).triad_mbs if reference in stream_by_node and stream_by_node[reference].triad_mbs else None
    lat_values = [r.latency_1b_us for r in osu if r.latency_1b_us is not None]
    bw_values = [r.bw_peak_mbs for r in osu if r.bw_peak_mbs is not None]
    median_lat = statistics.median(lat_values) if lat_values else None
    median_bw = statistics.median(bw_values) if bw_values else None

    hpl_standard = f"{HPL_GFLOPS_RANGE[0]:.0f}-{HPL_GFLOPS_RANGE[1]:.0f} Gflops and {HPL_WALLTIME_RANGE[0]:.0f}-{HPL_WALLTIME_RANGE[1]:.0f}s"
    stream_standard = (f">= {STREAM_MIN_FRACTION_OF_REFERENCE*100:.0f}% of reference ({ref_triad*STREAM_MIN_FRACTION_OF_REFERENCE:,.0f} MB/s)"
                        if ref_triad else None)
    osu_lat_standard = f"<= {median_lat*OSU_LATENCY_MAX_FACTOR:.1f} us ({OSU_LATENCY_MAX_FACTOR:.0f}x today's median)" if median_lat else None
    osu_bw_standard = f">= {median_bw*OSU_BW_MIN_FRACTION:,.0f} MB/s ({OSU_BW_MIN_FRACTION*100:.0f}% of today's median)" if median_bw else None

    shortfalls: List[Shortfall] = []
    for node in all_nodes:
        h = hpl_by_node.get(node)
        if h and h.gflops is not None:
            if h.status == "ANOMALY":
                shortfalls.append(Shortfall(node, "HPL", f"{h.gflops:,.1f} Gflops / {h.walltime:.0f}s", hpl_standard))
        else:
            shortfalls.append(Shortfall(node, "HPL", _no_output_str(timed_out, node, "HPL"), hpl_standard))

        s = stream_by_node.get(node)
        if s and s.triad_mbs is not None:
            if ref_triad and s.triad_mbs < ref_triad * STREAM_MIN_FRACTION_OF_REFERENCE:
                shortfalls.append(Shortfall(node, "STREAM", f"{s.triad_mbs:,.0f} MB/s", stream_standard))
        else:
            shortfalls.append(Shortfall(node, "STREAM", _no_output_str(timed_out, node, "STREAM"),
                                         stream_standard or "(reference Triad unavailable)"))

        # OSU only ever runs reference-vs-CANDIDATE -- the reference itself
        # was never meant to have an OSU entry (it's the baseline, not
        # something OSU tests directly), so it's excluded here rather than
        # reported as a false "no output" shortfall.
        if node not in candidates:
            continue
        o = osu_by_node.get(node)
        if o and (o.latency_1b_us is not None or o.bw_peak_mbs is not None):
            if median_lat and o.latency_1b_us and o.latency_1b_us > median_lat * OSU_LATENCY_MAX_FACTOR:
                shortfalls.append(Shortfall(node, "OSU-latency", f"{o.latency_1b_us:.1f} us", osu_lat_standard))
            if median_bw and o.bw_peak_mbs and o.bw_peak_mbs < median_bw * OSU_BW_MIN_FRACTION:
                shortfalls.append(Shortfall(node, "OSU-bandwidth", f"{o.bw_peak_mbs:,.0f} MB/s", osu_bw_standard))
        else:
            shortfalls.append(Shortfall(node, "OSU", _no_output_str(timed_out, node, "OSU"),
                                         "latency/bandwidth result expected"))

    baselines = {"ref_triad": ref_triad, "median_lat": median_lat, "median_bw": median_bw}
    return shortfalls, all_nodes, baselines


def write_report(shortfalls: List[Shortfall], all_nodes: List[str], reference: Optional[str],
                  out_dir: Path, run_label: str) -> None:
    lines: List[str] = []
    lines.append(f"# {DISCLAIMER}")
    lines.append("=" * 78)
    lines.append("AT-BENCH SUSPECT-NODE DIAGNOSTIC REPORT")
    lines.append(f"Run: {run_label}   |   Reference node: {reference or '(none)'}")
    lines.append("=" * 78)

    by_node: Dict[str, List[Shortfall]] = {}
    for sf in shortfalls:
        by_node.setdefault(sf.node, []).append(sf)
    suspect_nodes = sorted(by_node)

    lines.append("")
    lines.append(f"SUMMARY: {len(all_nodes)} node(s) tested, {len(suspect_nodes)} suspect, "
                 f"{len(all_nodes) - len(suspect_nodes)} clean")

    if suspect_nodes:
        lines.append("")
        lines.append("SUSPECTED NODES")
        lines.append("-" * 78)
        for node in suspect_nodes:
            lines.append(f"  {node}")
            for sf in by_node[node]:
                standard = sf.standard or "(no standard available to compare against)"
                lines.append(f"    {sf.benchmark:<12s} observed: {sf.observed:<22s} standard: {standard}")
            lines.append("")

    (out_dir / "report.txt").write_text("\n".join(lines) + "\n")
    log.info("Saved report -> %s", out_dir / "report.txt")


def write_csv(shortfalls: List[Shortfall], out_dir: Path) -> None:
    csv_path = out_dir / "records.csv"
    with csv_path.open("w", newline="") as f:
        f.write(f"# {DISCLAIMER}\n")
        w = csv.writer(f)
        w.writerow(["node", "benchmark", "observed", "standard"])
        for sf in sorted(shortfalls, key=lambda s: (s.node, s.benchmark)):
            w.writerow([sf.node, sf.benchmark, sf.observed, sf.standard or ""])
    log.info("Saved records (%d shortfall row(s)) -> %s", len(shortfalls), csv_path)


def read_timed_out_csv(path: Optional[Path]) -> Dict[Tuple[str, str], str]:
    """diagnose-nodes.sh's timed-out.csv: "node,benchmark,slurm_state" for
    every job it had to cancel after its wait timeout. No header, no
    disclaimer line (not a user-facing artifact -- purely report's own
    input) -- empty/missing file is the normal case (nothing timed out)."""
    if not path or not path.is_file():
        return {}
    result: Dict[Tuple[str, str], str] = {}
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split(",")
        if len(parts) >= 3 and parts[0].strip():
            result[(parts[0].strip(), parts[1].strip())] = parts[2].strip()
    return result


def cmd_report(args: argparse.Namespace) -> None:
    diag_dir = Path(args.diagnose_run_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    run_label = args.run_label or datetime.now().strftime("%d %B %Y")

    candidates = [ln.strip() for ln in Path(args.candidates).read_text().splitlines() if ln.strip()] \
        if Path(args.candidates).is_file() else []
    reference = Path(args.reference).read_text().strip() if Path(args.reference).is_file() else None
    reference = reference or None
    timed_out = read_timed_out_csv(Path(args.timed_out_file)) if args.timed_out_file else {}

    hpl_nodes = candidates + ([reference] if reference else [])
    stream_nodes = candidates + ([reference] if reference else [])

    hpl_results = []
    for node in hpl_nodes:
        run_dir = _find_run_dir(diag_dir / "HPL", node)
        hpl_results.append(parse_hpl(run_dir, node) if run_dir else HplResult(node=node))

    stream_results = []
    for node in stream_nodes:
        run_dir = _find_run_dir(diag_dir / "STREAM", node)
        stream_results.append(parse_stream(run_dir, node) if run_dir else StreamResult(node=node))

    osu_results = []
    if reference:
        for node in candidates:
            run_dir = _find_run_dir(diag_dir / "OSU", reference, node)
            osu_results.append(parse_osu(run_dir, reference, node) if run_dir
                                else OsuResult(reference=reference, node=node))

    shortfalls, all_nodes, _baselines = compute_shortfalls(hpl_results, stream_results, osu_results,
                                                             reference, candidates, timed_out)
    write_report(shortfalls, all_nodes, reference, out_dir, run_label)
    write_csv(shortfalls, out_dir)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Select suspect nodes for HPL/STREAM/OSU diagnostics, "
                                                  "and report on their results.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_select = sub.add_parser("select", help="Pick candidate suspect nodes + a reference node")
    p_select.add_argument("--nodes-dir", required=True)
    p_select.add_argument("--debug-dir", required=True)
    p_select.add_argument("--systemic-threshold", type=float, default=0.9,
                           help="App slow-rate at/above which its slow-node attribution is excluded as "
                                "noise (default 0.9 = 90%%)")
    p_select.add_argument("--candidates-out", required=True)
    p_select.add_argument("--reference-out", required=True)
    p_select.set_defaults(func=cmd_select)

    p_report = sub.add_parser("report", help="Parse HPL/STREAM/OSU output and write report.txt + records.csv")
    p_report.add_argument("--diagnose-run-dir", required=True, help="Base dir containing HPL/, STREAM/, OSU/")
    p_report.add_argument("--candidates", required=True)
    p_report.add_argument("--reference", required=True)
    p_report.add_argument("--out-dir", required=True)
    p_report.add_argument("--run-label", default=None)
    p_report.add_argument("--timed-out-file", default=None,
                           help="diagnose-nodes.sh's timed-out.csv (node,benchmark,slurm_state) for jobs "
                                "it had to cancel after its wait timeout -- optional, annotates the "
                                "corresponding NO OUTPUT entries with why instead of leaving them opaque")
    p_report.set_defaults(func=cmd_report)

    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        log.error("node_diagnose.py %s failed: %s", args.cmd, exc)
        sys.exit(1)


if __name__ == "__main__":
    main()
