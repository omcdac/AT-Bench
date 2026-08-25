# AT-Bench

Acceptance-test harness I built for our SLURM cluster here at C-DAC Pune
(HPC Technologies Group). It runs GROMACS, NAMD, OpenFOAM, and WRF jobs
across the cluster every night, verifies the results the next morning, and
gives me tooling to track down exactly which nodes are causing slow or
failed jobs, down to a benchmark-backed diagnosis (HPL/STREAM/OSU) of the
suspect hardware.

I've tested and run this on our own cluster, so a few values in here are
specific to that environment. If you're setting this up on a different
cluster, treat those as examples to replace rather than requirements --
they're called out below.

Author: Om Jadhav, HPC Technologies Group, C-DAC Pune (omjadhav@cdac.in)

For the day-to-day commands (how to actually run/submit/verify/diagnose),
see [HOW_TO_USE.md](HOW_TO_USE.md). This file is about layout and setup.

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

`SRC/` is ~25G on my end (WRF alone is ~18G, mostly one restart file) --
too large for GitHub, and it's data/binaries rather than code, so I'm
keeping it out of git and distributing it separately.

**Before running anything on a fresh checkout:**

1. Download the SRC archive: **`<TODO: paste the Google Drive (or other
   storage) link here once SRC/ has been uploaded>`**
2. Extract it at the repo root so you end up with `AT-Bench/SRC/...`:
   ```
   tar -xzf SRC.tar.gz -C /path/to/AT-Bench/
   ```

## Setting this up on a different cluster

Here's everything I have pinned to our specific environment, in the order
you'll run into it:

1. **Spack environment paths.** Every app's `SRC/<APP>/input/setup.sh` (or
   `env.sh`) sources our Spack install paths (Intel oneAPI compiler/MPI/MKL,
   MVAPICH, OpenFOAM, METIS, SCOTCH), and those paths are hash-pinned to our
   own Spack build tree -- they won't exist on your system even if you
   install the identical package versions. Build or locate the equivalent
   packages on your cluster and point each `setup.sh`/`env.sh` at them
   (`grep -rn 'spack/opt/spack' SRC/` finds every one of them once `SRC/` is
   restored).
2. **SLURM reservation name and partitions.** `workingcpunodes` is the
   reservation our admins use to scope jobs to healthy nodes; our real
   partition is `cpu` (plus `gpu`/`hm`/`hpl02` for other node classes on our
   cluster). I centralized all of this in **one place** so you only have to
   edit it once: `CRON/Jobsubmission/run-jobsubmission.sh`'s CONFIGURATION
   block at the top (`*_RESERVATION`, `*_PARTITION`, `*_NUM_JOBS`,
   `BASE_OUTDIR`). `SCRIPTS/diagnose-nodes.sh`'s `DIAGNOSE_RESERVATION`
   (env-overridable) needs the same update.
3. **`module load miniconda`** (in `run-verification.sh` and
   `diagnose-nodes.sh`) is what gives us Python 3 + matplotlib on our
   cluster. Point it at whatever module (or plain `source venv/bin/activate`,
   if you'd rather) provides that on yours.
4. **`MainDir`.** Every CRON script exports
   `MainDir=/home/nsmapplication/cdacapp01/AT-Bench` at the top -- change it
   to wherever you've actually cloned this repo.
5. **Crontab.** The crontab itself isn't part of this repo and won't come
   along with `git clone` -- add these two lines yourself once `MainDir` is
   set:
   ```
   45 0 * * * LOGDIR="<MainDir>/CRON/Jobsubmission/cron-job-submission-logs/$(date +\%d\%B\%Y)"; mkdir -p "$LOGDIR"; <MainDir>/CRON/Jobsubmission/run-jobsubmission.sh >> "$LOGDIR/JobSubmission.log" 2>&1
   0 9 * * * LOGDIR="<MainDir>/CRON/Verification/cron-job-verification-logs/$(date +\%d\%B\%Y)"; mkdir -p "$LOGDIR"; <MainDir>/CRON/Verification/run-verification.sh >> "$LOGDIR/Verification.log" 2>&1
   ```
6. **`SCRIPTS/fault-detection`** points at an old path of mine
   (`/home/cdacappadmin/OM/...`) and `JobPartition=standard` from an earlier
   setup -- I don't rely on it day-to-day anymore. Check it over before you
   use it.
