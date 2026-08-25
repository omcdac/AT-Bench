#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1

mkdir -p $OUTDIR/WRF/RUN-$dirNumber
RUNDIR=$OUTDIR/WRF/RUN-$dirNumber
#touch $RUNDIR/wrfrst_d01_2005-06-04_12_00_00
#lfs setstripe -S 32m -c 4 $RUNDIR/wrfrst_d01_2005-06-04_12_00_00

cd "$RUNDIR" || { echo "ERROR: could not cd into $RUNDIR (RUN-$dirNumber). Skipping this job."; return 1; }

#-------------------
# Assuming you are in the source directory
source_directory="$MainDir/SRC/WRF/input/data"
target_directory="$RUNDIR"

# Create symbolic links for all files in the source directory to the target directory
for file in "$source_directory"/*; do
    if [ -f "$file" ]; then
        # If it's a regular file, create a symbolic link in the target directory
        ln -s "$file" "$target_directory/$(basename "$file")"
    fi
done

ln -s $MainDir/SRC/WRF/input/wrfInput/wrfbdy_d01 .
ln -s $MainDir/SRC/WRF/input/wrfInput/wrfrst_d01_2005-06-04_06_00_00 .
#-------------------

#Submit Job
# Optional --reservation (empty $Reservation, set by the AT-JobSetup
# script from run-jobsubmission.sh's config, means submit without one -
# the job template no longer has a hardcoded #SBATCH --reservation line).
RESERVATION_ARGS=()
[ -n "$Reservation" ] && RESERVATION_ARGS=(--reservation="$Reservation")

jobid=$(sbatch -N $NumberOfNodesPerJob --ntasks-per-node=$NumberOfCoresPerNode --partition=$JobPartition "${RESERVATION_ARGS[@]}" ./wrf.job.sh | awk '{print $4}')

if [ -z "$jobid" ]; then
	echo "ERROR: sbatch submission failed for RUN-$dirNumber (no job id returned)"
	echo "RUN-$dirNumber" >> $OUTDIR/WRF/WRF_SubmissionFailed.txt
else
	echo "Job Submitted with job id $jobid"
	echo "$jobid" >> $OUTDIR/WRF/WRF_JobIDs.txt
fi
#echo "$jobid" >> $MainDir/LOGS/JobIDs/WRF_JobIDs.txt


