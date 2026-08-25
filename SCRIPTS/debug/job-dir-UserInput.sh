#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


# Loop through each job ID provided as command line parameters
for job_id in $(echo "$1" | tr ',' '\n'); do
    # Use find to locate files with the specified job ID
    matching_files=$(find /home/om/AT-om/RUN -name "*$job_id*")
    echo "-------------------------"
    # Print the job ID and corresponding directories
    echo "JOB ID: $job_id"
    #echo "Corresponding Directories:"
    RUNDIR=$(echo "$matching_files" | xargs -I{} dirname {} | sort -u | tail -1)
    echo "Directory: $RUNDIR"
    [ -f $RUNDIR/nodelist.txt ] && echo "Nodelist: $(cat $RUNDIR/nodelist.txt)"
    echo "-------------------------"
done

