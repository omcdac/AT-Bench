#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

export MainDir=$PWD

#export OUTDIR=/scratch/nsmapplication/cdacapp01/AT-RUN/24_HR_AT/1.BATCH/13_RUN_CPU

export OUTDIR=/home/nsmapplication/cdacapp01/scratch/AT-RUN/03Aug2026

echo "******************************"
echo "*      Welcome to AT         *"
echo "*           Tool             *"
echo "******************************"
echo ""
echo "Let's submit the Jobs of HPC Cluster !"
echo ""

echo "Please select application, to submit the job"
echo "1. NAMD"
echo "2. GROMACS"
echo "3. OPENFOAM"
echo "4. WRF"
echo "5. HPL"
echo "6. STREAM"
echo "7. OSU"
echo ""
read -p "" select
echo ""

if [ $select == 1 ];then
	echo "You have selected NAMD Application !"
    	echo ""
	echo "Please wait, Job submission will start soon..."
	sleep 1
	source $MainDir/SCRIPTS/AT-JobSetup/NAMD-atJobSubmission.sh

elif [ $select == 2 ];then
        echo "You have selected GROMACS Application !"
        echo ""
        echo "Please wait, Job submission will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/AT-JobSetup/GROMACS-atJobSubmission.sh

elif [ $select == 3 ];then
        echo "You have selected OPENFOAM Application !"
        echo ""
        echo "Please wait, Job submission will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/AT-JobSetup/OpenFOAM-atJobSubmission.sh

elif [ $select == 4 ];then
        echo "You have selected WRF Application !"
        echo ""
        echo "Please wait, Job submission will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/AT-JobSetup/WRF-atJobSubmission.sh

elif [ $select == 5 ];then
        echo "You have selected HPL Application !"
        echo ""
        echo "Please wait, Job submission will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/BENCH-setup/hpl/HPL-JobSubmission.sh

elif [ $select == 6 ];then
        echo "You have selected HPL Application !"
        echo ""
        echo "Please wait, Job submission will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/BENCH-setup/stream/STREAM-JobSubmission.sh

elif [ $select == 7 ];then
        echo "You have selected OSU Application !"
        echo ""
        echo "Please wait, Job submission will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/BENCH-setup/osu/OSU-JobSubmission.sh

else
	echo "Invalid choice!"
	echo ""
fi
