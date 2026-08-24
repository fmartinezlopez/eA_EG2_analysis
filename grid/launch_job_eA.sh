#!/bin/bash
#
# Submit one target's worth of eA generation jobs.
#
#   ./launch_job_eA.sh C12 1120
#   ./launch_job_eA.sh Pb208 300 --dry-run
#
# One submission per target: they need different job counts (D2 is the
# statistics-limiting denominator) and different runtimes (Pb cascades are
# several times slower than C), and separate output directories keep the
# bookkeeping clean.
#
# SEEDS: every submission draws a fresh SEED_BASE from a counter file and
# appends to a log. Seeds derived from $PROCESS alone repeat across
# submissions, which silently duplicates events.
#
# CONFIG: everything comes from ../setup.sh -- there is no copy of the
# version tag or tune in this file any more.  For a production run:
#
#   export CAMPAIGN=eA_prod_v1 && ./launch_job_eA.sh C12 1120
#
# The default campaign is the TEST one, so a bare invocation cannot land in the
# production directory by accident.

set -euo pipefail

TARGET_NAME="${1:-}"
NJOBS="${2:-100}"
DRYRUN="${3:-}"

# ------------------------------------------------------------------ config
EA_QUIET=1
# shellcheck disable=SC1091
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/source.sh"

if [ -z "${TARGET_NAME}" ]; then
  echo "usage: $0 <$(echo ${EA_TARGETS} | tr ' ' '|')> <njobs> [--dry-run]"; exit 1
fi

TARGET_PDG="$(ea_target_pdg "${TARGET_NAME}")" || {
  echo "unknown target ${TARGET_NAME} (known: ${EA_TARGETS})"; exit 1; }
export TARGET_NAME TARGET_PDG

# Resources are per-target defaults from source.sh, still overridable ad hoc.
LIFETIME="${LIFETIME:-$(ea_target_lifetime "${TARGET_NAME}")}"
MEM="${MEM:-$(ea_target_memory "${TARGET_NAME}")}"

# Disk: the raw ghep dominates and is only deleted at the end of the job, so the
# worker needs raw + filtered + gst simultaneously, plus the unpacked tarball
# (~0.5-0.9 GB).  Scales with NEVENTS; ~3 kB/event raw is the pessimistic case.
#   50k  -> ~1.2 GB peak   -> 3GB
#   500k -> ~2.8 GB peak   -> 4GB
if [ "${NEVENTS}" -le 100000 ]; then
  DEF_DISK="3GB"
else
  DEF_DISK="4GB"
fi
DISK="${DISK:-${DEF_DISK}}"

TARBALL="${EA_TARBALL}"
RUNSCRIPT="${EA_RUNSCRIPT}"
SEEDFILE="${EA_SEEDFILE}"
SEEDLOG="${EA_SEEDLOG}"

# ------------------------------------------------------------------ seeds
[ -f "${SEEDFILE}" ] || echo 1000000 > "${SEEDFILE}"
SEED_BASE=$(cat "${SEEDFILE}")
NEXT=$(( SEED_BASE + NJOBS + 1000 ))     # gap so overlapping ranges cannot overlap
export SEED_BASE
# NOTE: the counter is written only after a successful submission (below).
# Advancing it first burns the range whenever submission fails.

BANNER=""
if [ "${CAMPAIGN}" != "${EA_PROD_CAMPAIGN}" ]; then
  BANNER="   <-- NOT the production campaign"
fi
echo "=============================================================="
echo " campaign   : ${CAMPAIGN}${BANNER}"
echo " target     : ${TARGET_NAME} (${TARGET_PDG})"
echo " jobs       : ${NJOBS} x ${NEVENTS} events = $(( NJOBS * NEVENTS )) total"
echo " seeds      : ${SEED_BASE} .. $(( SEED_BASE + NJOBS - 1 ))"
echo " build      : ${GVERSION}  tune ${GTUNE}  Q2min ${Q2MIN_GEN}"
echo " ROI        : Q2>${ROI_Q2} W>${ROI_W} ${ROI_NUMIN}<nu<${ROI_NUMAX}"
echo " resources  : ${MEM}, ${DISK}, ${LIFETIME}"
echo " tarball    : ${TARBALL}"
echo "=============================================================="

if [ "${DRYRUN}" = "--dry-run" ]; then
  echo "(dry run: nothing submitted, seed counter NOT advanced)"
  exit 0
fi

for f in "${TARBALL}" "${RUNSCRIPT}"; do
  [ -f "${f}" ] || { echo "missing: ${f}"; exit 1; }
done

# The tarball was built against a specific GVERSION/GTUNE.  If the config has
# moved on since, the job will look for a spline file that is not in there.
if tar -tzf "${TARBALL}" | grep -qx "\./$(ea_spline_file)"; then
  echo "tarball contains the expected spline: $(ea_spline_file)"
else
  echo "ERROR: ${TARBALL} does not contain $(ea_spline_file)"
  echo "       The tarball is stale for this config. Rebuild it:"
  echo "         ${EA_GRID}/make_tarball_eA.sh"
  exit 1
fi

if ! command -v jobsub_submit >/dev/null 2>&1; then
  echo "ERROR: jobsub_submit is not on PATH."
  echo "       Set up the client first, e.g.:  setup jobsub_client"
  exit 1
fi

# ------------------------------------------------------------------ submit
SUBMIT_LOG=$(mktemp)
set +e
jobsub_submit -G uboone -N "${NJOBS}" \
  --memory="${MEM}" --disk="${DISK}" --expected-lifetime="${LIFETIME}" --cpu=1 \
  --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC \
  --tar_file_name=dropbox://"${TARBALL}" \
  -l '+SingularityImage="/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest"' \
  --append_condor_requirements='(TARGET.HAS_Singularity==true&&TARGET.HAS_CVMFS_larsoft_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser1_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser2_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser3_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser4_opensciencegrid_org==true)' \
  -e GFAL_PLUGIN_DIR=/usr/lib64/gfal2-plugins \
  -e GFAL_CONFIG_DIR=/etc/gfal2.d \
  -e UPS_OVERRIDE="-H Linux64bit+3.10-2.17" \
  -e CAMPAIGN -e TARGET_PDG -e TARGET_NAME -e BEAM_E -e NEVENTS \
  -e SEED_BASE -e GTUNE -e GVERSION -e GLIST -e PROBE -e Q2MIN_GEN \
  -e ROI_Q2 -e ROI_W -e ROI_NUMIN -e ROI_NUMAX \
  file://"${RUNSCRIPT}" 2>&1 | tee "${SUBMIT_LOG}"
RC=${PIPESTATUS[0]}
set -e

if [ "${RC}" -ne 0 ]; then
  echo
  echo "=============================================================="
  echo " SUBMISSION FAILED (exit ${RC}). Seed counter NOT advanced;"
  echo " range ${SEED_BASE}..$(( SEED_BASE + NJOBS - 1 )) is still free."
  echo "=============================================================="
  rm -f "${SUBMIT_LOG}"
  exit "${RC}"
fi

# submission succeeded: burn the seed range
echo "${NEXT}" > "${SEEDFILE}"

CLUSTER=$(grep -oE '[0-9]+\.[0-9]+@[^ ]+' "${SUBMIT_LOG}" | head -1)
rm -f "${SUBMIT_LOG}"

# The ledger is the only record tying a seed range to a cluster. Without it,
# a resubmission after a partial failure can silently reuse seeds.
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CAMPAIGN}" "${TARGET_NAME}" \
    "${CLUSTER:-unknown}" "${SEED_BASE}" "$(( SEED_BASE + NJOBS - 1 ))" \
    "${NEVENTS}" "${GVERSION}" "${GTUNE}"
} >> "${SEEDLOG}"

echo "seed range logged to ${SEEDLOG}"