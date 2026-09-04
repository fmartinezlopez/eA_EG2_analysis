#!/bin/bash
#
# Worker-node environment.  Sourced by run_grid_eA.sh from the unpacked tarball.
#
# EA_EXPERIMENT and EA_CVMFS_SETUP are forwarded by launch_job_eA.sh via
# jobsub -e.

# we cannot rely on "whoami" in a grid job. We have no idea what the local username will be.
# Use the GRID_USER environment variable instead (set automatically by jobsub).
USERNAME=${GRID_USER}

export WORKDIR=${_CONDOR_JOB_IWD} # if we use the RCDS our tarball will be placed in $INPUT_TAR_DIR_LOCAL.
if [ ! -d "$WORKDIR" ]; then
  export WORKDIR=`echo .`
fi

# NO DEFAULT.  A launcher that forgets to forward these via jobsub -e would
# otherwise get a silently wrong environment.
if [ -z "${EA_EXPERIMENT}" ] || [ -z "${EA_CVMFS_SETUP}" ]; then
  echo "ERROR: EA_EXPERIMENT and/or EA_CVMFS_SETUP are not set."
  echo "       They are forwarded from the submitting shell by jobsub -e."
  echo "       Check that the launcher exports them AND lists them:"
  echo "           export EA_EXPERIMENT EA_CVMFS_SETUP"
  echo "           jobsub_submit ... -e EA_EXPERIMENT -e EA_CVMFS_SETUP ..."
  echo "       EA_EXPERIMENT='${EA_EXPERIMENT}'  EA_CVMFS_SETUP='${EA_CVMFS_SETUP}'"
  return 1 2>/dev/null || exit 1
fi

echo "grid_setup: experiment=${EA_EXPERIMENT}"
echo "grid_setup: bootstrap =${EA_CVMFS_SETUP}"

# The two must agree. Pointing EA_EXPERIMENT at one experiment while the
# bootstrap script belongs to another gets a product list that cannot resolve.
case "${EA_CVMFS_SETUP}" in
  *"/${EA_EXPERIMENT}."*|*"/${EA_EXPERIMENT}/"*) ;;
  *) echo "WARNING: EA_CVMFS_SETUP does not mention '${EA_EXPERIMENT}'."
     echo "         Check the profile in setup.sh -- these should match." ;;
esac

if [ ! -e "${EA_CVMFS_SETUP}" ]; then
  echo "ERROR: bootstrap script not found: ${EA_CVMFS_SETUP}"
  echo "       CVMFS may not be mounted on this node, or the path is wrong for"
  echo "       EA_EXPERIMENT=${EA_EXPERIMENT}. Check the profile in source.sh."
  ls -l "$(dirname "${EA_CVMFS_SETUP}")" 2>/dev/null | head
  return 1 2>/dev/null || exit 1
fi

source "${EA_CVMFS_SETUP}"

# ------------------------------------------------------------------ products
# The product set and its qualifiers are experiment-specific: the versions
# below are what the uboone mcc9 area actually provides, and they will not
# resolve against another experiment's product area.
case "${EA_EXPERIMENT}" in

  uboone)
    setup ifdhc
    setup root v6_28_12 -q e26:p3915:prof
    setup lhapdf v6_5_4 -q e26:p3915:prof
    setup log4cpp v1_1_3e -q e26:prof
    setup pdfsets v5_9_1b
    setup gdb v13_1
    setup git v2_45_1
    setup cmake v3_27_4
    setup boost v1_82_0 -q e26:prof
    setup tbb v2021_9_0 -q e26
    setup sqlite v3_40_01_00
    setup pythia v6_4_28x -q e26:prof
    setup hepmc3 v3_3_1 -q e26:p3915:prof
    setup geant4 v4_11_2_p02 -q e26:prof
    setup inclxx v5_2_9_5f -q e26:prof
    setup hdf5 v1_12_2b -q e26:prof
    setup spdlog v1_9_2 -q e26:prof
    ;;

  dune)
    setup ifdhc
    setup root v6_28_12 -q e26:p3915:prof
    setup lhapdf v6_5_4 -q e26:p3915:prof
    setup log4cpp v1_1_3e -q e26:prof
    setup pdfsets v5_9_1b
    setup gdb v13_1
    setup git v2_45_1
    setup cmake v3_27_4
    setup boost v1_82_0 -q e26:prof
    setup tbb v2021_9_0 -q e26
    setup sqlite v3_40_01_00
    setup pythia v6_4_28x -q e26:prof
    setup hepmc3 v3_3_1 -q e26:p3915:prof
    setup geant4 v4_11_2_p02 -q e26:prof
    setup inclxx v5_2_9_5f -q e26:prof
    setup hdf5 v1_12_2b -q e26:prof
    setup spdlog v1_9_2 -q e26:prof
    ;;

  *)
    echo "ERROR: no product list for EA_EXPERIMENT=${EA_EXPERIMENT}"
    return 1 2>/dev/null || exit 1
    ;;
esac

# Setup GENIE -- stuff is in the tarball!
BASE_DIR=${INPUT_TAR_DIR_LOCAL}

export GENIE_FQ_DIR=${BASE_DIR}/genie
export GENIE=${BASE_DIR}/genie/Generator
export GENIE_LIB=${BASE_DIR}/genie/Generator/lib
export PYTHIA6=${PYTHIA_FQ_DIR}/lib
export LHAPDF5_INC=${LHAPDF_INC}
export LHAPDF5_LIB=${LHAPDF_LIB}
export GENIE_REWEIGHT=${BASE_DIR}/genie/Reweight
export PATH=${GENIE}/bin:${GENIE_REWEIGHT}/bin:$PATH
export LD_LIBRARY_PATH=${GENIE}/lib:${GENIE_REWEIGHT}/lib:${LD_LIBRARY_PATH}
export LIBRARY_PATH=${LIBRARY_PATH}:${GENIE_REWEIGHT}/lib
# Confirm the environment is the one that was asked for.
echo "grid_setup: ROOT      = $(root-config --version 2>/dev/null || echo MISSING)"
echo "grid_setup: GENIE     = ${GENIE}"
for _b in gfsireplay gntpc; do
  if command -v "${_b}" >/dev/null 2>&1; then
    echo "grid_setup: ${_b} -> $(command -v ${_b})"
  else
    echo "ERROR: ${_b} not on PATH after setup -- the tarball or the product"
    echo "       list is wrong for EA_EXPERIMENT=${EA_EXPERIMENT}."
    return 1 2>/dev/null || exit 1
  fi
done
unset _b
echo "Ready!"