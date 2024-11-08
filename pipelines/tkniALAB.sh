#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      ALAB
# DESCRIPTION:   TKNI Anatomical Labelling
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
FCN_NAME=${FCN_NAME%.*}
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
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,\
id:,dir-id:,\
image:,mod:,mask:,moving-dil:,fixed-dil:,no-premask,mask-restrict,\
template-prefix:,template-dir:,n-exemplar:,template_lab:,labels:,\
no-jac,\
dir-scratch:,dir-save:,\
help,verbose -n 'parse-options' -- "$@")
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
DIR_SCRATCH=
DIR_SAVE=
IDPFX=
IDDIR=

IMAGE=
MASK=
MOD="T1w"

MALF_ATLAS="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz"
MALF_MASK="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_mask-brain.nii.gz"
MALF_EXEMPLAR="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-1_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-2_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-3_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-4_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-5_T1w.nii.gz"
MALF_LABELS="DKT,wmparc,hcpmmp1,cerebellum,hippocampus"
#MALF_LABELS="a2009s,DKTatlas,aparc,wmparc,hcpmmp1,cerebellum,hippocampus,subcortical"
# NOTE: MALF Labels must be in the same folder and differ form exemplar filenames by replacing the modality (e.g., T1w) with label-LABELNAME.nii.gz
MALF_NAME="HCPYAX"
MALF_DIL=2
MALF_ATLAS_DIL=2
MALF_MASKAPPLY="true"
MALF_MASKRESTRICT="syn"

MTTSEG_METHOD="ants,5tt,synth"
MTTSEG_ATLAS="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_T1w.nii.gz"
MTTSEG_ROI="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_roi-brain_T1w.nii.gz"
MTTSEG_PROB="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_prob-brain.nii.gz"
MTTSEG_PRIOR="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_prior-%d+5tt.nii.gz"
MTTSEG_K=3
MTTSEG_WEIGHTANTS=0
MTTSEG_WEIGHT5TT=0
MTTSEG_WEIGHTSYNTH=0
MTTSEG_PTHRESH=0
MTTSEG_DIL=2
MTTSEG_FMED=3

REFINE_LABELS="DKT,wmparc,hcpmmp1"
REFINE_DIL=5
REFINE_FMED=3

NO_JAC="false"
NO_THICKNESS="false"
NO_VOLUME="false"

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image) IMG="$2" ; shift 2 ;;
    --mod) MOD="$2" ; shift 2 ;;
    --mask) MASK="$2" ; shift 2 ;;
    --moving-dil) MOVING_DIL="$2" ; shift 2 ;;
    --fixed-dil) FIXED_DIL="$2" ; shift 2 ;;
    --no-premask) MASK_APPLY="false" ; shift ;;
    --mask-restrict) MASK_RESTRICT="$2" ; shift 2 ;;
    --template-prefix) TEMPLATE_PFX="$2" ; shift 2 ;;
    --template-dir) TEMPLATE_DIR="$2" ; shift 2 ;;
    --n-exemplar) TEMPLATE_NEX="$2" ; shift 2 ;;
    --template-label) TEMPLATE_LABEL="$2" ; shift 2 ;;
    --no-jac) NO_JAC="true" ; shift ;;
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
# General Preparation ==========================================================
# Set Project Defaults ---------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] PI not provided"
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
  DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi
mkdir -p ${DIR_SCRATCH}

# Check ID ---------------------------------------------------------------------
if [[ -z ${IDPFX} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] ID Prefix not provided"
  exit 1
fi
if [[ -z ${IDDIR} ]]; then
  TSUB=$(getField -i ${IDPFX} -f sub)
  TSES=$(getField -i ${IDPFX} -f ses)
  IDDIR=sub-${TSUB}
  if [[ -n ${TSES} ]]; then IDDIR="${IDDIR}/ses-${TSES}"; fi
fi

# Set Up Directories -----------------------------------------------------------
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPELINE}
if [[ -z ${DIR_ANAT} ]]; then DIR_ANAT=${DIR_PIPE}/anat; fi
if [[ -z ${DIR_XFM} ]]; then DIR_XFM=${DIR_PIPE}/xfm/${IDDIR}; fi
DIR_PREP=${DIR_PIPE}/prep/${IDDIR}/${FCN_NAME}
mkdir -p ${DIR_PREP}

## Gather Inputs ---------------------------------------------------------------
if [[ -z ${IMAGE} ]]; then IMAGE=${DIR_ANAT}/native/${IDPFX}_${MOD}.nii.gz; fi
if [[ -z ${MASK} ]]; then MASK=${DIR_ANAT}/mask/${IDPFX}_mask-brain.nii.gz; fi
cp ${IMAGE} ${DIR_SCRATCH}/image.nii.gz
cp ${MASK} ${DIR_SCRATCH}/mask.nii.gz

# MALF =========================================================================
## Gather Atlas Inputs - -------------------------------------------------------
cp ${MALF_ATLAS} ${DIR_SCRATCH}/malf_atlas_orig.nii.gz
cp ${MALF_ATLAS} ${DIR_SCRATCH}/malf_atlas.nii.gz
cp ${MALF_MASK} ${DIR_SCRATCH}/malf_mask_orig.nii.gz
cp ${MALF_MASK} ${DIR_SCRATCH}/malf_mask.nii.gz
MALF_EXEMPLAR=(${MALF_EXEMPLAR//,/ })
MALF_NEX=${#MALF_EXEMPLAR[@]}
for (( i=0; i<${MALF_NEX}; i++ )); do
  cp ${MALF_EXEMPLAR[${i}]} ${DIR_SCRATCH}/malf_exemplar_${i}.nii.gz
done
if [[ -z ${MALF_LABEL} ]]; then
  TLAB=(${MALF_ATLAS//_/ })
  MALF_LABEL=${TLAB[0]}
fi

cp ${DIR_SCRATCH}/image.nii.gz ${DIR_SCRATCH}/malf_moving.nii.gz
cp ${DIR_SCRATCH}/mask.nii.gz ${DIR_SCRATCH}/malf_moving_mask.nii.gz

## Dilate Masks ----------------------------------------------------------------
if [[ ${MALF_DIL} -gt 0 ]]; then
  ImageMath 3 ${DIR_SCRATCH}/malf_moving_mask.nii.gz \
    MD ${DIR_SCRATCH}/malf_moving_mask.nii.gz ${MALF_DIL}
fi
if [[ ${TEMPLATE_DIL} -gt 0 ]]; then
  ImageMath 3 ${DIR_SCRATCH}/malf_mask.nii.gz \
    MD ${DIR_SCRATCH}/malf_mask.nii.gz ${MALF_ATLAS_DIL}
fi

## Apply Masks -----------------------------------------------------------------
if [[ ${MALF_MASKAPPLY} == "true" ]]; then
  fslmaths ${DIR_SCRATCH}/malf_moving.nii.gz \
    -mas ${DIR_SCRATCH}/malf_moving_mask.nii.gz \
    ${DIR_SCRATCH}/malf_moving.nii.gz
  fslmaths ${DIR_SCRATCH}/malf_atlas.nii.gz \
    -mas ${DIR_SCRATCH}/malf_mask.nii.gz \
    ${DIR_SCRATCH}/malf_atlas.nii.gz
  for (( i=0; i<${MALF_NEX}; i++ )); do
    fslmaths ${DIR_SCRATCH}/malf_exemplar_${i}.nii.gz \
      -mas ${DIR_SCRATCH}/malf_mask.nii.gz \
      ${DIR_SCRATCH}/malf_exemplar_${i}.nii.gz
  done
fi

## Multi-Exemplar Normalization ------------------------------------------------
### Generate Normalization Function
MOVING=${DIR_SCRATCH}/malf_moving.nii.gz
MOVING_MASK=${DIR_SCRATCH}/malf_moving_mask.nii.gz
FIXED=${DIR_SCRATCH}/malf_atlas.nii.gz
FIXED_MASK=${DIR_SCRATCH}/malf_mask.nii.gz
FIXED_EXEMPLAR=($(ls ${DIR_SCRATCH}/malf_exemplar_*.nii.gz))
ANTSCALL="antsRegistration --dimensionality 3"
ANTSCALL="${ANTSCALL} --output ${DIR_SCRATCH}/xfm_"
ANTSCALL="${ANTSCALL} --write-composite-transform 0"
ANTSCALL="${ANTSCALL} --collapse-output-transforms 1"
ANTSCALL="${ANTSCALL} --initialize-transforms-per-stage 0"
ANTSCALL="${ANTSCALL} --initial-moving-transform [${FIXED},${MOVING},1]"
ANTSCALL="${ANTSCALL} --transform Rigid[0.1]"
ANTSCALL="${ANTSCALL} --metric Mattes[${FIXED},${MOVING},1,32,Regular,0.25]"
if [[ "${MALF_MASKRESTRICT,,}" == *"rigid"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MALF_MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [1200x1200x100,1e-6,5]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 2x1x0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 4x2x1"
ANTSCALL="${ANTSCALL} --transform Affine[0.25]"
ANTSCALL="${ANTSCALL} --metric Mattes[${FIXED},${MOVING},1,32,Regular,0.25]"
if [[ "${MALF_MASKRESTRICT,,}" == *"affine"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MALF_MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [200x20,1e-6,5]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 1x0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 2x1"
ANTSCALL="${ANTSCALL} --transform SyN[0.2,3,0]"
for (( i=0; i<${MALF_NEX}; i++ )); do
  ANTSCALL="${ANTSCALL} --metric CC[${FIXED_EXEMPLAR[${i}]},${MOVING},1,4]"
done
if [[ "${MALF_MASKRESTRICT,,}" == *"syn"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MALF_MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [100x70x50x20,1e-6,10]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 3x2x1x0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 8x4x2x1"
ANTSCALL="${ANTSCALL} --use-histogram-matching 1"
ANTSCALL="${ANTSCALL} --winsorize-image-intensities [0.005,0.995]"
ANTSCALL="${ANTSCALL} --float 1"
if [[ ${VERBOSE} == "true" ]]; then
  ANTSCALL="${ANTSCALL} --verbose 1"
else
  ANTSCALL="${ANTSCALL} --verbose 0"
fi
ANTSCALL="${ANTSCALL} --random-seed 41066609"
if [[ ${VERBOSE} == "true" ]]; then echo ${ANTSCALL}; fi

### Run Normalizations Function
eval ${ANTSCALL}

## Apply Transforms ------------------------------------------------------------
XFM_AFFINE=${DIR_SCRATCH}/xfm_0GenericAffine.mat
XFM_AFFINE_INV="[${DIR_SCRATCH}/xfm_0GenericAffine.mat,1]"
XFM_SYN=${DIR_SCRATCH}/xfm_1Warp.nii.gz
XFM_SYN_INV=${DIR_SCRATCH}/xfm_1InverseWarp.nii.gz
## normalized anatomical image
antsApplyTransforms -d 3 -n BSpline[3] \
  -i ${DIR_SCRATCH}/image.nii.gz \
  -o ${DIR_PREP}/normalized.nii.gz \
  -r ${DIR_SCRATCH}/malf_atlas_orig.nii.gz \
  -t identity -t ${XFM_SYN} -t ${XFM_AFFINE}
if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == "false" ]]; then
  make3Dpng \
    --bg ${DIR_SCRATCH}/malf_atlas_orig.nii.gz \
      --bg-color "#000000,#00FF00,#FFFFFF" --bg-thresh "2.5,97.5" \
    --fg ${DIR_PREP}/normalized.nii.gz \
      --fg-thresh "2.5,97.5" --fg-color "#000000,#FF00FF,#FFFFFF" \
      --fg-alpha 50 --fg-cbar "false" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --offset "0,0,0" \
    --filename ${IDPFX}_from-native_to-${MALF_NAME}_overlay \
    --dir-save ${DIR_PREP}
  make3Dpng --bg ${DIR_PREP}/normalized.nii.gz --bg-threshold "2.5,97.5" \
    --filename ${IDPFX}_reg-${MALF_NAME}_${MOD}
fi
## MALF brain mask to native space
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${DIR_SCRATCH}/malf_mask_orig.nii.gz \
  -o ${DIR_PREP}/${IDPFX}_mask-brain+${FCN_NAME}.nii.gz \
  -r ${DIR_SCRATCH}/image.nii.gz \
  -t identity -t ${XFM_AFFINE_INV} -t ${XFM_SYN_INV}
if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == "false" ]]; then
  make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz \
    --fg ${DIR_PREP}/${IDPFX}_mask-brain+${FCN_NAME}.nii.gz \
    --fg-color "#FF0000" --fg-alpha 50 --fg-cbar "false" \
    --layout "11:x;11:x;11:x" --offset "0,0,0" \
    --filename ${IDPFX}_mask-brain+tkniALAB \
    --dir-save ${DIR_PREP}
fi

## Joint Label Fusion ----------------------------------------------------------
MALF_LABELS=(${MALF_LABELS//,/ })
### push exemplars to native space
for (( i=0; i<${MALF_NEX}; i++ )); do
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${DIR_SCRATCH}/malf_exemplar_${i}.nii.gz \
    -o ${DIR_SCRATCH}/malf_exemplar_${i}_native.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz \
    -t identity -t ${XFM_AFFINE_INV} -t ${XFM_SYN_INV}
done
for (( i=0; i<${#MALF_LABELS[@]}; i++ )); do
  LAB=${MALF_LABELS[${i}]}
  for (( j=0; j<${MALF_NEX}; j++ )); do
    TD=$(dirname ${MALF_EXEMPLAR[${j}]})
    TB=$(getBidsBase -i ${MALF_EXEMPLAR[${j}]} -s)
    TF="${TD}/${TB}_label-${LAB}.nii.gz"
    antsApplyTransforms -d 3 -n MultiLabel \
      -i ${TF} \
      -o ${DIR_SCRATCH}/malf_exemplar_${j}_label-${LAB}.nii.gz \
      -r ${DIR_SCRATCH}/image.nii.gz \
      -t identity -t ${XFM_AFFINE_INV} -t ${XFM_SYN_INV}
  done
  JLFCALL="antsJointFusion --image-dimensionality 3"
  if [[ ${VERBOSE} == "true" ]]; then
    JLFCALL="${JLFCALL} --verbose 1"
  else
    JLFCALL="${JLFCALL} --verbose 0"
  fi
  JLFCALL="${JLFCALL} --target-image ${DIR_SCRATCH}/image.nii.gz"
  JLFCALL="${JLFCALL} --output ${DIR_PREP}/${IDPFX}_label-${LAB}+MALF.nii.gz"
  for (( j=0; j<${MALF_NEX}; j++ )); do
    JLFCALL="${JLFCALL} --atlas-image ${DIR_SCRATCH}/malf_exemplar_${j}_native.nii.gz"
    JLFCALL="${JLFCALL} --atlas-segmentation ${DIR_SCRATCH}/malf_exemplar_${j}_label-${LAB}.nii.gz"
  done
  JLFCALL="${JLFCALL} --alpha 0.1 --beta 2.0"
  JLFCALL="${JLFCALL} --constrain-nonnegative 0"
  JLFCALL="${JLFCALL} --patch-radius 2"
  JLFCALL="${JLFCALL} --patch-metric PC"
  JLFCALL="${JLFCALL} --search-radius 3"
  if [[ ${VERBOSE} == "true" ]]; then echo ${JLFCALL}; fi
  eval ${JLFCALL}
  #${DIR_ANAT}/label/MALF/${IDPFX}_label-${LAB}+MALF.nii.gz

  if [[ ${NO_PNG} == "false" ]]; then
    make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
      --fg ${DIR_PREP}/${IDPFX}_label-${LAB}+MALF.nii.gz \
        --fg-color "timbow" --fg-order random --fg-discrete \
        --fg-cbar "false" --fg-alpha 50 \
      --layout "7:x;7:x;7:y;7:y;7:z;7:z" --offset "0,0,0" \
      --filename ${IDPFX}_label-${LAB}+MALF \
      --dir-save ${DIR_PREP}
  fi
  display ${DIR_PREP}/${IDPFX}_label-${LAB}+MALF.png &
done

## REMOVE MALF objects ---------------------------------------------------------
rm ${DIR_SCRATCH}/malf*

# Multi-Tool Tissue Segmentation ===============================================
MTTSEG_IMAGE=${DIR_SCRATCH}/mttseg_image.nii.gz
MTTSEG_MASK=${DIR_SCRATCH}/mttseg_mask.nii.gz
cp ${DIR_SCRATCH}/image.nii.gz ${MTTSEG_IMAGE}
cp ${DIR_SCRATCH}/mask.nii.gz ${MTTSEG_MASK}
### Dilate Masks
if [[ ${MTTSEG_DIL} -gt 0 ]]; then
  ImageMath 3 ${MTTSEG_MASK} MD ${MTTSEG_MASK} ${MTTSEG_DIL}
fi
### Apply Masks
fslmaths ${MTTSEG_IMAGE} -mas ${MTTSEG_MASK} ${MTTSEG_IMAGE}

## ANTs Cortical Thickness (short circuit brain extraction phase) --------------
if [[ ${MTTSEG_METHOD,,} == *"ants"* ]]; then
#  if [[ -z ${MTTSEG_ANTSDIR} ]]; then
#    MTTSEG_ANTSDIR=${TKNI_TEMPLATE}/ANTS/${MTTSEG_ANTSATLAS}
#  fi
#  ANTS_TEMPLATE="${MTTSEG_ANTSDIR}/ANTS_${MTTSEG_ANTSATLAS}_T1w.nii.gz"
#  ANTS_ROI="${MTTSEG_ANTSDIR}/ANTS_${MTTSEG_ANTSATLAS}_roi-brain_T1w.nii.gz"
#  ANTS_PROB="${MTTSEG_ANTSDIR}/ANTS_${MTTSEG_ANTSATLAS}_prob-brain.nii.gz"
#  ANTS_PRIOR="${MTTSEG_ANTSDIR}/ANTS_${MTTSEG_ANTSATLAS}_prior-%d+5tt.nii.gz"

  ## short circuit brain extraction phase
  mkdir -p ${DIR_SCRATCH}/antscx
  cp ${MTTSEG_MASK} ${DIR_SCRATCH}/antscx/ANTSCX_BrainExtractionMask.nii.gz
  cp ${MTTSEG_IMAGE} ${DIR_SCRATCH}/antscx/ANTSCX_BrainExtractionBrain.nii.gz
  cp ${MTTSEG_ROI} ${DIR_SCRATCH}/antscx/ANTSCX_ExtractedTemplateBrain.nii.gz
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

  antsCorticalThickness.sh -d 3 -a ${DIR_SCRATCH}/image.nii.gz \
    -e ${MTTSEG_ATLAS} -m ${MTTSEG_PROB} -p ${MTTSEG_PRIOR} \
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

## 5TT Segmentation ------------------------------------------------------------
if [[ ${MTTSEG_METHOD,,} == *"5tt"* ]]; then
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

## SynthSeg --------------------------------------------------------------------
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

## Combine Posteriors ----------------------------------------------------------
### Weighted Average Posterior - - - - - - - - - - - - - - - - - - - - - - - - -
TCLASS=("csf" "gm" "gmDeep" "wm")
TWEIGHT=$(($((${MTTSEG_WEIGHTANTS} + ${MTTSEG_WEIGHT5TT})) + ${MTTSEG_WEIGHTSYNTH}))
fslmaths ${DIR_SCRATCH}/image.nii.gz -mul 0 ${DIR_SCRATCH}/posterior-csf.nii.gz -odt float
cp ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_SCRATCH}/posterior-gm.nii.gz
cp ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_SCRATCH}/posterior-gmDeep.nii.gz
cp ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_SCRATCH}/posterior-wm.nii.gz
if [[ ${METHOD,,} == *"ants"* ]]; then
  for j in {0..3}; do
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}+ANTS.nii.gz \
      -mul ${MTTSEG_WEIGHTANTS} -div ${TWEIGHT} \
      ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+ANTS.nii.gz
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz \
      -add ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+ANTS.nii.gz \
      ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz
  done
fi
if [[ ${METHOD,,} == *"5tt"* ]]; then
  for j in {0..3}; do
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}+5TT.nii.gz \
      -mul ${MTTSEG_WEIGHT5TT} -div ${TWEIGHT} \
      ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+5TT.nii.gz
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz \
      -add ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+5TT.nii.gz \
      ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz
  done
fi
if [[ ${METHOD,,} == *"synth"* ]]; then
  for j in {0..3}; do
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}+synth.nii.gz \
      -mul ${MTTSEG_WEIGHTSYNTH} -div ${TWEIGHT} \
      ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+synth.nii.gz
    fslmaths ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz \
      -add ${DIR_SCRATCH}/weight-${TCLASS[${j}]}+synth.nii.gz \
      ${DIR_SCRATCH}/posterior-${TCLASS[${j}]}.nii.gz
  done
fi

### Most Likely Label - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
ImageMath 3 ${DIR_SCRATCH}/label-tissue.nii.gz MostLikely ${PTHRESH} \
  ${DIR_SCRATCH}/posterior-gm.nii.gz \
  ${DIR_SCRATCH}/posterior-gmDeep.nii.gz \
  ${DIR_SCRATCH}/posterior-wm.nii.gz \
  ${DIR_SCRATCH}/posterior-csf.nii.gz

### Median Filter - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
if [[ ${MTTSEG_FMED} -gt 0 ]]; then
  fslmaths ${DIR_SCRATCH}/label-tissue.nii.gz \
    -kernel boxv ${MTTSEG_FMED} -fmedian \
    ${DIR_SCRATCH}/label-tissue.nii.gz -odt char
fi

## Move results to Prep folder -------------------------------------------------
mv ${DIR_SCRATCH}/posterior-gm.nii.gz ${DIR_PREP}/${IDPFX}_posterior-gm.nii.gz
mv ${DIR_SCRATCH}/posterior-gmDeep.nii.gz ${DIR_PREP}/${IDPFX}_posterior-gmDeep.nii.gz
mv ${DIR_SCRATCH}/posterior-wm.nii.gz ${DIR_PREP}/${IDPFX}_posterior-wm.nii.gz
mv ${DIR_SCRATCH}/posterior-csf.nii.gz ${DIR_PREP}/${IDPFX}_posterior-csf.nii.gz
mv ${DIR_SCRATCH}/label-tissue.nii.gz ${DIR_PREP}/${IDPFX}_label-tissue.nii.gz
fslmerge -t ${DIR_PREP}/${IDPFX}_posterior-tissue.nii.gz \
  ${DIR_PREP}/${IDPFX}_posterior-gm.nii.gz \
  ${DIR_PREP}/${IDPFX}_posterior-gmDeep.nii.gz \
  ${DIR_PREP}/${IDPFX}_posterior-wm.nii.gz \
  ${DIR_PREP}/${IDPFX}_posterior-csf.nii.gz

## generate PNGs ---------------------------------------------------------------
if [[ ${NO_PNG} == "false" ]]; then
  ROIS=("gm" "gmDeep" "wm" "csf")
  CBARS=("#000000,#7b0031,#6a5700,#008a3c,#00a7b2,#b9afff"\
         "#000000,#1c4400,#006360,#0075e7,#ff49d9,#ffa277"\
         "#000000,#003f5f,#9e009f,#e32f00,#a19b00,#00d292"\
         "#000000,#4c3900,#036700,#008587,#7e8eff,#ff97d8")
  for (( i=0; i<${#ROIS[@]}; i++ )); do
    ROI=${ROIS[${i}]}
    fslmaths ${DIR_PREP}/${IDPFX}_posterior-${ROI}.nii.gz \
     -thr 0.2 -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
    make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz --bg-threshold 2.5,97.5 \
      --fg ${DIR_PREP}/${IDPFX}_posterior-${ROI}.nii.gz \
      --fg-mask ${DIR_SCRATCH}/mask-png-fg.nii.gz \
      --fg-color ${CBARS[${i}]} --fg-cbar "true" --fg-alpha 50 \
      --layout "9:z;9:z;9:z" --offset "0,0,0" \
      --filename ${IDPFX}_posterior-${ROI} \
      --dir-save ${DIR_PREP}
  done
  fslmaths ${DIR_PREP}/${IDPFX}_label-tissue.nii.gz \
    -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
  make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz --bg-threshold 2.5,97.5 \
    --fg ${DIR_PREP}/${IDPFX}_label-tissue.nii.gz \
    --fg-color "#000000,#FF0000,#00FF00,#0000FF,#FFFF00" \
    --fg-cbar "true" --fg-alpha 75 \
	--layout "9:z;9:z;9:z" --offset "0,0,0" \
    --filename ${IDPFX}_label-tissue \
    --dir-save ${DIR_PREP}
fi

# Refine Labels ================================================================
## Label Isolation by Tissue Class ---------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "Extracting Tissue Labels"; fi

REFINE_LABELS=(${REFINE_LABELS//,/ })
mkdir -p ${DIR_SCRATCH}/refine
for (( i=0; i<${#REFINE_LABELS[@]}; i++ )); do
  TLABEL=${DIR_PREP}/${IDPFX}_label-${REFINE_LABELS[${i}]}+MALF.nii.gz
  VAL_GM="1000:2999,17:18,53:54"
  if [[ ${LABEL} == *"aparc.a2009s"* ]]; then VAL_GM="11000,17:18,53:54"; fi
  VAL_WM="2,41,251:255"
  if [[ ${LABEL} == *"wmparc"* ]]; then VAL_WM="3000:5002,251:255"; fi
  VAL_KEEP="7:8,10:13,16,26,28,46:47,49:52,58,60"

  MASK_GM=${DIR_SCRATCH}/refine/mask_gm.nii.gz
  MASK_WM=${DIR_SCRATCH}/refine/mask_wm.nii.gz
  MASK_KEEP=${DIR_SCRATCH}/refine/mask_keep.nii.gz
  MASK_NA=${DIR_SCRATCH}/refine/mask_na.nii.gz
  fslmaths ${TLABEL} -mul 0 ${MASK_GM} -odt char
  cp ${MASK_GM} ${MASK_WM}
  cp ${MASK_GM} ${MASK_KEEP}
  cp ${MASK_GM} ${MASK_NA}
  VAL_GM=(${VAL_GM//,/ })
  for (( i=0; i<${#VAL_GM[@]}; i++ )); do
    TV=${VAL_GM[${i}]}
    TV=(${TV//:/ })
    fslmaths ${TLABEL} -thr ${TV[0]} -uthr ${TV[-1]} \
      -bin -add ${MASK_GM} ${MASK_GM} -odt char
  done

  VAL_WM=(${VAL_WM//,/ })
  for (( i=0; i<${#VAL_WM[@]}; i++ )); do
    TV=${VAL_WM[${i}]}
    TV=(${TV//:/ })
    fslmaths ${TLABEL} -thr ${TV[0]} -uthr ${TV[-1]} \
      -bin -add ${MASK_WM} ${MASK_WM} -odt char
  done

  VAL_KEEP=(${VAL_KEEP//,/ })
  for (( i=0; i<${#VAL_KEEP[@]}; i++ )); do
    TV=${VAL_KEEP[${i}]}
    TV=(${TV//:/ })
    fslmaths ${TLABEL} -thr ${TV[0]} -uthr ${TV[-1]} \
      -bin -add ${MASK_KEEP} ${MASK_KEEP} -odt char
  done

  fslmaths ${MASK_GM} -add ${MASK_WM} -add ${MASK_KEEP} \
    -binv -mul ${LABEL} -bin ${MASK_NA} -odt char
  LABEL_GM=${DIR_SCRATCH}/refine/label_gm.nii.gz
  LABEL_WM=${DIR_SCRATCH}/refine/label_wm.nii.gz
  LABEL_KEEP=${DIR_SCRATCH}/refine/label_keep.nii.gz
  LABEL_NA=${DIR_SCRATCH}/refine/label_na.nii.gz
  fslmaths ${LABEL} -mas ${MASK_GM} ${LABEL_GM}
  fslmaths ${LABEL} -mas ${MASK_WM} ${LABEL_WM}
  fslmaths ${LABEL} -mas ${MASK_KEEP} ${LABEL_KEEP}
  fslmaths ${LABEL} -mas ${MASK_NA} ${LABEL_NA}

  ## Dilate Masks and Labels ---------------------------------------------------
  ## dilate tissue mask, then propagate labels through it
  MASK_GM_DIL=${DIR_SCRATCH}/refine/mask_gm_dil.nii.gz
  MASK_WM_DIL=${DIR_SCRATCH}/refine/mask_wm_dil.nii.gz
  LABEL_GM_DIL=${DIR_SCRATCH}/refine/label_gm_dil.nii.gz
  LABEL_WM_DIL=${DIR_SCRATCH}/refine/label_wm_dil.nii.gz
  ImageMath 3 ${MASK_GM_DIL} MD ${MASK_GM} ${REFINE_DIL}
  ImageMath 3 ${MASK_WM_DIL} MD ${MASK_WM} ${REFINE_DIL}
  ImageMath 3 ${LABEL_GM_DIL} PropagateLabelsThroughMask ${MASK_GM_DIL} ${LABEL_GM} ${REFINE_DIL} 0
  ImageMath 3 ${LABEL_WM_DIL} PropagateLabelsThroughMask ${MASK_WM_DIL} ${LABEL_WM} ${REFINE_DIL} 0

  ## Apply Segmentation Masks to Dilated Labels --------------------------------
  MASK_GM_SEG=${DIR_SCRATCH}/refine/mask_gm_seg.nii.gz
  MASK_WM_SEG=${DIR_SCRATCH}/refine/mask_wm_seg.nii.gz
  REFINE_GM=${DIR_SCRATCH}/refine/label_gm_refine.nii.gz
  REFINE_WM=${DIR_SCRATCH}/refine/label_wm_refine.nii.gz
  fslmaths ${DIR_PREP}/${IDPFX}_label-tissue.nii.gz -thr 1 -uthr 1 -bin ${MASK_GM_SEG} -odt char
  fslmaths ${DIR_PREP}/${IDPFX}_label-tissue.nii.gz -thr 3 -uthr 3 -bin ${MASK_WM_SEG} -odt char
  fslmaths ${LABEL_GM_DIL} -mas ${MASK_GM_SEG} ${REFINE_GM}
  fslmaths ${LABEL_WM_DIL} -mas ${MASK_WM_SEG} ${REFINE_WM}

  ## Label Recombination -------------------------------------------------------
  ## make sure NON GM or WM voxels interfere or add to refined WM and GM labels
  REFINE_NA=${DIR_SCRATCH}/refine/label_na_refine.nii.gz
  REFINED=${DIR_SCRATCH}/refine/label_refine.nii.gz
  ## get mask of labels to be untouched
  fslmaths ${MASK_KEEP} -binv ${MASK_KEEP} -odt char
  fslmaths ${REFINE_GM} -add ${REFINE_WM} -mas ${MASK_KEEP} -add ${LABEL_KEEP} ${REFINED}
  fslmaths ${REFINED} -binv -mul ${TLABEL} ${REFINE_NA}
  fslmaths ${REFINED} -add ${REFINE_NA} ${REFINED}

  ## Median Filter -------------------------------------------------------------
  if [[ ${REFINE_FMED} -gt 0 ]]; then
    fslmaths ${REFINED} -kernel boxv ${REFINE_FMED} -fmedian ${REFINED}
  fi

  ## Move refined labels to Prep ,subcorticalfolder ----------------------------------------
  NEWLAB=$(getField -i ${TLABEL} -f label)
  NEWLAB=(${NEWLAB//+/ })
  NEWLAB="${NEWLAB}+REFINE"
  NEWNAME=$(modField -i $(getBidsBase -i ${LABEL}) -r -f label)
  NEWNAME=$(modField -i $(getBidsBase -i ${NEWNAME}) -a -f label -v ${NEWLAB})
  mv ${REFINED} ${DIR_PREP}/${NEWNAME}.nii.gz
done

## Outcomes ====================================================================
### Calculate Jacobian Determinants --------------------------------------------
if [[ ${NO_JAC} == "false" ]]; then
  XFM_NORIGID=${DIR_SCRATCH}/xfm_norigid.mat
  AverageAffineTransformNoRigid 3 ${XFM_NORIGID} -i ${XFM_AFFINE}
  mapJacobian --prefix ${IDPFX} \
    --xfm "${XFM_SYN},${XFM_RIGID}" \
    --ref-image ${DIR_SCRATCH}/malf_atlas_orig.nii.gz \
    --from "native" --to ${MALF_NAME} \
    --dir-save ${DIR_PROJECT}/derivatives/${PIPELINE}/anat/outcomes
fi

### Cortical Thickness ---------------------------------------------------------
if [[ ${NO_THICKNESS} == "false" ]]; then
  KellyKapowski -d 3 --verbose 1 \
    -s [ ${DIR_PREP}/label-tissue.nii.gz,1,3 ] \
    -g ${DIR_PREP}/posterior-gm.nii.gz \
    -w ${DIR_PREP}/posterior-wm.nii.gz \
    -o ${DIR_PREP}/thickness.nii.gz \
    -c [ 45,0.0,10 ] -r 0.025 -m 1.5 -n 10 -b 0 -t 10

  if [[ ${NO_PNG} == "false" ]]; then
    fslmaths ${DIR_PREP}/thickness.nii.gz \
      -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
    make3Dpng --bg ${IMAGE} --bg-threshold 5,95 \
      --fg ${DIR_PREP}/thickness.nii.gz \
      --fg-mask ${DIR_SCRATCH}/mask-png-fg.nii.gz \
      --fg-color "hot" --fg-cbar "true" --fg-alpha 50 \
      --layout "9:z;9:z;9:z" --offset "0,0,0" \
      --filename ${IDPFX}_thickness \
      --dir-save ${DIR_PREP}
  fi
fi

### Volumetrics ----------------------------------------------------------------
#MALF_LABELS="a2009s,DKTatlas,aparc,wmparc,hcpmmp1,cerebellum,hippocampus,subcortical"
#REFINE_LABELS="a2009s,DKTatlas,aparc,wmparc,hcpmmp1"
for (( i=0; i<${#MALF_LABELS[@]}; i++ )); do
  TLABEL=${DIR_PREP}/${IDPFX}_label-${REFINE_LABELS[${i}]}+MALF.nii.gz
  if [[ -f ${DIR_PREP}/${IDPFX}_label-${MALF_LABELS[${i}]}+REFINE.nii.gz ]]; then
    TLABEL=${DIR_PREP}/${IDPFX}_label-${REFINE_LABELS[${i}]}+REFINE.nii.gz
  fi
  LABNAME=$(getField -i ${TLABEL} -f label)
  LABNAME=(${LABNAME//\+/ })
  LABNAME=${LABNAME[0]}
  if [[ -f ${TKNIPATH}/lut/lut-${LABNAME}.tsv ]]; then
    summarize3D --label ${TLABEL} \
      --prefix ${IDPFX} \
      --stats volume \
      --lut ${TKNIPATH}/lut/lut-${LABNAME}.tsv
  fi
done

### Generate Save Directory Structure ------------------------------------------
mkdir -p ${DIR_ANAT}/label/MALF
mkdir -p ${DIR_ANAT}/label/REFINE
mkdir -p ${DIR_ANAT}/reg_${TEMPLATE_LABEL}
mkdir -p ${DIR_XFM}
mkdir -p ${DIR_SAVE}/outcomes/thickness

### Save files to appropriate locations ----------------------------------------
### save XFMs
mv ${DIR_SCRATCH}/xfm_0GenericAffine.mat \
  ${DIR_XFM}/${IDPFX}_from-native_to-${MALF_NAME}_xfm-affine.mat
mv ${DIR_SCRATCH}/xfm_1Warp.nii.gz \
  ${DIR_XFM}/${IDPFX}_from-native_to-${MALF_NAME}_xfm-syn.nii.gz
mv ${DIR_SCRATCH}/xfm_1InverseWarp.nii.gz \
  ${DIR_XFM}/${IDPFX}_from-native_to-${MALF_NAME}_xfm-syn+inverse.nii.gz

### save normalized anatomical
# ${DIR_PREP}/${IDPFX}_reg-${TEMPLATE_LABEL}_${MOD}.nii.gz
mv ${DIR_PREP}/normalized.nii.gz \
  ${DIR_ANAT}/reg_${MALF_NAME}/${IDPFX}_reg-${MALF_NAME}_${MOD}.nii.gz
mv ${DIR_PREP}/${IDPFX}_mask-brain+${FCN_NAME}.nii.gz \
  ${DIR_ANAT}/mask/${IDPFX}_mask-brain+${FCN_NAME}.nii.gz

### save labels and make final copies
for (( i=0; i<${#MALF_LABELS[@]}; i++ )); do
  if [[ -f ${DIR_PREP}/${IDPFX}_label-${MALF_LABELS[${i}]}+REFINE.nii.gz ]]; then
    cp ${DIR_PREP}/${IDPFX}_label-${MALF_LABELS[${i}]}+REFINE.nii.gz \
      ${DIR_ANAT}/label/${IDPFX}_label-${MALF_LABELS[${i}]}.nii.gz
    mv ${DIR_PREP}/${IDPFX}_label-${MALF_LABELS[${i}]}+REFINE.nii.gz \
      ${DIR_ANAT}/label/REFINE/${IDPFX}_label-${MALF_LABELS[${i}]}+REFINE.nii.gz
  else
    cp ${DIR_PREP}/${IDPFX}_label-${MALF_LABELS[${i}]}+MALF.nii.gz \
      ${DIR_ANAT}/label/${IDPFX}_label-${MALF_LABELS[${i}]}.nii.gz
  fi
  mv ${DIR_PREP}/${IDPFX}_label-${MALF_LABELS[${i}]}+MALF.nii.gz \
    ${DIR_ANAT}/label/MALF/${IDPFX}_label-${MALF_LABELS[${i}]}+MALF.nii.gz
done

cp ${DIR_SCRATCH}/thickness.nii.gz \
  ${DIR_SAVE}/outcomes/thickness/${IDPFX}_thickness.nii.gz

### Summarize Results ----------------------------------------------------------
### Generate RMD ---------------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  mkdir -p ${DIR_PIPE}/qc
  RMD=${DIR_PROJECT}/qc/${IDPFX}_${FCN_NAME}_${DATE_SUFFIX}.Rmd

   echo -e '---\ntitle: "&nbsp;"\noutput: html_document\n---\n' > ${RMD}
  echo '```{r setup, include=FALSE}' >> ${RMD}
  echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
  echo 'knitr::include_graphics("'${TKNIPATH}'/TK_BRAINLab_logo.png")' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, echo=FALSE}' >> ${RMD}
  echo 'library(DT)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '# Neuroanatomy' >> ${RMD}
  echo '## Multi-Atlas Normalization and Label Fusion Refined by Tissue Class' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}



#===============================================================================
# End of Function
#===============================================================================
exit 0
