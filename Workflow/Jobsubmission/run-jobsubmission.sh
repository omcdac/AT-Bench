#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================
#
# Consolidated job-submission wrapper - the submission-side twin of
# Workflow/Verification/run-verification.sh. Submits NAMD, GROMACS, OpenFOAM
# and WRF in parallel (same 4 apps run-verification.sh verifies), each
# into its own dated log file, then prints a submitted/failed count per
# app once all four finish. One crontab entry (or one manual run) in
# place of the 4 separate per-app entries.
#
# Log layout (mirrors Workflow/Verification's LOGS/<app>-logs/<date>/ fix):
#   Workflow/Jobsubmission/cron-job-submission-logs/<DDMonthYYYY>/
#     NAMD.log  GROMACS.log  OpenFOAM.log  WRF.log   (per-app raw output)
#     Summary.txt                                     (combined report)
# =============================================================================

export MainDir=/home/nsmapplication/cdacapp01/AT-Bench

#===========================================================================
# CONFIGURATION - this is the one file to edit. Everything below is read
# by SCRIPTS/AT-JobSetup/<APP>-atJobSubmission.sh and the per-app worker
# scripts via exported environment variables - no other file needs
# touching for a reservation/partition/job-count/output-location change.
#
#   *_RESERVATION : SLURM --reservation name for that app's jobs.
#                    Leave as "" for none - empty is a deliberate choice
#                    here, not "unset", so a job template can no longer
#                    silently reactivate an old reservation behind your
#                    back (see SRC/*/input/*.sh - the reservation flag now
#                    comes ONLY from here, the old #SBATCH lines in those
#                    templates were removed).
#   *_PARTITION   : SLURM --partition for that app's jobs.
#   *_NUM_JOBS    : how many jobs of that app to submit this run. If left
#                    unset (commented out), the AT-JobSetup script falls
#                    back to its own TotalNodes/NumberOfNodesPerJob
#                    calculation, so running SCRIPTS/AT-JobSetup/*.sh
#                    directly (e.g. via the interactive JobSubmission.sh
#                    menu, which doesn't go through this wrapper) is
#                    unaffected.
#   BASE_OUTDIR   : parent directory for run output. Each run still gets
#                    its own dated subfolder (BASE_OUTDIR/<DDMonthYYYY>),
#                    same as before - only the parent is configurable here.
#
# Current values below reproduce today's effective settings exactly
# (500 jobs/app, reservation=workingcpunodes, partition=cpu) - editing
# them changes tomorrow's 01:00 AM run, nothing else.
#===========================================================================

export BASE_OUTDIR="/scratch/nsmapplication/cdacapp01/AT-RUN/"

export NAMD_RESERVATION="workingcpunodes"
export NAMD_PARTITION="cpu"
export NAMD_NUM_JOBS=200

export GROMACS_RESERVATION="workingcpunodes"
export GROMACS_PARTITION="cpu"
export GROMACS_NUM_JOBS=200

export OPENFOAM_RESERVATION="workingcpunodes"
export OPENFOAM_PARTITION="cpu"
export OPENFOAM_NUM_JOBS=200

export WRF_RESERVATION="workingcpunodes"
export WRF_PARTITION="cpu"
export WRF_NUM_JOBS=200

#===========================================================================
# end configuration
#===========================================================================

TODAY=$(date +"%d%B%Y")
echo "$TODAY"

LOGDIR="$MainDir/Workflow/Jobsubmission/cron-job-submission-logs/$TODAY"
mkdir -p "$LOGDIR"

OUTDIR="$BASE_OUTDIR/$TODAY"

echo "=============================================="
echo " AT-Bench Job Submission - $TODAY"
echo "=============================================="
echo "Logs: $LOGDIR"
echo ""

### Section-1: Submit jobs for all 4 apps in parallel, each into its own log

bash "$MainDir/Workflow/Jobsubmission/NAMD.sh"    > "$LOGDIR/NAMD.log"     2>&1 &
pid_namd=$!

bash "$MainDir/Workflow/Jobsubmission/GROMACS.sh" > "$LOGDIR/GROMACS.log"  2>&1 &
pid_gromacs=$!

bash "$MainDir/Workflow/Jobsubmission/OFM.sh"     > "$LOGDIR/OpenFOAM.log" 2>&1 &
pid_ofm=$!

bash "$MainDir/Workflow/Jobsubmission/WRF.sh"     > "$LOGDIR/WRF.log"      2>&1 &
pid_wrf=$!

wait $pid_namd;    rc_namd=$?
wait $pid_gromacs; rc_gromacs=$?
wait $pid_ofm;     rc_ofm=$?
wait $pid_wrf;     rc_wrf=$?

echo "All job-submission scripts completed."
echo ""

### Section-2: Per-app submission summary (submitted / failed / exit code)
#
# NAMD-atJobSubmission.sh etc. abort early (pre-flight checks added
# 2026-08-05) if $OUTDIR or the app's input/template is missing - that
# shows up here as submitted=0 with a non-zero exit code, rather than
# needing to open each app's raw log to notice.

{
echo "=============================================="
echo " Job Submission Summary - $TODAY"
echo "=============================================="
printf "%-10s %-12s %-10s %-8s\n" "APP" "SUBMITTED" "FAILED" "EXIT"

declare -A subdir=( [NAMD]=NAMD [GROMACS]=GROMACS [OpenFOAM]=OPENFOAM [WRF]=WRF )
declare -A rc=( [NAMD]=$rc_namd [GROMACS]=$rc_gromacs [OpenFOAM]=$rc_ofm [WRF]=$rc_wrf )

any_issue=0
for app in NAMD GROMACS OpenFOAM WRF; do
    d="${subdir[$app]}"
    jobids_file="$OUTDIR/$d/${d}_JobIDs.txt"
    failed_file="$OUTDIR/$d/${d}_SubmissionFailed.txt"

    submitted=0
    [ -f "$jobids_file" ] && submitted=$(grep -c . "$jobids_file" 2>/dev/null)
    failed=0
    [ -f "$failed_file" ] && failed=$(grep -c . "$failed_file" 2>/dev/null)

    printf "%-10s %-12s %-10s %-8s\n" "$app" "$submitted" "$failed" "${rc[$app]}"

    if [ "${rc[$app]}" -ne 0 ] || [ "$failed" -gt 0 ] || [ "$submitted" -eq 0 ]; then
        any_issue=1
    fi
done
echo "=============================================="
if [ "$any_issue" -eq 1 ]; then
    echo "One or more apps had a non-zero exit code, failed submissions, or"
    echo "submitted 0 jobs - check the per-app log under $LOGDIR"
    echo "and, for individual failed submissions, <APP>_SubmissionFailed.txt"
    echo "under $OUTDIR/<APP>/"
else
    echo "All apps submitted cleanly."
fi
echo "=============================================="
} | tee "$LOGDIR/Summary.txt"
