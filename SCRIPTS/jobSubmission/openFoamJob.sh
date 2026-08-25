#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1

RUNDIR=$OUTDIR/OPENFOAM/RUN-$dirNumber
mkdir -p "$RUNDIR"
cd "$RUNDIR" || { echo "ERROR: could not cd into $RUNDIR (RUN-$dirNumber). Skipping this job."; return 1; }

# Recursively clone the input case as symlinks instead of a real `cp -r`
# (was the one app still doing a full physical copy per job - NAMD/GROMACS/
# WRF all symlink). Unlike those apps' flat input dirs, OpenFOAM's case is
# a real nested tree (0/, constant/polyMesh/, system/, ...), so a simple
# top-level `ln -s *` loop can't reach it - `cp -rs` recreates the
# directory structure for real but replaces every leaf FILE with a
# symlink back to the shared source (GNU coreutils only).
#
# This is safe for openfoam.sh's `sed -i .../system/decomposeParDict`:
# sed -i's default behavior (no --follow-symlinks) replaces the symlink
# with an independent real file via rename(), so the edit lands only in
# this job's own directory entry - the shared source and every other
# job's symlink are untouched (verified empirically before rollout).
# decomposePar's processor*/ output and any postProcessing/ writes also
# land in this job's own real directories, not the shared source.
source_directory="$MainDir/SRC/openFOAM/input"
target_directory="$RUNDIR"
cp -rs "$source_directory"/. "$target_directory"/

# Optional --reservation (empty $Reservation, set by the AT-JobSetup
# script from run-jobsubmission.sh's config, means submit without one -
# the job template no longer has a hardcoded #SBATCH --reservation line).
RESERVATION_ARGS=()
[ -n "$Reservation" ] && RESERVATION_ARGS=(--reservation="$Reservation")

jobid=$(sbatch -N $NumberOfNodesPerJob --ntasks-per-node=$NumberOfCoresPerNode --partition=$JobPartition "${RESERVATION_ARGS[@]}" ./openfoam.sh |  awk '{print $4}')

if [ -z "$jobid" ]; then
	echo "ERROR: sbatch submission failed for RUN-$dirNumber (no job id returned)"
	echo "RUN-$dirNumber" >> $OUTDIR/OPENFOAM/OPENFOAM_SubmissionFailed.txt
else
	echo "Job Submitted with job id $jobid"
	echo "$jobid" >> $OUTDIR/OPENFOAM/OPENFOAM_JobIDs.txt
fi
#echo "$jobid" >> $MainDir/LOGS/JobIDs/OPENFOAM_JobIDs.txt
