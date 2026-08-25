#!/bin/bash
#===========================================================
# Author: Om Jadhav, HPC Technologies Group, C-DAC Pune
#===========================================================
#
# On-demand suspect-node diagnostic. Reads a day's already-computed
# CRON/Verification/LOGS/<date>/nodes/{slow,failed}-nodes.txt and
# debug/job_debug_records.csv (both from run-verification.sh), filters
# down to nodes plausibly worth re-testing (see node_diagnose.py select),
# then runs single-node HPL + STREAM on every candidate (plus the
# reference node itself, for a same-run STREAM baseline) and
# reference-vs-candidate OSU point-to-point latency/bandwidth, and writes
# a report.
#
# NOT wired into run-verification.sh's daily cron run -- this submits real
# SLURM jobs (potentially many, one HPL + one STREAM per candidate node,
# plus one OSU job per candidate) and is meant to be triggered deliberately,
# not unattended every day.
#
# Usage:
#    ./diagnose-nodes.sh [date] [--limit N] [--nodes-dir DIR] [--timeout SECONDS]
#
# date defaults to today (format: DDMonthYYYY, e.g. 10August2026), and must
# already have a completed run-verification.sh pass (i.e.
# CRON/Verification/LOGS/<date>/nodes/ must exist) unless --nodes-dir is
# given instead.
#
# --limit N caps how many candidate nodes actually get submitted (the first
# N after selection) -- e.g. to try this out on 2 nodes before committing a
# cluster's worth of HPL/STREAM/OSU jobs to a day with a large candidate
# list. Omit it to run the full candidate list.
#
# --nodes-dir DIR picks which nodes/ directory candidates are selected
# from, instead of the default CRON/Verification/LOGS/<date>/nodes -- e.g.
# to diagnose against a hand-picked or backed-up node list that doesn't
# live under the usual dated LOGS tree. debug/, diagnose/ and the scratch
# run dir still follow <date> as usual.
#
# --timeout SECONDS caps how long this script waits for jobs to finish
# (default 2400 = 40 min: comfortably above HPL's own 30-min --time cap
# plus queueing room). A job that's still PENDING (e.g. a candidate node
# genuinely unreachable/unavailable) has no natural end on its own -- past
# the timeout, whatever's still outstanding gets cancelled and reported as
# a timeout with its last known SLURM state, rather than waiting forever.
#===========================================================

set -uo pipefail
# Deliberately not `set -e`: one node's sbatch failing shouldn't abort the
# whole batch -- we want a full report covering every node we could
# actually submit for, not a silent partial run.

MainDir=/home/nsmapplication/cdacapp01/AT-Bench
DISCLAIMER="Disclaimer: Internal testing, not publication ready. Contact: omjadhav@cdac.in"

# Same pattern/rationale as CRON/Jobsubmission/run-jobsubmission.sh's
# *_RESERVATION vars: most cbcn nodes (confirmed live 2026-08-10: 1669 of
# ~2906) sit inside the "workingcpunodes" reservation SLURM admins use to
# scope jobs to nodes considered healthy -- a plain sbatch with no
# --reservation gets "ReqNodeNotAvail, May be reserved for other job" and
# sits PENDING forever on any node inside it, confirmed by testing this
# directly against real candidate nodes. Overridable via env var, not
# hardcoded, for the same reason run-jobsubmission.sh's comments give:
# never silently reactivate a stale reservation if this one goes away.
DIAGNOSE_RESERVATION="${DIAGNOSE_RESERVATION:-workingcpunodes}"

TODAY="$(date +%d%B%Y)"
LIMIT=""
NODES_DIR_OVERRIDE=""
TIMEOUT=2400
while [ $# -gt 0 ]; do
    case "$1" in
        --limit) LIMIT="$2"; shift 2 ;;
        --nodes-dir) NODES_DIR_OVERRIDE="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) TODAY="$1"; shift ;;
    esac
done

[ -f /etc/profile.d/modules.sh ] && source /etc/profile.d/modules.sh
module load miniconda

NODES_DIR="${NODES_DIR_OVERRIDE:-$MainDir/CRON/Verification/LOGS/$TODAY/nodes}"
DEBUG_DIR="$MainDir/CRON/Verification/LOGS/$TODAY/debug"
REPORT_DIR="$MainDir/CRON/Verification/LOGS/$TODAY/diagnose"
RUN_DIR="/home/nsmapplication/cdacapp01/scratch/AT-RUN/Diagnose/$TODAY"

if [ ! -d "$NODES_DIR" ]; then
    if [ -n "$NODES_DIR_OVERRIDE" ]; then
        echo "Error: --nodes-dir $NODES_DIR not found." >&2
    else
        echo "Error: $NODES_DIR not found -- run-verification.sh hasn't produced node lists for $TODAY yet." >&2
    fi
    exit 1
fi

mkdir -p "$REPORT_DIR" "$RUN_DIR/HPL" "$RUN_DIR/STREAM" "$RUN_DIR/OSU"

CANDIDATES_FILE="$REPORT_DIR/candidates.txt"
REFERENCE_FILE="$REPORT_DIR/reference.txt"

echo "=== Selecting candidate suspect nodes for $TODAY (nodes dir: $NODES_DIR) ==="
python3 "$MainDir/SCRIPTS/debug/node_diagnose.py" select \
    --nodes-dir "$NODES_DIR" \
    --debug-dir "$DEBUG_DIR" \
    --candidates-out "$CANDIDATES_FILE" \
    --reference-out "$REFERENCE_FILE"

CANDIDATES=()
while IFS= read -r n; do [ -n "$n" ] && CANDIDATES+=("$n"); done < "$CANDIDATES_FILE"
REFERENCE=$(cat "$REFERENCE_FILE" 2>/dev/null)

FULL_CANDIDATE_COUNT="${#CANDIDATES[@]}"
if [ -n "$LIMIT" ] && [ "$FULL_CANDIDATE_COUNT" -gt "$LIMIT" ]; then
    CANDIDATES=("${CANDIDATES[@]:0:$LIMIT}")
    printf '%s\n' "${CANDIDATES[@]}" > "$CANDIDATES_FILE"
    echo
    echo "--limit $LIMIT given: submitting only $LIMIT of $FULL_CANDIDATE_COUNT selected candidate(s)."
fi

echo
echo "Candidates: ${#CANDIDATES[@]}   Reference node: ${REFERENCE:-(none)}"

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    echo "No hardware-attributable candidate nodes today -- nothing to diagnose."
    exit 0
fi

JOBIDS_FILE="$RUN_DIR/all-jobids.txt"
: > "$JOBIDS_FILE"
# jobid,benchmark,node -- node is the CANDIDATE node for OSU (not the
# reference), matching what node_diagnose.py's report actually keys a
# shortfall by. Used only if some job(s) have to be cancelled on timeout,
# to report exactly which node/benchmark that was instead of a bare jobid.
JOB_MAP_FILE="$RUN_DIR/job-map.txt"
: > "$JOB_MAP_FILE"

# ---- submit helpers ----
# Each symlinks the benchmark's source dir (SRC/BENCH/<APP>) into a fresh
# per-node run dir, matching the symlink-then-sbatch pattern
# SCRIPTS/jobSubmission/benchmarks/{hpl,stream,osu}.sh already use for the
# main daily pipeline -- kept self-contained here rather than reusing those
# scripts directly, since they're written to be `source`d with an implicit
# $node variable already in the caller's scope (fine for their own
# *-JobSubmission.sh sweep callers, but an easy footgun to inherit
# silently in a different orchestrator).

RESERVATION_ARGS=()
[ -n "$DIAGNOSE_RESERVATION" ] && RESERVATION_ARGS=(--reservation="$DIAGNOSE_RESERVATION")

submit_hpl() {
    local node="$1"
    local rundir="$RUN_DIR/HPL/RUN-$node"
    mkdir -p "$rundir"
    for f in "$MainDir/SRC/BENCH/HPL/hpl-1n"/*; do
        # xhpl_intel64_dynamic_outputs.txt is NOT symlinked: Intel's stock
        # runme_intel64_dynamic appends to it (never truncates), so
        # symlinking it would make every concurrent run on every node
        # append to the SAME file in SRC/BENCH -- confirmed live: 52MB and
        # 5,365 accumulated runs already, and all 3 nodes in this tool's
        # first real test wrote into that one file concurrently. Leaving it
        # unsymlinked means runme_intel64_dynamic's own `>> $OUT` just
        # creates a fresh local copy in each rundir instead.
        [ "$(basename "$f")" = "xhpl_intel64_dynamic_outputs.txt" ] && continue
        [ -f "$f" ] && ln -sf "$f" "$rundir/$(basename "$f")"
    done
    local jobid
    jobid=$(cd "$rundir" && sbatch "${RESERVATION_ARGS[@]}" --nodelist="$node" ./job.sh | awk '{print $4}')
    if [ -n "$jobid" ]; then
        echo "$jobid" >> "$JOBIDS_FILE"
        echo "$jobid,HPL,$node" >> "$JOB_MAP_FILE"
        echo "  HPL($node) -> job $jobid"
    else
        echo "  HPL($node): sbatch submission FAILED" >&2
    fi
}

submit_stream() {
    local node="$1"
    local rundir="$RUN_DIR/STREAM/RUN-$node"
    mkdir -p "$rundir"
    for f in "$MainDir/SRC/BENCH/STREAM"/*; do
        [ -f "$f" ] && ln -sf "$f" "$rundir/$(basename "$f")"
    done
    local jobid
    jobid=$(cd "$rundir" && sbatch "${RESERVATION_ARGS[@]}" --nodelist="$node" ./job.sh | awk '{print $4}')
    if [ -n "$jobid" ]; then
        echo "$jobid" >> "$JOBIDS_FILE"
        echo "$jobid,STREAM,$node" >> "$JOB_MAP_FILE"
        echo "  STREAM($node) -> job $jobid"
    else
        echo "  STREAM($node): sbatch submission FAILED" >&2
    fi
}

submit_osu() {
    local ref="$1" node="$2"
    local rundir="$RUN_DIR/OSU/RUN-$ref-$node"
    mkdir -p "$rundir"
    for f in "$MainDir/SRC/BENCH/OSU"/*; do
        [ -f "$f" ] && ln -sf "$f" "$rundir/$(basename "$f")"
    done
    local jobid
    jobid=$(cd "$rundir" && sbatch "${RESERVATION_ARGS[@]}" --export=ALL,REF_NODE="$ref" --nodelist="$ref,$node" ./job.sh | awk '{print $4}')
    if [ -n "$jobid" ]; then
        echo "$jobid" >> "$JOBIDS_FILE"
        echo "$jobid,OSU,$node" >> "$JOB_MAP_FILE"
        echo "  OSU($ref vs $node) -> job $jobid"
    else
        echo "  OSU($ref vs $node): sbatch submission FAILED" >&2
    fi
}

echo
echo "=== Submitting HPL + STREAM (${#CANDIDATES[@]} candidate(s) + reference) ==="
for node in "${CANDIDATES[@]}"; do
    submit_hpl "$node"
    submit_stream "$node"
done
if [ -n "$REFERENCE" ]; then
    submit_hpl "$REFERENCE"
    submit_stream "$REFERENCE"
fi

if [ -n "$REFERENCE" ]; then
    echo
    echo "=== Submitting OSU (reference vs. each candidate) ==="
    for node in "${CANDIDATES[@]}"; do
        submit_osu "$REFERENCE" "$node"
    done
else
    echo
    echo "No reference node available (no successful nodes today) -- skipping OSU."
fi

N_JOBS=$(wc -l < "$JOBIDS_FILE")
echo
echo "=== Waiting for $N_JOBS job(s) to finish (polling every 30s, timeout ${TIMEOUT}s) ==="

# NOTE on how this checks "are we done": earlier versions of this script
# did `squeue -j <comma-joined list of every job id> -h | grep -q .` and
# treated ANY empty result as "nothing left, we're done". Found by testing
# directly against this cluster: `squeue -j` can fail outright (non-zero
# exit, no output at all -- confirmed reproducible against a stale/aged-out
# job id) and that failure looked IDENTICAL to "genuinely zero jobs left"
# once piped through grep, since grep never saw squeue's exit code. In a
# real run (2026-08-11, 559 candidates / ~1,676 jobs) this made the whole
# script conclude "done" within ~2 minutes while the real HPL jobs kept
# running unsupervised in the background for another 7+ minutes before
# something else eventually cancelled them -- exactly the "gets out
# without actually waiting" symptom this loop exists to prevent.
#
# Fixed by querying `squeue -u <this user>` (one simple, single-purpose
# query slurmctld answers the same way regardless of how many job IDs we
# personally care about) and intersecting its output against our own
# JOBIDS_FILE locally, instead of asking slurmctld to look up a
# potentially-huge, potentially-stale explicit ID list every single poll.
WHOAMI=$(whoami)
JOBIDS_SORTED=$(sort -u "$JOBIDS_FILE")
WAITED=0
TIMED_OUT=0
while [ -n "$JOBIDS_SORTED" ]; do
    # Query squeue on its own (no pipe) so its exit status is checked
    # directly rather than swallowed by a pipeline -- a transient squeue
    # failure (slurmctld restart/RPC hiccup, realistic across up to 80
    # polls on a shared cluster) must NOT be treated the same as "squeue
    # genuinely reported zero active jobs", or this loop would repeat the
    # exact bug it was just fixed for.
    ACTIVE_NOW=$(squeue -u "$WHOAMI" -h -o "%i" 2>/dev/null)
    SQUEUE_RC=$?
    if [ "$SQUEUE_RC" -eq 0 ]; then
        STILL_ACTIVE=$(comm -12 <(printf '%s\n' "$JOBIDS_SORTED") <(printf '%s\n' "$ACTIVE_NOW" | sort -u))
        [ -z "$STILL_ACTIVE" ] && break
    else
        echo "  (squeue query failed this poll -- treating as inconclusive, still waiting)"
    fi
    if [ "$WAITED" -ge "$TIMEOUT" ]; then
        TIMED_OUT=1
        echo "Timeout (${TIMEOUT}s) reached with job(s) still outstanding -- not waiting any longer."
        break
    fi
    sleep 30
    WAITED=$((WAITED + 30))
done

# Anything still in the queue at this point is either genuinely stuck
# (PENDING on a node that never became available -- exactly the "node may
# not be available" case) or, in principle, still RUNNING past its own
# --time cap's tolerance. Either way, don't leave it running/queued in the
# background after this script has already moved on: capture its last
# known state for the report, then cancel it so the resource is freed.
TIMEDOUT_FILE="$REPORT_DIR/timed-out.csv"
: > "$TIMEDOUT_FILE"
if [ "$TIMED_OUT" -eq 1 ]; then
    STILL_QUEUED=$(squeue -u "$WHOAMI" -h -o "%i|%T" 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "  (squeue query failed -- retrying once before giving up on the cancel pass)"
        sleep 5
        STILL_QUEUED=$(squeue -u "$WHOAMI" -h -o "%i|%T" 2>/dev/null)
    fi
    if [ -n "$STILL_QUEUED" ]; then
        echo
        echo "=== Cancelling still-outstanding job(s) ==="
        while IFS='|' read -r jid jstate; do
            [ -z "$jid" ] && continue
            grep -qxF "$jid" "$JOBIDS_FILE" || continue   # not one of ours -- leave it alone
            map_line=$(grep "^$jid," "$JOB_MAP_FILE" 2>/dev/null)
            benchmark="${map_line#*,}"; benchmark="${benchmark%%,*}"
            node="${map_line##*,}"
            [ -z "$benchmark" ] && benchmark="UNKNOWN"
            [ -z "$node" ] && node="UNKNOWN"
            echo "  job $jid ($benchmark on $node): state=$jstate -- cancelling"
            scancel "$jid" 2>/dev/null
            echo "$node,$benchmark,$jstate" >> "$TIMEDOUT_FILE"
        done <<< "$STILL_QUEUED"
    fi
fi
echo "All jobs finished, timed out, or dropped out of the queue."

echo
echo "=== Parsing results and writing report ==="
python3 "$MainDir/SCRIPTS/debug/node_diagnose.py" report \
    --diagnose-run-dir "$RUN_DIR" \
    --timed-out-file "$TIMEDOUT_FILE" \
    --candidates "$CANDIDATES_FILE" \
    --reference "$REFERENCE_FILE" \
    --out-dir "$REPORT_DIR" \
    --run-label "$TODAY"

echo
echo "Done. Report: $REPORT_DIR/report.txt"
