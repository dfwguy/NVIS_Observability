#!/bin/bash
# NVIS Platform jobstats prolog — runs at job start.
# Writes per-job metadata to a shared dir so the slurm_job_exporter can
# correlate live squeue rows with their accounting attributes.
#
# Wire into Slurm by setting in slurm.conf:
#   PrologSlurmctld=/etc/slurm/jobstats_prolog.sh
# See docs/SLURM_INTEGRATION.md.

set -u
cd /tmp || true

JOBINFO_DIR="${NVIS_JOBINFO_DIR:-/cm/shared/apps/slurm/jobinfo}"

mkdir -p "$JOBINFO_DIR" 2>/dev/null || {
    echo "jobstats_prolog: cannot create ${JOBINFO_DIR}" >&2
    exit 0
}

cat > "${JOBINFO_DIR}/job_${SLURM_JOB_ID}" <<JOBEOF
jobid=${SLURM_JOB_ID}
user=${SLURM_JOB_USER:-}
account=${SLURM_JOB_ACCOUNT:-}
nodes=${SLURM_JOB_NODELIST:-}
ncpus=${SLURM_JOB_CPUS_PER_NODE:-}
JOBEOF

chmod 644 "${JOBINFO_DIR}/job_${SLURM_JOB_ID}" 2>/dev/null || true
echo "jobstats_prolog: wrote ${JOBINFO_DIR}/job_${SLURM_JOB_ID}"
exit 0
