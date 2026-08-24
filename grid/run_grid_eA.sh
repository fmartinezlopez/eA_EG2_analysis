#!/bin/bash
#
# Grid job: electron-nucleus event generation for the CLAS EG2 comparison.
#
#   gevgen (EM, monoenergetic)  ->  gfilterroi (kinematic ROI)  ->  gntpc (gst)
#
# Only the FILTERED ghep and its gst are copied back; the raw ghep is deleted on
# the worker node.
#
# A provenance file is copied back alongside each output. It records the number
# of events GENERATED, which is not recoverable from a filtered file and is
# required for any absolute normalisation.
#
# This script does NOT source setup.sh: on the worker node the only environment
# is what grid_setup.sh builds plus what jobsub forwarded with -e.  Everything
# below is supplied by launch_job_eA.sh, which reads it from source.sh.
#
# Expected environment (exported by launch_job_eA.sh via jobsub -e):
#   CAMPAIGN     e.g. eA_prod_v1
#   TARGET_PDG   e.g. 1000060120
#   TARGET_NAME  e.g. C12
#   BEAM_E       e.g. 5.014
#   NEVENTS      events per job
#   SEED_BASE    unique per submission; seed = SEED_BASE + PROCESS
#   GTUNE        e.g. G18_10a_00_000
#   GVERSION     e.g. v3_06_02-q2min0p8 (build tag, for bookkeeping)
#   Q2MIN_GEN    Q2 floor compiled into this GENIE build, e.g. 0.80
#   PROBE        PDG code of the beam particle, e.g. 11
#   GLIST        event generator list, e.g. EM
#   ROI_Q2 / ROI_W / ROI_NUMIN / ROI_NUMAX   filter thresholds

echo "=== $(date -u) : running on $(hostname) at ${GLIDEIN_Site} ==="

# ------------------------------------------------------------------ config
MISSING=""
for v in CAMPAIGN TARGET_PDG TARGET_NAME BEAM_E NEVENTS SEED_BASE \
         GTUNE GVERSION Q2MIN_GEN PROBE GLIST \
         ROI_Q2 ROI_W ROI_NUMIN ROI_NUMAX; do
  if [ -z "${!v}" ]; then
    MISSING="${MISSING} ${v}"
  fi
done
if [ -n "${MISSING}" ]; then
  echo "ERROR: required variables not forwarded by jobsub:${MISSING}"
  echo "       launch_job_eA.sh must pass each one with -e."
  exit 1
fi

echo "--- job configuration ---"
for v in CAMPAIGN TARGET_NAME TARGET_PDG BEAM_E NEVENTS SEED_BASE \
         GVERSION GTUNE GLIST PROBE Q2MIN_GEN \
         ROI_Q2 ROI_W ROI_NUMIN ROI_NUMAX; do
  printf '  %-12s = %s\n' "${v}" "${!v}"
done

OUTDIR=/pnfs/uboone/scratch/users/${GRID_USER}/${CAMPAIGN}/${TARGET_NAME}
echo "Output directory set to ${OUTDIR}"

pwd
ls -l $CONDOR_DIR_INPUT

cd ${_CONDOR_JOB_IWD}

if [ -e ${INPUT_TAR_DIR_LOCAL}/grid_setup.sh ]; then
    . ${INPUT_TAR_DIR_LOCAL}/grid_setup.sh
else
  echo "Error, setup script not found. Exiting."
  exit 1
fi

export IFDH_CP_MAXRETRIES=2
export XRD_CONNECTIONRETRY=32
export XRD_REQUESTTIMEOUT=14400
export XRD_REDIRECTLIMIT=255
export XRD_LOADBALANCERTTL=7200
export XRD_STREAMTIMEOUT=14400

gfal-stat $OUTDIR
if [ $? -ne 0 ]; then
    ifdh mkdir_p $OUTDIR || { echo "Error creating or checking $OUTDIR"; exit 2; }
fi

# Seed must be unique across the WHOLE campaign, not just within one submission.
SEED=$(( SEED_BASE + PROCESS ))
echo "Random seed set to ${SEED} (base ${SEED_BASE} + process ${PROCESS})"

SPLINES=${INPUT_TAR_DIR_LOCAL}/${PROBE}_ALL_${GLIST}_${GVERSION}_${GTUNE}.xml
if [ ! -f "${SPLINES}" ]; then
  echo "Spline file not found: ${SPLINES}"
  ls -l ${INPUT_TAR_DIR_LOCAL}
  exit 3
fi

MSGTHR=${GENIE}/config/Messenger_laconic.xml
MSGOPT=""
[ -f "${MSGTHR}" ] && MSGOPT="--message-thresholds ${MSGTHR}"

STEM=${PROBE}_${TARGET_NAME}_${GLIST}_${GVERSION}_${GTUNE}
RAW=${STEM}.raw.ghep.root
FILT=${STEM}.roi.ghep.root
GST=${STEM}.roi.gst.root

# ------------------------------------------------------------------ generate
echo "=== gevgen: ${NEVENTS} events, ${TARGET_NAME}, ${BEAM_E} GeV ==="
gevgen -n ${NEVENTS} -p ${PROBE} -t ${TARGET_PDG} -e ${BEAM_E} \
       --seed ${SEED} -r ${PROCESS} \
       --event-generator-list ${GLIST} \
       --tune ${GTUNE} \
       --cross-sections ${SPLINES} \
       ${MSGOPT} \
       -o ${RAW}
RC=$?
if [ $RC -ne 0 ]; then
    echo "gevgen exited with abnormal status $RC"; exit $RC
fi
if [ ! -s "${RAW}" ]; then
    echo "gevgen returned 0 but produced no output. Directory:"; ls -l
    exit 4
fi
RAW_BYTES=$(stat -c%s "${RAW}")
echo "raw ghep: ${RAW_BYTES} bytes"

# ------------------------------------------------------------------ filter
echo "=== gfilterroi: Q2>${ROI_Q2}, W>${ROI_W}, ${ROI_NUMIN}<nu<${ROI_NUMAX} ==="
gfilterroi -i "${RAW}" -o "${FILT}" \
           --min-Q2 ${ROI_Q2} --min-W ${ROI_W} \
           --min-nu ${ROI_NUMIN} --max-nu ${ROI_NUMAX} \
           ${MSGOPT} 2>&1 | tee filter.log
RC=${PIPESTATUS[0]}
if [ $RC -ne 0 ]; then
    echo "gfilterroi exited with abnormal status $RC"; exit $RC
fi
if [ ! -s "${FILT}" ]; then
    echo "gfilterroi produced no output."; exit 5
fi

N_SCANNED=$(grep -m1 'events scanned' filter.log | awk -F: '{print $NF}' | tr -d ' ')
N_KEPT=$(grep -m1 'events kept'    filter.log | awk -F: '{print $NF}' | awk '{print $1}')
echo "scanned=${N_SCANNED} kept=${N_KEPT}"

# ------------------------------------------------------------------ convert
echo "=== gntpc on the FILTERED file ==="
gntpc -f gst -i "${FILT}" -o "${GST}" --tune ${GTUNE} ${MSGOPT}
RC=$?
if [ $RC -ne 0 ]; then
    echo "gntpc exited with abnormal status $RC"; exit $RC
fi
if [ ! -s "${GST}" ]; then
    echo "gntpc produced no output."; exit 6
fi

# raw file is never copied back
rm -f "${RAW}"

# ------------------------------------------------------------------ provenance
TAG=${CAMPAIGN}_${TARGET_NAME}_${CLUSTER}_${PROCESS}_$(date -u +%Y%m%d)
PROV=${TAG}.provenance.json
cat > ${PROV} <<EOF
{
  "campaign":        "${CAMPAIGN}",
  "cluster":         "${CLUSTER}",
  "process":         "${PROCESS}",
  "site":            "${GLIDEIN_Site}",
  "date_utc":        "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "genie_version":   "${GVERSION}",
  "tune":            "${GTUNE}",
  "generator_list":  "${GLIST}",
  "q2min_generated": ${Q2MIN_GEN},
  "probe":           ${PROBE},
  "target_pdg":      ${TARGET_PDG},
  "target_name":     "${TARGET_NAME}",
  "beam_energy_gev": ${BEAM_E},
  "seed":            ${SEED},
  "run_number":      ${PROCESS},
  "n_requested":     ${NEVENTS},
  "n_generated":     ${N_SCANNED:-null},
  "n_kept":          ${N_KEPT:-null},
  "raw_bytes":       ${RAW_BYTES},
  "roi": { "min_Q2": ${ROI_Q2}, "min_W": ${ROI_W},
           "min_nu": ${ROI_NUMIN}, "max_nu": ${ROI_NUMAX} }
}
EOF
echo "--- provenance ---"; cat ${PROV}

# ------------------------------------------------------------------ copyback
OUT_FILT=${TAG}.roi.ghep.root
OUT_GST=${TAG}.roi.gst.root
mv "${FILT}" "${OUT_FILT}"
mv "${GST}"  "${OUT_GST}"

# Copy each file separately and check each one.
FAIL=0
for f in "${OUT_FILT}" "${OUT_GST}" "${PROV}"; do
    echo "copying ${f} -> ${OUTDIR}"
    ifdh cp -D "${f}" "${OUTDIR}"
    if [ $? -ne 0 ]; then
        echo "ERROR: copyback failed for ${f}"
        FAIL=1
    fi
done
if [ $FAIL -ne 0 ]; then
    echo "One or more copybacks failed."
    exit 7
fi

echo "Completed successfully."
exit 0