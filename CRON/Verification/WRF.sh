#!/bin/bash

export MainDir=/home/nsmapplication/cdacapp01/AT-Bench

TODAY=$(date +"%d%B%Y")
echo "$TODAY"

export OUTDIR="${OUTDIR:-/home/nsmapplication/cdacapp01/scratch/AT-RUN/$TODAY}"

DATED_DIR="$MainDir/LOGS/wrf-logs/$TODAY"
mkdir -p "$DATED_DIR"

source $MainDir/SCRIPTS/verification/wrf/wrf-verify-results.sh 2>&1 | tee "$DATED_DIR/wrf.txt"

sleep 5

LOG_DIR="$MainDir/CRON/Verification/LOGS/$TODAY"

mkdir -p "$LOG_DIR"

cp "$DATED_DIR/wrf.txt" "$LOG_DIR"
cp "$DATED_DIR/WRF-results.csv" "$LOG_DIR"

# Node lists (success/slow/failed) parsed out of the summary just written,
# so a bad-node exclude/include list is always ready alongside the CSV.
# Written straight into LOG_DIR/nodes (shared with GROMACS/NAMD/OFM, each
# prefixed with its own app name) so run-verification.sh can combine them
# across apps once all four wrappers finish.
NODES_DIR="$LOG_DIR/nodes"
mkdir -p "$NODES_DIR"
"$MainDir/SCRIPTS/extract-nodes" "$DATED_DIR/wrf.txt" "$NODES_DIR"


