#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
#
# OPTIMIZED: job-directory lookup changed from O(N x M) (one full `find`
# per job) to O(N + M) (one full `find` total, then O(1) in-memory lookups
# via an associative array). Also removes the per-job `sleep 2`, which at
# scale (N jobs) was adding N x 2 seconds of pure sleep on its own, and
# caches each job's nodelist.txt read once instead of re-reading it
# multiple times per job.
#
# LOG HIERARCHY (2026-08-05): dropped the separate, ever-growing
# LOGS/GROMACS_Summary.txt (tee -a'd forever, never rotated). See the
# equivalent note in namd-verify-results.sh for the full rationale; same
# fix applied here. Results CSV now lands under a dated subfolder
# (LOGS/gromacs-logs/<DDMonthYYYY>/) when $TODAY is set by the calling
# wrapper, falling back to the flat path for manual atVerify.sh runs.
# =============================================================================


# Specify the path to the file containing Slurm job IDs
job_ids_file="$OUTDIR/GROMACS/GROMACS_JobIDs.txt"

## For CSV file results
# Define the CSV file (dated subfolder when the calling wrapper sets $TODAY,
# flat path for manual atVerify.sh runs where $TODAY is unset)
if [ -n "$TODAY" ]; then
    mkdir -p "$MainDir/LOGS/gromacs-logs/$TODAY"
    csv_file="$MainDir/LOGS/gromacs-logs/$TODAY/GROMACS-results.csv"
else
    csv_file="$MainDir/LOGS/gromacs-logs/GROMACS-results.csv"
fi
[ -f "$csv_file" ] && rm "$csv_file"
# Check if the CSV file exists
if [ ! -f "$csv_file" ]; then
    # If the CSV file doesn't exist, create it with headers
    echo "job_id,nsperday,walltime,nodelist" > "$csv_file"
fi
###

# Define the acceptable ranges for ns/Day and WallClock time
nnodes=10
#1. ns/Day renge
nsperday_min=18
nsperday_max=27
#2. Walltime renge
walltime_min=300
walltime_max=480

#-----------------------------------------

### Initialize useful counters
ok_jobs=0
FileNotFoundJobs=0
NotWithinRengeJobs=0

if [ ! -s "$job_ids_file" ]; then
    echo "ERROR: $job_ids_file is missing or empty -- GROMACS job submission may not have run, or OUTDIR/BASE_OUTDIR doesn't match tonight's submission. Aborting instead of silently reporting 0 jobs as a clean run." >&2
    return 1
fi
totalJobs=$(cat $job_ids_file | wc -l)
# Loop through each job ID in the file
[ -f $MainDir/SCRIPTS/verification/gromacs/SuccesfullJobIDs ] && rm $MainDir/SCRIPTS/verification/gromacs/SuccesfullJobIDs
[ -f $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs ] && rm $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs
[ -f $MainDir/SCRIPTS/verification/gromacs/ResultOutOffRengeJobIDs ] && rm $MainDir/SCRIPTS/verification/gromacs/ResultOutOffRengeJobIDs

# =============================================================================
# ONE-TIME INDEX BUILD (replaces the per-job `find` call)
#
# Instead of running `find $OUTDIR/GROMACS -name "*$job_id*"` once for
# EVERY job (re-walking the whole tree each time), we walk the tree exactly
# once here and build an associative array: RUNDIR_OF[job_id] -> directory.
#
# ASSUMPTION: each job has its own run directory somewhere directly under
# $OUTDIR/GROMACS, and the job ID appears as a distinct numeric token in
# that directory's name (e.g. "case_1234", "1234_run", "GROMACS_1234").
# The regex below requires the job ID to be bounded by non-digit characters
# (or string start/end), so job 123 can no longer be mistaken for a
# substring of job 1234, 41230, etc. (that ambiguity existed in the
# original `-name "*$job_id*"` and got riskier as job counts grew).
#
# If your run directories are nested more than one level deep under
# $OUTDIR/GROMACS, adjust/remove `-maxdepth 1` below accordingly. Run
# `find "$OUTDIR/GROMACS" -maxdepth 2 -type d | head` once by hand if
# you're not sure of the actual depth/naming before relying on this.
# =============================================================================
declare -A RUNDIR_OF

while IFS= read -r -d '' d; do
    dname=$(basename "$d")
    if [[ "$dname" =~ (^|[^0-9])([0-9]+)([^0-9]|$) ]]; then
        RUNDIR_OF["${BASH_REMATCH[2]}"]="$d"
    fi
done < <(find "$OUTDIR/GROMACS" -mindepth 1 -maxdepth 1 -type d -print0)

# =============================================================================
# SECOND-PASS FILE INDEX (fixes false "file not found" for reused "RUN-N"
# slot directories)
#
# gromacsJob-softlink.sh submits into a fixed pool of reusable "RUN-N" slot
# directories (N = slot number, unrelated to any job ID) as well as
# directories named directly after the job ID. The dirname-only pass above
# only ever finds the job ID for the latter case: for a "RUN-N" slot, it
# indexes RUNDIR_OF[N] (the slot number, which no real job ID ever equals),
# so every job that lands in a slot directory was silently falling through
# to "file not found" even when its <job_id>.err/.out were sitting right
# there. Fix: also index every "<job_id>.err" file's containing directory
# directly by the job ID in its filename, regardless of the directory's own
# name. Existing dirname-based entries are left alone (first match wins).
# =============================================================================
while IFS= read -r -d '' f; do
    fname=$(basename "$f")
    if [[ "$fname" =~ ^([0-9]+)\.err$ ]]; then
        jid="${BASH_REMATCH[1]}"
        [ -z "${RUNDIR_OF[$jid]:-}" ] && RUNDIR_OF["$jid"]=$(dirname "$f")
    fi
done < <(find "$OUTDIR/GROMACS" -mindepth 2 -maxdepth 2 -type f -name "*.err" -print0)

echo "Indexed ${#RUNDIR_OF[@]} run directories under $OUTDIR/GROMACS"
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
    if [ -n "$RUNDIR" ] && [ -e "$RUNDIR/runtime.txt" ] && grep -q "real" "$RUNDIR/runtime.txt"; then
        # 1. ns/days
        nsperday=$(tail -2 "$RUNDIR/md.log" | head -1 | awk '{print $2}')
        # 2. Wall Clock time (get the run time)
        walltime1=$(grep "real" "$RUNDIR/runtime.txt" | awk '{print $2}')
        minutes=$(echo "$walltime1" | sed 's/m.*//')
        seconds=$(echo "$walltime1" | sed 's/.*m//;s/s//')
        walltime=$(echo "$minutes * 60 + $seconds" | bc)
        echo "RESULTS: ns/Day=$nsperday, WallClock=$walltime s"

        # Update the values in the CSV file
        echo "$job_id,$nsperday,$walltime,\"$NODELIST\"" >> "$csv_file"

        # Check if values are within the specified ranges
        if (( $(echo "$nsperday >= $nsperday_min && $nsperday <= $nsperday_max" | bc -l) )) && \
                (( $(echo "$walltime >= $walltime_min && $walltime <= $walltime_max" | bc -l) )); then
                #If Within renge
                #successfull Jobs
                echo ":OK: The job with JOB ID $job_id is succesfull and outputs are within renge"
                echo "$job_id(Nodelist:$NODELIST)" >> $MainDir/SCRIPTS/verification/gromacs/SuccesfullJobIDs
                ((ok_jobs++))
        else
                #If not within renge
                #unsuccesfull Jobs
                echo ":Slow Jobs: The results are not within the renge. Check JOB ID: $job_id"
                echo "$job_id(Nodelist:$NODELIST)" >> $MainDir/SCRIPTS/verification/gromacs/ResultOutOffRengeJobIDs
                ((NotWithinRengeJobs++))
        fi
    else
        #Incomplete Jobs
        echo ":Failed Jobs: Results are incomplete! Please Check Job ID: $job_id"
        echo "-------------------------"
        if [ -n "$NODELIST" ]; then
            echo "$job_id(Nodelist:$NODELIST)" >> $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs
        else
            # Deliberately NOT wrapped as "(Nodelist:...)" -- extract-nodes
            # matches that exact wrapper as a real SLURM hostlist token, and
            # would otherwise feed this placeholder text straight into
            # `scontrol show hostnames` alongside genuine hostlists (with no
            # node known, there's nothing to attribute a failed-node entry
            # to; this format lets extract-nodes cleanly skip the line).
            echo "$job_id: run directory not found (nodelist unknown)" >> $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs
        fi
        ((FileNotFoundJobs++))
        echo "-------------------------"
        unset nsperday
        unset walltime
        continue
    fi

    echo "-------------------------"

    unset nsperday
    unset walltime

done < "$job_ids_file"

###############################################################
#                      Summary                                #
###############################################################

not_ok_jobs=$(( NotWithinRengeJobs + FileNotFoundJobs ))

echo "##########################################################"
echo "%                 GROMACS Job Summary                    %"
echo "##########################################################"
echo "Total GROMACS Jobs: $totalJobs                            "
echo "Acceptable results range for $nnodes nodes"
echo "ns/day: minimum = $nsperday_min"
echo "ns/day: maximum = $nsperday_max"
echo "Walltime: minumum = $walltime_min"
echo "Walltime: maximum = $walltime_max"
# Succesfull Jobs
echo "----------------------------------------------------------"
echo "            A.SUCCESSFULL JOBS:(Results within range)                           "
echo "No. of Succesfull Jobs= $ok_jobs                         "
[ -f $MainDir/SCRIPTS/verification/gromacs/SuccesfullJobIDs ] && success_job_ids=$(cat $MainDir/SCRIPTS/verification/gromacs/SuccesfullJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $success_job_ids                     "
[ -f $MainDir/SCRIPTS/verification/gromacs/SuccesfullJobIDs ] && echo "Note*: The results of the above jobs are within specified renge!"
# Unsuccesfull Jobs
echo "----------------------------------------------------------"
echo "            B.SLOW JOBS:(Results not within range) $not_ok_jobs            "
# Outoff renge Jobs
echo "No. of Slow Jobs= $NotWithinRengeJobs            "
[ -f $MainDir/SCRIPTS/verification/gromacs/ResultOutOffRengeJobIDs ] && outoffrenge_job_ids=$(cat $MainDir/SCRIPTS/verification/gromacs/ResultOutOffRengeJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $outoffrenge_job_ids                 "
[ -f $MainDir/SCRIPTS/verification/gromacs/ResultOutOffRengeJobIDs ] && echo "Important*: You may need to debug above Jobs as results are not within specified renge! "

# Incomplete Jobs
echo "----------------------------------------------------------"
echo "            C.INCOMPLETE JOBS:(Output not generated) $not_ok_jobs               "
# File Not Found Jobs
echo "No. of Incomplete Jobs= $FileNotFoundJobs                 "
[ -f $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs ] && filenotexist_job_ids=$(cat $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $filenotexist_job_ids                "
[ -f $MainDir/SCRIPTS/verification/gromacs/FileNotExistsJobIDs ] && echo "Important*: You may need to either wait for the results of above jobs or Debug the issue as result is not complete yet! "

echo "----------------------------------------------------------"
echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
