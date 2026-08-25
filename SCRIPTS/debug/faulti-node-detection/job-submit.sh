#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================


# get the nodelist
#sinfo -N | awk '{print $1}' | tail -n +2 | uniq > nodelist.txt

# File containing the list of nodes
#NODELIST="/home/cdacappadmin/OM/AT-Bench/SCRIPTS/debug/faulti-node-detection/nodelist.txt"
# Or take file from command line
#NODELIST=$1

NNODES=2
# Read all nodes into an array
mapfile -t NODES_ARRAY < "$NODELIST"

# Get the total number of nodes
TOTAL_NODES=${#NODES_ARRAY[@]}

# Start index
START_INDEX=0

iteration=0
# Submit jobs in pairs of distinct nodes
while [ $START_INDEX -lt $TOTAL_NODES ]; do
    iteration=$((iteration+1))
    
    if [ $((TOTAL_NODES - START_INDEX)) -eq 1 ]; then
        # If there is only one node left, pair it with the first node
        NODE1="${NODES_ARRAY[$START_INDEX]}"
        NODE2="${NODES_ARRAY[0]}"
	nodelist="$NODE1,$NODE2"
        echo "Submitting job on nodes: $nodelist"
	source $MainDir/SCRIPTS/debug/faulti-node-detection/namdJob-softlink.sh $iteration $nodelist $NNODES
        break
    else
        # Get two distinct nodes from the list
        NODE1="${NODES_ARRAY[$START_INDEX]}"
        NODE2="${NODES_ARRAY[$START_INDEX + 1]}"
	nodelist="$NODE1,$NODE2"
        echo "Submitting job on nodes: $nodelist"
	source $MainDir/SCRIPTS/debug/faulti-node-detection/namdJob-softlink.sh $iteration $nodelist $NNODES
    fi
    # Move to the next pair of nodes
    START_INDEX=$((START_INDEX + 2))
done

