#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


#export MainDir=$PWD

#node_file=$MainDir/SCRIPTS/BENCH-setup/stream/cpuNodes.txt
#node_file=$MainDir/SCRIPTS/BENCH-setup/stream/hmNodes.txt
#node_file=$MainDir/SCRIPTS/BENCH-setup/stream/gpuNodes.txt
node_file=$MainDir/SCRIPTS/BENCH-setup/stream/allNodes.txt
# Check if the node file exists
if [ ! -f "$node_file" ]; then
    echo "Node file '$node_file' not found."
    return 1
fi

##
NumberOfJobsOfEachApps=`cat $node_file | wc -l`

#--------- Pre-flight checks (fail fast instead of NumberOfJobsOfEachApps x sbatch failures)
if [ -z "$OUTDIR" ]; then
	echo "ERROR: \$OUTDIR is not set. Aborting STREAM job submission."
	return 1
fi
if [ ! -f "$MainDir/SRC/BENCH/STREAM/job.sh" ]; then
	echo "ERROR: STREAM job template ($MainDir/SRC/BENCH/STREAM/job.sh) not found. Aborting."
	return 1
fi
#-------------------------------------

#Clean Old logs if any (the real file the worker script appends to, under $OUTDIR)
[ -f $OUTDIR/STREAM/STREAM.JobIDs.txt ] && rm $OUTDIR/STREAM/STREAM.JobIDs.txt

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
echo "Benchmark: STREAM"
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
    echo "Benchmark: STREAM, Node Number = $node"
    source $MainDir/SCRIPTS/jobSubmission/benchmarks/stream.sh $node
    #--------------------------
done < "$node_file"


