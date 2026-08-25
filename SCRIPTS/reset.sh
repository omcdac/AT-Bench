#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

export MainDir=/home/appsupport01/OM/AT-Bench/

echo "Please wait.. reset in progress!"
bash $MainDir/SCRIPTS/deleteJob.sh
sleep 10

#Reset RUN directories 
rm -rf $MainDir/RUN/MIX_MODE

#Remove Summaries
[ -f $MainDir/LOGS/WRF_Summary.txt ] && rm $MainDir/LOGS/WRF_Summary.txt
[ -f $MainDir/LOGS/NAMD_Summary.txt ] && rm $MainDir/LOGS/NAMD_Summary.txt
[ -f $MainDir/LOGS/GROMACS_Summary.txt ] && rm $MainDir/LOGS/GROMACS_Summary.txt
[ -f $MainDir/LOGS/OPENFOAM_Summary.txt ] && rm $MainDir/LOGS/OPENFOAM_Summary.txt

#rm /home/om/AT-om/LOGS/WRF_Summary.txt /home/om/AT-om/LOGS/NAMD_Summary.txt

echo "Done!"
