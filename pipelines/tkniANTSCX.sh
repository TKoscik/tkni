#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      ANTSCX
# DESCRIPTION:   antsCorticalThickness .sh
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-07
# README:
#     Procedure:
#     (1)
#     (2)
#     (3)
#     (4)
#     (5)
#     (6)
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
image:,mod:,template-ants:,template-dir:,\
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

IMAGE=
MASK=
MASK_DIL=2
MOD="T1w"
TEMPLATE_ANTS="OASIS"
TEMPLATE_DIR=

POST_LAB="csf,gm,wm,gmDeep,bs,crblm"

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
    --image) IMG="$2" ; shift 2 ;;
    --mod) MOD="$2" ; shift 2 ;;
    --template-ants) TEMPLATE_ANTS="$2" ; shift 2 ;;
    --template-dir) TEMPLATE_DIR="$2" ; shift 2 ;;
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
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PIPE}/anat; fi
if [[ -z ${TEMPLATE_DIR} ]]; then TEMPLATE_DIR=${TKNI_TEMPLATE}/ANTS/${TEMPLATE_ANTS}; fi
mkdir -p ${DIR_SCRATCH}

# parse image inputs -----------------------------------------------------------
if [[ -z ${IMAGE} ]]; then IMAGE=${DIR_PIPE}/anat/native/${IDPFX}_${MOD}.nii.gz; fi
if [[ -z ${MASK} ]]; then MASK=${DIR_PIPE}/anat/mask/${IDPFX}_mask-brain+tkniMALF.nii.gz; fi

ANTS_TEMPLATE="${TEMPLATE_DIR}/ANTS_${TEMPLATE_ANTS}_T1w.nii.gz"
ANTS_ROI="${TEMPLATE_DIR}/ANTS_${TEMPLATE_ANTS}_roi-brain_T1w.nii.gz"
ANTS_PROB="${TEMPLATE_DIR}/ANTS_${TEMPLATE_ANTS}_prob-brain.nii.gz"
ANTS_PRIOR="${TEMPLATE_DIR}/ANTS_${TEMPLATE_ANTS}_prior-%d.nii.gz"

## short circuit brain extraction phase
if [[ ${MASK_DIL} -gt 0 ]]; then
  ImageMath 3 ${DIR_SCRATCH}/ANTSCX_BrainExtractionMask.nii.gz MD ${MASK} ${MASK_DIL}
else
  cp ${MASK} ${DIR_SCRATCH}/ANTSCX_BrainExtractionMask.nii.gz
fi
fslmaths ${IMAGE} -mas ${MASK} ${DIR_SCRATCH}/ANTSCX_BrainExtractionBrain.nii.gz
cp ${ANTS_ROI} ${DIR_SCRATCH}/ANTSCX_ExtractedTemplateBrain.nii.gz
touch ${DIR_SCRATCH}/ANTSCX_ACTStage1Complete.txt

MOVING=${DIR_SCRATCH}/ANTSCX_BrainExtractionMask.nii.gz
FIXED=${ANTS_ROI}

antsRegistration --dimensionality 3 --float 1 --verbose 1 --random-seed 41066609 \
  --write-composite-transform 0 \
  --collapse-output-transforms 1 \
  --initialize-transforms-per-stage 0 \
  --use-histogram-matching 1 \
  --winsorize-image-intensities [ 0.005,0.995 ] \
  --output ${DIR_SCRATCH}/ANTSCX_BrainExtractionPrior \
  --initial-moving-transform [ ${FIXED},${MOVING},1 ] \
  --transform Rigid[ 0.1 ] \
    --metric Mattes[ ${FIXED},${MOVING},1,32,Regular,0.25 ] \
    --convergence [ 2000x2000x2000x2000x2000,1e-6,10 ] \
    --smoothing-sigmas 4x3x2x1x0vox \
    --shrink-factors 8x8x4x2x1 \
  --transform Affine[ 0.1 ] \
    --metric Mattes[ ${FIXED},${MOVING},1,32,Regular,0.25 ] \
    --convergence [ 2000x2000x2000x2000x2000,1e-6,10 ] \
    --smoothing-sigmas 4x3x2x1x0vox \
    --shrink-factors 8x8x4x2x1

# finish ants cortical thickness pipeline
antsCorticalThickness.sh -d 3 \
  -a ${IMAGE} \
  -e ${ANTS_TEMPLATE} \
  -m ${ANTS_PROB} \
  -p ${ANTS_PRIOR} \
  -o ${DIR_SCRATCH}/ANTSCX_

# rename and save output -------------------------------------------------------
## brain mask
mkdir -p ${DIR_SAVE}/mask/ANTSCX
mv ${DIR_SCRATCH}/ANTSCX_BrainExtractionMask.nii.gz \
  ${DIR_SAVE}/mask/ANTSCX/${IDPFX}_mask-brain-ANTSCX.nii.gz

## segmentation
mkdir -p ${DIR_SAVE}/label/ANTSCX
mv ${DIR_SCRATCH}/ANTSCX_BrainSegmentation.nii.gz \
  ${DIR_SAVE}/label/ANTSCX/${IDPFX}_label-tissue+ANTSCX.nii.gz
mv ${DIR_SCRATCH}/ANTSCX_BrainSegmentationTiledMosaic.png \
  ${DIR_SAVE}/label/ANTSCX/${IDPFX}_label-tissue+ANTSCX.png

## posteriors
mkdir mkdir -p ${DIR_SAVE}/posterior/ANTSCX
TLS=($(ls ${DIR_SCRATCH}/ANTSCX_BrainSegmentationPosteriors*.nii.gz))
POST_LAB=(${POST_LAB//,/ })
for (( i=0; i<${#TLS[@]}; i++ )); do
  PNUM=$((${i}+1))
  PLAB=${POST_LAB[${i}]}
  if [[ ${PLAB} == "" ]]; then PLAB=${PNUM}; fi
  mv ${DIR_SCRATCH}/ANTSCX_BrainSegmentationPosteriors${PNUM}.nii.gz \
    ${DIR_SAVE}/posterior/ANTSCX/${IDPFX}_posterior-${PLAB}+ANTSCX.nii.gz
done

## thickness
mkdir -p ${DIR_SAVE}/outcomes/thickness/ANTSCX
mv ${DIR_SCRATCH}/ANTSCX_CorticalThickness.nii.gz \
  ${DIR_SAVE}/outcomes/thickness/ANTSCX/${IDPFX}_thickness+ANTSCX.nii.gz
mv ${DIR_SCRATCH}/ANTSCX_CorticalThicknessTiledMosaic.png \
  ${DIR_SAVE}/outcomes/thickness/ANTSCX/${IDPFX}_thickness+ANTSCX.png

#===============================================================================
# End of Function
#===============================================================================
exit 0
