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
ts:,mask:,fx-onset:,fx-name:,\
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
FX_ONSET=
FX_NAME=
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
    --fx-onset) FX_ONSET="$2" ; shift 2 ;;
    --fx-name) FX_NAME="$2" ; shift 2 ;;
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
FX_ONSET=(${FX_ONSET//,/ })
N_FX=${#FX_ONSET[@]}
for (( i=0; i<${N_FX}; i++ )); do
  if [[ ! -f ${FX_ONSET[${i}]} ]]; then
    echo "ERROR [TKNI:${FCN_NAME}] ONSET file, ${FX_ONSET[${i}]} does not exist. ABORTING"
    exit 4
  fi
done

if [[ -n ${FX_NAME} ]]; then
echo "wtf"
  FX_NAME=(${FX_NAME//,/ })
  if [[ ${N_FX} -gt 1 ]]; then
    if [[ ${#FX_NAME[@]} -eq 1 ]]; then
      for (( i=1; i<${N_FX}; i++ )); do
        FX_NAME[${i}]=${FX_NAME[0]}
      done
    fi
  fi
else
  for (( i=0; i<${N_FX}; i++ )); do
    FX_NAME[${i}]="FX${i}"
  done
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
DCONV_FCN="${DCONV_FCN} -fout -rout -bucket ${DIR_SCRATCH}/bucket.nii.gz"
echo ${DCONV_FCN}

# run 3dDeconvolve function -----------------------------------------------------
eval ${DCONV_FCN}

## split bucket into rationally named files
3dTsplit4D -prefix ${DIR_SCRATCH}/tmp.nii.gz ${DIR_SCRATCH}/bucket.nii.gz
TLS=($(ls ${DIR_SCRATCH}/tmp.*.nii.gz))
mv ${TLS[0]} ${DIR_SCRATCH}/${PREFIX}_full_R2.nii.gz
mv ${TLS[1]} ${DIR_SCRATCH}/${PREFIX}_full_F.nii.gz
for (( i=0; i<${N_FX}; i++ )); do
  unset NC NR NF
  NC=$(echo "scale=0; (${i} * 3) + 2" | bc -l)
  NR=$((${NC} + 1))
  NF=$((${NC} + 2))
  mv ${TLS[${NC}]} ${DIR_SCRATCH}/${PREFIX}_effect-${FX_NAME[${i}]}_coef.nii.gz
  mv ${TLS[${NR}]} ${DIR_SCRATCH}/${PREFIX}_effect-${FX_NAME[${i}]}_R2.nii.gz
  mv ${TLS[${NF}]} ${DIR_SCRATCH}/${PREFIX}_effect-${FX_NAME[${i}]}_F.nii.gz
done

# make pngs of resulting coefficients ------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  for (( i=0; i<${N_FX}; i++ )); do
    niimath ${DIR_SCRATCH}/${PREFIX}_effect-${FX_NAME[${i}]}_coef.nii.gz \
      -uthr 0 ${DIR_SCRATCH}/coef_neg.nii.gz
    niimath ${DIR_SCRATCH}/${PREFIX}_effect-${FX_NAME[${i}]}_coef.nii.gz \
      -thr 0 ${DIR_SCRATCH}/coef_pos.nii.gz
    make3Dpng --bg ${DIR_SCRATCH}/coef_neg.nii.gz \
      --bg-color "timbow:hue=#0000FF:lum=85,0:cyc=0:" \
      --bg-cbar \
      --fg ${DIR_SCRATCH}/coef_pos.nii.gz \
      --fg-color "timbow:hue=#FF0000:lum=0,85:cyc=0:" \
      --fg-alpha 50 \
      --layout "9:z;9:z;9:z" \
      --edge-clip 0 \
      --filename ${PREFIX}_effect-${FX_NAME[${i}]}_coef
  done
fi

# save output to appropriate location ------------------------------------------
mv ${DIR_SCRATCH}/${PREFIX}_* ${DIR_SAVE}/

#-------------------------------------------------------------------------------
# End of Function
#-------------------------------------------------------------------------------
exit 0

