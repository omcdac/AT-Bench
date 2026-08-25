#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

#export MainDir=$PWD

#--------- Edit following section as per the cluster configuration
export TotalNodes=700  # As per the cluster configuration
#export TotalNodes=14
export TotalApps=1  #

# Job script parameters
export NumberOfNodesPerJob=14
export NumberOfCoresPerNode=48
# Partition/reservation/job-count: use the value exported by
# CRON/Jobsubmission/run-jobsubmission.sh if present (its CONFIGURATION
# block), else fall back to these defaults - keeps this script runnable
# standalone (e.g. via the interactive JobSubmission.sh menu).
export JobPartition="${OPENFOAM_PARTITION:-cpu}"
export Reservation="${OPENFOAM_RESERVATION-workingcpunodes}"
#-------------------------------------

NumberOfJobsOfEachApps="${OPENFOAM_NUM_JOBS:-$(( TotalNodes / (NumberOfNodesPerJob * TotalApps) ))}" # Need to calculate as per cluster nodes, application run time, number of applicatios etc.

#--------- Pre-flight checks (fail fast instead of NumberOfJobsOfEachApps x sbatch failures)
if [ -z "$OUTDIR" ]; then
	echo "ERROR: \$OUTDIR is not set. Aborting OPENFOAM job submission."
	return 1
fi
if [ ! -d "$MainDir/SRC/openFOAM/input" ] || [ -z "$(ls -A "$MainDir/SRC/openFOAM/input" 2>/dev/null)" ]; then
	echo "ERROR: OpenFOAM input directory ($MainDir/SRC/openFOAM/input) is missing or empty. Aborting."
	return 1
fi
if [ ! -f "$MainDir/SRC/openFOAM/input/openfoam.sh" ]; then
	echo "ERROR: OpenFOAM job template ($MainDir/SRC/openFOAM/input/openfoam.sh) not found. Aborting."
	return 1
fi
#-------------------------------------

#Clean Old logs if any (the real file the worker script appends to, under $OUTDIR)
[ -f $OUTDIR/OPENFOAM/OPENFOAM_JobIDs.txt ] && rm $OUTDIR/OPENFOAM/OPENFOAM_JobIDs.txt

##################
echo "******************************"
echo "*      Welcome to AT         *"
echo "*           Tool             *"
echo "******************************"
echo ""
sleep 3

echo "------------------------------"
echo "Job submission Summary"
echo ""
echo "Applications: OPENFOAM"
echo "Total Number of jobs to be submitted = $(( NumberOfJobsOfEachApps * TotalApps ))"
echo "Number of Jobs of each application= $(( NumberOfJobsOfEachApps ))"
echo "You have selected: Number of Nodes Per Job = $NumberOfNodesPerJob, Partition = $JobPartition, Reservation = ${Reservation:-<none>}"
echo "------------------------------"
echo ""
echo "With above details, the job submission will start soon..."
sleep 5

# Job submission
for i in $(seq 1 $NumberOfJobsOfEachApps); 
do
        #--------------------------
	echo "---------------------------------"
	echo "Application: OPENFOAM, Job Number = $i"
        source $MainDir/SCRIPTS/jobSubmission/openFoamJob.sh $i
        #--------------------------
done

