AT-BENCH: HOW TO USE
=====================

This document lists the commands used to operate AT-Bench. See README for
repository layout and cluster-specific setup.

"<MainDir>" below refers to the directory the repository is cloned into.


1. RUNNING JOB SUBMISSION AND VERIFICATION
---------------------------------------------

The pipeline consists of two scripts, run directly whenever needed:

    <MainDir>/CRON/Jobsubmission/run-jobsubmission.sh
        Submits GROMACS, NAMD, OpenFOAM, and WRF jobs, using the job
        counts and reservation/partition set in its CONFIGURATION block.

    <MainDir>/CRON/Verification/run-verification.sh
        Verifies the results of a completed submission run, builds
        cluster-wide success/slow/failed node lists, and runs the debug
        analyzer.

Neither script requires cron; both can be run directly, at any time, as
shown above. Cron is one option for running them on a recurring
schedule without manual invocation, at whatever interval or times suit
the deployment (an example schedule is given in README).


2. OUTPUT LOCATIONS
---------------------

For a given run date DDMonthYYYY (for example, 25August2026):

  CRON/Verification/LOGS/<date>/nodes/
      Success/slow/failed node lists, per application and combined
      cluster-wide, as plain comma-separated hostnames suitable for
      sbatch --nodelist= or --exclude=.

  CRON/Verification/LOGS/<date>/debug/
      job_debug_analyzer.py output: error_report.txt,
      job_debug_records.csv, app_wise_error_breakdown.png.

  CRON/Verification/LOGS/<date>/diagnose/
      diagnose-nodes.sh output (see section 4).


3. SUBMITTING OR VERIFYING A SINGLE APPLICATION
--------------------------------------------------

To submit or verify a single application outside a full submission or
verification run, use the interactive menus:

    ./JobSubmission.sh     select 1-4 for NAMD, GROMACS, OPENFOAM, WRF
    ./atVerify.sh           select 1-5 for NAMD, GROMACS, OPENFOAM, WRF, HPL

Both scripts set an OUTDIR variable near the top of the file, left
pointing at whichever run directory was last used. This should be
updated to the intended run directory before use.


4. DIAGNOSING SUSPECT NODES (HPL, STREAM, OSU)
--------------------------------------------------

Once a verification run has produced nodes/slow-nodes.txt and
nodes/failed-nodes.txt for a given date, run:

    <MainDir>/SCRIPTS/diagnose-nodes.sh
        Diagnose today's full candidate list.

    <MainDir>/SCRIPTS/diagnose-nodes.sh 25August2026
        Diagnose a specific past date.

    <MainDir>/SCRIPTS/diagnose-nodes.sh --limit 5
        Restrict to the first 5 candidate nodes (useful for a trial run).

    <MainDir>/SCRIPTS/diagnose-nodes.sh --nodes-dir /path/to/nodes
        Select candidates from an alternate nodes/ directory.

    <MainDir>/SCRIPTS/diagnose-nodes.sh --timeout 1200
        Cap the wait for job completion at 20 minutes instead of the
        default 40.

This filters the slow/failed node list down to nodes plausibly related to
a hardware fault (excluding nodes failing only due to a known
software/configuration issue), submits single-node HPL, single-node
STREAM, and a reference-node-versus-candidate OSU job for each, waits for
completion (cancelling and reporting anything still outstanding once the
timeout is reached), and writes diagnose/report.txt and
diagnose/records.csv, listing only the nodes that missed the expected
result, with the observed value alongside the expected standard.


5. EXTRACTING NODE LISTS FROM A VERIFICATION SUMMARY
---------------------------------------------------------

extract-nodes converts a verify-results.sh summary (its A.SUCCESSFULL
JOBS / B.SLOW JOBS / C.INCOMPLETE JOBS sections) into plain
comma-separated node lists. It is invoked automatically from each
application's CRON/Verification/<APP>.sh wrapper, and can also be run
directly against any summary file:

    <MainDir>/SCRIPTS/extract-nodes /path/to/some-verify-output.txt /path/to/output-dir

This writes <prefix>-success-nodes.txt, <prefix>-slow-nodes.txt, and
<prefix>-failed-nodes.txt (plus a -by-job variant of each) into
output-dir, with the prefix derived from the input filename.


6. DIAGNOSING JOB FAILURES
-----------------------------

job_debug_analyzer.py classifies why a batch of jobs failed (IB faults,
environment errors, timeouts, segfaults, and so on) rather than simply
counting failures. run-verification.sh invokes this automatically in
targeted mode against that run's failed-jobs.txt. To run it directly
against an arbitrary run directory:

    python3 <MainDir>/SCRIPTS/debug/job_debug_analyzer.py --run-dir /path/to/a/run/dir --output-dir /path/to/write/report/to
