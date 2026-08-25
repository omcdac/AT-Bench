#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


# Specify the path to the file containing Slurm job IDs
job_ids_file="$MainDir/LOGS/JobIDs/STREAM.JobIDs.txt"

## For CSV file results
# Define the CSV file
[ -f $MainDir/LOGS/STREAM-results.csv ] && rm $MainDir/LOGS/STREAM-results.csv
csv_file="$MainDir/LOGS/STREAM-results.csv"
# Check if the CSV file exists
if [ ! -f "$csv_file" ]; then
    # If the CSV file doesn't exist, create it with headers
    echo "Job_id,Gflops,Time,Efficiency(%),nodelist" > "$csv_file"
fi
###

# Define the acceptable ranges for ns/Day and WallClock time
nnodes=1
#1. ns/Day renge
gflop_min=2400
gflop_max=2600
#2. Walltime renge
walltime_min=450
walltime_max=580

#-----------------------------------------

### Initialize useful counters
ok_jobs=0
FileNotFoundJobs=0
NotWithinRengeJobs=0

totalJobs=$(cat $job_ids_file | wc -l)
# Loop through each job ID in the file
[ -f $MainDir/SCRIPTS/verification/stream/SuccesfullJobIDs ] && rm $MainDir/SCRIPTS/verification/stream/SuccesfullJobIDs
[ -f $MainDir/SCRIPTS/verification/stream/FileNotExistsJobIDs ] && rm $MainDir/SCRIPTS/verification/stream/FileNotExistsJobIDs
[ -f $MainDir/SCRIPTS/verification/stream/ResultOutOffRengeJobIDs ] && rm $MainDir/SCRIPTS/verification/stream/ResultOutOffRengeJobIDs
[ -f $MainDir/LOGS/STREAM_Summary.txt ] && rm $MainDir/LOGS/STREAM_Summary.txt
#
while IFS= read -r job_id; do
    # Use find to locate files with the specified job ID
    #matching_files=$(find $MainDir/RUN/MIX_MODE/NAMD -name "*$job_id*")
    matching_files=$(find /scratch/appsupport01/OM/BENCH_RUN/STREAM -name "*$job_id*")
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
    if [ -e "$RUNDIR/STREAM.out.$job_id" ] && grep -q "PASSED" "$RUNDIR/STREAM.out.$job_id" ; then #check if file is present and completes the run
        # 1. ns/days
        #nsperday=$(echo "scale=4; 1 / $(cat namd-cpu.output | grep "Benchmark time" | tail -1 | awk '{print $8}')" | bc)
        #nsperday=$(echo "scale=4; 1 / $(awk '/Info:/{print $8}' namd-cpu.output | tail -1)" | bc)
	gflop=$(cat HPL.out.$job_id | grep "WC00C2R2" | awk {'print $7'})
	gflop1=$(awk '{printf "%.6f", $1}' <<< "$gflop" | sed 's/\.0*$//')
	#Efficiency Calculation for single node. For the RUDRA single node Peak Performance number is 3686.
	#For verification visit the link: https://hpl-calculator.sourceforge.net/ or https://hpl-calculator.sourceforge.net/hpl-calculations.php
	efficiency=$(echo "scale=4; $gflop1*100/3686" | bc )
	#echo "ns/Day: $nsperday"
        # 2. Wall Clock time
        walltime=$(cat HPL.out.$job_id | grep "WC00C2R2" | awk {'print $6'})
        #echo "WallClock: $walltime"
        echo "RESULTS: Gflops=$gflop, WallClock=$walltime s"

	# Update the values in the CSV file
    	#sed -i "/^$job_id,/s/[^,]*,$/$nsperday,$walltime/" "$csv_file"
	echo "$job_id, $gflop, $walltime, $efficiency%, \"$(cat $RUNDIR/nodelist.txt)\"" >> "$csv_file"

	# Check if values are within the specified ranges
	if (( $(echo "$gflop1 >= $gflop_min && $gflop1 <= $gflop_max" | bc -l) )) && \
		(( $(echo "$walltime >= $walltime_min && $walltime <= $walltime_max" | bc -l) )); then
        	#If Within renge
		#successfull Jobs
        	echo ":OK: The job with JOB ID $job_id is succesfull and outputs are within renge"
		echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/verification/hpl/SuccesfullJobIDs
		[ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
        	((ok_jobs++))
	else
        	#If not within renge
		#unsuccesfull Jobs
        	echo ":Not OK: The results are not .within the renge. Check JOB ID: $job_id"
        	echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/verification/hpl/ResultOutOffRengeJobIDs
		[ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
        	((NotWithinRengeJobs++))
	fi
    elif [ -e "$RUNDIR/HPL.out.$job_id" ] && grep -q "HPL ERROR" "$RUNDIR/HPL.out.$job_id" ; then
	#HPL Error
	#nodeName=$(basename "$RUNDIR" | cut -d'-' -f2)
        #echo "$job_id,NULL,NULL,$nodeName" >> "$csv_file"
        echo "$job_id, NULL, ERROR, NULL, $(cat $RUNDIR/nodelist.txt)" >> "$csv_file"
	echo ":Not OK: Results are incomplete! Please Check Job ID: $job_id"
        echo "-------------------------"
        echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/verification/hpl/FileNotExistsJobIDs
        [ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
        ((FileNotFoundJobs++))
        continue

    else
	#Incomplete Jobs
	nodeName=$(basename "$RUNDIR" | cut -d'-' -f2)
	echo "$job_id, NULL, NODE DOWN, NULL, $nodeName" >> "$csv_file"
        echo ":Not OK: Results are incomplete! Please Check Job ID: $job_id"
        echo "-------------------------"
	echo "$job_id(Nodelist:$(cat $RUNDIR/nodelist.txt))" >> $MainDir/SCRIPTS/verification/hpl/FileNotExistsJobIDs
	[ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
	((FileNotFoundJobs++))
        continue  
    fi

    echo "-------------------------"

    unset gflop
    unset gflop1
    unset walltime

done < "$job_ids_file"

###############################################################
#                      Summary                                #
###############################################################

echo "##########################################################" | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "%   HPL Job Summary: Time-$(date +"%Y-%m-%d %H:%M:%S")  %" | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "##########################################################" | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "Total HPL Jobs: $totalJobs                               " | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "Acceptable results range for $nnodes nodes)"   | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "Gflop: minimum = $gflop_min"   | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "Gflop: maximum = $gflop_max"   | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "Walltime: minumum = $walltime_min"   | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "Walltime: maximum = $walltime_max"   | tee -a $MainDir/LOGS/HPL_Summary.txt
# Succesfull Jobs
echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "            A.SUCCESSFULL JOBS:(Results within range)     " | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "No. of Succesfull Jobs= $ok_jobs                         " | tee -a $MainDir/LOGS/HPL_Summary.txt
[ -f $MainDir/SCRIPTS/verification/hpl/SuccesfullJobIDs ] && success_job_ids=$(cat $MainDir/SCRIPTS/verification/hpl/SuccesfullJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $success_job_ids                     "             | tee -a $MainDir/LOGS/HPL_Summary.txt
[ -f $MainDir/SCRIPTS/verification/hpl/SuccesfullJobIDs ] && echo "Note*: The results of the above jobs are within specified renge!" | tee -a $MainDir/LOGS/HPL_Summary.txt
# Unsuccesfull Jobs
#not_ok_jobs=$(( NotWithinRengeJobs + FileNotFoundJobs ))
echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "            B.UNSUCCESSFULL JOBS:(Results not within range) $not_ok_jobs            " | tee -a $MainDir/LOGS/HPL_Summary.txt
# Outoff renge Jobs
echo "No. of Unsuccesfull Jobs= $NotWithinRengeJobs            " | tee -a $MainDir/LOGS/HPL_Summary.txt
[ -f $MainDir/SCRIPTS/verification/hpl/ResultOutOffRengeJobIDs ] && outoffrenge_job_ids=$(cat $MainDir/SCRIPTS/verification/hpl/ResultOutOffRengeJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $outoffrenge_job_ids                 "             | tee -a $MainDir/LOGS/HPL_Summary.txt
[ -f $MainDir/SCRIPTS/verification/hpl/ResultOutOffRengeJobIDs ] && echo "Important*: You may need to debug above Jobs as results are not within specified renge! " | tee -a $MainDir/LOGS/HPL_Summary.txt

# Incomplete Jobs
echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/HPL_Summary.txt
echo "            C.INCOMPLETE JOBS:(Output not generated) $not_ok_jobs               " | tee -a $MainDir/LOGS/HPL_Summary.txt
# File Not Found Jobs
echo "No. of Incomplete Jobs= $FileNotFoundJobs                 " | tee -a $MainDir/LOGS/HPL_Summary.txt
[ -f $MainDir/SCRIPTS/verification/hpl/FileNotExistsJobIDs ] && filenotexist_job_ids=$(cat $MainDir/SCRIPTS/verification/hpl/FileNotExistsJobIDs | tr '\n' ',' | sed 's/,$//')
echo "JOB IDs: $filenotexist_job_ids                "             | tee -a $MainDir/LOGS/HPL_Summary.txt
[ -f $MainDir/SCRIPTS/verification/hpl/FileNotExistsJobIDs ] && echo "Important*: You may need to either wait for the results of above jobs or Debug the issue as result is not complete yet! " | tee -a $MainDir/LOGS/HPL_Summary.txt

echo "----------------------------------------------------------" | tee -a $MainDir/LOGS/HPL_Summary.txt 
echo "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" | tee -a $MainDir/LOGS/HPL_Summary.txt


