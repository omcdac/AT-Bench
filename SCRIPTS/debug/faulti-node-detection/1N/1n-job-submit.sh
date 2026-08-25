#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================



# File containing the list of nodes
#NODELIST="nodelist.txt"

NNODES=1
# Read all nodes into an array
mapfile -t NODES_ARRAY < "$NODELIST"

# Get the total number of nodes
TOTAL_NODES=${#NODES_ARRAY[@]}

# Start index
START_INDEX=0

# Initialize iteration count
iteration=0

# Submit jobs on one node at a time
while [ $START_INDEX -lt $TOTAL_NODES ]; do
    iteration=$((iteration+1))

    # Get one node from the list
    NODE="${NODES_ARRAY[$START_INDEX]}"

    # Prepare nodelist with just one node
    nodelist="$NODE"
    
    # Submit job on the current node
    echo "Submitting job on node: $nodelist"
    source $MainDir/SCRIPTS/debug/faulti-node-detection/1N/namdJob-softlink.sh $iteration $nodelist $NNODES

    # Move to the next node
    START_INDEX=$((START_INDEX + 1))
done

