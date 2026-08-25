#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


# Specify the path to the file containing Slurm job IDs
job_ids_file="$OUTDIR/NODE-TEST/1N/TEST_JobIDs.txt"

## For CSV file results
# Define the CSV file
#[ -f $MainDir/LOGS/namd-logs/NAMD-results.csv ] && mv $MainDir/LOGS/namd-logs/NAMD-results.csv $MainDir/LOGS/namd-logs/records/NAMD-results.csv.`date "+%F-%T"`
#csv_file="$MainDir/LOGS/namd-logs/NAMD-results.csv"
# Check if the CSV file exists
#if [ ! -f "$csv_file" ]; then
#    # If the CSV file doesn't exist, create it with headers
#    echo "job_id,nsperday,walltime,nodelist" > "$csv_file"
#fi
###

## For CSV file results
# Define the CSV file
[ -f $MainDir/LOGS/nodeTest/1NODE-TEST-results.csv ] && rm $MainDir/LOGS/nodeTest/1NODE-TEST-results.csv
csv_file="$MainDir/LOGS/nodeTest/1NODE-TEST-results.csv"
# Check if the CSV file exists
if [ ! -f "$csv_file" ]; then
    # If the CSV file doesn't exist, create it with headers
    echo "job_id,cds,walltime,nodelist" > "$csv_file"
fi
###

# Define the acceptable ranges for ns/Day and WallClock time
nnodes=1
#1. ns/Day renge
nsperday_min=2.5
nsperday_max=2.9
#2. Walltime renge
walltime_min=120
walltime_max=180

#-----------------------------------------

### Initialize useful counters
ok_jobs=0
FileNotFoundJobs=0
NotWithinRengeJobs=0

totalJobs=$(cat $job_ids_file | wc -l)
# Loop through each job ID in the file
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/SuccesfullJobIDs ] && rm $MainDir/SCRIPTS/debug/faulti-node-detection/1N/SuccesfullJobIDs
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/FileNotExistsJobIDs ] && rm $MainDir/SCRIPTS/debug/faulti-node-detection/1N/FileNotExistsJobIDs
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/ResultOutOffRengeJobIDs ] && rm $MainDir/SCRIPTS/debug/faulti-node-detection/1N/ResultOutOffRengeJobIDs
[ -f $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt ] && mv $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt $MainDir/LOGS/nodeTest/records/1NODE-TEST_Summary.txt.`date "+%F-%T"`
#
while IFS= read -r job_id; do
    # Use find to locate files with the specified job ID
    matching_files=$(find $OUTDIR/NODE-TEST/1N -name "*$job_id*")

    # Print the job ID and corresponding directories
    echo "Checking JOB-ID: $job_id ..."
    sleep 2
    #echo "Corresponding Directory:"
    #echo "Dir: $matching_files" | xargs -I{} dirname {} | sort -u
    RUNDIR=$(echo "$matching_files" | xargs -I{} dirname {} | sort -u | tail -1) 
    #echo "-------------------------"
    echo "Job Dir: $RUNDIR"
    cd $RUNDIR
    #--- Verification of different Parametes
    if [ -e "$RUNDIR/namd-cpu.output" ] && grep -q "WallClock" "$RUNDIR/namd-cpu.output" ; then #check if file is present and completes the run
        # 1. ns/days
        nsperday=$(echo "scale=4; 1 / $(cat namd-cpu.output | grep "Benchmark time" | tail -1 | awk '{print $8}')" | bc)
        #nsperday=$(echo "scale=4; 1 / $(awk '/Info:/{print $8}' namd-cpu.output | tail -1)" | bc)
	#echo "ns/Day: $nsperday"
        # 2. Wall Clock time
        walltime=$(cat "$RUNDIR/namd-cpu.output" | grep "WallClock" | awk '{print $2}')
        #echo "WallClock: $walltime"
        echo "RESULTS: ns/Day=$nsperday, WallClock=$walltime s"

	# Update the values in the CSV file
    	#sed -i "/^$job_id,/s/[^,]*,$/$nsperday,$walltime/" "$csv_file"
	
	#echo "$job_id,$nsperday,$walltime,$(cat $RUNDIR/nodelist.txt)" >> "$csv_file"
	#Making Nodelist as string 
	echo "$job_id,$nsperday,$walltime,\"$(cat $RUNDIR/nodelist.txt)\"" >> "$csv_file"

	# Check if values are within the specified ranges
	if (( $(echo "$nsperday >= $nsperday_min && $nsperday <= $nsperday_max" | bc -l) )) && \
		(( $(echo "$walltime >= $walltime_min && $walltime <= $walltime_max" | bc -l) )); then
        	#If Within renge
		#successfull Jobs
        	echo ":OK: The job with JOB ID $job_id is succesfull and outputs are within renge"
		#echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/debug/faulti-node-detection/SuccesfullJobIDs
		echo "$(cat $RUNDIR/nodelist.txt)" >> $MainDir/SCRIPTS/debug/faulti-node-detection/1N/SuccesfullJobIDs
		[ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
        	((ok_jobs++))
	else
        	#If not within renge
		#unsuccesfull Jobs
        	echo ":Not OK: The results are not within the renge. Check JOB ID: $job_id"
        	#echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/debug/faulti-node-detection/ResultOutOffRengeJobIDs
		echo "$(cat $RUNDIR/nodelist.txt)" >> $MainDir/SCRIPTS/debug/faulti-node-detection/1N/ResultOutOffRengeJobIDs
		[ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
        	((NotWithinRengeJobs++))
	fi
    else
	#Incomplete Jobs
        echo ":Not OK: Results are incomplete! Please Check Job ID: $job_id"
        echo "-------------------------"
	#echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/debug/faulti-node-detection/FileNotExistsJobIDs
	echo "$(cat $RUNDIR/nodelist.txt)" >> $MainDir/SCRIPTS/debug/faulti-node-detection/1N/FileNotExistsJobIDs
	[ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
	((FileNotFoundJobs++))
        continue  
    fi

    echo "-------------------------"

    unset nsperday
    unset walltime

done < "$job_ids_file"

###############################################################
#                      Summary                                #
###############################################################

echo "##########################################################" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "%   NODE Test Job Summary: Time-$(date +"%Y-%m-%d %H:%M:%S")  %" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "##########################################################" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "Total Jobs: $totalJobs                               " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "Acceptable results range for $nnodes nodes)"   | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "ns/day: minimum = $nsperday_min"   | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "ns/day: maximum = $nsperday_max"   | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "Walltime: minumum = $walltime_min"   | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "Walltime: maximum = $walltime_max"   | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
# Succesfull Jobs
echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "            A: WORKING NODES (Results within range)     " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "No. of Succesfull Jobs= $ok_jobs                         " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/SuccesfullJobIDs ] && success_job_ids=$(cat $MainDir/SCRIPTS/debug/faulti-node-detection/1N/SuccesfullJobIDs | tr '\n' ',' | sed 's/,$//')
echo "NODE LIST: $success_job_ids                     "             | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/SuccesfullJobIDs ] && echo "Note*: The results of the above jobs are within specified renge!" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
# Unsuccesfull Jobs
#not_ok_jobs=$(( NotWithinRengeJobs + FileNotFoundJobs ))
echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "            B.SLOW NODES :(Results not within range) $not_ok_jobs            " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
# Outoff renge Jobs
echo "No. of Slow Jobs= $NotWithinRengeJobs            " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/ResultOutOffRengeJobIDs ] && outoffrenge_job_ids=$(cat $MainDir/SCRIPTS/debug/faulti-node-detection/1N/ResultOutOffRengeJobIDs | tr '\n' ',' | sed 's/,$//')
echo "NODE LIST: $outoffrenge_job_ids                 "             | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/ResultOutOffRengeJobIDs ] && echo "Important*: You may need to debug above Jobs as results are not within specified renge! " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt

# Incomplete Jobs
echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "            C.FAULTI NODES :(Output not generated) $not_ok_jobs               " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
# File Not Found Jobs
echo "No. of Faulti Jobs= $FileNotFoundJobs                 " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/FileNotExistsJobIDs ] && filenotexist_job_ids=$(cat $MainDir/SCRIPTS/debug/faulti-node-detection/1N/FileNotExistsJobIDs | tr '\n' ',' | sed 's/,$//')
echo "NODE LIST: $filenotexist_job_ids                "             | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
[ -f $MainDir/SCRIPTS/debug/faulti-node-detection/1N/FileNotExistsJobIDs ] && echo "Important*: You may need to DEBUG these nodes as result is not complete yet! " | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt

echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt
echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" | tee -a $MainDir/LOGS/nodeTest/1NODE-TEST_Summary.txt


