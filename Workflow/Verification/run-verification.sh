#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================
#
# Consolidated verification wrapper - the verification-side twin of
# Workflow/Jobsubmission/run-jobsubmission.sh. Verifies NAMD, GROMACS,
# OpenFOAM and WRF in parallel, then plots the combined graphs.
#
# Same "one file to edit" pattern as run-jobsubmission.sh's BASE_OUTDIR:
# the run directory to verify is set ONCE below and exported as OUTDIR
# to GROMACS.sh/NAMD.sh/OFM.sh/WRF.sh (which no longer hardcode their
# own OUTDIR), so pointing verification at a different run no longer
# means editing 4 separate files.
# =============================================================================

export MainDir=/home/nsmapplication/cdacapp01/AT-Bench

# Every generated file (text/CSV at the top as a "#" comment line, PNGs at
# the bottom in small print - see atbench_analyzer.py/job_debug_analyzer.py)
# carries this. A "#" line is filtered out by every downstream reader
# before it parses the actual data below it.
DISCLAIMER="Disclaimer: Internal testing, not publication ready. Contact: omjadhav@cdac.in"

#===========================================================================
# CONFIGURATION - this is the one file to edit. GROMACS.sh/NAMD.sh/OFM.sh/
# WRF.sh and the *-verify-results.sh scripts they source all read OUTDIR
# from the environment - no other file needs touching to verify a
# different run.
#
#   BASE_OUTDIR : parent directory holding the dated run folders
#                 (BASE_OUTDIR/<DDMonthYYYY>/<APP>/...) - same layout
#                 run-jobsubmission.sh's BASE_OUTDIR writes into.
#
# To verify a one-off run without editing this file, pass the parent
# directory as an argument instead:
#   ./run-verification.sh /path/to/run-parent-dir
#===========================================================================

export BASE_OUTDIR="${1:-/home/nsmapplication/cdacapp01/scratch/AT-RUN/}"

#===========================================================================
# end configuration
#===========================================================================

TODAY=$(date +"%d%B%Y")
echo "$TODAY"

export OUTDIR="$BASE_OUTDIR/$TODAY"
echo "Verifying run directory: $OUTDIR"

### Section-1: Run the verification

bash $MainDir/Workflow/Verification/GROMACS.sh &
bash $MainDir/Workflow/Verification/NAMD.sh &
bash $MainDir/Workflow/Verification/OFM.sh &
bash $MainDir/Workflow/Verification/WRF.sh &

wait

echo "All scripts completed."

### Section-1b: Combine each app's node lists into one cluster-wide list
#
# GROMACS.sh/NAMD.sh/OFM.sh/WRF.sh each already wrote their own
# <app>-success-nodes.txt / <app>-slow-nodes.txt / <app>-failed-nodes.txt
# into $NODES_DIR. This merges them into cluster-wide success-nodes.txt /
# slow-nodes.txt / failed-nodes.txt once all four have finished, so a node
# that showed up bad in e.g. GROMACS but not WRF still lands in the
# combined slow/failed list.
#
# A node can legitimately appear in more than one app's/job's category
# (e.g. it succeeded a GROMACS job but was slow in a WRF job), so the
# per-category unions below are not mutually exclusive on their own.
# Since these three files are meant to be used as clean --nodelist=/
# --exclude= inputs, each node is then assigned to exactly one combined
# list by its worst observed outcome - failed beats slow beats success -
# so success-nodes.txt, slow-nodes.txt and failed-nodes.txt never overlap.

NODES_DIR="$MainDir/Workflow/Verification/LOGS/$TODAY/nodes"

for category in success slow failed; do
    cat "$NODES_DIR"/*-"${category}"-nodes.txt 2>/dev/null |
        grep -v '^#' |
        tr ',' '\n' |
        sed '/^$/d' |
        sort -u > "$NODES_DIR/.${category}-nodes.raw"
done

comm -23 "$NODES_DIR/.slow-nodes.raw" "$NODES_DIR/.failed-nodes.raw" \
    > "$NODES_DIR/.slow-nodes.clean"
comm -23 "$NODES_DIR/.success-nodes.raw" "$NODES_DIR/.failed-nodes.raw" |
    comm -23 - "$NODES_DIR/.slow-nodes.raw" \
    > "$NODES_DIR/.success-nodes.clean"

{ echo "# $DISCLAIMER"; paste -sd, "$NODES_DIR/.failed-nodes.raw"; }    > "$NODES_DIR/failed-nodes.txt"
{ echo "# $DISCLAIMER"; paste -sd, "$NODES_DIR/.slow-nodes.clean"; }    > "$NODES_DIR/slow-nodes.txt"
{ echo "# $DISCLAIMER"; paste -sd, "$NODES_DIR/.success-nodes.clean"; } > "$NODES_DIR/success-nodes.txt"

rm -f "$NODES_DIR"/.success-nodes.raw "$NODES_DIR"/.slow-nodes.raw "$NODES_DIR"/.failed-nodes.raw \
      "$NODES_DIR"/.slow-nodes.clean "$NODES_DIR"/.success-nodes.clean

echo "Combined node lists written to $NODES_DIR (success/slow/failed are mutually exclusive)"

### Section-1c: One clean failed/incomplete job-ID list across all apps
#
# Pulls the job IDs out of each app's *-failed-nodes-by-job.txt (already
# written by extract-nodes from the C.INCOMPLETE/C.UNSUCCESFULL section of
# that app's summary) into a single app,job_id list for debugging - e.g.
# feeding job_debug_analyzer.py or sacct/scontrol lookups per job. Tagged
# with app since job output for the same ID lives under a different
# OUTDIR/<APP>/ tree per app.

FAILED_JOBS_FILE="$NODES_DIR/failed-jobs.txt"

{
    echo "# $DISCLAIMER"
    echo "app,job_id"
    for byjobfile in "$NODES_DIR"/*-failed-nodes-by-job.txt; do
        [ -s "$byjobfile" ] || continue
        app=$(basename "$byjobfile" | sed 's/-failed-nodes-by-job\.txt$//')
        grep -v '^#' "$byjobfile" | awk -F': ' -v app="$app" 'NF { print app "," $1 }'
    done | sort -t, -k2,2n
} > "$FAILED_JOBS_FILE"

echo "Failed job-ID list written to $FAILED_JOBS_FILE ($(($(wc -l < "$FAILED_JOBS_FILE") - 2)) jobs)"

sleep 10

### Section-2 : Plot the graphs

# cron runs a non-login, non-interactive shell that never sources
# /etc/profile.d/modules.sh, so the `module` function/command doesn't
# exist here by default (confirmed in cron-job-verification-logs:
# "run-verification.sh: line 20: module: command not found", every day
# since 2026-08-05) and `module load miniconda` was silently a no-op,
# leaving plain system python3 (no matplotlib/numpy/pandas) to run
# atbench_analyzer.py, which then crashed on `import matplotlib` before
# either PNG chart was written. Source Lmod's init script first so
# `module load` actually works under cron.
[ -f /etc/profile.d/modules.sh ] && source /etc/profile.d/modules.sh
module load miniconda

TODAY=$(date +"%d%B%Y")
echo "$TODAY"

LOGDIR=/home/nsmapplication/cdacapp01/AT-Bench/Workflow/Verification/LOGS/$TODAY
OUTDIR=$LOGDIR

python3 $MainDir/Workflow/graph/atbench_analyzer.py --log-dir "$LOGDIR"  --output-dir "$OUTDIR"

### Section-3: Debug pipeline - deep-dive into WHY the failed jobs failed
#
# Verification (Section 1) already decided WHICH jobs failed -- $NODES_DIR/
# failed-jobs.txt (Section 1c) is that authoritative app,job_id list. Feed
# it straight into job_debug_analyzer.py's --failed-jobs-csv (targeted)
# mode instead of letting the analyzer rescan every job and re-derive
# success/slow/failed itself: it trusts that verdict, analyzes only those
# failed jobs, and skips writing the plain job-ID/node-list outputs that
# would just restate what LOGS/<date>/nodes/ already has. What's left is
# exactly the part verification doesn't do -- reading each failed job's
# raw .err/output files to classify WHY (network/IB fault, MPI launch
# failure, segfault, env error, OOM, ...), plus mass-cancellation
# clustering and cross-app faulty-node ranking, written into its own
# LOGS/<date>/debug/ directory alongside nodes/.
#
# Uses BASE_OUTDIR/$TODAY (not $OUTDIR, reassigned above to $LOGDIR for
# atbench_analyzer.py) for the actual raw job-output tree to read.

DEBUG_RUN_DIR="$BASE_OUTDIR/$TODAY"
DEBUG_OUT_DIR="$MainDir/Workflow/Verification/LOGS/$TODAY/debug"
mkdir -p "$DEBUG_OUT_DIR"

python3 "$MainDir/SCRIPTS/debug/job_debug_analyzer.py" \
    --run-dir "$DEBUG_RUN_DIR" \
    --failed-jobs-csv "$NODES_DIR/failed-jobs.txt" \
    --output-dir "$DEBUG_OUT_DIR" \
    --run-label "$TODAY"

echo "Debug analysis written to $DEBUG_OUT_DIR"
