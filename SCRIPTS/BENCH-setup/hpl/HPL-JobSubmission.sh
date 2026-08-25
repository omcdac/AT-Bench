#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


#export MainDir=$PWD

#node_file=$MainDir/SCRIPTS/BENCH-setup/hpl/cpuNodes.txt
#node_file=$MainDir/SCRIPTS/BENCH-setup/hpl/hmNodes.txt
#node_file=$MainDir/SCRIPTS/BENCH-setup/hpl/gpuNodes.txt
node_file=$MainDir/SCRIPTS/BENCH-setup/hpl/nodes
# Check if the node file exists
if [ ! -f "$node_file" ]; then
    echo "Node file '$node_file' not found."
    return 1
fi

##
NumberOfJobsOfEachApps=`cat $node_file | wc -l`

#--------- Pre-flight checks (fail fast instead of NumberOfJobsOfEachApps x sbatch failures)
if [ -z "$OUTDIR" ]; then
	echo "ERROR: \$OUTDIR is not set. Aborting HPL job submission."
	return 1
fi
if [ ! -f "$MainDir/SRC/BENCH/HPL/hpl-1n/job.sh" ]; then
	echo "ERROR: HPL job template ($MainDir/SRC/BENCH/HPL/hpl-1n/job.sh) not found. Aborting."
	return 1
fi
#-------------------------------------

#Clean Old logs if any (the real file the worker script appends to, under $OUTDIR)
[ -f $OUTDIR/HPL/SingleNode/HPL-1N.JobIDs.txt ] && rm $OUTDIR/HPL/SingleNode/HPL-1N.JobIDs.txt

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
echo "Benchmark: HPL"
echo "Total Number of jobs to be submitted = $NumberOfJobsOfEachApps"
#echo "Number of Jobs of each application= $(( NumberOfJobsOfEachApps ))"
#echo "You have selected: Number of Nodes Per Job = $NumberOfNodesPerJob, Partition = $JobPartition"
echo "------------------------------"
echo ""
echo "With above details, the job submission will start soon..."
sleep 3

# Loop through each line/node in the file
while IFS= read -r node; do
    #--------------------------
    echo "---------------------------------"
    echo "Benchmark: HPL, Node Number = $node"
    source $MainDir/SCRIPTS/jobSubmission/benchmarks/hpl.sh $node
    #--------------------------
done < "$node_file"


