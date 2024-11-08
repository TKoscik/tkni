#!/bin/bash -e
#===============================================================================
# Run Freesurfer's recon-all-clinical.sh pipeline for EVANDERPLAS UNITCALL
# Author: Timothy R. Koscik, PhD
# Date Created: 2023-08-28
# Date Modified: 2023-08-28
# CHANGE_LOG:	-convert into a function
#===============================================================================
PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
PROC_NAME="dicomConversion"
FCN_NAME=($(basename "$0"))
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S%N)
OPERATOR=$(whoami)
KERNEL="$(uname -s)"
HARDWARE="$(uname -m)"
HPC_Q=${QUEUE}
HPC_SLOTS=${NSLOTS}
KEEP=false
NO_LOG=false
umask 007

# Parse inputs -----------------------------------------------------------------
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,\
id-flags:,id-values:,id-cols:,modality:,\
dir-scratch:,\
help,verbose -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
PIPELINE=fsSynth
DIR_PROJECT=
DIR_SCRATCH=${TKNI_SCRATCH}/${PROC_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
ID_FLAGS="pid,sid"
ID_VALUES=
ID_COLS="participant_id,session_id"
MOD="T1w"
HELP=false
VERBOSE=false
if [[ -z ${NSLOTS} ]]; then
  THREADS=4
fi

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id-flags) ID_FLAGS="$2" ; shift 2 ;;
    --id-values) ID_VALUES="$2" ; shift 2 ;;
    --id-cols) ID_COLS="$2" ; shift 2 ;;
    --modality) MOD="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    -- ) shift ; break ;;
    * ) break ;;
  esac
done

# Usage Help -------------------------------------------------------------------
if [[ "${HELP}" == "true" ]]; then
  echo ''
  echo '------------------------------------------------------------------------'
  echo "TK_BRAINLab: ${FCN_NAME}"
  echo '------------------------------------------------------------------------'
  echo '  -h | --help        display command help'
  echo '  -v | --verbose     add verbose output to log file'
  echo '  -n | --no-png      disable generating pngs of output'
  echo '  --pi               folder name for PI, no underscores'
  echo '                       default=evanderplas'
  echo '  --project          project name, preferrable camel case'
  echo '                       default=unitcall'
  echo '  --id-flags         Comma-separated string identifying the BIDS format'
  echo '                     flags used in the filename in the order that they'
  echo '                     should appear in filenames, DEFAULT="pid,sid"'
  echo '  --id-values        [REQUIRED] Flag values for selected participant,'
  echo '                     in same as id-flags order'
  echo '  --id-cols          [REQUIRED] comma-separated values indicating the'
  echo '                     names of the columns in the participant.tsv file'
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
ID_FLAGS=(${ID_FLAGS//,/ })
ID_VALUES=(${ID_VALUES//,/ })
ID_COLS=(${ID_COLS//,/ })

## process newest participant or set identifiers -------------------------------
unset TPAIR
for (( i=0; i<${#ID_FLAGS[@]}; i++ )); do
  TFLAG=${ID_FLAGS[${i}]}
  if [[ ${TFLAG} == "pid" ]]; then TFLAG="sub"; fi
  if [[ ${TFLAG} == "sid" ]]; then TFLAG="ses"; fi
  if [[ -z ${ID_VALUES} ]]; then
    TCOL=${ID_COLS[${i}]}
    TLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f ${TCOL}))
    TVALUE=${TLS[-1]}
  else
    TVALUE=${ID_VALUES[${i}]}
  fi
  if [[ ${TFLAG} == "sub" ]]; then
    TN=0
    PID=${TVALUE}
  elif [[ ${TFLAG} == "ses" ]]; then
    TN=1
    SID=${TVALUE}
  else
    TN=$((${i}+2))
  fi
  TPAIR[${TN}]=${TFLAG}-${TVALUE}
done
PIDSTR=$(echo ${TPAIR[@]})
PIDSTR=${PIDSTR// /_}
DIRPID="${TPAIR[0]}/${TPAIR[1]}"

# set directories --------------------------------------------------------------
DIR_RAW=${DIR_PROJECT}/rawdata/${DIRPID}
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPELINE}
DIR_FS=${DIR_PIPE}/fs
DIR_ANAT=${DIR_PIPE}/anat
mkdir -p ${DIR_FS}

# Recon-all-clinical -----------------------------------------------------------
IMG=${DIR_RAW}/anat/${PIDSTR}_${MOD}.nii.gz
if [[ -f ${IMG} ]]; then
  recon-all-clinical.sh ${IMG} ${PIDSTR} ${THREADS} ${DIR_FS}
else
  echo "ERROR [TKNI:${FCN_NAME}] Image does not exist. Aborting"
  echo "    >> ${IMG}"
  exit 1
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0

