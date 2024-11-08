#!/bin/bash -e
#===============================================================================
# DICOM Conversion for EVANDERPLAS UNITCALL
# Author: Timothy R. Koscik, PhD
# Date Created: 2023-08-10
# Date Modified: 2023-08-24
# CHANGE_LOG:	-convert into a function
#===============================================================================
PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
FCN_NAME=($(basename "$0"))
PROC_NAME="dicomAutoConvert"
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S%N)
OPERATOR=$(whoami)
KEEP=false
NO_LOG=false
umask 007

# egress function --------------------------------------------------------------
## clear scratch, write logs
function egress {
  EXIT_CODE=$?
  ## Safely remove scratch folder
  if [[ "${KEEP}" == "false" ]]; then
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

  ## write logs
  if [[ "${NO_LOG}" == "false" ]]; then
    unset LOGSTR
    LOGSTR="${OPERATOR},${HOSTNAME},${HOSTTYPE},${MACHTYPE},${OSTYPE},\
    ${PI},${PROJECT},${PIDSTR},\
    ${PROC_NAME},${PROC_START},${PROC_STOP},${EXIT_CODE}"
    LOGSTR=${LOGSTR// }
    FCN_LOG=${HOME}/tkni_log/tkni_benchmark_$(date +FY%Y)Q$((($(date +%-m)-1)/3+1)).log
    echo ${LOGSTR} >> ${FCN_LOG}
    echo ${LOGSTR} >> ${DIR_PROJECT}/log/tkni_processing.log
  fi
}
trap egress EXIT

# Parse inputs -----------------------------------------------------------------
OPTS=$(getopt -o hvn --long pi:,project:,dir-project:,pidstr:,input-dcm:,\
dir-scratch:,help,verbose,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
PIDSTR=
INPUT_DCM=
DIR_SCRATCH=${TKNI_SCRATCH}/${PROC_NAME}_${DATE_SUFFIX}
HELP=false
VERBOSE=false
NO_PNG=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --pidstr) ID="$2" ; shift 2 ;;
    --input-dcm) INPUT_DCM="$2" ; shift 2 ;;
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
  echo "TKNI: ${FCN_NAME}"
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
  echo '  --input-dcm        full path to DICOMs, may be directory or zip-file'
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

# Check if identifiers ---------------------------------------------------------
PIDCHK=$(chkID --pi ${PI} \
  --project ${PROJECT} \
  --dir-project ${DIR_PROJECT} \
  --pidstr ${PIDSTR})
if [[ ${PIDCHK} != "ID GOOD" ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] ${PIDCHK}"
  exit 1
fi

# Check inputs -----------------------------------------------------------------
if [[ -z ${INPUT_DCM} ]]; then
  INPUT_DCM=${DIR_PROJECT}/sourcedata/${PIDSTR}_dicom.zip
  if [[ ! -f ${INPUT_DCM} ]]; then
    echo "ERROR [TKNI:${FCN_NAME}] Expected input DICOM not found, please specify"
    echo "    Could not find: ${INPUT_DCM}"
    exit 1
  fi
fi

# get DICOM extracted or set folder in order to find MRS later on --------------
mkdir -p ${DIR_SCRATCH}
if [[ -d "${INPUT_DCM}" ]]; then
  if [[ ${VERBOSE} == "true" ]]; then echo "DICOM folder found"; fi
else
  FNAME="${INPUT_DCM##*/}"
  FEXT="${FNAME##*.}"
  if [[ "${FEXT,,}" != "zip" ]]; then
    echo "ERROR [TKNI:${FCN_NAME}] Input must be either a directory or zip file"
    exit 1
  fi
  mkdir -p ${DIR_SCRATCH}/dicom
  unzip -qq ${INPUT_DCM} -d ${DIR_SCRATCH}/dicom
  INPUT_DCM=${DIR_SCRATCH}/dicom
fi

# Convert DICOMS ---------------------------------------------------------------
dicomConvert --input ${INPUT_DCM} --depth 10 --dir-save ${DIR_SCRATCH}

# Autoname NIFTIs --------------------------------------------------------------
dicomAutoname --pid ${PID} --sid ${SID} --flagpair ${FLAGPAIR} \
  --dir-input ${DIR_SCRATCH} --dir-project ${DIR_PROJECT}

# Copy MRS as needed -----------------------------------------------------------
if [[ -d ${DIR_PROJECT}/rawdata/${DIRPID}/mrs ]]; then
  MRS_DAT=$(find ${DIR_SCRATCH}/ -name '*.dat' -type f)
  if [[ ${#MRS_DAT[@]} == 0 ]]; then
    echo "WARNING [TKNI:${FCN_NAME}] MRS Data not found, copy file manually"
  else
    mkdir -p ${DIR_PROJECT}/rawdata/${DIRPID}/mrs/
    for ((i=0; i<${#MRS_DAT[@]}; i++ )); do
      cp ${MRS_DAT[${i}]} ${DIR_PROJECT}/rawdata/${DIRPID}/mrs/
    done
  fi
fi
rm -rf ${DIR_SCRATCH}/dicom

# generate PNGs for QC ---------------------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  DIR_RAW=${DIR_PROJECT}/rawdata/${DIRPID}
  DLS=(anat dwi fmap func)
  for j in "${DLS[@]}"; do
    unset FLS
    FLS=($(ls ${DIR_RAW}/${j}/*.nii.gz))
    for (( i=0; i<${#FLS[@]}; i++ )); do
      MOD=$(getField -i ${FLS[${i}]} -f modality)
      if [[ ${MOD} == "qalas" ]]; then
        NV=$(3dinfo -nv ${FLS[${i}]})
        FNAME=$(getBidsBase -i ${FLS[${i}]})
        for (( k=1; k<=${NV}; k++ )); do
          ONAME=$(modField -i ${FNAME} -a -f vol -v ${k})
          make3Dpng --bg ${FLS[${i}]} --bg-volume ${k} --filename ${ONAME}
        done
      else
        make3Dpng --bg ${FLS[${i}]}
      fi
    done
  done
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0

