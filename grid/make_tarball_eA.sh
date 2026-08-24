#!/bin/bash
#
# Build the grid tarball for the eA production.
#
#   ./make_tarball_eA.sh [extra files to include...]
#
# Validates BEFORE tarring that the things the grid job needs are actually
# present and consistent: the gfilterroi binary, the Q2 constant compiled into
# this build, and a spline file whose name matches the GVERSION/GTUNE the
# launcher will ask for.
#
# Also writes a MANIFEST recording the git state of the GENIE fork. The rsync
# excludes hidden files (so .git is dropped), which means the tarball otherwise
# carries no record of which commit built it.
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

GEN="${EA_GENIE_TOP}/Generator"
SPLINE="$(ea_spline_path)"
OUT="${EA_TARBALL}"
SETUP="${EA_GRID_SETUP}"

echo "=============================================================="
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

if [ -s "${SPLINE}" ]; then
  echo "  OK    splines $(basename "${SPLINE}") ($(du -h "${SPLINE}" | cut -f1))"
else
  echo "  MISS  ${SPLINE}"
  echo "        Available in ${EA_SPLINEDIR}:"
  ls -1 "${EA_SPLINEDIR}"/*.xml 2>/dev/null | sed 's/^/          /' || echo "          (none)"
  echo "        The name must match GVERSION and GTUNE exactly."
  fail=1
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

rm -rf tar_state && mkdir tar_state

cat > tar_state/MANIFEST <<EOF
built_utc        : $(date -u +%Y-%m-%dT%H:%M:%SZ)
built_by         : $(whoami)@$(hostname)
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
spline_file      : $(basename "${SPLINE}")
spline_md5       : $(md5sum "${SPLINE}" | cut -d' ' -f1)
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

cp "${SETUP}"  ./tar_state/
cp "${SPLINE}" ./tar_state/

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
echo "Files the grid job expects at \$INPUT_TAR_DIR_LOCAL:"
missing=0
for f in grid_setup.sh "$(basename "${SPLINE}")" MANIFEST; do
  if ea_tarball_has_toplevel "${OUT}" "${f}"; then
    echo "   OK   ${f}"
  else
    echo "   MISS ${f}  <-- job will fail"
    missing=1
  fi
done

rm -rf tar_state

if [ "${missing:-0}" -ne 0 ]; then
  echo
  echo "ERROR: tarball is missing a file the grid job opens by name."
  exit 1
fi