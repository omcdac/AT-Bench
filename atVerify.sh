#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

export MainDir=$PWD

OUTDIR=/home/nsmapplication/cdacapp01/scratch/AT-RUN/24_HR_AT/OM-Gromacs

echo "******************************"
echo "*      Welcome to AT         *"
echo "*           Tool             *"
echo "******************************"
echo ""
echo "Now, Let's verify job results"
echo ""

echo "Please select application, whose results need to verify"
echo "1. NAMD"
echo "2. GROMACS"
echo "3. OPENFOAM"
echo "4. WRF"
echo "5. HPL"
echo ""
read -p "" select
echo ""

if [ $select == 1 ];then
	echo "You have selected NAMD Application !"
    	echo ""
	echo "Please wait, result verification will start soon..."
	sleep 1
	source $MainDir/SCRIPTS/verification/namd/namd-verify-results.sh | tee -a $MainDir/LOGS/namd-logs/namd.`date "+%F-%T"`.txt

elif [ $select == 2 ];then
        echo "You have selected GROMACS Application !"
        echo ""
        echo "Please wait, result verification will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/verification/gromacs/gromacs-verify-results.sh | tee -a $MainDir/LOGS/gromacs-logs/gromacs.`date "+%F-%T"`.txt

elif [ $select == 3 ];then
        echo "You have selected OPENFOAM Application !"
        echo ""
        echo "Please wait, result verification will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/verification/openfoam/openfoam-verify-results.sh | tee -a $MainDir/LOGS/openfoam-logs/openfoam.`date "+%F-%T"`.txt

elif [ $select == 4 ];then
        echo "You have selected WRF Application !"
        echo ""
        echo "Please wait, result verification will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/verification/wrf/wrf-verify-results.sh | tee -a $MainDir/LOGS/wrf-logs/wrf.`date "+%F-%T"`.txt

elif [ $select == 5 ];then
        echo "You have selected HPL Benchmakr !"
        echo ""
        echo "Please wait, result verification will start soon..."
        sleep 3
        source $MainDir/SCRIPTS/verification/hpl/hpl-verify-results.sh | tee -a $MainDir/LOGS/hpl-logs/hpl.`date "+%F-%T"`.txt

else
	echo "Invalid choice!"
	echo ""
fi
