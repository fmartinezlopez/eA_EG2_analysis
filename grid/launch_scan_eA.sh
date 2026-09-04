#!/bin/bash
#
# Submit the 1D-scan replay jobs for one target.
#
#   ./launch_scan_grid.sh C12 --param fz-ct0pion --values 0.1,0.2,0.342,0.6,1.0
#   ./launch_scan_grid.sh D2  --param fz-ct0pion --values 0.1,0.2,0.342 --dry-run
#
# ONE JOB = ONE INPUT FILE x ALL PARAMETER VALUES.
#
# -N therefore comes from the file list, via ea_filelist_count.
#
# Every parameter point reuses the SAME seed so the scan is paired.
#
# CONFIG: everything comes from ../setup.sh.

set -euo pipefail

TARGET_NAME="${1:-}"; shift || true
PARAM=""; VALUES=""; DRYRUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --param)   PARAM="$2";  shift 2 ;;
    --values)  VALUES="$2"; shift 2 ;;
    --dry-run) DRYRUN=1;    shift ;;
    *) echo "unknown argument: $1"; exit 1 ;;
  esac
done

# ------------------------------------------------------------------ config
EA_QUIET=1
# shellcheck disable=SC1091
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup.sh"

if [ -z "${TARGET_NAME}" ] || [ -z "${PARAM}" ] || [ -z "${VALUES}" ]; then
  echo "usage: $0 <$(echo ${EA_TARGETS} | tr ' ' '|')> --param P --values V1,V2,... [--dry-run]"
  echo "  P is a gfsireplay flag without dashes:"
  echo "     fz-ct0pion  fz-ct0nucleon  fz-kpt2  fsi-config"
  exit 1
fi

ea_require_profile || exit 1

case "${PARAM}" in
  fz-ct0pion|fz-ct0nucleon|fz-kpt2|fsi-config) ;;
  *) echo "unsupported --param '${PARAM}'"; exit 1 ;;
esac

TARGET_LAB="$(ea_target_label "${TARGET_NAME}")" || {
  echo "unknown target ${TARGET_NAME} (known: ${EA_TARGETS})"; exit 1; }

NJOBS="$(ea_filelist_count "${TARGET_NAME}")" || {
  echo "missing or empty $(ea_filelist_path "${TARGET_NAME}")"; exit 1; }

NVAL=$(awk -F, '{print NF}' <<< "${VALUES}")

# Exported for the payload.
export CAMPAIGN="${CAMPAIGN:-${EA_SCAN_CAMPAIGN}}"
export PARAM VALUES TARGET_LAB
export TARGET_DIR="${TARGET_NAME}"
export FILELIST="$(ea_filelist_file "${TARGET_NAME}")"
export GTUNE STAGE
export SEED="${SCAN_SEED}"
export FZ_CT0NUC FZ_KPT2

# grid_setup.sh picks the product list from these.
export EA_EXPERIMENT EA_CVMFS_SETUP
if [ -z "${EA_EXPERIMENT:-}" ] || [ -z "${EA_CVMFS_SETUP:-}" ]; then
  echo "ERROR: EA_EXPERIMENT / EA_CVMFS_SETUP are not set by setup.sh."
  echo "       The worker would fall back to uboone regardless of the profile."
  exit 1
fi

LIFETIME="${LIFETIME:-$(ea_scan_lifetime "${TARGET_NAME}" "${NVAL}")}"
MEM="${MEM:-$(ea_target_memory "${TARGET_NAME}")}"
# Only one staged input plus a transient ghep/gst per value.
DISK="${DISK:-4GB}"
ESTMIN="$(ea_scan_minutes "${TARGET_NAME}" "${NVAL}")"

TARBALL="${EA_SCAN_TARBALL}"
RUNSCRIPT="${EA_SCAN_RUNSCRIPT}"

echo "=============================================================="
echo " experiment : ${EA_EXPERIMENT}   (${EA_CVMFS_SETUP})"
echo " campaign   : ${CAMPAIGN}$([ "${CAMPAIGN}" = "${EA_SCAN_CAMPAIGN}" ] || echo "   <-- not the default scan campaign")"
echo " target     : ${TARGET_NAME} -> EG2Analysis label ${TARGET_LAB}"
echo " parameter  : --${PARAM}"
echo " values     : ${VALUES}   (${NVAL} points)"
echo " held fixed : ct0nucleon ${FZ_CT0NUC}, KPt2 ${FZ_KPT2}, stage ${STAGE}"
echo " seed       : ${SEED}   (same at every point -- the scan is paired)"
echo " jobs       : ${NJOBS}   (one per file in ${FILELIST})"
echo " est/job    : ~${ESTMIN} min  ->  lifetime ${LIFETIME}"
echo " resources  : ${MEM}, ${DISK}"
echo " outputs    : ${EA_SCRATCH}/\${GRID_USER}/${CAMPAIGN}/${TARGET_NAME}/${PARAM}_<value>/"
echo "=============================================================="

if [ "${DRYRUN}" = 1 ]; then
  echo "(dry run: nothing submitted)"
  echo
  echo "first 3 inputs:"
  grep -v '^[[:space:]]*\(#.*\)\?$' "$(ea_filelist_path "${TARGET_NAME}")" \
    | head -3 | sed 's/^/  /'
  exit 0
fi

for f in "${TARBALL}" "${RUNSCRIPT}"; do
  [ -f "${f}" ] || { echo "missing ${f}"; exit 1; }
done
command -v jobsub_submit >/dev/null || {
  echo "jobsub_submit not on PATH (setup jobsub_client)"; exit 1; }

SUBLOG=$(mktemp)
set +e
jobsub_submit -G "${EA_GROUP}" ${EA_ROLE:+--role="${EA_ROLE}"} -N "${NJOBS}" \
  --memory="${MEM}" --disk="${DISK}" --expected-lifetime="${LIFETIME}" --cpu=1 \
  --resource-provides=usage_model="${EA_USAGE_MODEL}" \
  --tar_file_name=dropbox://"${TARBALL}" \
  -l "+SingularityImage=\"${EA_SINGULARITY_IMAGE}\"" \
  --append_condor_requirements="${EA_CONDOR_REQS}" \
  -e GFAL_PLUGIN_DIR=/usr/lib64/gfal2-plugins \
  -e GFAL_CONFIG_DIR=/etc/gfal2.d \
  -e UPS_OVERRIDE="-H Linux64bit+3.10-2.17" \
  -e EA_EXPERIMENT -e EA_CVMFS_SETUP \
  -e CAMPAIGN -e PARAM -e VALUES -e TARGET_DIR -e TARGET_LAB -e FILELIST \
  -e GTUNE -e STAGE -e SEED -e FZ_CT0NUC -e FZ_KPT2 \
  file://"${RUNSCRIPT}" 2>&1 | tee "${SUBLOG}"
RC=${PIPESTATUS[0]}
set -e

if [ "${RC}" -ne 0 ]; then
  echo
  echo "=============================================================="
  echo " SUBMISSION FAILED (exit ${RC}). Nothing logged."
  echo "=============================================================="
  rm -f "${SUBLOG}"
  exit "${RC}"
fi

CLUSTER=$(grep -oE '[0-9]+\.[0-9]+@[^ ]+' "${SUBLOG}" | head -1)
rm -f "${SUBLOG}"

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CAMPAIGN}" "${TARGET_NAME}" \
  "${CLUSTER:-unknown}" "${PARAM}" "${VALUES}" "${NJOBS}" "${SEED}" \
  >> "${EA_SCAN_LEDGER}"
echo
echo "logged to ${EA_SCAN_LEDGER}"