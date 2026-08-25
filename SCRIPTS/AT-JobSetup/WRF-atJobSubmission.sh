#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

#export MainDir=$PWD

#--------- Edit following section as per the cluster configuration
export TotalNodes=11000  # As per the cluster configuration
export TotalApps=1  #

# Job script parameters
export NumberOfNodesPerJob=11
export NumberOfCoresPerNode=48
# Partition/reservation/job-count: use the value exported by
# Workflow/Jobsubmission/run-jobsubmission.sh if present (its CONFIGURATION
# block), else fall back to these defaults - keeps this script runnable
# standalone (e.g. via the interactive JobSubmission.sh menu).
export JobPartition="${WRF_PARTITION:-cpu}"
export Reservation="${WRF_RESERVATION-workingcpunodes}"
#-------------------------------------

NumberOfJobsOfEachApps="${WRF_NUM_JOBS:-$(( TotalNodes / (NumberOfNodesPerJob * TotalApps) ))}" # Need to calculate as per cluster nodes, application run time, number of applicatios etc.

#--------- Pre-flight checks (fail fast instead of NumberOfJobsOfEachApps x sbatch failures)
if [ -z "$OUTDIR" ]; then
	echo "ERROR: \$OUTDIR is not set. Aborting WRF job submission."
	return 1
fi
if [ ! -d "$MainDir/SRC/WRF/input/data" ] || [ -z "$(ls -A "$MainDir/SRC/WRF/input/data" 2>/dev/null)" ]; then
	echo "ERROR: WRF input directory ($MainDir/SRC/WRF/input/data) is missing or empty. Aborting."
	return 1
fi
if [ ! -f "$MainDir/SRC/WRF/input/data/wrf.job.sh" ]; then
	echo "ERROR: WRF job template ($MainDir/SRC/WRF/input/data/wrf.job.sh) not found. Aborting."
	return 1
fi
# wrf.sh symlinks these two into every RUN-N dir with `ln -s`, which does NOT
# fail on a missing target -- without this check a missing/moved file here
# silently produces NumberOfJobsOfEachApps real SLURM jobs with a dangling
# symlink, each failing hours later on the compute node instead of failing
# fast here.
if [ ! -f "$MainDir/SRC/WRF/input/wrfInput/wrfbdy_d01" ] || [ ! -f "$MainDir/SRC/WRF/input/wrfInput/wrfrst_d01_2005-06-04_06_00_00" ]; then
	echo "ERROR: WRF boundary/restart input ($MainDir/SRC/WRF/input/wrfInput/wrfbdy_d01 or wrfrst_d01_2005-06-04_06_00_00) is missing. Aborting."
	return 1
fi
#-------------------------------------

#Clean Old logs if any (the real file the worker script appends to, under $OUTDIR)
[ -f $OUTDIR/WRF/WRF_JobIDs.txt ] && rm $OUTDIR/WRF/WRF_JobIDs.txt

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
echo "Applications: WRF"
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
        echo "Application: WRF, Job Number = $i"
        source $MainDir/SCRIPTS/jobSubmission/wrf.sh $i
	#--------------------------
done

