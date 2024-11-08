#!/bin/bash -e
#===============================================================================
# Deconvolution for Task fMRI
#   Results in F-statistics
# Authors: Lauren Hopkins, Timothy R. Koscik
# Date: 2021-03-10
# CHANGELOG:
# - Need LSA/LSS method options (needs to go to 3dLSS, and I don't see it,
#   perhaps thats been deprecated in AFNI?). should default to LSA (no extra
#   3dLSS).
# - need -x1d output for 3dLSS
# - Can we simplify inputs to default saving what is need for LSS, set toggles
#   appropriately
# - for multi-run tasks need function to merge time series and onset files
#   appropriately?
# - stim-times-im does not appear to be implemented, but is necessary?
# - is using stim-times compatable with stim-times-im (and 3dLSS which can
#   use only 1)
#   - maybe break into separate functions? deconvolve and deconvolveSTBs
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
OPTS=$(getopt -o hvklnd --long prefix:,\
dimension:,image:,mask:,model:,shrink:,patch:,search:,\
dir-save:,dir-scratch:,\
help,fcn-verbose,verbose,keep,no-log,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values for function ---------------------------------------------
PREFIX=

TS=
MASK=
STIM_ONSET=
STIM_NAME=
RMODEL="SPMG1"
HNULL_POLY="A"
GOFORIT=0

3dDeconvolve -input ${TS} \
  -polort ${HNULL_POLY} \
  -num_stimts ${STIM_N} \

  -stim_times_FSL ${i} ${STIM_ONSET[${i}]} '${RMODEL}' \  # these two lines need to be
    -stim_label ${i} ${STIM_NAME[${i}]} \                 # looped based on the # of conditions
  -x1D ${DIR_SCRATCH}/${PREFIX}_xmat.1D" \
    -xjpeg ${DIR_SCRATCH}/${PREFIX}_xmat.png \
  -mask ${MASK} \
  -GOFORIT ${GOFORIT} \
  -fout \
  -rout \
  -cbucket ${DIR_SCRATCH}/${PREFIX}_coefficients.nii.gz



decon_fcn="3dDeconvolve"
decon_fcn="${decon_fcn} -input ${BOLD_TS}"
decon_fcn="${decon_fcn} -polort ${POLORT}"
decon_fcn="${decon_fcn} -num_stimts ${N_STIM}"
if [[ "${STIM_TIMES_IM}" == "false" ]]; then
  if [[ "${FSL_STIMS}" == "true" ]]; then
    for (( i=0; i<${N_STIM}; i++ )); do
      STIM_NUM=`expr $i + 1`
      decon_fcn="${decon_fcn} -stim_times_FSL ${STIM_NUM} ${STIMULI[${i}]} 'dmUBLOCK(1)' -stim_label ${STIM_NUM} ${STIM_NAMES[${i}]}"
    done
  elif [[ "${CONVERT_FSL}" == "true" ]]; then
    for (( i=0; i<${N_STIM}; i++ )); do
      STIM_NUM=`expr $i + 1`
      decon_fcn="${decon_fcn} -stim_times ${STIM_NUM} ${STIMULI[${i}]} 'BLOCK(2,1)' -stim_label ${STIM_NUM} ${STIM_NAMES[${i}]}"
    done
  fi
  decon_fcn="${decon_fcn} -x1D ${DIR_SCRATCH}/${PREFIX}_x1D"
else
# stim_times_IM
# IMPORTANT NOTE: cant do stim_times and stim_times_IM in same 3ddeconvolve call
  if [[ "${FSL_STIMS}" == "true" ]]; then
    for (( i=0; i<${N_STIM}; i++ )); do
      IM_NUM=`expr $i + 1`
      decon_fcn="${decon_fcn} -stim_times_IM ${IM_NUM} ${STIMULI[${i}]} 'dmUBLOCK(1)' -stim_label ${IM_NUM} ${STIM_NAMES[${i}]}_IM"
    done
  else
    for (( i=0; i<${N_STIM}; i++ )); do
      IM_NUM=`expr $i + 1`
      decon_fcn="${decon_fcn} -stim_times_IM ${IM_NUM} ${STIMULI[${i}]} 'BLOCK(2,1)' -stim_label ${IM_NUM} ${STIM_NAMES[${i}]}_IM"
    done
  fi
  decon_fcn="${decon_fcn} -x1D ${DIR_SCRATCH}/${PREFIX}_x1D_IM"
fi

decon_fcn="${decon_fcn} -jobs ${JOBS}"
