# AT-Bench

Acceptance-test harness for a SLURM HPC cluster (C-DAC Pune, HPC Technologies
Group). Runs GROMACS, NAMD, OpenFOAM, and WRF jobs nightly across the
cluster, verifies results the next morning, and provides debug/diagnostic
tooling to pin down which specific nodes are causing slow or failed jobs.

Author: Om Jadhav (omjadhav@cdac.in)

## Repo layout

```
CRON/Jobsubmission/   Nightly job-submission cron entry point + per-app config
CRON/Verification/    Morning verification cron entry point + per-app wrappers
CRON/graph/           Cluster-wide analysis charts (atbench_analyzer.py)
SCRIPTS/jobSubmission/  Per-app SLURM submission workers
SCRIPTS/AT-JobSetup/    Per-app job-count/preflight setup, sourced by the workers
SCRIPTS/verification/   Per-app result-verification scripts (verify-results.sh)
SCRIPTS/debug/          job_debug_analyzer.py (why did a job fail?), node_diagnose.py
SCRIPTS/extract-nodes   Turns a verify-results.sh summary into clean node lists
SCRIPTS/diagnose-nodes.sh  On-demand HPL/STREAM/OSU micro-benchmark diagnosis
                           of slow/failed nodes (not cron-wired -- run manually)
SRC/                    App source, inputs, and SLURM job templates (see below)
LOGS/, CRON/*/LOGS/, CRON/*/cron-job-*-logs/   Runtime output -- not in git
```

## SRC/ is not in this repo

`SRC/` is ~25G (WRF alone is ~18G, mostly one restart file) and is data, not
code, so it's excluded here (see `.gitignore`) and distributed separately.

**Before running anything on a new checkout:**

1. Download the SRC archive: **`<TODO: paste the Google Drive (or other
   storage) link here once SRC/ has been uploaded>`**
2. Extract it at the repo root so you end up with `AT-Bench/SRC/...`:
   ```
   tar -xzf SRC.tar.gz -C /path/to/AT-Bench/
   ```

## Setting this up on a new cluster

This harness was written for one specific cluster and has cluster-specific
values baked into it in a few places. None of this is a design flaw to fix
before using it elsewhere -- it's genuinely cluster-specific and has to be
re-supplied. In the order you'll hit them:

1. **Spack environment paths.** Every app's `SRC/<APP>/input/setup.sh` (or
   `env.sh`) sources hash-pinned Spack install paths (Intel oneAPI compiler/
   MPI/MKL, MVAPICH, OpenFOAM, METIS, SCOTCH). These hashes are unique to
   this machine's Spack build tree and will not exist anywhere else, even
   with identical package versions installed. Rebuild/locate the equivalent
   packages on the new system and update each `setup.sh`/`env.sh` file
   accordingly (`grep -rn 'spack/opt/spack' SRC/` finds all of them once
   SRC/ is restored).
2. **SLURM reservation name and partitions.** `workingcpunodes` is a SLURM
   reservation this cluster's admins use to scope jobs to healthy nodes; the
   real partition is `cpu` (plus `gpu`/`hm`/`hpl02` for other node classes).
   These are centralized in **one place**:
   `CRON/Jobsubmission/run-jobsubmission.sh`'s CONFIGURATION block at the
   top (`*_RESERVATION`, `*_PARTITION`, `*_NUM_JOBS`, `BASE_OUTDIR`) --
   edit only there. `SCRIPTS/diagnose-nodes.sh`'s `DIAGNOSE_RESERVATION`
   (env-overridable) needs the same update.
3. **`module load miniconda`** (in `run-verification.sh` and
   `diagnose-nodes.sh`) assumes a module of that exact name. Point it at
   whatever provides Python 3 + matplotlib on the new system.
4. **`MainDir`.** Every CRON script exports `MainDir=/home/nsmapplication/cdacapp01/AT-Bench`
   at the top -- update to wherever this repo actually lives.
5. **Crontab.** The crontab itself is not part of this repo and won't
   transfer with a `git clone`. Re-add both lines on the new system:
   ```
   45 0 * * * LOGDIR="<MainDir>/CRON/Jobsubmission/cron-job-submission-logs/$(date +\%d\%B\%Y)"; mkdir -p "$LOGDIR"; <MainDir>/CRON/Jobsubmission/run-jobsubmission.sh >> "$LOGDIR/JobSubmission.log" 2>&1
   0 9 * * * LOGDIR="<MainDir>/CRON/Verification/cron-job-verification-logs/$(date +\%d\%B\%Y)"; mkdir -p "$LOGDIR"; <MainDir>/CRON/Verification/run-verification.sh >> "$LOGDIR/Verification.log" 2>&1
   ```
6. **`SCRIPTS/fault-detection`** references an old, different path
   (`/home/cdacappadmin/OM/...`) and `JobPartition=standard` -- this looks
   like a stale leftover from an earlier environment, not part of the
   current pipeline. Confirm whether it's still needed before relying on it.

## Day-to-day operation

- **Nightly, automated:** `run-jobsubmission.sh` (00:45) submits jobs;
  `run-verification.sh` (09:00) verifies the previous night's results,
  builds cluster-wide success/slow/failed node lists, and runs the debug
  analyzer.
- **On demand:** `SCRIPTS/diagnose-nodes.sh [date] [--limit N] [--nodes-dir DIR] [--timeout SECONDS]`
  runs single-node HPL/STREAM and reference-vs-candidate OSU on the
  slow/failed nodes a verification run identified, to pin down genuine
  hardware culprits. Not cron-wired -- run manually when investigating.
