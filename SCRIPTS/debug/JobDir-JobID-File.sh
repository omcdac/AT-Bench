#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


# Specify the path to the file containing Slurm job IDs
job_ids_file="/home/om/AT-om/SCRIPTS/jobSubmission/NAMD_JobIDs.txt"

# Loop through each job ID in the file
while IFS= read -r job_id; do
    # Use find to locate files with the specified job ID
    matching_files=$(find /home/om/AT-om/RUN -name "*$job_id*")

    # Print the job ID and corresponding directories
    echo "JOB ID: $job_id"
    #echo "Corresponding Directory:"
    echo "Dir: $matching_files" | xargs -I{} dirname {} | sort -u | tail -1
    echo "-------------------------"

done < "$job_ids_file"

