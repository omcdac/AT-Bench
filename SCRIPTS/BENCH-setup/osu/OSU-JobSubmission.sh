#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


#export MainDir=$PWD

#--------- Pre-flight checks (fail fast instead of 63 x sbatch failures)
if [ -z "$OUTDIR" ]; then
	echo "ERROR: \$OUTDIR is not set. Aborting OSU job submission."
	return 1
fi
if [ ! -f "$MainDir/SRC/BENCH/OSU/slurm.mpi.sh" ]; then
	echo "ERROR: OSU job template ($MainDir/SRC/BENCH/OSU/slurm.mpi.sh) not found. Aborting."
	return 1
fi
#-------------------------------------

#Clean Old logs if any (the real file the worker script appends to, under $OUTDIR)
[ -f $OUTDIR/OSU/OSU.JobIDs.txt ] && rm $OUTDIR/OSU/OSU.JobIDs.txt

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
echo "Benchmark: OSU"
echo "------------------------------"
echo ""
echo "The job submission will start soon..."
sleep 3


for nodes in 2 4 8 16 32 64 128 256 512
do
	for ppn in 1 2 4 8 16 32 48 
	do
    		#--------------------------
    		echo "---------------------------------"
    		echo "Benchmark: OSU, Number of Nodes, Process per node = $nodes, $ppn"
    		source $MainDir/SCRIPTS/jobSubmission/benchmarks/osu.sh $nodes $ppn
    		#--------------------------
    	done
done

