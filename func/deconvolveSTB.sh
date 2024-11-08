#!/bin/bash -e
#===============================================================================
# Deconvolution for Task fMRI
#  Results in Beta Coefficients, F-statistics, and R-squared values for each
#  effect
# Authors: Lauren Hopkins, Timothy R. Koscik
# Date: 2024-11/08
# CHANGELOG:
# - simplified to a less flexible approach from prior deconvolution function
#===============================================================================
PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
FCN_NAME=($(basename "$0"))
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S%N)
OPERATOR=$(whoami)
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
OPTS=$(getopt -o hvlp --long prefix:,\
ts:,mask:,st-onset:,method:,\
hrf:,poly:,goforit:,\
dir-save:,dir-scratch:,\
help,verbose,no-log,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values for function ---------------------------------------------
PREFIX=
TS=
MASK=
ST_ONSET=
METHOD="LSA"
HRF="SPMG1"
POLY="A"
GOFORIT=0

DIR_SAVE=
DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${OPERATOR}_${DATE_SUFFIX}

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=1 ; shift ;;
    -l | --no-log) NO_LOG=true ; shift ;;
    -p | --no-png) NO_PNG=true ; shift ;;
    --prefix) PREFIX="$2" ; shift 2 ;;
    --ts) TS="$2" ; shift 2 ;;
    --mask) MASK="$2" ; shift 2 ;;
    --st-onset) ST_ONSET="$2" ; shift 2 ;;
    --method) METHOD="$2" ; shift 2 ;;
    --hrf) HRFL="$2" ; shift 2 ;;
    --poly) POLY="$2" ; shift 2 ;;
    --goforit) GOFORIT="$2" ; shift 2 ;;
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
  echo '  -h | --help              display command help'
  echo '  -l | --no-log            disable writing to output log'
  echo '  --prefix  <optional>     filename, without extension to use for file'
  echo '  --other                  other inputs as needed'
  echo '  --dir-save               location to save output'
  echo '  --dir-scratch            location for temporary files'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================

# check if input files exist ---------------------------------------------------
if [[ -z ${TS} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] TS must be specified. ABORTING"
  exit 1
fi
if [[ ! -f ${TS} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] TS does not exist. ABORTING"
  exit 2
fi

if [[ -n ${MASK} ]]; then
  if [[ ! -f ${MASK} ]]; then
    echo "ERROR [TKNI:${FCN_NAME}] MASK does not exist. ABORTING"
    exit 3
  fi
fi

# setup output file prefix and directories -------------------------------------
if [[ -z "${PREFIX}" ]]; then PREFIX=$(getBidsBase -s -i ${TS}); fi
if [[ -z "${DIR_SAVE}" ]]; then DIR_SAVE=$(dirname ${TS}); fi
mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_SAVE}

# parse onsets -----------------------------------------------------------------
ST_ONSET=(${ST_ONSET//,/ })
if [[ ! -f ${ST_ONSET} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] ONSET file, ${ST_ONSET} does not exist. ABORTING"
  exit 4
fi

# Write 3dDeconvolve Function --------------------------------------------------
DCONV_FCN="3dDeconvolve"
DCONV_FCN="${DCONV_FCN} -input ${TS}"
DCONV_FCN="${DCONV_FCN} -polort ${POLY}"
DCONV_FCN="${DCONV_FCN} -num_stimts ${N_FX}"
for (( i=0; i<${N_FX}; i++ )); do
  N=$((${i} + 1))
  DCONV_FCN="${DCONV_FCN} -stim_times_FSL ${N} ${FX_ONSET[${i}]} '${HRF}'"
  DCONV_FCN="${DCONV_FCN} -stim_label ${N} ${FX_NAME[${i}]}"
done
DCONV_FCN="${DCONV_FCN} -x1D ${DIR_SCRATCH}/${PREFIX}_xmat.1D"
DCONV_FCN="${DCONV_FCN} -xjpeg ${DIR_SCRATCH}/${PREFIX}_xmat.png"
if [[ -n ${MASK} ]]; then
  DCONV_FCN="${DCONV_FCN} -mask ${MASK}"
fi
if [[ ${GOFORIT} -gt 0 ]]; then
  DCONV_FCN="${DCONV_FCN} -GOFORIT ${GOFORIT}"
fi

if [[ "${METHOD^^}" == "LSS" ]]; then
  DCONV_FCN="${DCONV_FCN} -x1d_stop"
elif [[ "${METHOD^^}" == "LSA" ]]; then
  DCONV_FCN="${DCONV_FCN} -nofullf_atall -nobucket"
  DCONV_FCN="${DCONV_FCN} -cbucket ${DIR_SCRATCH}/${PREFIX}_method-LSA_stbs.nii.gz"
fi
echo ${DCONV_FCN}

# run 3dDeconvolve function -----------------------------------------------------
eval ${DCONV_FCN}

# run 3dLSS method if selected --------------------------------------------------
if [[ "${METHOD^^}" == "LSS" ]]; then
  LSS_FCN="3dLSS"
  LSS_FCN="${LSS_FCN} -matrix ${DIR_SCRATCH}/${PREFIX}_xmat.1D"
  LSS_FCN="${LSS_FCN} -input ${TS}"
  if [[ -n ${MASK} ]]; then
    LSS_FCN="${LSS_FCN} -mask ${MASK}"
  fi
  LSS_FCN="${LSS_FCN} -prefix ${DIR_SCRATCH}/${PREFIX}_method-LSS_stbs.nii.gz"
  echo ${LSS_FCN}
  eval ${LSS_FCN}
fi

# make pngs of resulting coefficients ------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  for (( i=0; i<${N_FX}; i++ )); do
*********************
  NB=($(cat ${DIR_DWI}/preproc/dwi/${IDPFX}_dwi.bval))
  N10=$((${#NB[@]} / 10))
  N1=$(($((${#NB[@]} % 10)) - 1))
  TLAYOUT="10"
  for (( i=1; i<${N10}; i++ )) { TLAYOUT="${TLAYOUT};10"; }
  if [[ ${N1} -gt 0 ]]; then TLAYOUT="${TLAYOUT};${N1}"; fi
  echo 1
  make4Dpng --fg ${DIR_DWI}/preproc/dwi/${IDPFX}_dwi.nii.gz \
    --fg-mask ${DIR_DWI}/preproc/mask/${IDPFX}_mask-brain+b0.nii.gz \
    --fg-color "timbow" --fg-alpha 100 --fg-thresh "2.5,97.5" --layout "${TLAYOUT}"
  done
fi

# save output to appropriate location ------------------------------------------
mv ${DIR_SCRATCH}/${PREFIX}_* ${DIR_SAVE}/

#-------------------------------------------------------------------------------
# End of Function
#-------------------------------------------------------------------------------
exit 0

