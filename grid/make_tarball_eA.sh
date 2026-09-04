#!/bin/bash
#
# Build the grid tarball.
#
#   ./make_tarball_eA.sh [extra files to include...]              # generation
#   MODE=scan ./make_tarball_eA.sh [extra files...]               # replay scan
#
# Two payloads need two tarballs:
#
#   prod  gevgen -> gfilterroi -> gntpc.  Needs the cross-section splines.
#   scan  gfsireplay -> gntpc -> eg2analysis.  Needs no splines, but does need
#         the compiled counts binary, the CLAS tables, and the per-target
#         input lists the jobs index into.
#
# Validates BEFORE tarring that everything the job opens by name is present.
#
# Also writes a MANIFEST recording the git state of the GENIE fork and of this
# repo.
#
# All configuration comes from ../setup.sh. Override per-invocation with
# exported variables, or permanently in config.local.sh:
#
#   export GTUNE=G18_02a_00_000 && ./make_tarball_eA.sh

set -euo pipefail

# ------------------------------------------------------------------ config
EA_QUIET=1
# shellcheck disable=SC1091
. "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/setup.sh"

MODE="${MODE:-prod}"
case "${MODE}" in
  prod|scan) ;;
  *) echo "MODE must be 'prod' or 'scan', not '${MODE}'"; exit 1 ;;
esac

GEN="${EA_GENIE_TOP}/Generator"
SPLINE="$(ea_spline_path)"
SETUP="${EA_GRID_SETUP}"
if [ "${MODE}" = "scan" ]; then
  OUT="${EA_SCAN_TARBALL}"
else
  OUT="${EA_TARBALL}"
fi

echo "=============================================================="
echo " mode       : ${MODE}"
echo " GENIE tree : ${GEN}"
echo " version tag: ${GVERSION}"
echo " tune       : ${GTUNE}"
echo " tarball    : ${OUT}"
echo "=============================================================="
echo

# ------------------------------------------------------------ pre-flight
fail=0

# Checks $GENIE, the four binaries, and ROOT.  Non-fatal here so that the rest
# of the pre-flight still runs and reports everything in one pass.
ea_check_genie || fail=1

# The Q2 floor is a compile-time constant. If the source does not carry the
# value the config advertises, the splines and events disagree with the
# provenance record and nothing downstream is trustworthy.  Heuristic grep, so
# a mismatch warns rather than blocks.
ea_check_q2min || true

if [ "${MODE}" = "scan" ]; then
  # gfsireplay lives only in the fork, so it is the canary for scan mode the
  # way gfilterroi is for production.
  if [ -x "${GEN}/bin/gfsireplay" ]; then
    echo "  OK    bin/gfsireplay"
  else
    echo "  MISS  ${GEN}/bin/gfsireplay"
    echo "        build it: add gfsireplay to \$GENIE/src/Apps/Makefile and make"
    fail=1
  fi
  echo "  --    splines not needed in scan mode"
  ea_check_analysis  || fail=1
  ea_check_filelists || fail=1
else
  if [ -s "${SPLINE}" ]; then
    echo "  OK    splines $(basename "${SPLINE}") ($(du -h "${SPLINE}" | cut -f1))"
  else
    echo "  MISS  ${SPLINE}"
    echo "        Available in ${EA_SPLINEDIR}:"
    ls -1 "${EA_SPLINEDIR}"/*.xml 2>/dev/null | sed 's/^/          /' || echo "          (none)"
    echo "        The name must match GVERSION and GTUNE exactly."
    fail=1
  fi
fi

if [ -f "${SETUP}" ]; then
  echo "  OK    ${SETUP}"
else
  echo "  MISS  ${SETUP}"
  fail=1
fi

# the job sources ${INPUT_TAR_DIR_LOCAL}/grid_setup.sh by that exact name
[ "$(basename "${SETUP}")" = "grid_setup.sh" ] || {
  echo "  ERR   setup script must be named grid_setup.sh (job sources it by name)"
  fail=1; }

if [ "${fail}" -ne 0 ]; then
  echo; echo "pre-flight FAILED - not building tarball."; exit 1
fi
echo; echo "pre-flight passed."; echo

# ------------------------------------------------------------ manifest
GITDESC="unknown"; GITSHA="unknown"; GITDIRTY=""
if [ -d "${GEN}/.git" ]; then
  GITDESC=$(git -C "${GEN}" describe --tags --always --dirty 2>/dev/null || echo unknown)
  GITSHA=$(git -C "${GEN}" rev-parse HEAD 2>/dev/null || echo unknown)
  git -C "${GEN}" diff --quiet 2>/dev/null || GITDIRTY=" (UNCOMMITTED CHANGES PRESENT)"
fi

# The analysis repo's own state matters too: it is what produced this config.
ANADESC="unknown"; ANADIRTY=""
if [ -d "${EA_ROOT}/.git" ]; then
  ANADESC=$(git -C "${EA_ROOT}" describe --tags --always --dirty 2>/dev/null || echo unknown)
  git -C "${EA_ROOT}" diff --quiet 2>/dev/null || ANADIRTY=" (UNCOMMITTED CHANGES PRESENT)"
fi

# Payload-specific provenance: the splines identify a generation tarball, the
# counts binary identifies a scan one.
if [ "${MODE}" = "scan" ]; then
  PAYLOAD_A="eg2analysis_md5  : $(md5sum "${EA_ANALYSIS}/eg2analysis" | cut -d' ' -f1)"
  PAYLOAD_B="clas_tables      : $(echo ${EA_CLAS_CSVS} | wc -w) files from ${EA_DATA}"
  PAYLOAD_C="file_lists       : $(for t in ${EA_TARGETS}; do \
                printf '%s=%s ' "${t}" "$(ea_filelist_count "${t}")"; done)"
else
  PAYLOAD_A="spline_file      : $(basename "${SPLINE}")"
  PAYLOAD_B="spline_md5       : $(md5sum "${SPLINE}" | cut -d' ' -f1)"
  PAYLOAD_C="events_per_job   : ${NEVENTS}"
fi

rm -rf tar_state && mkdir tar_state

cat > tar_state/MANIFEST <<EOF
built_utc        : $(date -u +%Y-%m-%dT%H:%M:%SZ)
built_by         : $(whoami)@$(hostname)
mode             : ${MODE}
genie_tree       : ${GEN}
git_describe     : ${GITDESC}${GITDIRTY}
git_sha          : ${GITSHA}
analysis_repo    : ${EA_ROOT}
analysis_describe: ${ANADESC}${ANADIRTY}
version_tag      : ${GVERSION}
tune             : ${GTUNE}
generator_list   : ${GLIST}
probe            : ${PROBE}
beam_energy_gev  : ${BEAM_E}
q2min_compiled   : ${Q2MIN_GEN}
${PAYLOAD_A}
${PAYLOAD_B}
${PAYLOAD_C}
EOF

echo "--- MANIFEST ---"; cat tar_state/MANIFEST; echo

if [ -n "${GITDIRTY}" ] || [ -n "${ANADIRTY}" ]; then
  echo "WARNING: there are uncommitted changes. The tarball will not be"
  echo "         reproducible from git. Commit before a production run."
  echo
fi

# ------------------------------------------------------------ assemble
echo "copying GENIE tree (this takes a few minutes)..."
rsync -a --exclude=".*" "${EA_GENIE_TOP}" ./tar_state

cp "${SETUP}" ./tar_state/

if [ "${MODE}" = "scan" ]; then
  cp "${EA_ANALYSIS}/eg2analysis" ./tar_state/
  mkdir -p ./tar_state/data
  for _f in ${EA_CLAS_CSVS}; do cp "${EA_DATA}/${_f}" ./tar_state/data/; done
  for _t in ${EA_TARGETS}; do
    cp "${EA_LISTDIR}/$(ea_filelist_file "${_t}")" ./tar_state/
  done
  unset _f _t
  echo "  + eg2analysis, data/ ($(echo ${EA_CLAS_CSVS} | wc -w) tables), file lists for ${EA_TARGETS}"
else
  cp "${SPLINE}" ./tar_state/
fi

# any extra files passed on the command line
for var in "$@"; do
  cp "$(realpath "$var")" ./tar_state/
  echo "  + $(basename "$var")"
done

echo "creating ${OUT} ..."
( cd tar_state && tar -zcf "$(basename "${OUT}")" ./* )
mv "tar_state/$(basename "${OUT}")" "${OUT}"

echo
echo "=============================================================="
echo " tarball : ${OUT}"
echo " size    : $(du -h "${OUT}" | cut -f1)"
echo " top-level contents:"
tar -tzf "${OUT}" | awk -F/ '{print $2}' | sort -u | head -20 | sed 's/^/   /'
echo "=============================================================="
echo

# What the job opens BY NAME. Top level specifically: the payload reads
# ${INPUT_TAR_DIR_LOCAL}/<name>, so a copy in a subdirectory is not a pass.
# The CLAS tables are the exception -- the payload passes data/ as a directory.
if [ "${MODE}" = "scan" ]; then
  EXPECT="grid_setup.sh eg2analysis MANIFEST data"
  for _t in ${EA_TARGETS}; do EXPECT="${EXPECT} $(ea_filelist_file "${_t}")"; done
  unset _t
else
  EXPECT="grid_setup.sh $(basename "${SPLINE}") MANIFEST"
fi

echo "Files the grid job expects at \$INPUT_TAR_DIR_LOCAL:"
missing=0
for f in ${EXPECT}; do
  if ea_tarball_has_toplevel "${OUT}" "${f}"; then
    echo "   OK   ${f}"
  else
    echo "   MISS ${f}  <-- job will fail"
    missing=1
  fi
done

# The four tables live inside data/, so check them separately: an empty data/
# directory would pass the top-level check and then leave EG2Analysis with an
# empty fill grid, which writes zero-row counts that merge without complaint.
if [ "${MODE}" = "scan" ]; then
  ntab=$(tar -tzf "${OUT}" | sed 's#^\./##' | grep -c '^data/clas_eg2_.*\.csv$' || true)
  want=$(echo ${EA_CLAS_CSVS} | wc -w)
  if [ "${ntab}" -eq "${want}" ]; then
    echo "   OK   data/ contains ${ntab} CLAS tables"
  else
    echo "   MISS data/ has ${ntab} tables, expected ${want}"
    missing=1
  fi
fi

rm -rf tar_state

if [ "${missing:-0}" -ne 0 ]; then
  echo
  echo "ERROR: tarball is missing a file the grid job opens by name."
  exit 1
fi