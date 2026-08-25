# AT-Bench

AT-Bench is an acceptance-test toolset for a SLURM HPC cluster, developed by the HPC Technologies Group at C-DAC Pune. It submits GROMACS, NAMD, OpenFOAM, and WRF jobs across the cluster and verifies the results — run directly on demand, or automated on whatever schedule is required (for example, via cron) — and provides diagnostic tooling to pinpoint which specific nodes are responsible for slow or failed jobs, including a benchmark-based diagnosis (HPL, STREAM, OSU) of suspect hardware.

The configuration values documented below reflect the cluster on which this toolset was developed and is currently in use. When deploying on a different cluster, treat these values as examples to replace, not as fixed requirements.

| | |
|---|---|
| **Contact** | Om Jadhav, HPC Technologies Group, C-DAC Pune — omjadhav@cdac.in |

> Day-to-day usage commands are documented separately in **[HOW_TO_USE.md](HOW_TO_USE.md)**. This file covers repository layout and cluster setup.

## Contents

- [Repository layout](#repository-layout)
- [Source data (SRC/)](#source-data-src)
- [Cluster-specific setup](#cluster-specific-setup)

## Repository layout

| Path | Contents |
|---|---|
| `Workflow/Jobsubmission/` | Job-submission entry point (cron-compatible) and per-application configuration |
| `Workflow/Verification/` | Verification entry point (cron-compatible) and per-application wrappers |
| `Workflow/graph/` | Cluster-wide analysis charts (`atbench_analyzer.py`) |
| `SCRIPTS/jobSubmission/` | Per-application SLURM submission workers |
| `SCRIPTS/AT-JobSetup/` | Per-application job-count and preflight setup, sourced by the submission workers |
| `SCRIPTS/verification/` | Per-application result-verification scripts (`verify-results.sh`) |
| `SCRIPTS/debug/` | `job_debug_analyzer.py` (failure classification) and `node_diagnose.py` |
| `SCRIPTS/extract-nodes` | Converts a `verify-results.sh` summary into plain node lists |
| `SCRIPTS/diagnose-nodes.sh` | On-demand HPL/STREAM/OSU diagnosis of slow or failed nodes (not scheduled by cron; run manually) |
| `SRC/` | Application source, inputs, and SLURM job templates ([see below](#source-data-src)) |
| `LOGS/`, `Workflow/*/LOGS/`, `Workflow/*/cron-job-*-logs/` | Runtime output — not tracked in this repository |

## Source data (SRC/)

`SRC/` is approximately 25 GB (WRF alone accounts for roughly 18 GB, mostly a single restart file). It consists of application inputs and binaries rather than source code, and is excluded from this repository (see `.gitignore`) and distributed separately.

Before running this toolset on a fresh checkout:

1. **Download the SRC archive** from:
   `<TODO: storage link to be added once SRC/ has been uploaded>`

2. **Extract it at the repository root**, so the result is `AT-Bench/SRC/...`:

   ```bash
   tar -xzf SRC.tar.gz -C /path/to/AT-Bench/
   ```

## Cluster-specific setup

The following items are specific to the cluster this toolset currently runs on. They will likely need to be modified to match the target cluster's own configuration before it will run correctly there, in the order they are likely to be encountered:

### 1. Spack environment paths

Each application's `SRC/<APP>/input/setup.sh` (or `env.sh`) sources Spack install paths that are hash-pinned to this cluster's own Spack build tree (Intel oneAPI compiler/MPI/MKL, MVAPICH, OpenFOAM, METIS, SCOTCH). These paths will not exist on another system, even with identical package versions installed.

Build or locate the equivalent packages on the target cluster and update each `setup.sh`/`env.sh` accordingly. Running:

```bash
grep -rn 'spack/opt/spack' SRC/
```

against a restored `SRC/` tree locates every occurrence.

### 2. SLURM reservation name and partitions

`workingcpunodes` is the SLURM reservation used on this cluster to scope jobs to healthy nodes; the CPU partition is named `cpu` (with `gpu`, `hm`, and `hpl02` used for other node classes).

These values are centralized in a single location: **`Workflow/Jobsubmission/run-jobsubmission.sh`**, in its CONFIGURATION block at the top of the file (`*_RESERVATION`, `*_PARTITION`, `*_NUM_JOBS`, `BASE_OUTDIR`). `SCRIPTS/diagnose-nodes.sh`'s `DIAGNOSE_RESERVATION` variable (environment-overridable) requires the same update.

### 3. `module load miniconda`

Used in `run-verification.sh` and `diagnose-nodes.sh` to provide Python 3 and matplotlib. Replace with whatever module, virtual environment, or equivalent provides this on the target system.

### 4. `MainDir`

Every script under `Workflow/` exports `MainDir=/home/nsmapplication/cdacapp01/AT-Bench` near the top of the file. Update this to the actual path of the cloned repository.

### 5. Crontab (optional)

`run-jobsubmission.sh` and `run-verification.sh` do not require cron; either can be invoked directly at any time (see [HOW_TO_USE.md](HOW_TO_USE.md)). Cron is only needed if the pipeline should run on a recurring schedule without manual invocation. The crontab itself is not part of this repository and is not transferred by a `git clone`.

An example schedule, once `MainDir` has been set, adjusted to whatever timing is required:

```cron
45 0 * * * LOGDIR="<MainDir>/Workflow/Jobsubmission/cron-job-submission-logs/$(date +\%d\%B\%Y)"; mkdir -p "$LOGDIR"; <MainDir>/Workflow/Jobsubmission/run-jobsubmission.sh >> "$LOGDIR/JobSubmission.log" 2>&1
0 9 * * *  LOGDIR="<MainDir>/Workflow/Verification/cron-job-verification-logs/$(date +\%d\%B\%Y)"; mkdir -p "$LOGDIR"; <MainDir>/Workflow/Verification/run-verification.sh >> "$LOGDIR/Verification.log" 2>&1
```

### 6. `SCRIPTS/fault-detection`

References an older path (`/home/cdacappadmin/OM/...`) and `JobPartition=standard` from a previous environment. It is not part of the current pipeline and should be reviewed before use.
