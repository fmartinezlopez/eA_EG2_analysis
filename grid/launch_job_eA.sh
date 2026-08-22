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

set -euo pipefail

TARGET_NAME="${1:-}"
NJOBS="${2:-100}"
DRYRUN="${3:-}"

if [ -z "${TARGET_NAME}" ]; then
  echo "usage: $0 <D2|C12|Fe56|Pb208> <njobs> [--dry-run]"; exit 1
fi

# ------------------------------------------------------------------ campaign
# Overridable so a machinery test cannot land in the production directory:
#   CAMPAIGN=eA_test ./launch_job_eA.sh C12 2
: "${CAMPAIGN:=eA_prod_v1}"
export CAMPAIGN
export GVERSION="v3_06_02-q2min0p8"      # must match the tarball's GENIE build
export GTUNE="G18_10a_00_000"
export GLIST="EM"
export PROBE="11"
export BEAM_E="5.014"
export Q2MIN_GEN="0.8"

export ROI_Q2="0.9"
export ROI_W="1.9"
export ROI_NUMIN="2.2"
export ROI_NUMAX="4.3"

# Overridable for test runs:  NEVENTS=50000 CAMPAIGN=... ./launch_job_eA.sh C12 2
: "${NEVENTS:=500000}"
export NEVENTS

GRIDDIR=/exp/uboone/app/users/fmlopez/generators/eA_EG2_analysis/grid
TARBALL=${GRIDDIR}/ProdBooNE.tar.gz
RUNSCRIPT=${GRIDDIR}/run_grid_eA.sh
SEEDFILE=${GRIDDIR}/.seed_counter
SEEDLOG=${GRIDDIR}/seed_ledger.txt

# Defaults are sized for NEVENTS=500000. Heavier nuclei cascade more, so they
# get longer lifetimes; Pb is roughly 3x slower per event than C.
case "${TARGET_NAME}" in
  D2)    export TARGET_PDG=1000010020; DEF_LIFE="2h";  DEF_MEM="2500MB" ;;
  C12)   export TARGET_PDG=1000060120; DEF_LIFE="2h";  DEF_MEM="2500MB" ;;
  Fe56)  export TARGET_PDG=1000260560; DEF_LIFE="3h";  DEF_MEM="3000MB" ;;
  Pb208) export TARGET_PDG=1000822080; DEF_LIFE="4h"; DEF_MEM="3500MB" ;;
  *) echo "unknown target ${TARGET_NAME}"; exit 1 ;;
esac
export TARGET_NAME
LIFETIME="${LIFETIME:-${DEF_LIFE}}"
MEM="${MEM:-${DEF_MEM}}"

# Disk: the raw ghep dominates and is only deleted at the end of the job, so the
# worker needs raw + filtered + gst simultaneously, plus the unpacked tarball
# (~0.5-0.9 GB).
# Scales with NEVENTS; ~3 kB/event raw is the pessimistic case.
#   50k  -> ~1.2 GB peak   -> 3GB
#   500k -> ~2.8 GB peak   -> 6GB
if [ "${NEVENTS}" -le 100000 ]; then
  DEF_DISK="3GB"
else
  DEF_DISK="4GB"
fi
DISK="${DISK:-${DEF_DISK}}"

# ------------------------------------------------------------------ seeds
[ -f "${SEEDFILE}" ] || echo 1000000 > "${SEEDFILE}"
SEED_BASE=$(cat "${SEEDFILE}")
NEXT=$(( SEED_BASE + NJOBS + 1000 ))     # gap so overlapping ranges cannot overlap
export SEED_BASE
# NOTE: the counter is written only after a successful submission (below).
# Advancing it first burns the range whenever submission fails.

BANNER=""
if [ "${CAMPAIGN}" != "eA_prod_v1" ]; then
  BANNER="   <-- NOT the production campaign"
fi
echo "=============================================================="
echo " campaign   : ${CAMPAIGN}${BANNER}"
echo " target     : ${TARGET_NAME} (${TARGET_PDG})"
echo " jobs       : ${NJOBS} x ${NEVENTS} events = $(( NJOBS * NEVENTS )) total"
echo " seeds      : ${SEED_BASE} .. $(( SEED_BASE + NJOBS - 1 ))"
echo " build      : ${GVERSION}  tune ${GTUNE}  Q2min ${Q2MIN_GEN}"
echo " resources  : ${MEM}, ${DISK}, ${LIFETIME}"
echo "=============================================================="

if [ "${DRYRUN}" = "--dry-run" ]; then
  echo "(dry run: nothing submitted, seed counter NOT advanced)"
  exit 0
fi

for f in "${TARBALL}" "${RUNSCRIPT}"; do
  [ -f "${f}" ] || { echo "missing: ${f}"; exit 1; }
done

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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CAMPAIGN}" "${TARGET_NAME}" \
    "${CLUSTER:-unknown}" "${SEED_BASE}" "$(( SEED_BASE + NJOBS - 1 ))" "${NEVENTS}"
} >> "${SEEDLOG}"

echo "seed range logged to ${SEEDLOG}"