#!/bin/bash

# =============================================================================
# Author      : Om Jadhav
# Organization: HPC Technologies Group, C-DAC Pune
# Email       : omjadhav@cdac.in
# =============================================================================



sinfo -N | awk {'print $1'} | grep rbcn* | sort | uniq > cpuNodes.txt

sinfo -N | awk {'print $1'} | grep rbhm* | sort | uniq > hmNodes.txt

sinfo -N | awk {'print $1'} | grep rbgpu* | sort | uniq > gpuNodes.txt
