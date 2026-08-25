#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1

mkdir -p $OUTDIR/NAMD/RUN-$dirNumber
RUNDIR="$OUTDIR/NAMD/RUN-$dirNumber"

cd "$RUNDIR" || { echo "ERROR: could not cd into $RUNDIR (RUN-$dirNumber). Skipping this job."; return 1; }

#-------------------
# Assuming you are in the source directory
source_directory="$MainDir/SRC/NAMD/input"
target_directory="$RUNDIR"

# Create symbolic links for all files in the source directory to the target directory
for file in "$source_directory"/*; do
    if [ -f "$file" ]; then
        # If it's a regular file, create a symbolic link in the target directory
        ln -s "$file" "$target_directory/$(basename "$file")"
    fi
done
#-------------------
#jobid=$(sbatch -N $NumberOfNodesPerJob --ntasks-per-node=$NumberOfCoresPerNode  ./namd.cpu.sh | awk '{print $4}')

# Optional --reservation (empty $Reservation, set by the AT-JobSetup
# script from run-jobsubmission.sh's config, means submit without one -
# the job template no longer has a hardcoded #SBATCH --reservation line).
RESERVATION_ARGS=()
[ -n "$Reservation" ] && RESERVATION_ARGS=(--reservation="$Reservation")

jobid=$(sbatch -N $NumberOfNodesPerJob --ntasks-per-node=$NumberOfCoresPerNode --partition=$JobPartition "${RESERVATION_ARGS[@]}" ./namd.cpu.sh | awk '{print $4}')

if [ -z "$jobid" ]; then
	echo "ERROR: sbatch submission failed for RUN-$dirNumber (no job id returned)"
	echo "RUN-$dirNumber" >> $OUTDIR/NAMD/NAMD_SubmissionFailed.txt
else
	echo "Job Submitted with job id $jobid"
	echo "$jobid" >> $OUTDIR/NAMD/NAMD_JobIDs.txt
fi
#echo "$jobid" >> $MainDir/LOGS/JobIDs/NAMD_JobIDs.txt

