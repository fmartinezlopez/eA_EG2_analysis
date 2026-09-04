#!/bin/bash
#
# Environment for the eA-vA EG2 analysis.  SOURCE this, do not execute it:
#
#     source setup.sh
#
# It sets:
#   - repository paths, derived from the location of this file.
#   - the physics configuration -- version tag, tune, generator list, probe,
#     beam energy, Q2 floor, ROI cuts.
#   - helper functions:  ea_config, ea_check_genie, ea_require_genie,
#     ea_check_q2min, ea_spline_path.
#
# Everything is overridable.  Precedence, highest first:
#   1. variables already exported in your shell
#   2. ${EA_ROOT}/config.local.sh   (gitignored, per-machine settings)
#   3. the defaults below
#
# Sourcing this does NOT fail if GENIE is missing -- it only reports.  Scripts
# that actually need GENIE call ea_require_genie.

# ------------------------------------------------------------------ guard
# Must be sourced: executing it would set variables in a subshell and exit.
if ! (return 0 2>/dev/null); then
  echo "setup.sh must be sourced, not executed:" >&2
  echo "    source $0" >&2
  exit 1
fi

if [ -z "${BASH_SOURCE[0]:-}" ]; then
  echo "setup.sh needs bash (it uses BASH_SOURCE to find the repo root)." >&2
  return 1
fi

# ------------------------------------------------------------------ root
# Resolve symlinks so that sourcing through a symlinked checkout still lands
# on the real tree.
_ea_this="${BASH_SOURCE[0]}"
while [ -L "${_ea_this}" ]; do
  _ea_dir="$(cd -P "$(dirname "${_ea_this}")" && pwd)"
  _ea_this="$(readlink "${_ea_this}")"
  case "${_ea_this}" in
    /*) ;;
    *) _ea_this="${_ea_dir}/${_ea_this}" ;;
  esac
done
EA_ROOT="$(cd -P "$(dirname "${_ea_this}")" && pwd)"
export EA_ROOT
unset _ea_this _ea_dir

# ------------------------------------------------------------------ local overrides
# Per-machine settings that should never be committed.  Put things like
#   EA_GENIE_TOP=/my/build/of/genie
#   EA_SCRATCH=/pnfs/uboone/scratch/users/$(whoami)
# in there.
EA_LOCAL_CONFIG="${EA_ROOT}/config.local.sh"
if [ -f "${EA_LOCAL_CONFIG}" ]; then
  # shellcheck disable=SC1090
  . "${EA_LOCAL_CONFIG}"
fi

# ------------------------------------------------------------------ paths
: "${EA_GRID:=${EA_ROOT}/grid}"
: "${EA_SPLINEDIR:=${EA_ROOT}/splines}"
: "${EA_INPUT:=${EA_ROOT}/input}"
: "${EA_OUTPUT:=${EA_ROOT}/output}"

# The GENIE tree lives outside this repo.  Default to a sibling directory.
: "${EA_GENIE_TOP:=$(dirname "${EA_ROOT}")/genie}"

# Grid artefacts
: "${EA_TARBALL:=${EA_GRID}/ProdEA.tar.gz}"
: "${EA_RUNSCRIPT:=${EA_GRID}/run_grid_eA.sh}"
: "${EA_GRID_SETUP:=${EA_GRID}/grid_setup.sh}"
: "${EA_SEEDFILE:=${EA_GRID}/.seed_counter}"
: "${EA_SEEDLOG:=${EA_GRID}/seed_ledger.txt}"

export EA_GRID EA_SPLINEDIR EA_INPUT EA_OUTPUT EA_GENIE_TOP
export EA_TARBALL EA_RUNSCRIPT EA_GRID_SETUP EA_SEEDFILE EA_SEEDLOG

# ------------------------------------------------------------------ experiment profile
#
# Everything that ties this to one experiment lives here.  Switching should be
#     export EA_EXPERIMENT=dune
# and nothing else.  Six separate things are experiment-specific, and changing
# only the jobsub group gives you a job that submits fine and then dies on the
# worker node, so they are set together:
#
#   EA_GROUP              jobsub_submit -G
#   EA_ROLE               jobsub_submit --role (empty = do not pass the flag)
#   EA_SCRATCH            /pnfs base the job writes into
#   EA_CVMFS_SETUP        the UPS/spack bootstrap grid_setup.sh sources
#   EA_SINGULARITY_IMAGE  container the job runs in
#   EA_CONDOR_REQS        --append_condor_requirements expression
#   EA_USAGE_MODEL        --resource-provides=usage_model
#
# Any of them can be overridden individually after the profile is applied.

: "${EA_EXPERIMENT:=uboone}"

case "${EA_EXPERIMENT}" in

  uboone)
    : "${EA_GROUP:=uboone}"
    : "${EA_ROLE:=}"
    : "${EA_SCRATCH:=/pnfs/uboone/scratch/users}"
    : "${EA_CVMFS_SETUP:=/cvmfs/uboone.opensciencegrid.org/products/setup_uboone_mcc9.sh}"
    : "${EA_SINGULARITY_IMAGE:=/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest}"
    : "${EA_USAGE_MODEL:=DEDICATED,OPPORTUNISTIC}"
    : "${EA_CONDOR_REQS:=(TARGET.HAS_Singularity==true&&TARGET.HAS_CVMFS_larsoft_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser1_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser2_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser3_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser4_opensciencegrid_org==true)}"
    ;;

  dune)
    : "${EA_GROUP:=dune}"
    : "${EA_ROLE:=Analysis}"
    : "${EA_SCRATCH:=/pnfs/dune/scratch/users}"
    : "${EA_CVMFS_SETUP:=/cvmfs/dune.opensciencegrid.org/products/dune/setup_dune.sh}"
    : "${EA_SINGULARITY_IMAGE:=/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-dev-sl7:latest}"
    : "${EA_USAGE_MODEL:=OPPORTUNISTIC,OFFSITE}"
    : "${EA_CONDOR_REQS:=(TARGET.HAS_Singularity==true&&TARGET.HAS_CVMFS_dune_opensciencegrid_org==true&&TARGET.HAS_CVMFS_larsoft_opensciencegrid_org==true&&TARGET.CVMFS_dune_opensciencegrid_org_REVISION>=1105&&TARGET.HAS_CVMFS_fifeuser1_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser2_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser3_opensciencegrid_org==true&&TARGET.HAS_CVMFS_fifeuser4_opensciencegrid_org==true)}"
    ;;

  *)
    # Unknown experiment: no guessing.  Everything must be supplied explicitly,
    # and we check below that it was.
    ;;
esac

# Fail loudly rather than submitting a half-configured job.
_ea_missing_profile=""
for _v in EA_GROUP EA_SCRATCH EA_CVMFS_SETUP EA_SINGULARITY_IMAGE \
          EA_USAGE_MODEL EA_CONDOR_REQS; do
  [ -z "${!_v:-}" ] && _ea_missing_profile="${_ea_missing_profile} ${_v}"
done
if [ -n "${_ea_missing_profile}" ]; then
  echo "WARNING: EA_EXPERIMENT='${EA_EXPERIMENT}' has no built-in profile and these"
  echo "         are unset:${_ea_missing_profile}"
  echo "         Set them in config.local.sh, or add a case to setup.sh."
fi
unset _v _ea_missing_profile

# Define every profile variable even when unset, so consumers under `set -u`
# fail with their own message rather than an "unbound variable" backtrace.
# EA_ROLE may legitimately be empty (uboone), so it is not in the check above.
: "${EA_GROUP:=}"
: "${EA_ROLE:=}"
: "${EA_SCRATCH:=}"
: "${EA_CVMFS_SETUP:=}"
: "${EA_SINGULARITY_IMAGE:=}"
: "${EA_USAGE_MODEL:=}"
: "${EA_CONDOR_REQS:=}"

# Returns nonzero if the profile is incomplete. Scripts that submit call this.
ea_require_profile() {
  local missing="" v
  for v in EA_GROUP EA_SCRATCH EA_CVMFS_SETUP EA_SINGULARITY_IMAGE \
           EA_USAGE_MODEL EA_CONDOR_REQS; do
    [ -z "${!v}" ] && missing="${missing} ${v}"
  done
  [ -z "${missing}" ] && return 0
  echo "ERROR: experiment profile '${EA_EXPERIMENT}' is incomplete."   >&2
  echo "       Unset:${missing}"                                        >&2
  echo "       Add a case for it in setup.sh, or set them in"          >&2
  echo "       config.local.sh. Known profiles: uboone, dune."          >&2
  return 1
}

export EA_EXPERIMENT EA_GROUP EA_ROLE EA_SCRATCH EA_CVMFS_SETUP
export EA_SINGULARITY_IMAGE EA_USAGE_MODEL EA_CONDOR_REQS

# ------------------------------------------------------------------ physics config
#
# NOTE ON NAMING: these deliberately keep the bare names (GVERSION, GTUNE, ...)
# rather than an EA_ prefix, because they are the contract with the grid job --
# launch_job_eA.sh forwards them verbatim via `jobsub_submit -e GVERSION ...`
# and run_grid_eA.sh reads them under those names.

: "${GVERSION:=v3_06_02-q2min0p8}"   # build tag of the GENIE fork
: "${GTUNE:=G18_10a_00_000}"
: "${GLIST:=EM}"                     # event generator list
: "${PROBE:=11}"                     # PDG code: 11 = e-
: "${BEAM_E:=5.014}"                 # GeV, CLAS EG2
: "${Q2MIN_GEN:=0.80}"               # Q2 floor COMPILED INTO the GENIE build

# Region of interest applied by gfilterroi.  Must be at least as tight as the
# generated Q2 floor or the filter is a no-op on that variable.
: "${ROI_Q2:=0.9}"
: "${ROI_W:=1.9}"
: "${ROI_NUMIN:=2.2}"
: "${ROI_NUMAX:=4.3}"

# Campaign defaults.  Deliberately NOT the production campaign: a bare
# ./launch_job_eA.sh with no environment should not be able to write into the
# production directory by accident.
: "${CAMPAIGN:=eA_test}"
: "${EA_PROD_CAMPAIGN:=eA_prod_v1}"
: "${NEVENTS:=500000}"

export GVERSION GTUNE GLIST PROBE BEAM_E Q2MIN_GEN
export ROI_Q2 ROI_W ROI_NUMIN ROI_NUMAX
export CAMPAIGN EA_PROD_CAMPAIGN NEVENTS

# ------------------------------------------------------------------ targets
# name -> PDG, plus the grid resources each one needs.  Pb cascades are roughly
# 3x slower per event than C, hence the longer lifetimes.
# Fields: PDG:lifetime:memory
ea_target_pdg() {
  case "${1:-}" in
    D2)    echo 1000010020 ;;
    C12)   echo 1000060120 ;;
    Fe56)  echo 1000260560 ;;
    Pb208) echo 1000822080 ;;
    *)     return 1 ;;
  esac
}

ea_target_lifetime() {
  case "${1:-}" in
    D2|C12) echo "4h" ;;
    Fe56)   echo "6h" ;;
    Pb208)  echo "6h" ;;
    *)      return 1 ;;
  esac
}

ea_target_memory() {
  case "${1:-}" in
    D2|C12) echo "2500MB" ;;
    Fe56)   echo "3000MB" ;;
    Pb208)  echo "3500MB" ;;
    *)      return 1 ;;
  esac
}

EA_TARGETS="D2 C12 Fe56 Pb208"
export EA_TARGETS

# ------------------------------------------------------------------ splines
# The spline filename encodes the config.  Every script that touches splines
# must agree on this string, so it is computed in exactly one place.
ea_spline_file() {
  echo "${PROBE}_ALL_${GLIST}_${GVERSION}_${GTUNE}.xml"
}

ea_spline_path() {
  echo "${EA_SPLINEDIR}/$(ea_spline_file)"
}

# ------------------------------------------------------------------ tarball
# Is NAME present at the TOP LEVEL of TARBALL?
#
# Top level specifically: the grid job opens ${INPUT_TAR_DIR_LOCAL}/<name>, so
# a copy buried in a subdirectory is not a pass.
#
# Returns 0 found, 1 not found, 2 the tarball could not be read.
ea_tarball_has_toplevel() {
  local tarball="$1" name="$2" listing entry
  listing=$(tar -tzf "${tarball}" 2>/dev/null) || return 2
  [ -n "${listing}" ] || return 2
  # A here-string, not a pipe: any reader that stops at the first match sends
  # SIGPIPE to the writer, and pipefail then reports the whole check as failed.
  while IFS= read -r entry; do
    entry="${entry#./}"                # tolerate a ./ prefix
    entry="${entry%/}"                 # tolerate a trailing / on directories
    [ "${entry}" = "${name}" ] && return 0
  done <<< "${listing}"
  return 1
}

# Top-level entries, for error messages that actually help.
ea_tarball_toplevel() {
  tar -tzf "$1" 2>/dev/null \
    | sed 's#^\./##' \
    | awk -F/ 'NF==1 && $1!="" {print $1}' \
    | sort -u
}

# ------------------------------------------------------------------ GENIE
# Returns 0 if a usable GENIE is set up, 1 otherwise.  Prints what it found.
ea_check_genie() {
  local quiet=0
  [ "${1:-}" = "-q" ] && quiet=1
  local ok=0

  _ea_say() { [ "${quiet}" -eq 1 ] || echo "$@"; }

  # $GENIE is set by grid_setup.sh on the worker and by the UPS setup
  # interactively.  Fall back to the tree we expect next to the repo.
  if [ -z "${GENIE:-}" ]; then
    if [ -d "${EA_GENIE_TOP}/Generator" ]; then
      export GENIE="${EA_GENIE_TOP}/Generator"
      _ea_say "  note  \$GENIE was unset, using ${GENIE}"
    else
      _ea_say "  MISS  \$GENIE is not set and ${EA_GENIE_TOP}/Generator does not exist"
      _ea_say "        Set up GENIE first, or set EA_GENIE_TOP in config.local.sh"
      unset -f _ea_say
      return 1
    fi
  fi

  if [ ! -d "${GENIE}" ]; then
    _ea_say "  MISS  \$GENIE points at ${GENIE}, which does not exist"
    ok=1
  else
    _ea_say "  OK    \$GENIE = ${GENIE}"
  fi

  # The four binaries the pipeline actually invokes.  gfilterroi is the one
  # that lives only in the fork, so it is the useful canary.
  local b
  for b in gevgen gntpc gfilterroi gmkspl; do
    if [ -x "${GENIE}/bin/${b}" ]; then
      _ea_say "  OK    bin/${b}"
    else
      _ea_say "  MISS  bin/${b}"
      ok=1
    fi
  done

  # ROOT is a hard dependency of every GENIE binary.
  if [ -z "${ROOTSYS:-}" ] && ! command -v root-config >/dev/null 2>&1; then
    _ea_say "  WARN  ROOT does not look set up (\$ROOTSYS unset, no root-config)"
  fi

  unset -f _ea_say
  return ${ok}
}

# Hard version, for scripts that cannot proceed without it.
ea_require_genie() {
  if ! ea_check_genie; then
    echo "ERROR: GENIE is not set up.  Set it up and re-source setup.sh." >&2
    return 1
  fi
}

# The Q2 floor is a compile-time constant in the fork.  If the source does not
# carry the value the launcher advertises, the splines, the events and the
# provenance record disagree and nothing downstream is trustworthy.
# Returns 0 = matches, 1 = mismatch, 2 = could not check.
ea_check_q2min() {
  local ku="${GENIE:-${EA_GENIE_TOP}/Generator}/src/Framework/Utils/KineUtils.h"
  if [ ! -f "${ku}" ]; then
    echo "  WARN  ${ku} not found, cannot verify Q2 floor"
    return 2
  fi
  local got
  got=$(grep -oE 'kMinQ2Limit[^;]*=[^;]*' "${ku}" | head -1 \
        | grep -oE '[0-9]+\.?[0-9]*' | tail -1 || true)
  # numeric compare: '0.80' and '0.8' are the same number
  local same
  same=$(awk -v a="${got:-nan}" -v b="${Q2MIN_GEN}" \
           'BEGIN{ if (a+0==b+0 && a!="nan") print "yes"; else print "no" }')
  if [ "${same}" = "yes" ]; then
    echo "  OK    electromagnetic::kMinQ2Limit = ${got}"
    return 0
  fi
  echo "  WARN  KineUtils.h reports '${got}', config says Q2MIN_GEN=${Q2MIN_GEN}"
  echo "        Check by hand; the grep is heuristic."
  return 1
}

# ------------------------------------------------------------------ analysis
# The EG2 analysis chain: the compiled counts binary, the published CLAS
# tables it reads its BINNING from, and the per-target input lists the scan
# jobs index into.
: "${EA_ANALYSIS:=${EA_ROOT}/analysis}"
: "${EA_DATA:=${EA_ROOT}/data}"
: "${EA_LISTDIR:=${EA_GRID}/lists}"
export EA_ANALYSIS EA_DATA EA_LISTDIR

# EG2Analysis loads its fill grid out of these four files, check explicitly.
EA_CLAS_CSVS="clas_eg2_charged_pion_multiplicity_ratios_Moran_PRC105_015201.csv
clas_eg2_neutral_pion_multiplicity_ratios_Mineeva_PRC112_035203.csv
clas_eg2_dipion_correlations_Paul_PRC111_035201.csv
clas_eg2_pion_proton_correlations_Paul_2512_05083.csv"
export EA_CLAS_CSVS

# ------------------------------------------------------------------ scan campaign
# Replay jobs are a different campaign from generation, keep separate
: "${EA_SCAN_TARBALL:=${EA_GRID}/ScanEA.tar.gz}"
: "${EA_SCAN_RUNSCRIPT:=${EA_GRID}/run_scan_eA.sh}"
: "${EA_SCAN_LEDGER:=${EA_GRID}/scan_ledger.txt}"
: "${EA_SCAN_CAMPAIGN:=scan_test}"
export EA_SCAN_TARBALL EA_SCAN_RUNSCRIPT EA_SCAN_LEDGER EA_SCAN_CAMPAIGN

# Replay physics defaults.  SCAN_SEED is deliberately ONE value shared by every
# parameter point.
: "${STAGE:=fsi}"
: "${SCAN_SEED:=101}"
: "${FZ_CT0PION:=0.342}"
: "${FZ_CT0NUC:=2.300}"
: "${FZ_KPT2:=0.0}"
export STAGE SCAN_SEED FZ_CT0PION FZ_CT0NUC FZ_KPT2

# ROI events per input file: a 500k-event job filtered by gfilterroi keeps ~30%.
# Used only to estimate job lifetimes.
: "${EA_EV_PER_FILE:=150000}"
export EA_EV_PER_FILE

# ------------------------------------------------------------------ target maps
# EG2Analysis wants the label that appears in the `target` column of the
# published CSVs, which is NOT the production directory name.
ea_target_label() {
  case "${1:-}" in
    D2)    echo D  ;;
    C12)   echo C  ;;
    Fe56)  echo Fe ;;
    Pb208) echo Pb ;;
    *)     return 1 ;;
  esac
}

# Measured replay cost, milliseconds per ROI event (scan_timing.py).
ea_target_mspe() {
  case "${1:-}" in
    D2)    echo 0.97 ;;
    C12)   echo 1.02 ;;
    Fe56)  echo 2.04 ;;
    Pb208) echo 3.49 ;;
    *)     return 1 ;;
  esac
}

# ------------------------------------------------------------------ file lists
# One job = one input file x ALL parameter values, so the list length IS the
# job count.  Computed in one place so the tarball and the launcher cannot
# disagree about how many jobs there should be.
ea_filelist_file() { echo "filelist_${1}.txt"; }
ea_filelist_path() { echo "${EA_LISTDIR}/$(ea_filelist_file "$1")"; }

ea_filelist_count() {
  local f
  f="$(ea_filelist_path "${1}")"
  [ -s "${f}" ] || { echo 0; return 1; }
  grep -vc '^[[:space:]]*\(#.*\)\?$' "${f}"
}

# ------------------------------------------------------------------ scan checks
# Returns 0 if the analysis side is ready to be tarred up, 1 otherwise.
ea_check_analysis() {
  local ok=0 f
  # The worker has no rootcling and the source tree may be read-only, so the
  # COMPILED binary is required
  if [ -x "${EA_ANALYSIS}/eg2analysis" ]; then
    echo "  OK    eg2analysis binary"
  else
    echo "  MISS  ${EA_ANALYSIS}/eg2analysis"
    echo "        run 'make' in ${EA_ANALYSIS} -- ACLiC will not work on a worker"
    ok=1
  fi
  for f in ${EA_CLAS_CSVS}; do
    if [ -s "${EA_DATA}/${f}" ]; then
      echo "  OK    data/$(echo "${f}" | cut -c1-52)..."
    else
      echo "  MISS  ${EA_DATA}/${f}"
      ok=1
    fi
  done
  return ${ok}
}

ea_check_filelists() {
  local ok=0 t n
  for t in ${EA_TARGETS}; do
    if n=$(ea_filelist_count "${t}"); then
      echo "  OK    $(ea_filelist_file "${t}") (${n} files -> ${n} jobs)"
      if head -1 "$(ea_filelist_path "${t}")" | grep -q '^root://'; then
        echo "        NOTE  xrootd URLs need a valid token on the worker."
        echo "              Plain /pnfs paths are copied by ifdh without one."
      fi
    else
      echo "  MISS  $(ea_filelist_path "${t}")"
      ok=1
    fi
  done
  return ${ok}
}

# ------------------------------------------------------------------ scan sizing
# Minutes per job = ROI events x ms/event x number of values, plus a fixed
# allowance for stage-in, the counts pass and copyback.
ea_scan_minutes() {   # target nvalues
  local mspe
  mspe="$(ea_target_mspe "${1}")" || return 1
  awk -v e="${EA_EV_PER_FILE}" -v m="${mspe}" -v n="${2:-1}" \
      'BEGIN{ printf "%.0f", e*m/1000/60*n + 5 }'
}

# Whole hours with ~4x headroom, floored at 2h.
ea_scan_lifetime() {  # target nvalues
  local min
  min="$(ea_scan_minutes "${1}" "${2}")" || return 1
  awk -v m="${min}" 'BEGIN{ h=int(m*4/60)+1; if(h<2)h=2; printf "%dh", h }'
}

# ------------------------------------------------------------------ PATH
# Idempotent: re-sourcing this file must not grow $PATH without bound.
ea_prepend_path() {
  local var="$1" dir="$2" cur
  [ -d "${dir}" ] || return 0
  cur="${!var:-}"                 # :- so this is safe under `set -u`
  case ":${cur}:" in
    *":${dir}:"*) return 0 ;;
  esac
  export "${var}=${dir}${cur:+:${cur}}"
}

if [ -n "${GENIE:-}" ] && [ -d "${GENIE}/bin" ]; then
  ea_prepend_path PATH "${GENIE}/bin"
  ea_prepend_path LD_LIBRARY_PATH "${GENIE}/lib"
fi

# ------------------------------------------------------------------ report
ea_config() {
  cat <<EOF
--------------------------------------------------------------
 eA-vA EG2 analysis environment
--------------------------------------------------------------
 experiment  : ${EA_EXPERIMENT}   (group ${EA_GROUP}${EA_ROLE:+, role ${EA_ROLE}})
 scratch     : ${EA_SCRATCH}
 root        : ${EA_ROOT}
 grid        : ${EA_GRID}
 splines     : ${EA_SPLINEDIR}
 output      : ${EA_OUTPUT}
 genie tree  : ${EA_GENIE_TOP}
 local cfg   : $([ -f "${EA_LOCAL_CONFIG}" ] && echo "${EA_LOCAL_CONFIG}" || echo "(none)")

 build tag   : ${GVERSION}
 tune        : ${GTUNE}
 gen list    : ${GLIST}    probe ${PROBE}    beam ${BEAM_E} GeV
 Q2min (gen) : ${Q2MIN_GEN}
 ROI         : Q2>${ROI_Q2}  W>${ROI_W}  ${ROI_NUMIN}<nu<${ROI_NUMAX}
 campaign    : ${CAMPAIGN}$([ "${CAMPAIGN}" = "${EA_PROD_CAMPAIGN}" ] && echo "   <-- PRODUCTION")
 events/job  : ${NEVENTS}
 spline file : $(ea_spline_file)
--------------------------------------------------------------
EOF
}

# Full status, including the things that can be wrong.
ea_status() {
  ea_config
  echo " GENIE:"
  ea_check_genie
  ea_check_q2min
  echo " Splines:"
  if [ -s "$(ea_spline_path)" ]; then
    echo "  OK    $(ea_spline_file) ($(du -h "$(ea_spline_path)" | cut -f1))"
  else
    echo "  MISS  $(ea_spline_path)"
    echo "        Available in ${EA_SPLINEDIR}:"
    ls -1 "${EA_SPLINEDIR}"/*.xml 2>/dev/null | sed 's/^/          /' \
      || echo "          (none)"
  fi
}

# EA_QUIET=1 suppresses the banner, for when scripts source this file.
if [ "${EA_QUIET:-0}" != "1" ]; then
  ea_config
  ea_check_genie || echo "  (GENIE not ready -- fine unless you are building the tarball)"
fi

return 0