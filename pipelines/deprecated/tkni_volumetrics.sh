#!/bin/bash -e
#===============================================================================
# Run TK_BRAINLab Anatomical Preprocessing Pipeline for EVANDERPLAS UNITCALL
# Freesurfer's recon-all-clinical.sh pipeline is required
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
pid:,sid:,aid:,print-color:,dir-scratch:,\
help,verbose -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=evanderplas
PROJECT=unitcall
PIPELINE=tkni
DIR_PROJECT=/data/x/projects/${PI}/${PROJECT}
DIR_SCRATCH=${TKNI_SCRATCH}/${PROC_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
PID=
SID=
AID=
PRINT_CLR="coolRainbow"
HELP=false
VERBOSE=false
NO_PNG=false
if [[ -z ${NSLOTS} ]]; then
  THREADS=4
fi

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --pid) PID="$2" ; shift 2 ;;
    --sid) SID="$2" ; shift 2 ;;
    --aid) AID="$2" ; shift 2 ;;
    --print-color) PRINT_CLR="$2" ; shift 2 ;;
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
  echo '  --pid              participant identifier'
  echo '  --sid              session identifier'
  echo '  --aid              assessment identifier'
  echo '  --print-color      filament color for 3D brain printing,'
  echo '                       default="coolRainbow"'
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  NO_LOG=true
  exit 0
fi

## process newest participant or set identifiers -------------------------------
if [[ -z ${PID} ]]; then
  PIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f participant_id))
  SIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f session_id))
  AIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f assessment_id))
  PID=${PIDLS[-1]}
  SID=${SIDLS[-1]}
  AID=${AIDLS[-1]}
fi
PIDSTR=sub-${PID}_ses-${SID}_aid-${AID}
DIRPID=sub-${PID}/ses-${SID}

# set directories --------------------------------------------------------------
DIR_RAW=${DIR_PROJECT}/rawdata/${DIRPID}
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPELINE}
DIR_ANAT=${DIR_PIPE}/anat
DIR_FS=${DIR_PROJECT}/derivatives/fsSynth/fs
if [[ ! -d ${DIR_FS}/${PIDSTR} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] Freesurfer fsSynth run not detected, check"
  exit 1
fi
mkdir -p ${DIR_PROJECT}/summary
mkdir -p ${DIR_ANAT}/native
mkdir -p ${DIR_ANAT}/native_raw
mkdir -p ${DIR_ANAT}/native_synth
mkdir -p ${DIR_ANAT}/label
mkdir -p ${DIR_ANAT}/mask
mkdir -p ${DIR_ANAT}/surface

# Convert to NIFTI -------------------------------------------------------------
mri_convert ${DIR_FS}/${PIDSTR}/mri/native.mgz \
  ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz \
  -o ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz \
  -r ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz \
  -t identity

mri_convert ${DIR_FS}/${PIDSTR}/mri/synthSR.raw.mgz \
  ${DIR_ANAT}/native_synth/${PIDSTR}_synthT1w.nii.gz
antsApplyTransforms -d 3 -n BSpline[3] \
  -i ${DIR_ANAT}/native_synth/${PIDSTR}_synthT1w.nii.gz \
  -o ${DIR_ANAT}/native_synth/${PIDSTR}_synthT1w.nii.gz \
  -r ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz \
  -t identity

LABLS=("aparc.a2009s+aseg" "aparc.DKTatlas+aseg" "aparc+aseg" "wmparc")
for (( i=0; i<${#LABLS[@]}; i ++ )); do 
  LAB=${LABLS[${i}]}
  mri_convert ${DIR_FS}/${PIDSTR}/mri/${LAB}.mgz \
    ${DIR_ANAT}/label/${PIDSTR}_label-${LAB}.nii.gz
  antsApplyTransforms -d 3 -n MultiLabel \
    -i ${DIR_ANAT}/label/${PIDSTR}_label-${LAB}.nii.gz \
    -o ${DIR_ANAT}/label/${PIDSTR}_label-${LAB}.nii.gz \
    -r ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz \
    -t identity
done

# create masks -----------------------------------------------------------------
fslmaths ${DIR_ANAT}/label/${PIDSTR}_label-wmparc.nii.gz \
  -thr 24 -uthr 24 -binv \
  -mul ${DIR_ANAT}/label/${PIDSTR}_label-wmparc.nii.gz -bin \
  ${DIR_ANAT}/mask/${PIDSTR}_mask-brain.nii.gz

# create surface ---------------------------------------------------------------
mri_tessellate ${DIR_ANAT}/mask/${PIDSTR}_mask-brain.nii.gz 1 \
  ${DIR_ANAT}/surface/${PIDSTR}_tmp
mris_convert ${DIR_ANAT}/surface/${PIDSTR}_tmp \
  ${DIR_ANAT}/surface/${PIDSTR}_color-${SURF_CLR}_surface-brain.stl
rm ${DIR_ANAT}/surface/${PIDSTR}_tmp

# clean up native image --------------------------------------------------------
ricianDenoise --no-png \
  --image ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz \
  --dir-save ${DIR_ANAT}/native
mv ${DIR_ANAT}/native/${PIDSTR}_prep-denoise_T1w.nii.gz \
  ${DIR_ANAT}/native/${PIDSTR}_T1w.nii.gz
  
# summarize output -------------------------------------------------------------
LABLS=("aparc.a2009s+aseg" "aparc.DKTatlas+aseg" "aparc+aseg" "wmparc")
for (( i=0; i<${#LABLS[@]}; i ++ )); do 
  LAB=${LABLS[${i}]}
  summarize3D --stats volume \
    --label ${DIR_ANAT}/label/${PIDSTR}_label-${LAB}.nii.gz \
    --lut ${TKNI_LUT}/lut-${LAB}.tsv
done

# make PNGs --------------------------------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  make3Dpng --bg ${DIR_ANAT}/native/${PIDSTR}_T1w.nii.gz
  make3Dpng --bg ${DIR_ANAT}/native_raw/${PIDSTR}_T1w.nii.gz
  make3Dpng --bg ${DIR_ANAT}/native_synth/${PIDSTR}_synthT1w.nii.gz
  
  make3Dpng --bg ${DIR_ANAT}/native/${PIDSTR}_T1w.nii.gz \
    --fg ${DIR_ANAT}/mask/${PIDSTR}_mask-brain.nii.gz \
    --fg-color "#FF0000" --fg-alpha 50 --fg-cbar "false" \
    --layout "11:x;11:x;11:x" --offset "0,0,0" \
    --filename ${PIDSTR}_mask-brain \
    --dir-save ${DIR_ANAT}/mask

  LABLS=("aparc.a2009s+aseg" "aparc.DKTatlas+aseg" "aparc+aseg" "wmparc")
  for (( j=0; j<${#LABLS[@]}; j ++ )); do
    LAB=${LABLS[${i}]}
    make3Dpng --bg ${DIR_ANAT}/native/${PIDSTR}_T1w.nii.gz \
      --fg ${DIR_ANAT}/label/${PIDSTR}_label-${LAB}.nii.gz \
      --fg-color "timbow" --fg-order "random" --fg-alpha 50 --fg-cbar "false" \
      --layout "11:y;11:y;11:y" --offset "0,0,0" \
      --filename ${PIDSTR}_label-${LAB} \
      --dir-save ${DIR_ANAT}/label
  done
fi


#===============================================================================
# End of Function
#===============================================================================
exit 0



