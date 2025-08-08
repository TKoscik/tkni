#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      ANTS DiReCT, registration based cortical thickness
# DESCRIPTION:   antsCorticalThickness .sh
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-22
# README:
# DATE MODIFIED:
# CHANGELOG:
#===============================================================================
PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
FCN_NAME=($(basename "$0"))
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
OPTS=$(getopt -o hvn --long pi:,project:,dir-project:,\
id:,dir-id:,\
seg:,val-gm:,val-wm:,p-gm:,p-wm:,\
direct-convergence:,direct-prior:,direct-gradstep:,direct-smooth:,direct-ncomps:,\
dir-scratch:,dir-save:,\
help,verbose,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
PIPELINE=tkni
DIR_PROJECT=
DIR_SAVE=
DIR_SCRATCH=
IDPFX=
IDDIR=

SEG=
VAL_GM=1
VAL_WM=3
P_GM=
P_WM=

DIRECT_CONVERGENCE="[ 45,0.0,10 ]"
DIRECT_PRIOR="10"
DIRECT_GRADSTEP="0.025"
DIRECT_SMOOTH="1.5"
DIRECT_NCOMPS="10"
PNG_BG=

HELP=false
VERBOSE=false
NO_PNG=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --seg) SEG="$2" ; shift 2 ;;
    --) VAL_GM="$2" ; shift 2 ;;
    --) VAL_WM="$2" ; shift 2 ;;
    --) P_GM="$2" ; shift 2 ;;
    --) P_WM="$2" ; shift 2 ;;
    --direct-convergence) DIRECT_CONVERGENCE="$2" ; shift 2 ;;
    --direct-prior) DIRECT_PRIOR="$2" ; shift 2 ;;
    --direct-gradstep) DIRECT_GRADSTEP="$2" ; shift 2 ;;
    --direct-smoothing) DIRECT_SMOOTH="$2" ; shift 2 ;;
    --direct-ncomps) DIRECT_NCOMPS="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    -- ) shift ; break ;;
    * ) break ;;
  esac
done

# Usage Help -------------------------------------------------------------------
if [[ "${HELP}" == "true" ]]; then
  echo ''
  echo '------------------------------------------------------------------------'
  echo "TKNI: ${FCN_NAME}"
  echo '------------------------------------------------------------------------'
  echo '  -h | --help        display command help'
  echo '  -v | --verbose     add verbose output to log file'
  echo '  -n | --no-png      disable generating pngs of output'
  echo '  --pi               folder name for PI, no underscores'
  echo '                       default=evanderplas'
  echo '  --project          project name, preferrable camel case'
  echo '                       default=unitcall'
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --id               file prefix, usually participant identifier string'
  echo '                       e.g., sub-123_ses-20230111T1234_aid-4567'
  echo '  --dir-id           sub-directory corresponding to subject in BIDS'
  echo '                       e.g., sub-123/ses-20230111T1234'
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
# set project defaults ---------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] PROJECT must be provided"
  exit 1
fi
if [[ -z ${DIR_PROJECT} ]]; then
  DIR_PROJECT=/data/x/projects/${PI}/${PROJECT}
fi
if [[ -z ${DIR_SCRATCH} ]]; then
  DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME%.*}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi

# Check ID ---------------------------------------------------------------------
if [[ -z ${IDPFX} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] ID Prefix must be provided"
  exit 1
fi
if [[ -z ${IDDIR} ]]; then
  TSUB=$(getField -i ${IDPFX} -f sub)
  TSES=$(getField -i ${IDPFX} -f ses)
  IDDIR=sub-${TSUB}
  if [[ -n ${TSES} ]]; then
    IDDIR="${IDDIR}/ses-${TSES}"
  fi
fi

# set up directories -----------------------------------------------------------
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPELINE}
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PIPE}/anat/outcomes/thickness; fi
mkdir -p ${DIR_SAVE}

# parse image inputs -----------------------------------------------------------
if [[ -z ${SEG} ]]; then
  SEG=${DIR_PIPE}/anat/label/${IDPFX}_label-tissue.nii.gz
fi
if [[ -z ${P_GM} ]]; then
  P_GM=${DIR_PIPE}/anat/posterior/${IDPFX}_posterior-gm.nii.gz
fi
if [[ -z ${P_WM} ]]; then
  P_WM=${DIR_PIPE}/anat/posterior/${IDPFX}_posterior-wm.nii.gz
fi

# Run DiReCT -------------------------------------------------------------------
KellyKapowski -d 3 \
  -o ${DIR_SAVE}/${IDPFX}_thickness.nii.gz
  -s [ ${SEG},${VAL_GM},${VAL_WM} ] \
  -g ${P_GM} -w ${P_WM} \
  -c ${DIRECT_CONVERGENCE} \
  -t ${DIRECT_PRIOR} \
  -r ${DIRECT_GRADSTEP} \
  -m ${DIRECT_SMOOTH} \
  -n ${DIRECT_NCOMPS}

# generate PNG -----------------------------------------------------------------
if [[ ${NO_PNG} == "false" ]]; then
  if [[ -z ${PNG_BG} ]]; then
    PNG_BG=${DIR_PIPE}/anat/native/${IDPFX}_T1w.nii.gz
  fi
  make3Dpng --bg ${PNG_BG} --bg-threshold 5,95 \
    --fg ${DIR_SAVE}/${IDPFX}_thickness.nii.gz \
    --fg-mask ${DIR_SAVE}/${IDPFX}_thickness.nii.gz \
    --fg-color "hot" --fg-cbar "true" --fg-alpha 50 \
    --layout "9:z;9:z;9:z" --offset "0,0,0" \
    --filename ${IDPFX}_thickness \
    --dir-save ${DIR_SAVE}
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0

