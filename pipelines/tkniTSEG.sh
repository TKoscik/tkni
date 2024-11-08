#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      Tissue Segmentation
# DESCRIPTION:   Multi-method segmentation of Cortical GM, WM, CSF. Current
#                implementation includes ANTs Atropos, MRTRIX 5ttgen (FSL),
#                and FreeSurfer (though a recon-all or recon-all-clinical run
#                must be completed outside this function).
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-15
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
image:,mask:,mask-dil:,method:,\
template-ants:,template-dir:,\
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
METHOD="ants,5tt,synth"
WEIGHT_ANTS=0
WEIGHT_5TT=0
WEIGHT_SYNTH=0
PTHRESH=0
ANTS_ATLAS="OASIS"
ANTS_DIR=
ANTS_K=3
FS_DIR=

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
mkdir -p ${DIR_SCRATCH}

# parse image inputs -----------------------------------------------------------
if [[ -z ${IMAGE} ]]; then IMAGE=${DIR_PIPE}/anat/native/${IDPFX}_T1w.nii.gz; fi
if [[ -z ${MASK} ]]; then MASK=${DIR_PIPE}/anat/mask/${IDPFX}_mask-brain.nii.gz; fi

# copy input to scratch --------------------------------------------------------
cp ${IMAGE} ${DIR_SCRATCH}/image.nii.gz
cp ${MASK} ${DIR_SCRATCH}/mask.nii.gz

# apply mask to run on brain only ----------------------------------------------
## dilate mask and apply
if [[ ${MASK_DIL} -gt 0 ]]; then
  ImageMath 3 ${DIR_SCRATCH}/mask.nii.gz \
    MD ${DIR_SCRATCH}/mask.nii.gz ${MASK_DIL}
fi
fslmaths ${DIR_SCRATCH}/image.nii.gz \
  -mas ${DIR_SCRATCH}/mask.nii.gz \
  ${DIR_SCRATCH}/image.nii.gz

# run Atropos ------------------------------------------------------------------
if [[ ${METHOD,,} == *"ants"* ]]; then
  if [[ -z ${ANTS_DIR} ]]; then
    ANTS_DIR=${TKNI_TEMPLATE}/ANTS/${ANTS_ATLAS}
  fi
  ANTS_TEMPLATE="${ANTS_DIR}/ANTS_${ANTS_ATLAS}_T1w.nii.gz"
  ANTS_ROI="${ANTS_DIR}/ANTS_${ANTS_ATLAS}_roi-brain_T1w.nii.gz"
  ANTS_PROB="${ANTS_DIR}/ANTS_${ANTS_ATLAS}_prob-brain.nii.gz"
  ANTS_PRIOR="${ANTS_DIR}/ANTS_${ANTS_ATLAS}_prior-%d+5tt.nii.gz"

  ## short circuit brain extraction phase
  mkdir -p ${DIR_SCRATCH}/antscx
  cp ${MASK} ${DIR_SCRATCH}/antscx/ANTSCX_BrainExtractionMask.nii.gz
  cp ${DIR_SCRATCH}/image.nii.gz ${DIR_SCRATCH}/antscx/ANTSCX_BrainExtractionBrain.nii.gz
  cp ${ANTS_ROI} ${DIR_SCRATCH}/antscx/ANTSCX_ExtractedTemplateBrain.nii.gz
  touch ${DIR_SCRATCH}/antscx/ANTSCX_ACTStage1Complete.txt

  MOVING=${DIR_SCRATCH}/antscx/ANTSCX_BrainExtractionMask.nii.gz
  FIXED=${DIR_SCRATCH}/antscx/ANTSCX_ExtractedTemplateBrain.nii.gz
  antsRegistration --dimensionality 3 --float 1 --verbose 1 --random-seed 41066609 \
    --write-composite-transform 0 \
    --collapse-output-transforms 1 \
    --initialize-transforms-per-stage 0 \
    --use-histogram-matching 1 \
    --winsorize-image-intensities [ 0.005,0.995 ] \
    --output ${DIR_SCRATCH}/antscx/ANTSCX_BrainExtractionPrior \
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

  antsCorticalThickness.sh -d 3 -a ${IMAGE} \
    -e ${ANTS_TEMPLATE} -m ${ANTS_PROB} -p ${ANTS_PRIOR} \
    -o ${DIR_SCRATCH}/antscx/ANTSCX_
  ## posteriors
  TLS=($(ls ${DIR_SCRATCH}/antscx/ANTSCX_BrainSegmentationPosteriors*.nii.gz))
  PLAB=("csf" "gm" "wm" "gmDeep")
  for (( i=0; i<${#TLS[@]}; i++ )); do
    PNUM=$((${i}+1))
    cp ${DIR_SCRATCH}/antscx/ANTSCX_BrainSegmentationPosteriors${PNUM}.nii.gz \
      ${DIR_SCRATCH}/posterior-${PLAB[${i}]}+ANTS.nii.gz
  done
  ImageMath 3 ${DIR_SCRATCH}/label-tissue+ANTS.nii.gz MostLikely ${PTHRESH} \
    ${DIR_SCRATCH}/posterior-gm+ANTS.nii.gz \
    ${DIR_SCRATCH}/posterior-gmDeep+ANTS.nii.gz \
    ${DIR_SCRATCH}/posterior-wm+ANTS.nii.gz \
    ${DIR_SCRATCH}/posterior-csf+ANTS.nii.gz
  # calculate weights for averaging
  if [[ ${WEIGHT_ANTS} -eq 0 ]]; then WEIGHT_ANTS=1; fi
fi

# run 5TT ----------------------------------------------------------------------
if [[ ${METHOD,,} == *"5tt"* ]]; then
  mkdir ${DIR_SCRATCH}/5tt
  mrconvert ${DIR_SCRATCH}/image.nii.gz ${DIR_SCRATCH}/5tt/image.mif
  5ttgen fsl ${DIR_SCRATCH}/5tt/image.mif ${DIR_SCRATCH}/5tt/posterior-5TT.mif -premasked
  mrconvert ${DIR_SCRATCH}/5tt/posterior-5TT.mif ${DIR_SCRATCH}/5tt/posterior-5TT.nii.gz

  antsApplyTransforms -d 3 -e 3 -n Linear \
    -i ${DIR_SCRATCH}/5tt/posterior-5TT.nii.gz \
    -o ${DIR_SCRATCH}/5tt/posterior-5TT.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz \
    -t identity
  ## get Tissue probability maps as separate files
  fslsplit ${DIR_SCRATCH}/5tt/posterior-5TT.nii.gz ${DIR_SCRATCH}/5tt/tvol -t
  mv ${DIR_SCRATCH}/5tt/tvol0000.nii.gz ${DIR_SCRATCH}/posterior-gm+5TT.nii.gz
  mv ${DIR_SCRATCH}/5tt/tvol0001.nii.gz ${DIR_SCRATCH}/posterior-gmDeep+5TT.nii.gz
  mv ${DIR_SCRATCH}/5tt/tvol0002.nii.gz ${DIR_SCRATCH}/posterior-wm+5TT.nii.gz
  mv ${DIR_SCRATCH}/5tt/tvol0003.nii.gz ${DIR_SCRATCH}/posterior-csf+5TT.nii.gz
  ImageMath 3 ${DIR_SCRATCH}/label-tissue+5TT.nii.gz MostLikely ${PTHRESH} \
    ${DIR_SCRATCH}/posterior-gm+5TT.nii.gz \
    ${DIR_SCRATCH}/posterior-gmDeep+5TT.nii.gz \
    ${DIR_SCRATCH}/posterior-wm+5TT.nii.gz \
    ${DIR_SCRATCH}/posterior-csf+5TT.nii.gz
  if [[ ${WEIGHT_5TT} -eq 0 ]]; then WEIGHT_5TT=1; fi
fi

# run SynthSeg -----------------------------------------------------------------
## if freesurfer directory doesn't exist run recon-all-clinical
if [[ ${METHOD,,} == *"synth"* ]]; then
  mkdir ${DIR_SCRATCH}/synthseg
  mri_synthseg --i ${DIR_SCRATCH}/image.nii.gz \
    --o ${DIR_SCRATCH}/synthseg/label-tissue+synth.nii.gz \
    --post ${DIR_SCRATCH}/synthseg/posterior-synth.nii.gz \
    --robust --threads 4 --cpu
  antsApplyTransforms -d 3 -n MultiLabel \
    -i ${DIR_SCRATCH}/synthseg/label-tissue+synth.nii.gz \
    -o ${DIR_SCRATCH}/synthseg/label-tissue+synth.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz -t identity
  antsApplyTransforms -d 3 -e 3 -n Linear \
    -i ${DIR_SCRATCH}/synthseg/posterior-synth.nii.gz \
    -o ${DIR_SCRATCH}/synthseg/posterior-synth.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz -t identity
  fslsplit ${DIR_SCRATCH}/synthseg/posterior-synth.nii.gz ${DIR_SCRATCH}/synthseg/tvol -t
  ## CSF
  fslmaths ${DIR_SCRATCH}/synthseg/tvol0003.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0004.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0011.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0012.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0016.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0021.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0022.nii.gz \
    ${DIR_SCRATCH}/posterior-csf+synth.nii.gz
  ## GM
  fslmaths ${DIR_SCRATCH}/synthseg/tvol0002.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0006.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0014.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0015.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0018.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0020.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0024.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0029.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0030.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0032.nii.gz \
    ${DIR_SCRATCH}/posterior-gm+synth.nii.gz
  ## WM
  fslmaths ${DIR_SCRATCH}/synthseg/tvol0001.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0005.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0013.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0019.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0023.nii.gz \
    ${DIR_SCRATCH}/posterior-wm+synth.nii.gz
  ## Deep GM
  fslmaths ${DIR_SCRATCH}/synthseg/tvol0007.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0008.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0009.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0010.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0017.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0025.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0026.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0027.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0028.nii.gz \
    -add ${DIR_SCRATCH}/synthseg/tvol0031.nii.gz \
    ${DIR_SCRATCH}/posterior-gmDeep+synth.nii.gz
  ImageMath 3 ${DIR_SCRATCH}/label-tissue+synth.nii.gz MostLikely ${PTHRESH} \
    ${DIR_SCRATCH}/posterior-gm+synth.nii.gz \
    ${DIR_SCRATCH}/posterior-gmDeep+synth.nii.gz \
    ${DIR_SCRATCH}/posterior-wm+synth.nii.gz \
    ${DIR_SCRATCH}/posterior-csf+synth.nii.gz
  if [[ ${WEIGHT_SYNTH} -eq 0 ]]; then WEIGHT_SYNTH=1; fi
fi

# Combine Posterior Maps -------------------------------------------------------
## weight posteriors
TCLASS=("csf" "gm" "gmDeep" "wm")
TWEIGHT=$(($((${WEIGHT_ANTS} + ${WEIGHT_5TT})) + ${WEIGHT_SYNTH}))
fslmaths ${DIR_SCRATCH}/image.nii.gz -mul 0 ${DIR_SCRATCH}/posterior-csf.nii.gz -odt float
cp ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_SCRATCH}/posterior-gm.nii.gz
cp ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_SCRATCH}/posterior-gmDeep.nii.gz
cp ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_SCRATCH}/posterior-wm.nii.gz
if [[ ${METHOD,,} == *"ants"* ]]; then
  for j in {0..3}; do
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}+ANTS.nii.gz \
      -mul ${WEIGHT_ANTS} -div ${TWEIGHT} \
      ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+ANTS.nii.gz
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz \
      -add ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+ANTS.nii.gz \
      ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz
  done
fi
if [[ ${METHOD,,} == *"5tt"* ]]; then
  for j in {0..3}; do
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}+5TT.nii.gz \
      -mul ${WEIGHT_5TT} -div ${TWEIGHT} \
      ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+5TT.nii.gz
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz \
      -add ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+5TT.nii.gz \
      ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz
  done
fi
if [[ ${METHOD,,} == *"synth"* ]]; then
  for j in {0..3}; do
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}+synth.nii.gz \
      -mul ${WEIGHT_SYNTH} -div ${TWEIGHT} \
      ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+synth.nii.gz
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz \
      -add ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+synth.nii.gz \
      ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz
  done
fi

# Assign Most Likely Label -----------------------------------------------------
ImageMath 3 ${DIR_SCRATCH}/label-tissue.nii.gz MostLikely ${PTHRESH} \
  ${DIR_SCRATCH}/posterior-gm.nii.gz \
  ${DIR_SCRATCH}/posterior-gmDeep.nii.gz \
  ${DIR_SCRATCH}/posterior-wm.nii.gz \
  ${DIR_SCRATCH}/posterior-csf.nii.gz

# Median filter ----------------------------------------------------------------
if [[ ${FMED} -gt 0 ]]; then
  fslmaths ${DIR_SCRATCH}/label-tissue.nii.gz \
    -kernel boxv ${FMED} -fmedian \
    ${DIR_SCRATCH}/label-tissue.nii.gz -odt char
fi

# thickness -------------------------------------------------------------------
if [[ ${NO_THICKNESS} == "false" ]]; then
  KellyKapowski -d 3 --verbose 1 \
    -s [ ${DIR_SCRATCH}/label-tissue.nii.gz,1,3 ] \
    -g ${DIR_SCRATCH}/posterior-gm.nii.gz \
    -w ${DIR_SCRATCH}/posterior-wm.nii.gz \
    -o ${DIR_SCRATCH}/thickness.nii.gz \
    -c [ 45,0.0,10 ] -r 0.025 -m 1.5 -n 10 -b 0 -t 10
  mkdir -p ${DIR_SAVE}/outcomes/thickness
  cp ${DIR_SCRATCH}/thickness.nii.gz \
    ${DIR_SAVE}/outcomes/thickness/${IDPFX}_thickness.nii.gz
  if [[ ${NO_PNG} == "false" ]]; then
    fslmaths ${DIR_SAVE}/outcomes/thickness/${IDPFX}_thickness.nii.gz \
      -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
    make3Dpng --bg ${IMAGE} --bg-threshold 5,95 \
      --fg ${DIR_SAVE}/outcomes/thickness/${IDPFX}_thickness.nii.gz \
      --fg-mask ${DIR_SCRATCH}/mask-png-fg.nii.gz \
      --fg-color "hot" --fg-cbar "true" --fg-alpha 50 \
      --layout "9:z;9:z;9:z" --offset "0,0,0" \
      --filename ${IDPFX}_thickness \
      --dir-save ${DIR_SAVE}/outcomes/thickness
  fi
fi

# save output ------------------------------------------------------------------
mkdir -p ${DIR_SAVE}/posterior/TSEG
mkdir -p ${DIR_SAVE}/label/TSEG
if [[ ${METHOD,,} == *"ants"* ]]; then
  mv ${DIR_SCRATCH}/posterior-gm+ANTS.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-gm+ANTS.nii.gz
  mv ${DIR_SCRATCH}/posterior-gmDeep+ANTS.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-gmDeep+ANTS.nii.gz
  mv ${DIR_SCRATCH}/posterior-wm+ANTS.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-wm+ANTS.nii.gz
  mv ${DIR_SCRATCH}/posterior-csf+ANTS.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-csf+ANTS.nii.gz
  mv ${DIR_SCRATCH}/label-tissue+ANTS.nii.gz \
    ${DIR_SAVE}/label/TSEG/${IDPFX}_label-tissue+ANTS.nii.gz
fi
if [[ ${METHOD,,} == *"5tt"* ]]; then
  mkdir -p ${DIR_SAVE}/posterior/5TT
  mv ${DIR_SCRATCH}/posterior-gm+5TT.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-gm+5TT.nii.gz
  mv ${DIR_SCRATCH}/posterior-gmDeep+5TT.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-gmDeep+5TT.nii.gz
  mv ${DIR_SCRATCH}/posterior-wm+5TT.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-wm+5TT.nii.gz
  mv ${DIR_SCRATCH}/posterior-csf+5TT.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-csf+5TT.nii.gz
  mv ${DIR_SCRATCH}/5tt/posterior-5TT.nii.gz \
    ${DIR_SAVE}/posterior/5TT/${IDPFX}_posterior-5TT.nii.gz
fi
if [[ ${METHOD,,} == *"synth"* ]]; then
  mv ${DIR_SCRATCH}/posterior-gm+synth.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-gm+synth.nii.gz
  mv ${DIR_SCRATCH}/posterior-gmDeep+synth.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-gmDeep+synth.nii.gz
  mv ${DIR_SCRATCH}/posterior-wm+synth.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-wm+synth.nii.gz
  mv ${DIR_SCRATCH}/posterior-csf+synth.nii.gz \
    ${DIR_SAVE}/posterior/TSEG/${IDPFX}_posterior-csf+synth.nii.gz
  mv ${DIR_SCRATCH}/synthseg/label-tissue+synth.nii.gz \
    ${DIR_SAVE}/label/TSEG/${IDPFX}_label-tissue+synth.nii.gz
fi

cp ${DIR_SCRATCH}/posterior-gm.nii.gz \
  ${DIR_SAVE}/posterior/${IDPFX}_posterior-gm.nii.gz
cp ${DIR_SCRATCH}/posterior-gmDeep.nii.gz \
  ${DIR_SAVE}/posterior/${IDPFX}_posterior-gmDeep.nii.gz
cp ${DIR_SCRATCH}/posterior-wm.nii.gz \
  ${DIR_SAVE}/posterior/${IDPFX}_posterior-wm.nii.gz
cp ${DIR_SCRATCH}/posterior-csf.nii.gz \
  ${DIR_SAVE}/posterior/${IDPFX}_posterior-csf.nii.gz
cp ${DIR_SCRATCH}/label-tissue.nii.gz \
  ${DIR_SAVE}/label/${IDPFX}_label-tissue.nii.gz
fslmerge -t ${DIR_SAVE}/posterior/${IDPFX}_posterior-tissue.nii.gz \
  ${DIR_SCRATCH}/posterior-gm.nii.gz \
  ${DIR_SCRATCH}/posterior-gmDeep.nii.gz \
  ${DIR_SCRATCH}/posterior-wm.nii.gz \
  ${DIR_SCRATCH}/posterior-csf.nii.gz


if [[ ${NO_PNG} == "false" ]]; then
  ROIS=("gm" "gmDeep" "wm" "csf")
  CBARS=("#000000,#7b0031,#6a5700,#008a3c,#00a7b2,#b9afff"\
         "#000000,#1c4400,#006360,#0075e7,#ff49d9,#ffa277"\
         "#000000,#003f5f,#9e009f,#e32f00,#a19b00,#00d292"\
         "#000000,#4c3900,#036700,#008587,#7e8eff,#ff97d8"\
         "#000000,#00433e,#005c97,#d700c5,#ff6714,#b8c100"\
         "#000000,#6b0076,#b3002e,#867800,#00ad67,#00cbe2"\
         "#000000,#7b0031,#9400b9,#0082a1,#00ac83,#b8c100"\
         "#000000,#1c4400,#765200,#e4008d,#ae7dff,#00cbe2"\
         "#000000,#003f5f,#006457,#628100,#de8000,#ff97d8"\
         "#000000,#4c3900,#ae005c,#b428ff,#00a6c2,#00d292"\
         "#000000,#00433e,#3d6200,#a66a00,#ff53ba,#b9afff"\
         "#000000,#6b0076,#005f80,#00876f,#8ba100,#ffa277")
  for (( i=0; i<${#ROIS[@]}; i++ )); do
    ROI=${ROIS[${i}]}
    fslmaths ${DIR_SAVE}/posterior/${IDPFX}_posterior-${ROI}.nii.gz \
     -thr 0.2 -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
    make3Dpng --bg ${IMAGE} --bg-threshold 5,95 \
      --fg ${DIR_SAVE}/posterior/${IDPFX}_posterior-${ROI}.nii.gz \
      --fg-mask ${DIR_SCRATCH}/mask-png-fg.nii.gz \
      --fg-color ${CBARS[${i}]} --fg-cbar "true" --fg-alpha 50 \
      --layout "9:z;9:z;9:z" --offset "0,0,0" \
      --filename ${IDPFX}_posterior-${ROI} \
      --dir-save ${DIR_SAVE}/posterior
  done
  fslmaths ${DIR_SAVE}/label/${IDPFX}_label-tissue.nii.gz \
    -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
  make3Dpng --bg ${IMAGE} \
    --fg ${DIR_SAVE}/label/${IDPFX}_label-tissue.nii.gz \
    --fg-color "#000000,#FF0000,#00FF00,#0000FF,#FFFF00" \
    --fg-cbar "true" --fg-alpha 75 \
	--layout "9:z;9:z;9:z" --offset "0,0,0" \
    --filename ${IDPFX}_label-tissue \
    --dir-save ${DIR_SAVE}/label
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0



