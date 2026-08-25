# How to use AT-Bench

Practical commands for running this. See [README.md](README.md) for layout
and what needs adapting on a different cluster.

`<MainDir>` below means wherever you've cloned this repo.

## 1. The automated nightly pipeline (normal operation)

Once the crontab (see README) is in place, this runs itself:

- **00:45** -- `CRON/Jobsubmission/run-jobsubmission.sh` submits the
  night's GROMACS/NAMD/OpenFOAM/WRF jobs, using the job counts and
  reservation/partition set in its own CONFIGURATION block.
- **09:00** -- `CRON/Verification/run-verification.sh` verifies the
  previous night's results, builds cluster-wide success/slow/failed node
  lists, and runs the debug analyzer.

You don't run either of these by hand day-to-day -- cron does. To trigger
one manually (e.g. to re-run a verification pass, or test a config change):

```bash
<MainDir>/CRON/Jobsubmission/run-jobsubmission.sh
<MainDir>/CRON/Verification/run-verification.sh
```

## 2. Where the output lands

For a given run date `DDMonthYYYY` (e.g. `25August2026`):

```
CRON/Verification/LOGS/<date>/nodes/     success/slow/failed node lists,
                                          per app and combined cluster-wide
                                          (comma-separated -- feed straight
                                          into sbatch --nodelist=/--exclude=)
CRON/Verification/LOGS/<date>/debug/     job_debug_analyzer.py's output:
                                          error_report.txt, job_debug_records.csv,
                                          app_wise_error_breakdown.png
CRON/Verification/LOGS/<date>/diagnose/  diagnose-nodes.sh's output (see #4)
```

## 3. Submitting or verifying a single app by hand

For a one-off run of just one app (skip the full nightly sweep), use the
interactive menus:

```bash
./JobSubmission.sh   # pick 1-4 for NAMD/GROMACS/OPENFOAM/WRF
./atVerify.sh        # pick 1-5 for NAMD/GROMACS/OPENFOAM/WRF/HPL
```

Both hardcode an `OUTDIR` near the top of the script (a leftover from
whichever run I last pointed them at) -- edit that line to the run
directory you actually want before using them.

## 4. Diagnosing suspect nodes (HPL/STREAM/OSU)

After a verification run has produced `nodes/slow-nodes.txt` and
`nodes/failed-nodes.txt` for a given date, run:

```bash
<MainDir>/SCRIPTS/diagnose-nodes.sh                        # today, full candidate list
<MainDir>/SCRIPTS/diagnose-nodes.sh 25August2026            # a specific past date
<MainDir>/SCRIPTS/diagnose-nodes.sh --limit 5                # try it on 5 nodes first
<MainDir>/SCRIPTS/diagnose-nodes.sh --nodes-dir /path/to/nodes  # pick candidates from
                                                                  # elsewhere, e.g. a
                                                                  # backed-up nodes/ dir
<MainDir>/SCRIPTS/diagnose-nodes.sh --timeout 1200            # cap the wait at 20 min
                                                                 # instead of the 40 min
                                                                 # default
```

This filters the slow/failed nodes down to ones plausibly hardware-related
(not nodes only failing because of a known software/config bug), submits
single-node HPL, single-node STREAM, and a reference-node-vs-candidate OSU
job for each, waits for them to finish (or times out and cancels anything
still stuck), and writes `diagnose/report.txt` + `diagnose/records.csv` --
just the nodes that actually missed the expected numbers, with the real
value observed next to the standard it should have hit.

## 5. Extracting node lists from a verification summary by hand

`extract-nodes` is what turns a `verify-results.sh` summary (the
`A.SUCCESSFULL JOBS` / `B.SLOW JOBS` / `C.INCOMPLETE JOBS` sections) into
plain comma-separated node lists. Normally called for you inside each app's
`CRON/Verification/<APP>.sh` wrapper, but you can run it directly against
any summary file:

```bash
<MainDir>/SCRIPTS/extract-nodes /path/to/some-verify-output.txt /path/to/output-dir
```

It writes `<prefix>-success-nodes.txt`, `<prefix>-slow-nodes.txt`,
`<prefix>-failed-nodes.txt` (and a `-by-job` variant of each) into
`output-dir`, prefixed from the input filename.

## 6. Debugging why jobs failed

`job_debug_analyzer.py` classifies *why* a batch of jobs failed (IB
faults, environment errors, timeouts, segfaults, ...) rather than just
counting them. The nightly pipeline already calls this for you in targeted
mode against the night's `failed-jobs.txt`. To run it yourself against an
arbitrary run directory:

```bash
python3 <MainDir>/SCRIPTS/debug/job_debug_analyzer.py --run-dir /path/to/a/run/dir --output-dir /path/to/write/report/to
```
