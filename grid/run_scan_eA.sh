#!/bin/bash
#
# Grid job for a parameter scan.
#
#   one input file  x  ALL parameter values  ->  counts CSVs
#
# Only counts CSVs come back, a few hundred kB per value. The ghep and gst are
# deleted on the node.
#
# The merge is exact: EG2Analysis writes raw sums (N_e, S1, S2, N, N_raw), so
# adding the per-file outputs reproduces a single pass over everything.
#
# Expected environment (via jobsub -e):
#   CAMPAIGN     e.g. scan_ct0pion_v1
#   PARAM        gfsireplay flag without dashes, e.g. fz-ct0pion
#   VALUES       comma-separated, e.g. 0.1,0.2,0.342,0.6,1.0
#   TARGET_DIR   D2 | C12 | Fe56 | Pb208      (input subdirectory)
#   TARGET_LAB   D  | C   | Fe   | Pb         (EG2Analysis label, MUST match
#                                              the `target` column in the CSVs)
#   FILELIST     name of the per-target list inside the tarball
#   GTUNE, STAGE, SEED
#   FZ_CT0NUC, FZ_KPT2   held fixed while PARAM is scanned

echo "=== $(date -u) : $(hostname) at ${GLIDEIN_Site} ==="

: "${CAMPAIGN:=scan_v1}"
: "${PARAM:=fz-ct0pion}"
: "${VALUES:=0.342}"
: "${TARGET_DIR:=C12}"
: "${TARGET_LAB:=C}"
: "${FILELIST:=${TARGET_DIR}.txt}"
: "${GTUNE:=G18_10a_00_000}"
: "${STAGE:=fsi}"
: "${SEED:=101}"
: "${FZ_CT0NUC:=2.300}"
: "${FZ_KPT2:=0.0}"

OUTDIR=/pnfs/dune/scratch/users/${GRID_USER}/${CAMPAIGN}/${TARGET_DIR}
echo "Output -> ${OUTDIR}"

cd ${_CONDOR_JOB_IWD}
if [ -e ${INPUT_TAR_DIR_LOCAL}/grid_setup.sh ]; then
    . ${INPUT_TAR_DIR_LOCAL}/grid_setup.sh
else
  echo "setup script not found"; exit 1
fi

export IFDH_CP_MAXRETRIES=2
export XRD_CONNECTIONRETRY=32
export XRD_REQUESTTIMEOUT=14400
export XRD_STREAMTIMEOUT=14400

gfal-stat $OUTDIR >/dev/null 2>&1 || ifdh mkdir_p $OUTDIR || {
  echo "cannot create ${OUTDIR}"; exit 2; }

# ---- pick this job's input file: line PROCESS+1 of the list -----------------
LIST=${INPUT_TAR_DIR_LOCAL}/${FILELIST}
[ -f "${LIST}" ] || { echo "no file list ${LIST}"; ls -l ${INPUT_TAR_DIR_LOCAL}; exit 3; }
NLINES=$(grep -vc '^\s*\(#.*\)\?$' "${LIST}")
IDX=$(( PROCESS + 1 ))
if [ "${IDX}" -gt "${NLINES}" ]; then
  echo "PROCESS ${PROCESS} beyond the ${NLINES} files in ${FILELIST} -- nothing to do"
  exit 0
fi
SRC=$(grep -v '^\s*\(#.*\)\?$' "${LIST}" | sed -n "${IDX}p")
echo "input [${IDX}/${NLINES}]: ${SRC}"

# ---- stage it locally once --------------------------------------------------
LOCAL=input.ghep.root
ifdh cp "${SRC}" "${LOCAL}" || { echo "stage-in failed"; exit 4; }
ls -lh "${LOCAL}"

DATADIR=${INPUT_TAR_DIR_LOCAL}/data
[ -d "${DATADIR}" ] || { echo "no data tables at ${DATADIR}"; exit 5; }

if [ -x "${INPUT_TAR_DIR_LOCAL}/eg2analysis" ]; then
  ANA="${INPUT_TAR_DIR_LOCAL}/eg2analysis"
else
  echo "no eg2analysis binary in the tarball -- build it before make_tarball"; exit 6
fi

STEM=${CAMPAIGN}_${TARGET_DIR}_${CLUSTER}_${PROCESS}
NCOPIED=0

IFS=',' read -r -a VALS <<< "${VALUES}"
for V in "${VALS[@]}"; do
  TAG=$(echo "$V" | tr '.' 'p' | tr -cd '[:alnum:]p_-')
  echo "--- ${PARAM} = ${V} ---"

  t0=$(date +%s)
  if [ "${PARAM}" = "fsi-config" ]; then
    gfsireplay -i "${LOCAL}" -o rep.ghep.root --tune "${GTUNE}" --seed "${SEED}" \
               --fsi-config "${V}" > replay_${TAG}.log 2>&1
  else
    gfsireplay -i "${LOCAL}" -o rep.ghep.root --tune "${GTUNE}" --seed "${SEED}" \
               --"${PARAM}" "${V}" \
               --fz-ct0nucleon "${FZ_CT0NUC}" --fz-kpt2 "${FZ_KPT2}" \
               > replay_${TAG}.log 2>&1
  fi
  RC=$?
  if [ $RC -ne 0 ] || [ ! -s rep.ghep.root ]; then
    echo "gfsireplay failed (rc=$RC) at ${V}"; tail -20 replay_${TAG}.log; exit 7
  fi

  gntpc -f gst -i rep.ghep.root -o rep.gst.root --tune "${GTUNE}" \
        >> replay_${TAG}.log 2>&1
  [ -s rep.gst.root ] || { echo "gntpc produced nothing at ${V}"; exit 8; }
  rm -f rep.ghep.root

  "${ANA}" rep.gst.root "${TARGET_LAB}" "${STAGE}" -1 "${DATADIR}" . \
      > counts_${TAG}.log 2>&1
  rm -f rep.gst.root

  # EG2Analysis writes fixed names; tag them so the merge can glob per value
  for K in mult corr; do
    SRCF=counts_${K}_${TARGET_LAB}_${STAGE}.csv
    if [ ! -s "${SRCF}" ]; then
      echo "no ${SRCF} at ${V}"; tail -20 counts_${TAG}.log; exit 9
    fi
    DSTF=counts_${K}_${TARGET_LAB}_${STAGE}_${STEM}.csv
    mv "${SRCF}" "${DSTF}"
    ifdh mkdir_p "${OUTDIR}/${PARAM}_${TAG}" >/dev/null 2>&1
    ifdh cp -D "${DSTF}" "${OUTDIR}/${PARAM}_${TAG}" || {
      echo "copyback failed for ${DSTF}"; exit 10; }
    rm -f "${DSTF}"
    NCOPIED=$((NCOPIED+1))
  done
  t1=$(date +%s)
  echo "    done in $((t1-t0))s"
done

rm -f "${LOCAL}"
echo "Completed: ${NCOPIED} counts files for ${#VALS[@]} parameter value(s)."
exit 0