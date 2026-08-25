#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1
ppn=$2

mkdir -p $OUTDIR/OSU/RUN-$dirNumber-$ppn
RUNDIR=$OUTDIR/OSU/RUN-$dirNumber-$ppn

cd "$RUNDIR" || { echo "ERROR: could not cd into $RUNDIR (RUN-$dirNumber-$ppn). Skipping this job."; return 1; }

#-------------------
# Assuming you are in the source directory
source_directory="$MainDir/SRC/BENCH/OSU"
target_directory="$RUNDIR"

# Create symbolic links for all files in the source directory to the target directory
for file in "$source_directory"/*; do
    if [ -f "$file" ]; then
        # If it's a regular file, create a symbolic link in the target directory
        ln -s "$file" "$target_directory/$(basename "$file")"
    fi
done
#-------------------

jobid=$(sbatch -N $nodes --ntasks-per-node=$ppn ./slurm.mpi.sh | awk '{print $4}')

if [ -z "$jobid" ]; then
	echo "ERROR: sbatch submission failed for nodes=$nodes ppn=$ppn (no job id returned)"
	echo "nodes=$nodes,ppn=$ppn" >> $OUTDIR/OSU/OSU_SubmissionFailed.txt
else
	echo "$jobid" > $jobid
	echo "Job Submitted with job id $jobid"
	echo "$jobid" >> $OUTDIR/OSU/OSU.JobIDs.txt
fi
#echo "$jobid" >> $MainDir/LOGS/JobIDs/OSU.JobIDs.txt
