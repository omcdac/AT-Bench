#!/usr/bin/env python3
"""
atbench_analyzer.py
====================

AT-Bench Verification Log Analyzer for C-DAC HPC Application Runs
-------------------------------------------------------------------

Analyzes a single day's AT-Bench verification LOGS directory
(e.g. ".../AT-Bench/CRON/Verification/LOGS/04August2026") which contains,
for each benchmarked application (GROMACS, WRF, NAMD, OpenFOAM, ...):

    <APP>.txt              -> per-job checker log + a machine-generated
                               "Job Summary" block (Total / Successful /
                               Slow / Incomplete-Failed counts)
    <APP>-results.csv       -> per-job numeric results (job_id, walltime,
                               [nsperday for GROMACS], nodelist)

and produces three PNG charts:

    1. combined_boxplot.png     - Walltime distribution per application
                                   (box + whisker, min/median/max labels,
                                   per-app SLA/target line, outlier note)
    2. combined_job_stats.png   - Grouped bar chart: Total / Successful /
                                   Slow / Failed jobs per application
    3. combined_node_stats.png  - Single stacked bar: of the nodes actually
                                   TESTED today (from LOGS/<date>/nodes/,
                                   already deduped + made mutually exclusive
                                   by run-verification.sh's Section 1b), how
                                   many came back Success / Slow / Failed

Design notes / robustness
--------------------------
* Real AT-Bench logs are messy: fields can be corrupted mid-write
  (e.g. a walltime value split across physical lines), non-numeric
  placeholders can appear (e.g. "Chem." instead of a ns/day figure),
  and the "Failed"/"Incomplete" wording differs between apps. The CSV
  parser therefore validates every row itself (rather than trusting
  pandas' default CSV reader) and silently quarantines anything that
  doesn't parse cleanly, instead of crashing or silently corrupting
  the walltime distribution.
* App discovery is name-based (case-insensitive substring match), not
  hard-coded to exact filenames, so it tolerates minor naming
  variations (GROMACS.txt / gromacs.txt / GROMACS-results.csv / ...).
* Summary-block parsing uses tolerant regexes because different apps
  phrase the failed/incomplete category slightly differently
  ("C.INCOMPLETE JOBS" + "No. of Incomplete Jobs=" in these samples).

Usage
-----
    python3 atbench_analyzer.py --log-dir /path/to/LOGS/04August2026 \\
        --output-dir /path/to/output \\
        [--apps GROMACS WRF NAMD OpenFOAM] \\
        [--target-walltime 480]           # fallback SLA line if a per-app
                                           # target can't be read from the .txt

Can also be imported and driven programmatically via `run_analysis(...)`.
"""

from __future__ import annotations

import argparse
import csv
import io
import logging
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("atbench_analyzer")

DEFAULT_APPS = ["GROMACS", "WRF", "NAMD", "OpenFOAM"]

# Stamped on every generated artifact: a "#"-prefixed comment line at the
# top of text/CSV output (filtered out by every reader that parses one of
# these files back, e.g. read_node_counts), small print at the bottom of
# every PNG chart.
DISCLAIMER = "Disclaimer: Internal testing, not publication ready. Contact: omjadhav@cdac.in"

# Distinct, print-friendly colors per known app (extra apps cycle a palette)
APP_COLORS = {
    "GROMACS": "#7FA6D6",   # blue
    "WRF": "#B5651D",       # brown/dark-red (box shown brownish in ref chart)
    "NAMD": "#8FBF8F",      # green
    "OpenFOAM": "#C97B84",  # rose
}
FALLBACK_PALETTE = ["#7FA6D6", "#B5651D", "#8FBF8F", "#C97B84",
                    "#C9A15A", "#9A8FBF", "#6FB8B2", "#D6A97F"]

# App version + nodes-per-job, printed under each app's name on the job-stats
# bar chart x-axis. Sourced from SRC/<app>/... build paths and the `nnodes=`
# value each app's verify-results.sh is hardcoded with. Apps not listed here
# just get their bare name (no second line).
APP_METADATA = {
    "GROMACS": {"version": "5.1.4", "nodes_per_job": 10},
    "WRF": {"version": "v3.8.1", "nodes_per_job": 11},
    "NAMD": {"version": "v3.0.3", "nodes_per_job": 11},
    "OpenFOAM": {"version": "v2206", "nodes_per_job": 14},
}


# --------------------------------------------------------------------------
# Data containers
# --------------------------------------------------------------------------

@dataclass
class AppFiles:
    app: str
    txt_path: Optional[Path] = None
    csv_path: Optional[Path] = None


@dataclass
class AppSummary:
    app: str
    total: Optional[int] = None
    successful: Optional[int] = None
    slow: Optional[int] = None
    failed: Optional[int] = None          # "Incomplete"/"Failed" category
    walltime_min: Optional[float] = None  # acceptable-range lower bound
    walltime_max: Optional[float] = None  # acceptable-range upper bound (SLA)
    parse_warnings: List[str] = field(default_factory=list)


@dataclass
class AppRunData:
    app: str
    walltimes: pd.Series          # cleaned numeric walltime values (seconds)
    n_rows_total: int = 0         # rows seen in the CSV
    n_rows_dropped: int = 0       # rows that failed validation
    summary: Optional[AppSummary] = None


# --------------------------------------------------------------------------
# File discovery
# --------------------------------------------------------------------------

def discover_app_files(log_dir: Path, apps: List[str]) -> Dict[str, AppFiles]:
    """Case-insensitively match files in log_dir to each app name."""
    found: Dict[str, AppFiles] = {app: AppFiles(app=app) for app in apps}

    all_files = [p for p in log_dir.iterdir() if p.is_file()]
    for app in apps:
        app_lc = app.lower()
        candidates_txt = [p for p in all_files
                           if p.suffix.lower() == ".txt" and app_lc in p.stem.lower()]
        candidates_csv = [p for p in all_files
                           if p.suffix.lower() == ".csv" and app_lc in p.stem.lower()]
        if candidates_txt:
            # Prefer the shortest / most specific filename if multiple match
            found[app].txt_path = sorted(candidates_txt, key=lambda p: len(p.name))[0]
        if candidates_csv:
            found[app].csv_path = sorted(candidates_csv, key=lambda p: len(p.name))[0]

        if not candidates_txt:
            log.warning("No .txt summary log found for app '%s' in %s", app, log_dir)
        if not candidates_csv:
            log.warning("No -results.csv data file found for app '%s' in %s", app, log_dir)

    return found


# --------------------------------------------------------------------------
# CSV parsing (robust, row-by-row validation)
# --------------------------------------------------------------------------

def parse_results_csv(csv_path: Path) -> pd.Series:
    """
    Parse a <APP>-results.csv file and return a clean pandas Series of
    numeric walltime values (seconds), silently discarding any row that
    does not validate (wrong column count, non-numeric walltime, out of
    a sane physical range, etc).

    Expected columns (header optional / auto-detected):
        job_id, [nsperday,] walltime, nodelist

    The walltime column is auto-identified as the last purely-numeric
    field before the (typically quoted) trailing nodelist field.
    """
    raw_text = csv_path.read_text(errors="replace")
    reader = csv.reader(io.StringIO(raw_text))

    rows = list(reader)
    if not rows:
        log.warning("Empty CSV: %s", csv_path)
        return pd.Series([], dtype=float)

    # Detect / skip header row
    header = [c.strip().lower() for c in rows[0]]
    start_idx = 1 if "job_id" in header or "jobid" in header else 0
    walltime_col_idx = None
    if start_idx == 1:
        for i, col in enumerate(header):
            if "walltime" in col:
                walltime_col_idx = i
                break

    n_total = 0
    n_dropped = 0
    walltimes: List[float] = []

    for row in rows[start_idx:]:
        if not row or all(not c.strip() for c in row):
            continue
        n_total += 1

        walltime_val = None
        if walltime_col_idx is not None and walltime_col_idx < len(row):
            walltime_val = _to_float(row[walltime_col_idx])

        if walltime_val is None:
            # Fallback: scan fields for the *last* plausible numeric field
            # before a quoted/nodelist-looking trailing field. We treat any
            # field matching a float pattern as a candidate and take the
            # last one that isn't the job_id itself (row[0]).
            candidates = []
            for i, field_val in enumerate(row):
                if i == 0:
                    continue
                f = _to_float(field_val)
                if f is not None:
                    candidates.append(f)
            walltime_val = candidates[-1] if candidates else None

        # Sanity bounds: HPC job walltimes here are on the order of
        # seconds-to-low-thousands; reject absurd/garbage values.
        if walltime_val is None or not (0 < walltime_val < 36000):
            n_dropped += 1
            continue

        walltimes.append(walltime_val)

    if n_dropped:
        log.info("%s: parsed %d rows, discarded %d malformed/invalid row(s)",
                  csv_path.name, n_total, n_dropped)

    series = pd.Series(walltimes, dtype=float)
    series.attrs["n_rows_total"] = n_total
    series.attrs["n_rows_dropped"] = n_dropped
    return series


def _to_float(value: str) -> Optional[float]:
    try:
        v = float(value.strip())
        return v
    except (ValueError, AttributeError):
        return None


# --------------------------------------------------------------------------
# Summary (.txt) parsing
# --------------------------------------------------------------------------

_TOTAL_RE = re.compile(r"Total\s+\S+\s+Jobs:\s*(\d+)", re.IGNORECASE)
_SUCCESS_RE = re.compile(r"No\.?\s*of\s*Succes+ful+\s*Jobs\s*=\s*(\d+)", re.IGNORECASE)
_SLOW_RE = re.compile(r"No\.?\s*of\s*Slow\s*Jobs\s*=\s*(\d+)", re.IGNORECASE)
_FAILED_RE = re.compile(r"No\.?\s*of\s*(?:Incomplete|Failed)\s*Jobs\s*=\s*(\d+)", re.IGNORECASE)
_WT_MIN_RE = re.compile(r"Walltime:\s*min\w*\s*=\s*(\d+(?:\.\d+)?)", re.IGNORECASE)
_WT_MAX_RE = re.compile(r"Walltime:\s*max\w*\s*=\s*(\d+(?:\.\d+)?)", re.IGNORECASE)


def parse_summary_txt(txt_path: Path, app: str) -> AppSummary:
    """Extract the machine-generated 'Job Summary' block from a log file."""
    text = txt_path.read_text(errors="replace")
    summary = AppSummary(app=app)

    # Only look inside the summary block if present (after the banner),
    # else fall back to scanning the whole file.
    marker_idx = text.rfind("Job Summary")
    scan_text = text[marker_idx:] if marker_idx != -1 else text

    def _find(pattern: re.Pattern, name: str) -> Optional[int]:
        m = pattern.search(scan_text)
        if m:
            return int(float(m.group(1)))
        summary.parse_warnings.append(f"Could not find '{name}' in {txt_path.name}")
        return None

    summary.total = _find(_TOTAL_RE, "Total Jobs")
    summary.successful = _find(_SUCCESS_RE, "Successful Jobs")
    summary.slow = _find(_SLOW_RE, "Slow Jobs")
    summary.failed = _find(_FAILED_RE, "Incomplete/Failed Jobs")

    wt_min_m = _WT_MIN_RE.search(scan_text)
    wt_max_m = _WT_MAX_RE.search(scan_text)
    summary.walltime_min = float(wt_min_m.group(1)) if wt_min_m else None
    summary.walltime_max = float(wt_max_m.group(1)) if wt_max_m else None

    for w in summary.parse_warnings:
        log.warning(w)

    return summary


# --------------------------------------------------------------------------
# Data collection orchestration
# --------------------------------------------------------------------------

def collect_run_data(log_dir: Path, apps: List[str]) -> Dict[str, AppRunData]:
    files_by_app = discover_app_files(log_dir, apps)
    results: Dict[str, AppRunData] = {}

    for app in apps:
        af = files_by_app[app]
        walltimes = pd.Series([], dtype=float)
        n_total = 0
        n_dropped = 0
        if af.csv_path is not None:
            walltimes = parse_results_csv(af.csv_path)
            n_total = walltimes.attrs.get("n_rows_total", len(walltimes))
            n_dropped = walltimes.attrs.get("n_rows_dropped", 0)
        else:
            log.warning("Skipping walltime data for %s (no CSV found)", app)

        summary = None
        if af.txt_path is not None:
            summary = parse_summary_txt(af.txt_path, app)
        else:
            log.warning("Skipping job-count summary for %s (no .txt found)", app)

        results[app] = AppRunData(
            app=app,
            walltimes=walltimes,
            n_rows_total=n_total,
            n_rows_dropped=n_dropped,
            summary=summary,
        )

    return results


# --------------------------------------------------------------------------
# Node-level data (for Plot 3) -- separate from the per-app job data above.
# SCRIPTS/extract-nodes + run-verification.sh's Section 1b already write
# one deduped, mutually-exclusive (failed beats slow beats success) node
# list per category into LOGS/<date>/nodes/{success,slow,failed}-nodes.txt
# -- read those directly rather than re-deriving node status here.
# --------------------------------------------------------------------------

NODE_STATUS_FILES = [("Success", "success-nodes.txt"), ("Slow", "slow-nodes.txt"),
                      ("Failed", "failed-nodes.txt")]


def read_node_counts(nodes_dir: Path) -> Dict[str, int]:
    """{"Success": n, "Slow": n, "Failed": n} from the combined node-list
    .txt files (one comma-separated line each, preceded by a "#"-prefixed
    disclaimer comment line -- see DISCLAIMER -- filtered out before the
    real data line is parsed). A missing/empty file counts as 0 rather than
    erroring -- e.g. a day with zero failed nodes legitimately has an empty
    failed-nodes.txt."""
    counts: Dict[str, int] = {}
    for label, filename in NODE_STATUS_FILES:
        path = nodes_dir / filename
        if not path.is_file():
            log.warning("%s not found under %s", filename, nodes_dir)
            counts[label] = 0
            continue
        data_lines = [ln for ln in path.read_text(errors="replace").splitlines()
                      if not ln.startswith("#")]
        text = ",".join(data_lines).strip()
        counts[label] = len([n for n in text.split(",") if n.strip()]) if text else 0
    return counts


# --------------------------------------------------------------------------
# Plot 1: Combined boxplot of walltimes
# --------------------------------------------------------------------------

def plot_combined_boxplot(
    run_data: Dict[str, AppRunData],
    output_path: Path,
    fallback_target: Optional[float] = 480.0,
    y_limits: Optional[tuple] = None,
    run_date: Optional[str] = None,
) -> None:
    apps = [a for a in run_data if len(run_data[a].walltimes) > 0]
    if not apps:
        log.error("No walltime data available for any app; skipping boxplot.")
        return

    data = [run_data[a].walltimes.values for a in apps]
    colors = [APP_COLORS.get(a, FALLBACK_PALETTE[i % len(FALLBACK_PALETTE)])
              for i, a in enumerate(apps)]

    run_date = run_date or datetime.now().strftime("%d %B %Y")

    fig, ax = plt.subplots(figsize=(13, 8))

    # Determine a sensible fixed y-range based on each app's whisker
    # (IQR * 1.5) bounds rather than raw min/max, so a handful of extreme
    # low/high garbage values (e.g. a failed job logging walltime=2.3s)
    # don't crush the visible box detail. Those points are still drawn as
    # flier dots when in-range, and counted as "hidden outliers" when not.
    if y_limits is None:
        whisker_los, whisker_his = [], []
        for vals in data:
            q1, q3 = np.percentile(vals, [25, 75])
            iqr = q3 - q1
            lo_bound, hi_bound = q1 - 1.5 * iqr, q3 + 1.5 * iqr
            in_range = vals[(vals >= lo_bound) & (vals <= hi_bound)]
            if len(in_range):
                whisker_los.append(in_range.min())
                whisker_his.append(in_range.max())
        y_lo = min(whisker_los) if whisker_los else np.concatenate(data).min()
        y_hi = max(whisker_his) if whisker_his else np.concatenate(data).max()
        pad = max(20, 0.12 * (y_hi - y_lo))
        y_lo = 10 * np.floor(max(0, y_lo - pad) / 10)
        y_hi = 10 * np.ceil((y_hi + pad) / 10)
    else:
        y_lo, y_hi = y_limits

    positions = list(range(1, len(apps) + 1))
    bp = ax.boxplot(
        data,
        positions=positions,
        widths=0.5,
        patch_artist=True,
        showfliers=True,
        flierprops=dict(marker="o", markersize=3, markerfacecolor="lightgrey",
                         markeredgecolor="grey", alpha=0.6),
        medianprops=dict(color="black", linewidth=1.5),
        whiskerprops=dict(color="black"),
        capprops=dict(color="black"),
        boxprops=dict(linewidth=1),
    )
    for patch, color in zip(bp["boxes"], colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.85)

    # Per-app annotations: whisker min/max (grey, small) + bold median value
    outliers_hidden_total = 0
    for pos, a in zip(positions, apps):
        vals = run_data[a].walltimes.values
        med = np.median(vals)
        whisk_lo = np.min(vals[vals >= np.percentile(vals, 25) - 1.5 *
                                (np.percentile(vals, 75) - np.percentile(vals, 25))]) \
            if len(vals) else np.min(vals)
        whisk_hi = np.max(vals[vals <= np.percentile(vals, 75) + 1.5 *
                                (np.percentile(vals, 75) - np.percentile(vals, 25))]) \
            if len(vals) else np.max(vals)

        hidden = int(np.sum((vals < y_lo) | (vals > y_hi)))
        outliers_hidden_total += hidden

        # whisker labels (grey, offset left of the box, larger for readability)
        if whisk_hi <= y_hi:
            ax.text(pos - 0.34, whisk_hi, f"{whisk_hi:.0f}", fontsize=9,
                    color="dimgrey", va="bottom", ha="center")
        if whisk_lo >= y_lo:
            ax.text(pos - 0.34, whisk_lo, f"{whisk_lo:.0f}", fontsize=9,
                    color="dimgrey", va="top", ha="center")
        # bold median, offset to the right of the box
        ax.text(pos + 0.34, med, f"{med:.0f}", fontsize=12, fontweight="bold",
                color="black", va="center", ha="left")

    # X-axis labels: app name on one line, sample size (n=) just below it,
    # so readers can see exactly how many CSV rows fed each box.
    xtick_labels = []
    for a in apps:
        n_samples = len(run_data[a].walltimes)
        xtick_labels.append(f"{a}\n(n = {n_samples:,})")

    ax.set_xticks(positions)
    ax.set_xticklabels(xtick_labels, fontsize=12)
    ax.tick_params(axis="y", labelsize=11)
    ax.set_ylabel("Walltime (sec)", fontsize=13)
    ax.set_ylim(y_lo, y_hi)
    ax.set_title(
        "Combined Walltime Distribution by Application",
        fontsize=16, fontweight="bold", pad=34,
    )
    ax.text(0.5, 1.02, f"AT-Bench Verification Run  —  {run_date}",
            transform=ax.transAxes, ha="center", va="bottom",
            fontsize=11, color="dimgrey")
    ax.grid(axis="y", linestyle=":", alpha=0.5)

    if outliers_hidden_total > 0:
        ax.text(0.5, 0.02, f"{outliers_hidden_total} outlier(s) not shown "
                f"(outside plotted y-axis range)",
                transform=ax.transAxes, ha="center", va="bottom",
                fontsize=9, style="italic", color="dimgrey")

    # Per-app SLA/target line(s): group apps sharing the same target value
    # (from the .txt "Walltime: maximum" field, falling back to
    # `fallback_target` if not found) and draw one dashed segment per group.
    target_by_app: Dict[str, Optional[float]] = {}
    for a in apps:
        s = run_data[a].summary
        t = s.walltime_max if (s and s.walltime_max is not None) else fallback_target
        target_by_app[a] = t

    groups: Dict[float, List[int]] = {}
    for pos, a in zip(positions, apps):
        t = target_by_app[a]
        if t is None:
            continue
        groups.setdefault(t, []).append(pos)

    for t, group_positions in groups.items():
        if t < y_lo or t > y_hi:
            continue
        x0 = min(group_positions) - 0.4
        x1 = max(group_positions) + 0.4
        ax.plot([x0, x1], [t, t], linestyle="--", color="red", linewidth=1.3)
        ax.text(x1 + 0.05, t, f"{t:.0f} sec\ntarget", color="red", fontsize=8,
                fontweight="bold", va="center", ha="left")

    ax.set_xlim(0.4, len(apps) + 1.05)
    fig.text(0.5, 0.01, DISCLAIMER, ha="center", va="bottom", fontsize=7, color="grey")
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    log.info("Saved boxplot -> %s", output_path)


# --------------------------------------------------------------------------
# Plot 2: Combined job-status bar chart
# --------------------------------------------------------------------------

def plot_job_stats_bar(
    run_data: Dict[str, AppRunData],
    output_path: Path,
    run_date: Optional[str] = None,
    target_walltime: Optional[float] = 480.0,
) -> None:
    """
    One stacked bar per application: Successful (bottom) + Slow (middle) +
    Failed (top), each segment labeled with its count and % of that app's
    total. The app's Total job count is printed above the bar, and each
    x-tick shows the app's version + nodes-per-job (see APP_METADATA).
    """
    apps = [a for a in run_data if run_data[a].summary is not None]
    if not apps:
        log.error("No summary data available for any app; skipping bar chart.")
        return

    run_date = run_date or datetime.now().strftime("%d %B %Y")
    wt = target_walltime if target_walltime is not None else 480.0

    segments = ["Successful", "Slow", "Failed"]
    seg_colors = {"Successful": "#4C9A4C", "Slow": "#E0A458", "Failed": "#C0504D"}
    seg_labels = {
        "Successful": f"Successful (≤ {wt:.0f} sec)",
        "Slow": f"Slow (> {wt:.0f} sec)",
        "Failed": "Failed",
    }

    x = np.arange(len(apps))
    bar_width = 0.55

    fig, ax = plt.subplots(figsize=(11, 8))

    bottoms = np.zeros(len(apps))
    for seg in segments:
        values = []
        for a in apps:
            s = run_data[a].summary
            v = getattr(s, seg.lower())
            values.append(v if v is not None else 0)
        values = np.array(values, dtype=float)

        bars = ax.bar(x, values, width=bar_width, bottom=bottoms,
                      label=seg_labels[seg], color=seg_colors[seg],
                      edgecolor="white", linewidth=1)

        for rect, v, base, a in zip(bars, values, bottoms, apps):
            if v <= 0:
                continue
            s = run_data[a].summary
            total = s.total or (v + base)
            pct = (v / total * 100) if total else 0
            # Only annotate inside the segment if it's tall enough to fit
            # the two-line label; otherwise skip (still visible in legend).
            if v / max(total, 1) > 0.04:
                ax.text(rect.get_x() + rect.get_width() / 2,
                        base + v / 2,
                        f"{int(v):,}\n({pct:.1f}%)",
                        ha="center", va="center", fontsize=10,
                        color="white", fontweight="bold")

        bottoms += values

    # Total job count printed above each bar
    for xi, a in zip(x, apps):
        s = run_data[a].summary
        total = s.total if s.total is not None else int(bottoms[xi])
        ax.text(xi, bottoms[xi] + max(bottoms) * 0.015,
                f"Total Jobs: {total:,}", ha="center", va="bottom",
                fontsize=12, fontweight="bold", color="black")

    def _xtick_label(app: str) -> str:
        meta = APP_METADATA.get(app)
        if not meta:
            return app
        return f"{app} ({meta['version']})\n{meta['nodes_per_job']} Nodes per Job"

    ax.set_xticks(x)
    ax.set_xticklabels([_xtick_label(a) for a in apps], fontsize=12)
    ax.tick_params(axis="y", labelsize=11)
    ax.set_ylabel("Number of Jobs", fontsize=13)
    ax.set_ylim(0, max(bottoms) * 1.12)
    ax.set_title("Job Run Statistics by Application", fontsize=16,
                 fontweight="bold", pad=34)
    ax.text(0.5, 1.02, f"Successful / Slow / Failed breakdown  —  {run_date}",
            transform=ax.transAxes, ha="center", va="bottom",
            fontsize=11, color="dimgrey")
    ax.legend(loc="upper right", frameon=True, fontsize=10)
    ax.grid(axis="y", linestyle=":", alpha=0.5)
    fig.text(0.5, 0.01, DISCLAIMER, ha="center", va="bottom", fontsize=7, color="grey")
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    log.info("Saved bar chart -> %s", output_path)


# --------------------------------------------------------------------------
# Plot 3: Node-status bar (cluster-wide, not per-app)
# --------------------------------------------------------------------------

def plot_node_status_bar(
    node_counts: Dict[str, int],
    output_path: Path,
    run_date: Optional[str] = None,
) -> None:
    """One stacked bar: how many of the nodes today's verification run
    actually TESTED (i.e. showed up in some job's nodelist) came back
    Successful / Slow / Failed (see read_node_counts) -- distinct from
    plot_job_stats_bar's per-app JOB counts, this is node-level, answering
    "of the nodes we exercised today, what shape were they in." Scoped to
    tested nodes only -- not a comparison against the cluster's total size."""
    run_date = run_date or datetime.now().strftime("%d %B %Y")

    tested = sum(node_counts.values())
    if tested == 0:
        log.warning("No success/slow/failed node data available; skipping node-status chart.")
        return

    segments = ["Success", "Slow", "Failed"]
    seg_colors = {"Success": "#4C9A4C", "Slow": "#E0A458", "Failed": "#C0504D"}

    fig, ax = plt.subplots(figsize=(7.5, 8))

    bottom = 0.0
    for seg in segments:
        v = node_counts[seg]
        if v <= 0:
            continue
        ax.bar([0], [v], bottom=bottom, width=0.5, label=seg,
               color=seg_colors[seg], edgecolor="white", linewidth=1)
        pct = v / tested * 100 if tested else 0
        if v / tested > 0.025:
            ax.text(0, bottom + v / 2, f"{v:,}\n({pct:.1f}%)",
                    ha="center", va="center", fontsize=10.5, fontweight="bold", color="white")
        bottom += v

    ax.text(0, bottom + max(bottom, 1) * 0.015, f"Total tested: {tested:,}",
            ha="center", va="bottom", fontsize=12, fontweight="bold", color="black")

    ax.set_xticks([0])
    ax.set_xticklabels(["Tested Nodes"], fontsize=13)
    ax.set_xlim(-0.7, 0.7)
    ax.tick_params(axis="y", labelsize=11)
    ax.set_ylabel("Number of Nodes", fontsize=13)
    ax.set_ylim(0, bottom * 1.12)
    ax.set_title("Node Status Among Tested Nodes", fontsize=16, fontweight="bold", pad=34)
    subtitle = f"Success / Slow / Failed nodes actually exercised today  —  {run_date}"
    ax.text(0.5, 1.02, subtitle, transform=ax.transAxes, ha="center", va="bottom",
            fontsize=10.5, color="dimgrey")
    ax.legend(loc="upper right", frameon=True, fontsize=10)
    ax.grid(axis="y", linestyle=":", alpha=0.5)
    fig.text(0.5, 0.01, DISCLAIMER, ha="center", va="bottom", fontsize=7, color="grey")
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    log.info("Saved node-status chart -> %s", output_path)


# --------------------------------------------------------------------------
# Console summary report
# --------------------------------------------------------------------------

def print_report(run_data: Dict[str, AppRunData]) -> None:
    print("\n" + "=" * 70)
    print("AT-BENCH RUN ANALYSIS SUMMARY")
    print("=" * 70)
    for app, rd in run_data.items():
        print(f"\n[{app}]")
        s = rd.summary
        if s is not None:
            print(f"  Total jobs (from log)   : {s.total}")
            print(f"  Successful              : {s.successful}")
            print(f"  Slow                    : {s.slow}")
            print(f"  Failed/Incomplete       : {s.failed}")
            if s.walltime_min is not None or s.walltime_max is not None:
                print(f"  Acceptable walltime     : "
                      f"{s.walltime_min} - {s.walltime_max} sec")
        else:
            print("  (no summary .txt parsed)")

        if len(rd.walltimes):
            wt = rd.walltimes
            print(f"  Walltime samples (CSV)  : n={len(wt)} "
                  f"(rows seen={rd.n_rows_total}, dropped={rd.n_rows_dropped})")
            print(f"  Walltime min/median/max : "
                  f"{wt.min():.1f} / {wt.median():.1f} / {wt.max():.1f} sec")
        else:
            print("  (no walltime data parsed from CSV)")
    print("\n" + "=" * 70 + "\n")


# --------------------------------------------------------------------------
# Public entry point
# --------------------------------------------------------------------------

def run_analysis(
    log_dir: str,
    output_dir: str,
    apps: Optional[List[str]] = None,
    target_walltime: Optional[float] = 480.0,
    run_date: Optional[str] = None,
) -> Dict[str, AppRunData]:
    """
    Programmatic entry point. Returns the parsed run data dict.

    `run_date` is the date label printed on all three charts (defaults to
    today's date). Pass an explicit value (e.g. "04 August 2026") if
    you're re-analyzing a past date's LOGS directory after the fact.
    """
    log_dir_p = Path(log_dir).expanduser().resolve()
    out_dir_p = Path(output_dir).expanduser().resolve()
    out_dir_p.mkdir(parents=True, exist_ok=True)

    if not log_dir_p.is_dir():
        raise FileNotFoundError(f"Log directory not found: {log_dir_p}")

    apps = apps or DEFAULT_APPS
    run_date = run_date or datetime.now().strftime("%d %B %Y")
    log.info("Scanning %s for apps: %s", log_dir_p, ", ".join(apps))

    run_data = collect_run_data(log_dir_p, apps)
    print_report(run_data)

    plot_combined_boxplot(
        run_data,
        out_dir_p / "combined_boxplot.png",
        fallback_target=target_walltime,
        run_date=run_date,
    )
    plot_job_stats_bar(run_data, out_dir_p / "combined_job_stats.png",
                       run_date=run_date, target_walltime=target_walltime)

    nodes_dir = log_dir_p / "nodes"
    if nodes_dir.is_dir():
        node_counts = read_node_counts(nodes_dir)
        plot_node_status_bar(node_counts, out_dir_p / "combined_node_stats.png", run_date=run_date)
    else:
        log.warning("No nodes/ directory found under %s; skipping node-status chart", log_dir_p)

    return run_data


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze AT-Bench verification LOGS for HPC applications "
                    "and produce a combined walltime boxplot + job-status bar chart."
    )
    parser.add_argument("--log-dir", required=True,
                        help="Path to the day's LOGS directory, e.g. "
                             ".../AT-Bench/CRON/Verification/LOGS/04August2026")
    parser.add_argument("--output-dir", required=True,
                        help="Directory to write the PNG charts into")
    parser.add_argument("--apps", nargs="*", default=None,
                        help=f"App names to look for (default: {DEFAULT_APPS})")
    parser.add_argument("--target-walltime", type=float, default=480.0,
                        help="Fallback SLA/target walltime (sec) used only if "
                             "an app's .txt doesn't specify one (default: 480)")
    parser.add_argument("--run-date", default=None,
                        help="Date label to print on the charts, e.g. "
                             "'04 August 2026' (default: today's date)")
    args = parser.parse_args()

    try:
        run_analysis(
            log_dir=args.log_dir,
            output_dir=args.output_dir,
            apps=args.apps,
            target_walltime=args.target_walltime,
            run_date=args.run_date,
        )
    except Exception as exc:
        log.error("Analysis failed: %s", exc)
        sys.exit(1)


if __name__ == "__main__":
    main()
