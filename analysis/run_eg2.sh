#!/bin/bash
#
# Full chain: four targets x two FSI stages -> observables -> overlay.
#
#   ./run_eg2.sh /exp/dune/data/users/$USER/eA_samples/v1 [datadir] [outdir]
#
# Expects one subdirectory per target under $1, named D2/C12/Fe56/Pb208, each
# holding *.gst.root files. Adjust DIRS if your layout differs.
#
# Uses the standalone binary if `make` has been run, otherwise falls back to
# ACLiC. The binary is preferable on a worker node: no rootcling, no dictionary,
# no shared library to write into a possibly read-only source directory.
#
# Runs "prefsi" as well as "fsi" every time, and it is not optional: the
# pre-FSI pass is the only thing that tells you whether an A-dependence you see
# is the cascade or the primary vertex (nuclear PDFs, Fermi motion, the neutron
# excess in Pb). A tune fitted without that control is fitting the wrong
# parameters.

set -euo pipefail

PROD="${1:?usage: $0 <production-dir> [datadir] [outdir]}"
DATA="${2:-../data}"
OUT="${3:-out}"

declare -A DIRS=( [D]=D2 [C]=C12 [Fe]=Fe56 [Pb]=Pb208 )

mkdir -p "${OUT}"

for f in clas_eg2_charged_pion_multiplicity_ratios_Moran_PRC105_015201.csv \
         clas_eg2_neutral_pion_multiplicity_ratios_Mineeva_PRC112_035203.csv \
         clas_eg2_dipion_correlations_Paul_PRC111_035201.csv \
         clas_eg2_pion_proton_correlations_Paul_2512_05083.csv; do
  [ -f "${DATA}/${f}" ] || { echo "!! missing ${DATA}/${f}"; exit 1; }
done

run_one () {  # glob target stage
  if [ -x ./eg2analysis ]; then
    ./eg2analysis "$1" "$2" "$3" -1 "${DATA}" "${OUT}"
  else
    root -l -b -q "EG2Analysis.C+(\"$1\",\"$2\",\"$3\",-1,\"${DATA}\",\"${OUT}\")"
  fi
}

for stage in prefsi fsi; do
#  for tgt in D C Fe Pb; do
  for tgt in Pb; do
    glob="${PROD}/${DIRS[$tgt]}/*.gst.root"
    n=$(ls -1 ${glob} 2>/dev/null | wc -l)
    if [ "${n}" -eq 0 ]; then
      echo "!! no gst files at ${glob} -- skipping ${tgt}"
      continue
    fi
    echo "=== ${tgt} (${stage}), ${n} files ==="
    run_one "${glob}" "${tgt}" "${stage}"
  done

  python3 eg2_observables.py --counts "${OUT}" --stage "${stage}" --out "${OUT}"
  python3 eg2_overlay.py --data "${DATA}" --pred "${OUT}" --stage "${stage}" \
                         --out "${OUT}" --plots "plots_${stage}" --match-norm
done
