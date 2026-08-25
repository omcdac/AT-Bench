#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1

mkdir -p $OUTDIR/STREAM/RUN-$dirNumber
RUNDIR=$OUTDIR/STREAM/RUN-$dirNumber

cd "$RUNDIR" || { echo "ERROR: could not cd into $RUNDIR (RUN-$dirNumber). Skipping this job."; return 1; }

#-------------------
# Assuming you are in the source directory
source_directory="$MainDir/SRC/BENCH/STREAM"
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
	echo "$node" >> $OUTDIR/STREAM/STREAM_SubmissionFailed.txt
else
	echo "$jobid" > $jobid
	echo "Job Submitted with job id $jobid"
	echo "$jobid" >> $OUTDIR/STREAM/STREAM.JobIDs.txt
fi
#echo "$jobid" >> $MainDir/LOGS/JobIDs/STREAM.JobIDs.txt
