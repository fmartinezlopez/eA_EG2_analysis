#!/bin/bash
#
# Build the grid tarball for the eA production.
#
#   ./make_tarball_eA.sh
#
# Validates BEFORE tarring that the things the grid job needs are actually
# present and consistent: the gfilterroi binary, the Q2 constant compiled into
# this build, and a spline file whose name matches the GVERSION/GTUNE the
# launcher will ask for.
#
# Also writes a MANIFEST recording the git state of the GENIE fork. The rsync
# excludes hidden files (so .git is dropped), which means the tarball otherwise
# carries no record of which commit built it.

set -euo pipefail

# ------------------------------------------------------------------ config
GENIE_TOP=/exp/uboone/app/users/fmlopez/generators/genie
GRIDDIR=/exp/uboone/app/users/fmlopez/generators/eA_EG2_analysis/grid
SETUP=${GRIDDIR}/grid_setup.sh
SPLINEDIR=/exp/uboone/app/users/fmlopez/generators/eA_EG2_analysis/input

# MUST match launch_job_eA.sh exactly, character for character
GVERSION="v3_06_02-q2min0p8"
GTUNE="G18_10a_00_000"
GLIST="EM"
PROBE="11"
EXPECT_Q2MIN="0.80"

SPLINE=${SPLINEDIR}/${PROBE}_ALL_${GLIST}_${GVERSION}_${GTUNE}.xml
OUT=${GRIDDIR}/ProdBooNE.tar.gz

GEN=${GENIE_TOP}/Generator

echo "=============================================================="
echo " GENIE tree : ${GEN}"
echo " version tag: ${GVERSION}"
echo " tune       : ${GTUNE}"
echo "=============================================================="
echo

# ------------------------------------------------------------ pre-flight
fail=0

for b in gevgen gntpc gfilterroi gmkspl; do
  if [ -x "${GEN}/bin/${b}" ]; then
    echo "  OK   bin/${b}"
  else
    echo "  MISS bin/${b}   <-- build it before tarring"
    fail=1
  fi
done

# The Q2 floor is a compile-time constant. If the source does not carry the
# value the launcher advertises, the splines and events disagree with the
# provenance record and nothing downstream is trustworthy.
KU=${GEN}/src/Framework/Utils/KineUtils.h
if [ -f "${KU}" ]; then
  got=$(grep -oE 'kMinQ2Limit[^;]*=[^;]*' "${KU}" | head -1 | grep -oE '[0-9]+\.?[0-9]*' | tail -1 || true)
  # compare numerically: '0.80' and '0.8' are the same number
  same=$(awk -v a="${got:-nan}" -v b="${EXPECT_Q2MIN}" \
           'BEGIN{ if (a+0==b+0 && a!="nan") print "yes"; else print "no" }')
  if [ "${same}" = "yes" ]; then
    echo "  OK   electromagnetic::kMinQ2Limit = ${got}"
  else
    echo "  WARN KineUtils.h reports '${got}', expected '${EXPECT_Q2MIN}'"
    echo "       Check by hand; the grep is heuristic."
  fi
else
  echo "  WARN ${KU} not found, cannot verify Q2 floor"
fi

if [ -s "${SPLINE}" ]; then
  echo "  OK   splines $(basename "${SPLINE}") ($(du -h "${SPLINE}" | cut -f1))"
else
  echo "  MISS ${SPLINE}"
  echo "       Available in ${SPLINEDIR}:"
  ls -1 "${SPLINEDIR}"/*.xml 2>/dev/null | sed 's/^/         /' || echo "         (none)"
  echo "       The name must match GVERSION and GTUNE exactly."
  fail=1
fi

[ -f "${SETUP}" ] && echo "  OK   ${SETUP}" || { echo "  MISS ${SETUP}"; fail=1; }

# the job sources ${INPUT_TAR_DIR_LOCAL}/grid_setup.sh by that exact name
[ "$(basename "${SETUP}")" = "grid_setup.sh" ] || {
  echo "  ERR  setup script must be named grid_setup.sh (job sources it by name)"
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

rm -rf tar_state && mkdir tar_state

cat > tar_state/MANIFEST <<EOF
built_utc        : $(date -u +%Y-%m-%dT%H:%M:%SZ)
built_by         : $(whoami)@$(hostname)
genie_tree       : ${GEN}
git_describe     : ${GITDESC}${GITDIRTY}
git_sha          : ${GITSHA}
version_tag      : ${GVERSION}
tune             : ${GTUNE}
generator_list   : ${GLIST}
q2min_compiled   : ${EXPECT_Q2MIN}
spline_file      : $(basename "${SPLINE}")
spline_md5       : $(md5sum "${SPLINE}" | cut -d' ' -f1)
EOF

echo "--- MANIFEST ---"; cat tar_state/MANIFEST; echo

if [ -n "${GITDIRTY}" ]; then
  echo "WARNING: the GENIE fork has uncommitted changes. The tarball will not be"
  echo "         reproducible from git. Commit before a production run."
  echo
fi

# ------------------------------------------------------------ assemble
echo "copying GENIE tree (this takes a few minutes)..."
rsync -a --exclude=".*" "${GENIE_TOP}" ./tar_state

cp "${SETUP}"  ./tar_state/
cp "${SPLINE}" ./tar_state/

# any extra files passed on the command line
for var in "$@"; do
  cp "$(realpath "$var")" ./tar_state/
  echo "  + $(basename "$var")"
done

echo "creating ${OUT} ..."
( cd tar_state && tar -zcf ProdBooNE.tar.gz ./* )
mv tar_state/ProdBooNE.tar.gz "${OUT}"

echo
echo "=============================================================="
echo " tarball : ${OUT}"
echo " size    : $(du -h "${OUT}" | cut -f1)"
echo " top-level contents:"
tar -tzf "${OUT}" | awk -F/ '{print $2}' | sort -u | head -20 | sed 's/^/   /'
echo "=============================================================="
echo
echo "Files the grid job expects at \$INPUT_TAR_DIR_LOCAL:"
LIST=$(mktemp)
tar -tzf "${OUT}" > "${LIST}"
missing=0
for f in grid_setup.sh "$(basename "${SPLINE}")" MANIFEST; do
  if grep -qx "\./${f}" "${LIST}"; then
    echo "   OK   ${f}"
  else
    echo "   MISS ${f}  <-- job will fail"
    missing=1
  fi
done
rm -f "${LIST}"

rm -rf tar_state

if [ "${missing:-0}" -ne 0 ]; then
  echo
  echo "ERROR: tarball is missing a file the grid job opens by name."
  exit 1
fi