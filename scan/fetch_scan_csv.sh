#!/usr/bin/env bash
#
# Copy the scan counts CSVs off dCache scratch onto disk.
#
#   SRC=/path/to/scratch/data \
#   DST=/path/to/disk/data ./fetch_scan_csv.sh
#
#   ... ./fetch_scan_csv.sh C12       # one target
#   DRYRUN=1 ... ./fetch_scan_csv.sh  # list without copying
#
# Mirrors  <SRC>/<TARGET>/<param>_<value>/*.csv
#     to   <DST>/<TARGET>/<param>_<value>/*.csv
#
# Target directories already exist; the per-value subdirectories are created as
# they are found, so this works whatever parameter and values are scanned.

set -euo pipefail

if [ -z "${SRC:-}" ] || [ -z "${DST:-}" ]; then
  echo "SRC and DST must both be set."
  echo "  SRC : campaign directory on dCache, holding <TARGET>/<param>_<value>/"
  echo "  DST : local directory, with a subdirectory per target"
  exit 1
fi

TARGETS="${*:-D2 C12 Fe56 Pb208}"
DRYRUN="${DRYRUN:-0}"

command -v ifdh >/dev/null || { echo "ifdh not on PATH (setup ifdhc)"; exit 1; }
[ -d "${DST}" ] || { echo "destination ${DST} does not exist"; exit 1; }

echo "src : ${SRC}"
echo "dst : ${DST}"
echo

total=0; copied=0; skipped=0; failed=0

for T in ${TARGETS}; do
  echo "=== ${T} ==="
  # ifdh ls returns the directory itself plus its contents, one per line
  vdirs=$(ifdh ls "${SRC}/${T}" 1 2>/dev/null \
          | sed 's:/*$::' | grep -v "^${SRC}/${T}$" | grep -v '^$' || true)
  if [ -z "${vdirs}" ]; then
    echo "  no subdirectories under ${SRC}/${T}"
    continue
  fi

  for VD in ${vdirs}; do
    VAL=$(basename "${VD}")
    OUT="${DST}/${T}/${VAL}"
    files=$(ifdh ls "${VD}" 1 2>/dev/null | grep '\.csv$' || true)
    n=$(printf '%s\n' "${files}" | grep -c . || true)
    [ "${n}" -gt 0 ] || { echo "  ${VAL}: no csv"; continue; }

    if [ "${DRYRUN}" = 1 ]; then
      echo "  ${VAL}: ${n} csv -> ${OUT}  (dry run)"
      total=$((total+n))
      continue
    fi

    mkdir -p "${OUT}"
    echo -n "  ${VAL}: ${n} csv -> "
    c=0; s=0; f=0
    while IFS= read -r F; do
      [ -n "${F}" ] || continue
      total=$((total+1))
      B=$(basename "${F}")
      if [ -s "${OUT}/${B}" ]; then s=$((s+1)); continue; fi
      if ifdh cp -D "${F}" "${OUT}" >/dev/null 2>&1; then c=$((c+1)); else
        echo; echo "    FAILED ${B}"; f=$((f+1)); fi
    done <<< "${files}"
    copied=$((copied+c)); skipped=$((skipped+s)); failed=$((failed+f))
    echo "copied ${c}, already had ${s}$([ ${f} -gt 0 ] && echo ", FAILED ${f}")"
  done
done

echo
echo "files seen : ${total}"
echo "copied     : ${copied}"
echo "already had: ${skipped}"
echo "failed     : ${failed}"
[ "${failed}" -eq 0 ] || { echo; echo "Re-run to retry; existing files are skipped."; exit 1; }