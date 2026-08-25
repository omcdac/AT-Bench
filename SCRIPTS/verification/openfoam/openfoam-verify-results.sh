#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
#
# OPTIMIZED: job-directory lookup changed from O(N x M) (one full `find`
# per job) to O(N + M) (one full `find` total, then O(1) in-memory lookups
# via an associative array). Also removes the per-job `sleep 2`, which at
# scale (N jobs) was adding N x 2 seconds of pure sleep on its own.
#
# LOG HIERARCHY (2026-08-05): dropped the separate, ever-growing
# LOGS/OPENFOAM_Summary.txt (tee -a'd forever, never rotated). See the
# equivalent note in namd-verify-results.sh for the full rationale; same
# fix applied here. Results CSV now lands under a dated subfolder
# (LOGS/openfoam-logs/<DDMonthYYYY>/) when $TODAY is set by the calling
# wrapper, falling back to the flat path for manual atVerify.sh runs.
# =============================================================================

# Specify the path to the file containing Slurm job IDs
job_ids_file="$OUTDIR/OPENFOAM/OPENFOAM_JobIDs.txt"

## For CSV file results
# Define the CSV file (dated subfolder when the calling wrapper sets $TODAY,
# flat path for manual atVerify.sh runs where $TODAY is unset)
if [ -n "$TODAY" ]; then
    mkdir -p "$MainDir/LOGS/openfoam-logs/$TODAY"
    csv_file="$MainDir/LOGS/openfoam-logs/$TODAY/OPENFOAM-results.csv"
else
    csv_file="$MainDir/LOGS/openfoam-logs/OPENFOAM-results.csv"
fi
[ -f "$csv_file" ] && rm "$csv_file"
# Check if the CSV file exists
if [ ! -f "$csv_file" ]; then
    # If the CSV file doesn't exist, create it with headers
    echo "job_id,cds,walltime,nodelist" > "$csv_file"
fi
###


# Define the acceptable ranges for ns/Day and WallClock time
nnodes=14
#1. ns/Day renge
cds_min=0.006
cds_max=0.030
#2. Walltime renge
walltime_min=300
walltime_max=480

#-----------------------------------------

### Initialize useful counters
ok_jobs=0
FileNotFoundJobs=0
NotWithinRengeJobs=0

if [ ! -s "$job_ids_file" ]; then
    echo "ERROR: $job_ids_file is missing or empty -- OpenFOAM job submission may not have run, or OUTDIR/BASE_OUTDIR doesn't match tonight's submission. Aborting instead of silently reporting 0 jobs as a clean run." >&2
    return 1
fi
totalJobs=$(cat $job_ids_file | wc -l)
# Loop through each job ID in the file
[ -f $MainDir/SCRIPTS/verification/openfoam/SuccesfullJobIDs ] && rm $MainDir/SCRIPTS/verification/openfoam/SuccesfullJobIDs
[ -f $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs ] && rm $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs
[ -f $MainDir/SCRIPTS/verification/openfoam/ResultOutOffRengeJobIDs ] && rm $MainDir/SCRIPTS/verification/openfoam/ResultOutOffRengeJobIDs

# =============================================================================
# ONE-TIME INDEX BUILD (replaces the per-job `find` call)
#
# Instead of running `find $OUTDIR/OPENFOAM -name "*$job_id*"` once for
# EVERY job (re-walking the whole tree each time), we walk the tree exactly
# once here and build an associative array: RUNDIR_OF[job_id] -> directory.
#
# ASSUMPTION: each job has its own run directory somewhere under
# $OUTDIR/OPENFOAM, and the job ID appears as a distinct numeric token in
# that directory's name (e.g. "case_1234", "1234_run", "OPENFOAM_1234").
# The regex below requires the job ID to be bounded by non-digit characters
# (or string start/end) so job 123 can no longer be mistaken for a
# substring of job 1234, 41230, etc. (that ambiguity existed in the
# original `-name "*$job_id*"` and got riskier as job counts grew).
#
# If your run directories are nested more than one level deep under
# $OUTDIR/OPENFOAM, adjust/remove `-maxdepth 1` below accordingly. Run
# `find "$OUTDIR/OPENFOAM" -maxdepth 2 -type d | head` once by hand if
# you're not sure of the actual depth/naming before relying on this.
# =============================================================================
declare -A RUNDIR_OF

while IFS= read -r -d '' d; do
    dname=$(basename "$d")
    if [[ "$dname" =~ (^|[^0-9])([0-9]+)([^0-9]|$) ]]; then
        RUNDIR_OF["${BASH_REMATCH[2]}"]="$d"
    fi
done < <(find "$OUTDIR/OPENFOAM" -mindepth 1 -maxdepth 1 -type d -print0)

# =============================================================================
# SECOND-PASS FILE INDEX (fixes false "file not found" for ALL OpenFOAM
# jobs — this was a real, confirmed bug, not just theoretical)
#
# openFoamJob.sh submits into a fixed pool of reusable "RUN-N" slot
# directories (N = slot number, unrelated to any job ID) — EVERY OpenFOAM
# run directory is named this way, never after the job ID. That means the
# dirname-only pass above only ever indexes RUNDIR_OF[N] (the slot number),
# which no real 6-digit Slurm job ID ever equals, so RUNDIR_OF[$job_id]
# was empty for 100% of OpenFOAM jobs — every single one was being
# reported as "file not found / incomplete" regardless of whether it
# actually succeeded (confirmed against LOGS/OPENFOAM_Summary.txt showing
# 0 successful jobs out of 1549 checked, all "run directory not found").
# Fix: index every "job.<job_id>.err" file's containing directory directly
# by the job ID in its filename, regardless of the RUN-N directory's own
# name. Existing dirname-based entries are left alone (first match wins).
# =============================================================================
while IFS= read -r -d '' f; do
    fname=$(basename "$f")
    if [[ "$fname" =~ ^job\.([0-9]+)\.err$ ]]; then
        jid="${BASH_REMATCH[1]}"
        [ -z "${RUNDIR_OF[$jid]:-}" ] && RUNDIR_OF["$jid"]=$(dirname "$f")
    fi
done < <(find "$OUTDIR/OPENFOAM" -mindepth 2 -maxdepth 2 -type f -name "job.*.err" -print0)

echo "Indexed ${#RUNDIR_OF[@]} run directories under $OUTDIR/OPENFOAM"
echo "-------------------------"

#
while IFS= read -r job_id; do
    echo "Checking JOB-ID: $job_id ..."

    RUNDIR="${RUNDIR_OF[$job_id]:-}"
    echo "Job Dir: $RUNDIR"

    #--- Verification of different Parametes
    if [ -n "$RUNDIR" ] && [ -e "$RUNDIR/openfoamResult.txt" ] && grep -q "real" "$RUNDIR/openfoamResult.txt"; then
        # 1. ns/days
        cds=$(grep "Cd" "$RUNDIR/openfoamResult.txt" | tail -3 | head -1 | awk '{print $3}')
        # 2. Wall Clock time
        walltime1=$(grep "real" "$RUNDIR/openfoamResult.txt" | awk '{print $2}')
        minutes=$(echo "$walltime1" | sed 's/m.*//')
        seconds=$(echo "$walltime1" | sed 's/.*m//;s/s//')
        walltime=$(echo "$minutes * 60 + $seconds" | bc)
        echo "RESULTS: cds=$cds, WallClock=$walltime s"
        # Update the values in the CSV file
        echo "$job_id,$cds,$walltime,\"$(cat "$RUNDIR/nodelist.txt")\"" >> "$csv_file"

        # Check if values are within the specified ranges
        if (( $(echo "$cds >= $cds_min && $cds <= $cds_max" | bc -l) )) && \
                (( $(echo "$walltime >= $walltime_min && $walltime <= $walltime_max" | bc -l) )); then
                #If Within renge
                #successfull Jobs
                echo ":OK: The job with JOB ID $job_id is succesfull and outputs are within renge"
                echo "$job_id(Nodelist:$(cat "$RUNDIR/nodelist.txt"))" >> $MainDir/SCRIPTS/verification/openfoam/SuccesfullJobIDs
                ((ok_jobs++))
        else
                #If not within renge
                #unsuccesfull Jobs
                echo ":Slow Jobs: The results are not within the renge. Check JOB ID: $job_id"
                echo "$job_id(Nodelist:$(cat "$RUNDIR/nodelist.txt"))" >> $MainDir/SCRIPTS/verification/openfoam/ResultOutOffRengeJobIDs
                ((NotWithinRengeJobs++))
        fi
    else
        #Incomplete Jobs
        echo ":Failed Jobs: Results are incomplete! Please Check Job ID: $job_id"
        echo "-------------------------"
        if [ -n "$RUNDIR" ] && [ -f "$RUNDIR/nodelist.txt" ]; then
            echo "$job_id(Nodelist:$(cat "$RUNDIR/nodelist.txt"))" >> $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs
        else
            # Deliberately NOT wrapped as "(Nodelist:...)" -- see the same
            # note in gromacs-verify-results.sh: extract-nodes matches that
            # exact wrapper as a real SLURM hostlist token.
            echo "$job_id: run directory not found (nodelist unknown)" >> $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs
        fi
        ((FileNotFoundJobs++))
        echo "-------------------------"
        unset cds
        unset walltime
        continue
    fi

    echo "-------------------------"

    unset cds
    unset walltime

done < "$job_ids_file"

###############################################################
#                      Summary                                #
###############################################################

not_ok_jobs=$(( NotWithinRengeJobs + FileNotFoundJobs ))

echo "##########################################################"
echo "%                 OPENFOAM Job Summary                       %"
echo "##########################################################"
echo "Total OPENFOAM Jobs: $totalJobs                               "
echo "Acceptable results range for $nnodes nodes"
echo "cds: minimum = $cds_min"
echo "cds: maximum = $cds_max"
echo "Walltime: minumum = $walltime_min"
echo "Walltime: maximum = $walltime_max"
# Succesfull Jobs
echo "----------------------------------------------------------"
echo "            A.SUCCESSFULL JOBS:(Results within range)                           "
echo "No. of Succesfull Jobs= $ok_jobs                         "
[ -f $MainDir/SCRIPTS/verification/openfoam/SuccesfullJobIDs ] && success_job_ids=$(cat $MainDir/SCRIPTS/verification/openfoam/SuccesfullJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $success_job_ids                     "
[ -f $MainDir/SCRIPTS/verification/openfoam/SuccesfullJobIDs ] && echo "Note*: The results of the above jobs are within specified renge!"
# Unsuccesfull Jobs
echo "----------------------------------------------------------"
echo "            B.SLOW JOBS:(Results not within range) $not_ok_jobs            "
# Outoff renge Jobs
echo "No. of Slow Jobs= $NotWithinRengeJobs            "
[ -f $MainDir/SCRIPTS/verification/openfoam/ResultOutOffRengeJobIDs ] && outoffrenge_job_ids=$(cat $MainDir/SCRIPTS/verification/openfoam/ResultOutOffRengeJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $outoffrenge_job_ids                 "
[ -f $MainDir/SCRIPTS/verification/openfoam/ResultOutOffRengeJobIDs ] && echo "Important*: You may need to debug above Jobs as results are not within specified renge! "

# Incomplete Jobs
echo "----------------------------------------------------------"
echo "            C.INCOMPLETE JOBS:(Output not generated) $not_ok_jobs               "
# File Not Found Jobs
echo "No. of Incomplete Jobs= $FileNotFoundJobs                 "
[ -f $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs ] && filenotexist_job_ids=$(cat $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $filenotexist_job_ids                "
[ -f $MainDir/SCRIPTS/verification/openfoam/FileNotExistsJobIDs ] && echo "Important*: You may need to either wait for the results of above jobs or Debug the issue as result is not complete yet! "

echo "----------------------------------------------------------"
echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%"
