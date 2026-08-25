#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

#export MainDir=$PWD

#--------- Edit following section as per the cluster configuration
export TotalNodes=10000  # As per the cluster configuration
export TotalApps=1  #

# Job script parameters
export NumberOfNodesPerJob=10
export NumberOfCoresPerNode=48
# Partition/reservation/job-count: use the value exported by
# Workflow/Jobsubmission/run-jobsubmission.sh if present (its CONFIGURATION
# block), else fall back to these defaults - keeps this script runnable
# standalone (e.g. via the interactive JobSubmission.sh menu).
export JobPartition="${GROMACS_PARTITION:-cpu}"
export Reservation="${GROMACS_RESERVATION-workingcpunodes}"
#-------------------------------------

NumberOfJobsOfEachApps="${GROMACS_NUM_JOBS:-$(( TotalNodes / (NumberOfNodesPerJob * TotalApps) ))}" # Need to calculate as per cluster nodes, application run time, number of applicatios etc.

#--------- Pre-flight checks (fail fast instead of NumberOfJobsOfEachApps x sbatch failures)
if [ -z "$OUTDIR" ]; then
	echo "ERROR: \$OUTDIR is not set. Aborting GROMACS job submission."
	return 1
fi
if [ ! -d "$MainDir/SRC/GROMACS/input" ] || [ -z "$(ls -A "$MainDir/SRC/GROMACS/input" 2>/dev/null)" ]; then
	echo "ERROR: GROMACS input directory ($MainDir/SRC/GROMACS/input) is missing or empty. Aborting."
	return 1
fi
if [ ! -f "$MainDir/SRC/GROMACS/input/gromacs_v2.cpu.sh" ]; then
	echo "ERROR: GROMACS job template ($MainDir/SRC/GROMACS/input/gromacs_v2.cpu.sh) not found. Aborting."
	return 1
fi
#-------------------------------------

#Clean Old logs if any (the real file the worker script appends to, under $OUTDIR)
[ -f $OUTDIR/GROMACS/GROMACS_JobIDs.txt ] && rm $OUTDIR/GROMACS/GROMACS_JobIDs.txt

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
echo "Applications: GROMACS"
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
	echo "Application: GROMACS, Job Number = $i"
        source $MainDir/SCRIPTS/jobSubmission/gromacsJob-softlink.sh $i
        #--------------------------
done

