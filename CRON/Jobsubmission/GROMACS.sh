#!/bin/bash

export MainDir=/home/nsmapplication/cdacapp01/AT-Bench

TODAY=$(date +"%d%B%Y")
echo "$TODAY"

export OUTDIR="${BASE_OUTDIR:-/home/nsmapplication/cdacapp01/scratch/AT-RUN}/$TODAY"

source $MainDir/SCRIPTS/AT-JobSetup/GROMACS-atJobSubmission.sh
