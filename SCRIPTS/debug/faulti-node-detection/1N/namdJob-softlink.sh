#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


dirNumber=$1
nodes=$2
nnode=$3

mkdir -p $OUTDIR/NODE-TEST/1N/RUN-$dirNumber
RUNDIR="$OUTDIR/NODE-TEST/1N/RUN-$dirNumber"

cd $RUNDIR

#-------------------
# Assuming you are in the source directory
source_directory="$MainDir/SRC/NAMD/nodetest"
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

jobid=$(sbatch -N $nnode --nodelist=$nodes --partition=$JobPartition  ./namd.cpu.sh | awk '{print $4}')

echo "$jobid" > $jobid

echo "Job Submitted with job id $jobid"
echo "$jobid" >> $OUTDIR/NODE-TEST/1N/TEST_JobIDs.txt
#echo "$jobid" >> $MainDir/LOGS/JobIDs/NAMD_JobIDs.txt

