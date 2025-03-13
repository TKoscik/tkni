#!/bin/bash -e
#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      PCASL
# DESCRIPTION:   TKNI Arterial Spin Labelling Pipeline
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-03-13
# README:
#     Procedure:
#     (1) Copy to scratch
#     (2) Reorient
#     (3) Motion Correction
#     (4) Split 4D file into 3D, organize into pairs
#     (5) Denoise
#     (6) FG Mask
#     (7) Bias Correction
#     (8) Calculate M0, mean control image
#     (9) Brain mask
#    (10) Coregister to Native Space
#    (11) Calculate change in control/label pairs, dM
#    (12) Calculate CBF
# DATE MODIFIED:
# CHANGELOG:
#===============================================================================

PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
FCN_NAME=($(basename "$0"))
FCN_NAME=${FCN_NAME%.*}
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S%N)
OPERATOR=$(whoami)
OPERATOR=${OPERATOR//@}
KERNEL="$(uname -s)"
HARDWARE="$(uname -m)"
NO_LOG=false
umask 007

# actions on exit, write to logs, clean scratch --------------------------------
function egress {
  EXIT_CODE=$?
  PROC_STOP=$(date +%Y-%m-%dT%H:%M:%S%z)
  if [[ ${EXIT_CODE} -eq 0 ]]; then
    if [[ -n ${DIR_SCRATCH} ]]; then
      if [[ -d ${DIR_SCRATCH} ]]; then
        if [[ "$(ls -A ${DIR_SCRATCH})" ]]; then
          rm -R ${DIR_SCRATCH}
        else
          rmdir ${DIR_SCRATCH}
        fi
      fi
    fi
  fi
  if [[ "${NO_LOG}" == "false" ]]; then
    writeBenchmark ${OPERATOR} ${HARDWARE} ${KERNEL} ${FCN_NAME} \
      ${PROC_START} ${PROC_STOP} ${EXIT_CODE}
  fi
}
trap egress EXIT

# Parse inputs -----------------------------------------------------------------
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,id:,dir-id:,\
asl:,asl-type:,pwi:,pwi-label:,native:,native-mask:,\
opt-brainblood:,opt-t1blood:,opt-duration:,opt-efficiency:,opt-delay:,\
no-denoise,no-debias,no-norm,\
atlas:atlas-xfm:,\
dir-scratch:,requires:,\
help,verbose,force,no-png,no-rmd -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
IDPFX=
IDDIR=

ASL=
ASL_TYPE="pcasl"
PWI=
PWI_LABEL="proc-scanner_relCBF"
NATIVE=
NATIVE_MASK=

OPT_LAMBDA=0.9
OPT_ALPHA=0.85
OPT_T1BLOOD=1650
OPT_OMEGA=
OPT_TAU=
#FORMULA="(6000*lambda*deltaM*exp(-((gamma)/(t1blood))))/(2*alpha*M0*t1blood*(1-exp(-(tau)/(t1blood))))"

NO_DENOISE="false"
NO_DEBIAS="false"
NO_NORM="false"

ATLAS="/usr/local/tkni/atlas/adult/HCPYAX/HCPYAX_700um_T1w.nii.gz"
ATLAS_XFM=

DIR_SAVE=
DIR_SCRATCH=

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false
KEEP_CLEANED=true

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF"
FORCE=false

