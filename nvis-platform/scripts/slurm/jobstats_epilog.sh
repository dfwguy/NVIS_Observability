#!/bin/bash
# NVIS Platform jobstats epilog — runs at job end.
# Removes per-job metadata file written by jobstats_prolog.sh.
#
# Wire into Slurm by setting in slurm.conf:
#   EpilogSlurmctld=/etc/slurm/jobstats_epilog.sh
# See docs/SLURM_INTEGRATION.md.

set -u
cd /tmp || true

JOBINFO_DIR="${NVIS_JOBINFO_DIR:-/cm/shared/apps/slurm/jobinfo}"

rm -f "${JOBINFO_DIR}/job_${SLURM_JOB_ID}" 2>/dev/null || true
echo "jobstats_epilog: removed job_${SLURM_JOB_ID}"
exit 0
