#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
# Email : omjadhav@cdac.in
#===========================================================

# Get a list of all job IDs except 123 and 456
all_job_ids=$(squeue -h -o "%i" -u cdacappadmin)
exclude_job_ids="126752"
cancel_job_ids=$(comm -23 <(echo "$all_job_ids" | tr ',' '\n' | sort) <(echo "$exclude_job_ids" | tr ',' '\n' | sort) | tr '\n' ',' | sed 's/,$//')

# Cancel all jobs except 123 and 456
scancel $cancel_job_ids

