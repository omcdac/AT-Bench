#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1

mkdir -p $OUTDIR/HPL/SingleNode/RUN-$dirNumber
RUNDIR=$OUTDIR/HPL/SingleNode/RUN-$dirNumber

cd "$RUNDIR" || { echo "ERROR: could not cd into $RUNDIR (RUN-$dirNumber). Skipping this job."; return 1; }

#-------------------
# Assuming you are in the source directory
source_directory="$MainDir/SRC/BENCH/HPL/hpl-1n"
target_directory="$RUNDIR"

# Create symbolic links for all files in the source directory to the target directory
for file in "$source_directory"/*; do
    if [ -f "$file" ]; then
        # If it's a regular file, create a symbolic link in the target directory
        ln -s "$file" "$target_directory/$(basename "$file")"
    fi
done
#-------------------

jobid=$(sbatch --nodelist=$node ./job.sh | awk '{print $4}')

if [ -z "$jobid" ]; then
	echo "ERROR: sbatch submission failed for node $node (no job id returned)"
	echo "$node" >> $OUTDIR/HPL/SingleNode/HPL_SubmissionFailed.txt
else
	echo "$jobid" > $jobid
	echo "Job Submitted with job id $jobid"
	echo "$jobid" >> $OUTDIR/HPL/SingleNode/HPL-1N.JobIDs.txt
fi
#echo "$jobid" >> $MainDir/LOGS/JobIDs/HPL-1N.JobIDs.txt
