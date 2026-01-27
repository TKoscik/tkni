#!/bin/bash -e
#===============================================================================
# <<DESCRIPTION>>
# Authors: <GIVENNAME> <FAMILYNAME>,
# Date: <date of initial commit>
# CHANGELOG: <description of major changes to functionality>
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
OPTS=$(getopt -o hvl --long image:,mask:,dir-scratch:,\
help,verbose,no-log -n 'parse-options' -- "$@")
if [ $? != 0 ]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values for function ---------------------------------------------
IMAGE=
MASK=
VOLUME="all"
ADD_MEAN="false"
PRECISION=4
HELP=false
VERBOSE=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=1 ; shift ;;
    -l | --no-log) NO_LOG=true ; shift ;;
    --image) IMAGE="$2" ; shift 2 ;;
    --mask) MASK="$2" ; shift 2 ;;
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
  echo ''
  echo '  -h | --help              display command help'
  echo '  -l | --no-log            disable writing to output log'
  echo '  --image    <required>    NIfTI image to calculate stats for'
  echo '  --mask     <required>    binary mask indicating foreground region'
  echo '  --dir-scratch            location for temporary files'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
mkdir -p ${DIR_SCRATCH}

NV=$(niiInfo -i ${IMAGE} -f volumes)
if [[ ${VOLUME}== "all" ]]; then
  VOLUME=($(seq 0 $((${NV}-1))))
else
  VOLUME=(${VOLUME//,/ })
fi

if [[ -z ${MASK} ]]; then
  MASK=${DIR_SCRATCH}/MASK.nii.gz
  3dcalc -a ${IMAGE}[0] -expr a -overwrite -prefix ${MASK}
  niimath ${MASK} -add 1 -bin ${MASK}
fi

unset OUT
VAL_M=0
for i in "${VOLUME[@]}"; do
  TIMG=${DIR_SCRATCH}/timg.nii.gz
  DN=${DIR_SCRATCH}/denoise.nii.gz
  NZ=${DIR_SCRATCH}/noise.nii.gz
  3dcalc -a ${IMAGE}[${i}] -expr a -prefix ${TIMG}
  DenoiseImage -d 3 -n Rician -x ${MASK} -i ${TIMG} -o [${DN},${NZ}]
  STATS=($(3dROIstats -mask ${MASK} -sigma ${NZ})
  TVAL=$(printf "%.6f" ${STATS[-2]})
  if [[ ${ADD_MEAN} == "true" ]] && [[ ${NV} -gt 1 ]]; then
    VAL_M=$(echo "scale=6; (${TVAL} + ${VAL_M}) / ${#VOLUME[@]}" | bc -l)
  fi
  VAL+=($(printf "%.*f" ${PRECISION} ${TVAL}))
done
if [[ ${ADD_MEAN} == "true" ]] && [[ ${NV} -gt 1 ]]; then
  VAL+=($(printf "%.*f" ${PRECISION} ${VAL_M}))
fi
echo ${VAL[@]}

#===============================================================================
# End of Function
#===============================================================================
exit 0
