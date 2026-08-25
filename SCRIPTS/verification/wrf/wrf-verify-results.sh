#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
#
# OPTIMIZED: job-directory lookup changed from O(N x M) (one full `find`
# per job) to O(N + M) (one full `find` total, then O(1) in-memory lookups
# via an associative array). Also removes the per-job `sleep 2`, which at
# scale (N jobs) was adding N x 2 seconds of pure sleep on its own, caches
# each job's nodelist.txt read once instead of re-reading it multiple
# times per job, and fixes two copy-paste bugs from the shared template:
#   1. Summary block referenced $nsperday_min/$nsperday_max, which WRF
#      never defines (this check is walltime-only) - those lines removed.
#   2. One "Important*" line was being written to LOGS/NAMD_Summary.txt
#      instead of LOGS/WRF_Summary.txt - corrected.
#
# LOG HIERARCHY (2026-08-05): dropped LOGS/WRF_Summary.txt entirely (it
# was tee -a'd forever, never rotated - the fix above corrected which
# file it grew into, this fix stops it growing at all). See the
# equivalent note in namd-verify-results.sh for the full rationale.
# Results CSV now lands under a dated subfolder
# (LOGS/wrf-logs/<DDMonthYYYY>/) when $TODAY is set by the calling wrapper,
# falling back to the flat path for manual atVerify.sh runs.
# =============================================================================


# Specify the path to the file containing Slurm job IDs
#job_ids_file="$MainDir/LOGS/JobIDs/WRF_JobIDs.txt"
job_ids_file="$OUTDIR/WRF/WRF_JobIDs.txt"
## For CSV file results
# Define the CSV file (dated subfolder when the calling wrapper sets $TODAY,
# flat path for manual atVerify.sh runs where $TODAY is unset)
if [ -n "$TODAY" ]; then
    mkdir -p "$MainDir/LOGS/wrf-logs/$TODAY"
    csv_file="$MainDir/LOGS/wrf-logs/$TODAY/WRF-results.csv"
else
    csv_file="$MainDir/LOGS/wrf-logs/WRF-results.csv"
fi
[ -f "$csv_file" ] && rm "$csv_file"
# Check if the CSV file exists
if [ ! -f "$csv_file" ]; then
    # If the CSV file doesn't exist, create it with headers
    echo "job_id,walltime,nodelist" > "$csv_file"
fi
###
# Define the acceptable ranges for ns/Day and WallClock time
nnodes=11
#1. ns/Day renge
#nsperday_min=1
#nsperday_max=2
#2. Walltime renge
walltime_min=300
walltime_max=480

#-----------------------------------------

### Initialize useful counters
ok_jobs=0
FileNotFoundJobs=0
NotWithinRengeJobs=0

if [ ! -s "$job_ids_file" ]; then
    echo "ERROR: $job_ids_file is missing or empty -- WRF job submission may not have run, or OUTDIR/BASE_OUTDIR doesn't match tonight's submission. Aborting instead of silently reporting 0 jobs as a clean run." >&2
    return 1
fi
totalJobs=$(cat $job_ids_file | wc -l)
# Loop through each job ID in the file
[ -f $MainDir/SCRIPTS/verification/wrf/SuccesfullJobIDs ] && rm $MainDir/SCRIPTS/verification/wrf/SuccesfullJobIDs
[ -f $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs ] && rm $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs
[ -f $MainDir/SCRIPTS/verification/wrf/ResultOutOffRengeJobIDs ] && rm $MainDir/SCRIPTS/verification/wrf/ResultOutOffRengeJobIDs

# =============================================================================
# ONE-TIME INDEX BUILD (replaces the per-job `find` call)
#
# Instead of running `find $OUTDIR/WRF -name "*$job_id*"` once for EVERY
# job (re-walking the whole tree each time), we walk the tree exactly once
# here and build an associative array: RUNDIR_OF[job_id] -> directory.
#
# ASSUMPTION: each job has its own run directory somewhere directly under
# $OUTDIR/WRF, and the job ID appears as a distinct numeric token in that
# directory's name (e.g. "case_1234", "1234_run", "WRF_1234"). The regex
# below requires the job ID to be bounded by non-digit characters (or
# string start/end), so job 123 can no longer be mistaken for a substring
# of job 1234, 41230, etc. (that ambiguity existed in the original
# `-name "*$job_id*"` and got riskier as job counts grew).
#
# If your run directories are nested more than one level deep under
# $OUTDIR/WRF, adjust/remove `-maxdepth 1` below accordingly. Run
# `find "$OUTDIR/WRF" -maxdepth 2 -type d | head` once by hand if you're
# not sure of the actual depth/naming before relying on this.
# =============================================================================
declare -A RUNDIR_OF

while IFS= read -r -d '' d; do
    dname=$(basename "$d")
    if [[ "$dname" =~ (^|[^0-9])([0-9]+)([^0-9]|$) ]]; then
        RUNDIR_OF["${BASH_REMATCH[2]}"]="$d"
    fi
done < <(find "$OUTDIR/WRF" -mindepth 1 -maxdepth 1 -type d -print0)

# =============================================================================
# SECOND-PASS FILE INDEX (fixes false "file not found" for reused "RUN-N"
# slot directories)
#
# wrf.sh submits into a fixed pool of reusable "RUN-N" slot directories
# (N = slot number, unrelated to any job ID), same as GROMACS/NAMD/OpenFOAM.
# The dirname-only pass above only ever finds the job ID for a directory
# already renamed to the job ID itself (wrf.job.sh's own `mv $SLURM_SUBMIT_DIR
# $JOBDIR` at the end of a completed run): for a still-pending/still-running
# "RUN-N" slot, it indexes RUNDIR_OF[N] (the slot number, which no real job ID
# ever equals), so any job still sitting in its slot directory at
# verification time was silently falling through to "file not found" even
# though its job.<job_id>.out was sitting right there. Fix: also index every
# "job.<job_id>.out" file's containing directory directly by the job ID in
# its filename (wrf.job.sh's own `#SBATCH --error=job.%J.out`), regardless
# of the directory's own name. Existing dirname-based entries are left
# alone (first match wins).
# =============================================================================
while IFS= read -r -d '' f; do
    fname=$(basename "$f")
    if [[ "$fname" =~ ^job\.([0-9]+)\.out$ ]]; then
        jid="${BASH_REMATCH[1]}"
        [ -z "${RUNDIR_OF[$jid]:-}" ] && RUNDIR_OF["$jid"]=$(dirname "$f")
    fi
done < <(find "$OUTDIR/WRF" -mindepth 2 -maxdepth 2 -type f -name "job.*.out" -print0)

echo "Indexed ${#RUNDIR_OF[@]} run directories under $OUTDIR/WRF"
echo "-------------------------"

#
while IFS= read -r job_id; do
    echo "Checking JOB-ID: $job_id ..."

    RUNDIR="${RUNDIR_OF[$job_id]:-}"
    echo "Job Dir: $RUNDIR"

    # Read the nodelist once per job instead of re-reading it multiple
    # times further down (each `cat` was a separate filesystem hit before).
    NODELIST=""
    [ -n "$RUNDIR" ] && [ -f "$RUNDIR/nodelist.txt" ] && NODELIST=$(cat "$RUNDIR/nodelist.txt")

    #--- Verification of different Parametes
    if [ -n "$RUNDIR" ] && [ -e "$RUNDIR/WRF.rsl" ] && [ -e "$RUNDIR/WRF.result" ] \
        && grep -q "SUCCESS" "$RUNDIR/WRF.rsl" && grep -q "real" "$RUNDIR/WRF.result"; then
        # Get the run time
        walltime=$(grep "real" "$RUNDIR/WRF.result" | awk '{print $2}')
        minutes=$(echo "$walltime" | sed 's/m.*//')
        seconds=$(echo "$walltime" | sed 's/.*m//;s/s//')
        total_seconds=$(echo "$minutes * 60 + $seconds" | bc)
        echo "RESULTS: WallTime(real)=$total_seconds s"

        # Update the values in the CSV file
        echo "$job_id,$total_seconds,\"$NODELIST\"" >> "$csv_file"

        # Check if values are within the specified ranges
        if (( $(echo "$total_seconds >= $walltime_min && $total_seconds <= $walltime_max" | bc -l) )); then
                #If Within renge
                #successfull Jobs
                echo ":OK: The job with JOB ID $job_id is succesfull and outputs are within renge"
                echo "$job_id(Nodelist:$NODELIST)" >> $MainDir/SCRIPTS/verification/wrf/SuccesfullJobIDs
                [ -n "$NODELIST" ] && echo "Nodelist: $NODELIST"
                ((ok_jobs++))
        else
                #If not within renge
                #unsuccesfull Jobs
                echo ":Slow Jobs: The results are not within the renge. Check JOB ID: $job_id"
                echo "$job_id(Nodelist:$NODELIST)" >> $MainDir/SCRIPTS/verification/wrf/ResultOutOffRengeJobIDs
                [ -n "$NODELIST" ] && echo "Nodelist: $NODELIST"
                ((NotWithinRengeJobs++))
        fi
    else
        #Incomplete Jobs
        echo ":Failed Jobs: Results are incomplete! Please Check Job ID: $job_id"
        echo "-------------------------"
        if [ -n "$NODELIST" ]; then
            echo "$job_id(Nodelist:$NODELIST)" >> $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs
            echo "Nodelist: $NODELIST"
        else
            # Deliberately NOT wrapped as "(Nodelist:...)" -- see the same
            # note in gromacs-verify-results.sh: extract-nodes matches that
            # exact wrapper as a real SLURM hostlist token.
            echo "$job_id: run directory not found (nodelist unknown)" >> $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs
        fi
        ((FileNotFoundJobs++))
        echo "-------------------------"
        unset walltime
        continue
    fi

    echo "-------------------------"

    unset walltime

done < "$job_ids_file"

###############################################################
#                      Summary                                #
###############################################################

not_ok_jobs=$(( NotWithinRengeJobs + FileNotFoundJobs ))

echo "##########################################################"
echo "%   WRF Job Summary: Time-$(date +"%Y-%m-%d %H:%M:%S")   %"
echo "##########################################################"
echo "Total WRF Jobs: $totalJobs                               "
echo "Acceptable results range for $nnodes nodes)"
echo "Walltime: minumum = $walltime_min"
echo "Walltime: maximum = $walltime_max"
# Succesfull Jobs
echo "----------------------------------------------------------"
echo "            A.SUCCESSFULL JOBS:(Results within range)                           "
echo "No. of Succesfull Jobs= $ok_jobs                         "
[ -f $MainDir/SCRIPTS/verification/wrf/SuccesfullJobIDs ] && success_job_ids=$(cat $MainDir/SCRIPTS/verification/wrf/SuccesfullJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $success_job_ids                     "
[ -f $MainDir/SCRIPTS/verification/wrf/SuccesfullJobIDs ] && echo "Note*: The results of the above jobs are within specified renge!"
# Unsuccesfull Jobs
echo "----------------------------------------------------------"
echo "            B.SLOW JOBS:(Results not within range) $not_ok_jobs            "
# Outoff renge Jobs
echo "No. of Slow Jobs= $NotWithinRengeJobs            "
[ -f $MainDir/SCRIPTS/verification/wrf/ResultOutOffRengeJobIDs ] && outoffrenge_job_ids=$(cat $MainDir/SCRIPTS/verification/wrf/ResultOutOffRengeJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $outoffrenge_job_ids                 "
[ -f $MainDir/SCRIPTS/verification/wrf/ResultOutOffRengeJobIDs ] && echo "Important*: You may need to debug above Jobs as results are not within specified renge! "

# Incomplete Jobs
echo "----------------------------------------------------------"
echo "            C.INCOMPLETE JOBS:(Output not generated) $not_ok_jobs               "
# File Not Found Jobs
echo "No. of Incomplete Jobs= $FileNotFoundJobs                 "
[ -f $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs ] && filenotexist_job_ids=$(cat $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $filenotexist_job_ids                "
[ -f $MainDir/SCRIPTS/verification/wrf/FileNotExistsJobIDs ] && echo "Important*: You may need to either wait for the results of above jobs or Debug the issue as result is not complete yet! "

echo "----------------------------------------------------------"
echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
