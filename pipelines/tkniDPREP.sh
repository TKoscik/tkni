#!/bin/bash -e
#===============================================================================
# Run TKNI Diffusion Preprocessing Pipeline
# Required: MRtrix3, ANTs, FSL
# Description: # Pre-Processing
#   1. Concatenate images into MRtrix data format
#   2. Denoise
#        Estimate the spatially varying noise map
#        Veraart et al., 2016b, 2016a
#   3. Unringing
#        remove Gibb’s ringing artefacts (Kellner et al., 2016)
#   4. Motion and Distortion Correction
#        -EPI-distortion correction: suggest using a pair of opposite phase
#           ecoded B0s (Holland et al., 2010)
#        -B0-field inhomogeneity correction: FSL’s topup tool is called by
#           MRtrix (Andersson et al., 2003; Smith et al.,2004)
#        -Eddy-current and movement distortion correction: FSL’s eddy tool is
#           called by MRtrix (Andersson and Sotiropoulos, 2016)
#   5. Bias Field Correction
#        Improve brain mask estimation (Tustison et al., 2010)
#   6. Brain Mask Estimation
#        Create a binary mask of the brain. Downstream analyses will be
#        performed within that mask to improve biological plausibility of
#        streamlines and reduce computation time.
#   7. Coregistration to Anatomical
#        Remove residual distortion from anatomical space, retain DWI spacing
# Output:  1. Preprocessed DWI
#          2. Brain Mask
#          3. Mean B0
# Author: Timothy R. Koscik, PhD
# Date Created: 2023-10-31
# Date Modified:
# CHANGE_LOG:
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
id:,dir-id:,dir-anat:,dir-dwi:,dir-xfm:,\
image-dwi:,image-ap:,image-pa:,image-anat:,mask-brain:,mask-b0-method:,rpenone,\
dir-save:,dir-mrtrix:,dir-scratch:,requires:,\
help,verbose,force,no-png,no-rmd -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_SCRATCH=
DIR_ANAT=
DIR_DWI=
DIR_XFM=
DIR_MRTRIX=
DIR_SAVE=
IDPFX=
IDDIR=

IMAGE_DWI=
IMAGE_AP=
IMAGE_PA=
IMAGE_ANAT=
MASK_BRAIN=
MASK_DIL=2
MASK_BO_METHOD="mrtrix"
RPENONE="false"

PIPE=tkni
FLOW=DPREP
REQUIRES="tkniDICOM,tkniAINIT"
FORCE=false
HELP=false
VERBOSE=false
LOQUACIOUS=false
NO_PNG=false
NO_RMD=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image-dwi) IMAGE_DWI="$2" ; shift 2 ;;
    --image-ap) IMAGE_AP="$2" ; shift 2 ;;
    --image-pa) IMAGE_PA="$2" ; shift 2 ;;
    --image-anat) IMAGE_ANAT="$2" ; shift 2 ;;
    --mask-brain) MASK_BRAIN="$2" ; shift 2 ;;
    --mask-dil) MASK_DIL="$2" ; shift 2 ;;
    --mask-b0-method) MASK_B0_METHOD="$2" ; shift 2 ;;
    --rpenone) RPENONE="true" ; shift ;;
    --dir-anat) DIR_ANAT="$2" ; shift 2 ;;
    --dir-dwi) DIR_DWI="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-mrtrix) DIR_MRTRIX="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    -- ) shift ; break ;;
    * ) break ;;
  esac
done

# Usage Help -------------------------------------------------------------------
if [[ "${HELP}" == "true" ]]; then
    echo '------------------------------------------------------------------------'
    echo " TKNI Pipeline: ${PIPE}:${FLOW}"
    echo ' DESCRIPTION: DWI Preprocessing (Denoise, Unring, Eddy, Topup, Coreg)'
    echo '------------------------------------------------------------------------'
    echo ' REQUIRED ARGUMENTS:'
    echo '  --pi <name>           PI folder name (no underscores)'
    echo '  --project <name>      Project name (preferably CamelCase)'
    echo '  --id <string>         Participant identifier (BIDS prefix)'
    echo ''
    echo ' INPUT IMAGERY:'
    echo '  --image-dwi <list>    Comma-separated DWI NIfTIs (searches raw/dwi if omitted)'
    echo '  --image-ap <file>     Phase-encoding AP B0 image (for Topup)'
    echo '  --image-pa <file>     Phase-encoding PA B0 image (for Topup)'
    echo '  --image-anat <file>   Native T1w anatomical reference'
    echo '  --mask-brain <file>   Anatomical brain mask'
    echo ''
    echo ' PREPROCESSING OPTIONS:'
    echo '  --mask-b0-method <m>  B0 masking: mrtrix or afni,<clip> (default: mrtrix)'
    echo '  --mask-dil <int>      Voxels to dilate anatomical mask (default: 2)'
    echo '  --rpenone             Flag: Assume no reverse-phase encoding available'
    echo ''
    echo ' PATHING & DIRECTORIES:'
    echo '  --dir-save <path>     Directory for derivatives (default: derivatives/tkni)'
    echo '  --dir-mrtrix <path>   Directory for .mif formatted outputs'
    echo '  --dir-anat <path>     Path to anatomical inputs'
    echo '  --dir-dwi <path>      Path to DWI inputs'
    echo '  --dir-xfm <path>      Path to registration transforms'
    echo '  --dir-scratch <path>  Override default temporary workspace'
    echo ''
    echo ' PIPELINE FLAGS:'
    echo '  -h | --help           Display this help'
    echo '  -v | --verbose        Enable console logging'
    echo '  --loquacious          Enable extreme ANTs/MRtrix verbosity'
    echo '  -n | --no-png         Disable generation of QC images'
    echo '  -r | --no-rmd         Disable HTML report generation'
    echo '  --force               Force re-run and overwrite status'
    echo ''
    NO_LOG=true
    exit 0
fi


#===============================================================================
# Start of Function
#===============================================================================
if [[ ${VERBOSE} == "true" ]]; then echo "TKNI DWI Preprocessing Pipeline"; fi
if [[ ${LOQUACIOUS} == "true" ]]; then ANTS_VERBOSE=1; else ANTS_VERBOSE=0; fi

# set project defaults ---------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [${PIPE}${FLOW}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [${PIPE}${FLOW}] PROJECT must be provided"
  exit 1
fi
if [[ -z ${DIR_PROJECT} ]] && [[ -n ${DIR_SAVE} ]]; then
  DIR_PROJECT=${DIR_SAVE}
elif [[ -z ${DIR_PROJECT} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] You must set a PROJECT DIRECTORY or SAVE DIRECTORY"
  exit 1
fi
if [[ -z ${DIR_SCRATCH} ]]; then
  DIR_SCRATCH=${TKNI_SCRATCH}/${FLOW}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo "Running ${PIPE}${FLOW}"
  echo -e "PI:\t${PI}\nPROJECT:\t${PROJECT}"
  echo -e "PROJECT DIRECTORY:\t${DIR_PROJECT}"
  echo -e "SAVE DIRECTORY:\t${DIR_SAVE}"
  echo -e "SCRATCH DIRECTORY:\t${DIR_SCRATCH}"
  echo -e "Start Time:\t${PROC_START}"
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
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Process DWI images for the following participant:"
  echo -e "\tID:\t${IDPFX}"
  echo -e "\tDIR_SUBJECT:\t${IDDIR}"
fi

# Check if Prerequisites are run and QC'd --------------------------------------
if [[ ${REQUIRES} != "null" ]]; then
  REQUIRES=(${REQUIRES//,/ })
  ERROR_STATE=0
  for (( i=0; i<${#REQUIRES[@]}; i++ )); do
    REQ=${REQUIRES[${i}]}
    FCHK=${DIR_SAVE}/status/${REQ}/DONE_${REQ}_${IDPFX}.txt
    if [[ ! -f ${FCHK} ]]; then
      echo -e "${IDPFX}\n\tERROR [${PIPE}:${FLOW}] Prerequisite WORKFLOW: ${REQ} not run."
      ERROR_STATE=1
    fi
  done
  if [[ ${ERROR_STATE} -eq 1 ]]; then
    echo -e "\tABORTING [${PIPE}:${FLOW}]"
    exit 1
  fi
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> Prerequisites COMPLETE: ${REQUIRES[@]}"
fi

# Check if has already been run, and force if requested ------------------------
FCHK=${DIR_SAVE}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
FDONE=${DIR_SAVE}/status/${PIPE}${FLOW}/DONE_${PIPE}${FLOW}_${IDPFX}.txt
echo -e "${IDPFX}\n\tRUNNING [${PIPE}:${FLOW}]"
if [[ -f ${FCHK} ]] || [[ -f ${FDONE} ]]; then
  echo -e "\tWARNING [${PIPE}:${FLOW}] already run"
  if [[ "${FORCE}" == "true" ]]; then
    echo -e "\tRERUN [${PIPE}:${FLOW}]"
  else
    echo -e "\tABORTING [${PIPE}:${FLOW}] use the '--force' option to re-run"
    exit 1
  fi
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> Previous Runs CHECKED"
fi

# set project defaults ---------------------------------------------------------
if [[ -z ${MRTRIXPATH} ]]; then MRTRIXPATH=/usr/lib/mrtrix3/bin; fi
if [[ -z ${DIR_MRTRIX} ]]; then
  DIR_MRTRIX=${DIR_PROJECT}/derivatives/mrtrix/${IDDIR}
fi

# Additional default values ----------------------------------------------------
if [[ -z ${DIR_ANAT} ]]; then DIR_ANAT=${DIR_PROJECT}/derivatives/${PIPE}/anat; fi
if [[ -z ${DIR_DWI} ]]; then DIR_DWI=${DIR_PROJECT}/derivatives/${PIPE}/dwi; fi
if [[ -z ${DIR_XFM} ]]; then DIR_XFM=${DIR_PROJECT}/derivatives/${PIPE}/xfm/${IDDIR}; fi
if [[ -z ${IMAGE_ANAT} ]]; then IMAGE_ANAT=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/${IDPFX}_T1w.nii.gz; fi
if [[ ! -f ${IMAGE_ANAT} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] Anatomical image not found."
  exit 1
fi
if [[ -z ${MASK_BRAIN} ]]; then MASK_BRAIN=${DIR_PROJECT}/derivatives/${PIPE}/anat/mask/${IDPFX}_mask-brain.nii.gz; fi
if [[ ! -f ${MASK_BRAIN} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] Brain Mask image not found."
  exit 2
fi

# Locate DWI files -------------------------------------------------------------
if [[ -z ${IMAGE_DWI} ]]; then
  if ls ${DIR_PROJECT}/rawdata/${IDDIR}/dwi/${IDPFX}*dwi.nii.gz 1> /dev/null 2>&1; then
    IMAGE_DWI=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/dwi/${IDPFX}*dwi.nii.gz))
  else
    echo ">>>>>There are 0 DWI files to process, aborting"
    exit 0
  fi
else
  IMAGE_DWI=(${IMAGE_DWI//,/ })
fi
N_DWI=${#IMAGE_DWI[@]}
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>There are ${N_DWI} DWI files that will be processed"
fi

# copy all files to scratch ----------------------------------------------------
TMP_DWI=${DIR_SCRATCH}/DWI
TMP_NII=${DIR_SCRATCH}/NII
TMP_XFM=${DIR_SCRATCH}/XFM
mkdir -p ${TMP_DWI}
mkdir -p ${TMP_NII}
mkdir -p ${TMP_XFM}

for (( i=0; i<${N_DWI}; i++ )); do
  DWI=${IMAGE_DWI[${i}]}
  PFX=$(getBidsBase -i ${DWI})
  DNAME=$(dirname ${DWI})
  cp ${DNAME}/${PFX}.bval ${TMP_NII}/dwi_${i}.bval
  cp ${DNAME}/${PFX}.bvec ${TMP_NII}/dwi_${i}.bvec
  cp ${DNAME}/${PFX}.json ${TMP_NII}/dwi_${i}.json
  cp ${DWI} ${TMP_NII}/dwi_${i}.nii.gz
done
cp ${IMAGE_ANAT} ${TMP_NII}/anat.nii.gz
cp ${MASK_BRAIN} ${TMP_NII}/mask.nii.gz
IMAGE_ANAT=${TMP_NII}/anat.nii.gz
MASK_BRAIN=${TMP_NII}/mask.nii.gz

# check image dimensions and pad if uneven -------------------------------------
for (( i=0; i<${N_DWI}; i++ )); do
  c4d ${TMP_NII}/dwi_${i}.nii.gz -pad-to-multiple 2x2x2x1 0 -o ${TMP_NII}/dwi_${i}.nii.gz
done

## convert to DWI to mif -------------------------------------------------------
for (( i=0; i<${N_DWI}; i++ )); do
  mrconvert ${TMP_NII}/dwi_${i}.nii.gz ${TMP_DWI}/dwi_${i}.mif \
    -fslgrad ${TMP_NII}/dwi_${i}.bvec ${TMP_NII}/dwi_${i}.bval \
    -json_import ${TMP_NII}/dwi_${i}.json
done

## concatenate DWI -------------------------------------------------------------
if [[ ${N_DWI} -gt 1 ]]; then
  mrcat $(ls ${TMP_DWI}/dwi_*.mif) ${TMP_DWI}/dwi_raw.mif
else
  mv ${TMP_DWI}/dwi_0.mif ${TMP_DWI}/dwi_raw.mif
fi

# Denoise ----------------------------------------------------------------------
dwidenoise ${TMP_DWI}/dwi_raw.mif ${TMP_DWI}/dwi_den.mif -noise ${TMP_DWI}/noise.mif
mrcalc ${TMP_DWI}/dwi_raw.mif ${TMP_DWI}/dwi_den.mif -subtract ${TMP_DWI}/residual.mif

# Unringing --------------------------------------------------------------------
mrdegibbs ${TMP_DWI}/dwi_den.mif ${TMP_DWI}/dwi_den_unr.mif -axes 0,1
mrcalc ${TMP_DWI}/dwi_den.mif ${TMP_DWI}/dwi_den_unr.mif \
  -subtract ${TMP_DWI}/residualUnringed.mif

# Motion and Distortion Correction ---------------------------------------------
if [[ -n ${AP} ]] && [[ -n ${PA} ]]; then
  mrconvert ${AP} ${TMP_DWI}/b0_AP.mif
  mrconvert ${PA} ${TMP_DWI}/b0_PA.mif
  mrcat ${AP} ${PA} -axis 3 ${TMP_DWI}/b0_pair.mif
  dwifslpreproc ${TMP_DWI}/dwi_den_unr.mif \
    ${TMP_DWI}/dwi_den_unr_preproc.mif \
    -scratch ${DIR_SCRATCH}/dwifslpreproc-tmp \
    -nocleanup -pe_dir j -rpe_pair -se_epi ${TMP_DWI}/b0_pair.mif \
    -eddy_options " --slm=linear --data_is_shelled"
elif [[ "${RPENONE}" == "true" ]]; then
  dwifslpreproc ${TMP_DWI}/dwi_den_unr.mif \
    ${TMP_DWI}/dwi_den_unr_preproc.mif \
    -scratch ${DIR_SCRATCH}/dwifslpreproc-tmp \
    -nocleanup -rpe_none -pe_dir \
    -eddy_options " --slm=linear --data_is_shelled"
else
  dwifslpreproc ${TMP_DWI}/dwi_den_unr.mif \
    ${TMP_DWI}/dwi_den_unr_preproc.mif \
    -scratch ${DIR_SCRATCH}/dwifslpreproc-tmp \
    -nocleanup -rpe_header \
    -eddy_options " --slm=linear --data_is_shelled"
fi

## Check "dwi_post_eddy.eddy_outlier_map", where 1's represent outlier slices
## due to motion, eddy currents, or something else.
## Courtesy of Andy's Brain Book
#TDIR=$(find ${DIR_SCRATCH}/dwifslpreproc-tmp-* -maxdepth 0 -type d)
TDIR=${DIR_SCRATCH}/dwifslpreproc-tmp
N_SLICES=`mrinfo ${TDIR}/dwi.mif | grep Dimensions | awk '{print $6 * $8}'`
N_OUTLIER=`awk '{ for(i=1;i<=NF;i++)sum+=$i } END { print sum }' ${TDIR}/dwi_post_eddy.eddy_outlier_map`
echo "If >10, may have too much motion or corrupted slices"
echo "scale=5; (${N_OUTLIER} / ${N_SLICES} * 100)/1" | bc | tee ${TMP_DWI}/percentageOutliers.txt
rm ${TDIR}/*
rmdir ${TDIR}

# Bias Field Correction --------------------------------------------------------
dwibiascorrect ants ${TMP_DWI}/dwi_den_unr_preproc.mif \
  ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif \
  -bias ${TMP_DWI}/bias.mif

## extract B0 ------------------------------------------------------------------
dwiextract -bzero ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif ${TMP_DWI}/b0_all.mif
mrmath ${TMP_DWI}/b0_all.mif mean ${TMP_DWI}/b0_mean.mif -axis 3
mrconvert ${TMP_DWI}/b0_mean.mif ${TMP_NII}/b0_mean.nii.gz

# Brain Mask Estimation --------------------------------------------------------
MASK_B0_METHOD=(${MASK_B0_METHOD//,/ })
if [[ ${MASK_B0_METHOD[0],,} == "afni" ]] || [[ ${MASK_B0_METHOD[0],,} == "automask" ]]; then
  if [[ ${#MASK_B0_METHOD[@]} -gt 0 ]]; then
    CLFRAC=${MASK_B0_METHOD[1]}
  else
    CLFRAC=0.65
  fi
  3dAutomask -clfrac ${CLFRAC} -prefix ${TMP_NII}/b0_mask.nii.gz ${TMP_NII}/b0_mean.nii.gz
  mrconvert ${TMP_NII}/b0_mask.nii.gz ${TMP_DWI}/mask_den_unr_preproc_unb.mif -force
else
  dwi2mask ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif \
    ${TMP_DWI}/mask_den_unr_preproc_unb.mif
fi

# Anatomical Coregistration ----------------------------------------------------
MOVING=${TMP_NII}/b0_mean.nii.gz

## extract brain
if [[ ${MASK_DIL} -gt 0 ]]; then
  ImageMath 3 ${TMP_NII}/mask-brain_MD.nii.gz MD ${MASK_BRAIN} ${MASK_DIL}
  MASK_BRAIN=${TMP_NII}/mask-brain_MD.nii.gz
fi
niimath ${IMAGE_ANAT} -mas ${MASK_BRAIN} ${TMP_NII}/T1_roi-brain.nii.gz
FIXED=${TMP_NII}/T1_roi-brain.nii.gz

## coregister to anatomical T1w
antsRegistration \
  --dimensionality 3 \
  --output ${TMP_XFM}/xfm_ \
  --write-composite-transform 0 \
  --collapse-output-transforms 1 \
  --initialize-transforms-per-stage 0 \
  --initial-moving-transform [ ${FIXED},${MOVING},1 ] \
  --transform Rigid[ 0.1 ] \
    --metric Mattes[ ${FIXED},${MOVING},1,32,Regular,0.2 ] \
    --convergence [ 1200x1200x100,1e-6,5 ] \
    --smoothing-sigmas 2x1x0vox \
    --shrink-factors 4x2x1 \
  --transform Affine[ 0.25 ] \
    --metric Mattes[ ${FIXED},${MOVING},1,32,Regular,0.2 ] \
    --convergence [ 200x20,1e-6,5 ] \
    --smoothing-sigmas 1x0vox \
    --shrink-factors 2x1 \
  --transform SyN[ 0.2,3,0 ] \
    --metric Mattes[ ${FIXED},${MOVING},1,32 ] \
    --convergence [ 40x20x0,1e-7,8 ] \
    --smoothing-sigmas 2x1x0vox \
    --shrink-factors 4x2x1 \
  --use-histogram-matching 0 \
  --winsorize-image-intensities [ 0.005,0.995 ] \
  --float 1 \
  --verbose ${ANTS_VERBOSE} \
  --random-seed 13311800

## resample T1w to DWI spacing
DIMS_DWI=$(niiInfo -i ${TMP_NII}/b0_mean.nii.gz -f spacing)
DIMS_DWI=${DIMS_DWI// /x}
ResampleImage 3 ${FIXED} ${TMP_NII}/T1_spacing-DWI.nii.gz ${DIMS_DWI} 0 0 2
REF_IMG=${TMP_NII}/T1_spacing-DWI.nii.gz

## apply transforms to B0
antsApplyTransforms -d 3 -n Linear \
  -i ${TMP_NII}/b0_mean.nii.gz \
  -o ${TMP_NII}/b0_mean_coreg.nii.gz \
  -t identity \
  -t ${TMP_XFM}/xfm_1Warp.nii.gz \
  -t ${TMP_XFM}/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${TMP_NII}/b0_mean_coreg.nii.gz ${TMP_DWI}/b0_mean_coreg.mif -force

## apply transforms to B0 mask
mrconvert ${TMP_DWI}/mask_den_unr_preproc_unb.mif ${TMP_NII}/b0_mask.nii.gz -force
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${TMP_NII}/b0_mask.nii.gz \
  -o ${TMP_NII}/b0_mask_coreg.nii.gz \
  -t identity \
  -t ${TMP_XFM}/xfm_1Warp.nii.gz \
  -t ${TMP_XFM}/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${TMP_NII}/b0_mask_coreg.nii.gz ${TMP_DWI}/b0_mask_coreg.mif -force

## apply transforms to preprocessed DWI data
mrconvert ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif \
  ${TMP_NII}/dwi_preproc.nii.gz \
  -export_grad_fsl ${TMP_NII}/dwi_preproc.bvec ${TMP_NII}/dwi_preproc.bval -force
antsApplyTransforms -d 3 -e 3 -n Linear \
  -i ${TMP_NII}/dwi_preproc.nii.gz \
  -o ${TMP_NII}/dwi_preproc_coreg.nii.gz \
  -t identity \
  -t ${TMP_XFM}/xfm_1Warp.nii.gz \
  -t ${TMP_XFM}/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${TMP_NII}/dwi_preproc_coreg.nii.gz \
  ${TMP_DWI}/dwi_preproc_coreg.mif \
  -fslgrad ${TMP_NII}/dwi_preproc.bvec ${TMP_NII}/dwi_preproc.bval -force

# convert QC images to nifti----------------------------------------------------
mrconvert ${TMP_DWI}/bias.mif ${TMP_NII}/${IDPFX}_bias.nii.gz -force
mrconvert ${TMP_DWI}/noise.mif ${TMP_NII}/${IDPFX}_noise.nii.gz -force
mrconvert ${TMP_DWI}/residual.mif ${TMP_NII}/${IDPFX}_residual.nii.gz -force
mrconvert ${TMP_DWI}/residualUnringed.mif ${TMP_NII}/${IDPFX}_residualUnring.nii.gz -force

if [[ ${NO_PNG} == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  make3Dpng --bg ${TMP_NII}/b0_mean_coreg.nii.gz
  NB=($(cat ${TMP_NII}/dwi_preproc.bval))
  N10=$((${#NB[@]} / 10))
  N1=$(($((${#NB[@]} % 10)) - 1))
  TLAYOUT="10"
  for (( i=1; i<${N10}; i++ )) { TLAYOUT="${TLAYOUT};10"; }
  if [[ ${N1} -gt 0 ]]; then TLAYOUT="${TLAYOUT};${N1}"; fi
  make4Dpng --fg ${TMP_NII}/dwi_preproc_coreg.nii.gz \
    --fg-mask ${TMP_NII}/b0_mask_coreg.nii.gz \
    --fg-color "timbow" --fg-alpha 100 --fg-thresh "2.5,97.5" --layout "${TLAYOUT}"
  make3Dpng --bg --bg ${TMP_NII}/b0_mean_coreg.nii.gz -v \
    --fg ${TMP_NII}/b0_mask_coreg.nii.gz \
    --fg-color "timbow:random" --fg-alpha 25 --fg-cbar "false" \
    --layout "10:x;10:y;10:z" \
    --filename "${IDPFX}_mask-brain+b0" --dir-save ${TMP_NII}
  make3Dpng --bg ${TMP_NII}/${IDPFX}_bias.nii.gz --bg-color "plasma"
  make3Dpng --bg ${TMP_NII}/${IDPFX}_noise.nii.gz --bg-color "virid-esque"
  make4Dpng --fg ${TMP_NII}/${IDPFX}_residual.nii.gz --layout 5x5 --fg-color grayscale
  make4Dpng --fg ${TMP_NII}/${IDPFX}_residualUnring.nii.gz --layout 5x5 --fg-color grayscale
  make3Dpng \
    --bg ${TMP_NII}/T1_spacing-DWI.nii.gz \
      --bg-color "timbow:hue=#00FF00:lum=0,100:cyc=1/6" --bg-thresh "2.5,97.5" \
    --fg ${TMP_NII}/b0_mean_coreg.nii.gz \
      --fg-color "timbow:hue=#FF00FF:lum=0,100:cyc=1/6" --fg-thresh "2.5,97.5" \
      --fg-alpha 50 --fg-cbar "false" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_from-b0_to-native_overlay \
    --dir-save ${TMP_NII}
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  RMD=${DIR_SCRATCH}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd

  echo -e '---\ntitle: "&nbsp;"\noutput: html_document\n---\n' > ${RMD}
  echo '```{r setup, include=FALSE}' >> ${RMD}
  echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
  echo 'knitr::include_graphics("'${TKNIPATH}'/TK_BRAINLab_logo.png")' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## '${PIPE}${FLOW}': DWI PreProcessing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  # Show output file tree ------------------------------------------------------
  echo '' >> ${RMD}
  echo '### DWI Preprocessing Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_DWI}/preproc >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  PCTOUT=$(cat ${TMP_DWI}/percentageOutliers.txt)
  echo "### ${PCTOUT} % of SLICES are outliers.  " >> ${RMD}
  echo "If >10 %, may have too much motion or corrupted slices.  " >> ${RMD}
  echo '' >> ${RMD}

  # B0
  echo '### DWI Preprocessing Results {.tabset}' >> ${RMD}
  echo '#### B0' >> ${RMD}
    echo -e '!['${IDPFX}'_b0.nii.gz]('${TMP_NII}'/b0_mean_coreg.png)\n' >> ${RMD}
  echo '#### Brain Mask' >> ${RMD}
    echo -e '!['${IDPFX}'_mask-brain+b0.nii.gz]('${TMP_NII}'/'${IDPFX}'_mask-brain+b0.png)\n' >> ${RMD}
  echo '#### DWI' >> ${RMD}
    echo -e '!['${IDPFX}'_dwi.nii.gz]('${TMP_NII}'/dwi_preproc_coreg.nii.gz)\n' >> ${RMD}
  echo '#### Coregistration' >> ${RMD}
    echo -e '![]('${TMP_NII}'/'${IDPFX}'_from-b0_to-native_overlay.png)\n' >> ${RMD}

  # QC
  echo '### DWI Preprocessing Results {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### Noise' >> ${RMD}
    echo -e '!['${IDPFX}'_noise.nii.gz]('${TMP_NII}'/'${IDPFX}'_noise.png)\n' >> ${RMD}
  echo '#### Bias' >> ${RMD}
    echo -e '!['${IDPFX}'_bias.nii.gz]('${TMP_NII}'/'${IDPFX}'_bias.png)\n' >> ${RMD}
  echo '#### Unring' >> ${RMD}
    echo -e '!['${IDPFX}'_residualUnring.nii.gz]('${TMP_NII}'/'${IDPFX}'_residualUnring.png)\n' >> ${RMD}
  echo '#### Residual' >> ${RMD}
    echo -e '!['${IDPFX}'_residual.nii.gz]('${TMP_NII}'/'${IDPFX}'_residual.png)\n' >> ${RMD}

  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_SAVE}/qc/${PIPE}${FLOW}/Rmd
  mv ${DIR_SCRATCH}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.html ${DIR_SAVE}/qc/${PIPE}${FLOW}/
  mv ${DIR_SCRATCH}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd ${DIR_SAVE}/qc/${PIPE}${FLOW}/Rmd/
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> HTML summary of ${PIPE}${FLOW} generated:"
    echo -e "\t${DIR_SAVE}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}.html"
  fi
fi

## save cleaned nifti format to tkni folders -----------------------------------
mkdir -p ${DIR_DWI}/preproc/dwi
mkdir -p ${DIR_DWI}/preproc/b0
mkdir -p ${DIR_DWI}/preproc/mask
mkdir -p ${DIR_ANAT}/native/dwi
mv ${TMP_NII}/dwi_preproc_coreg.nii.gz   ${DIR_DWI}/preproc/dwi/${IDPFX}_dwi.nii.gz
mv ${TMP_NII}/dwi_preproc_coreg.png      ${DIR_DWI}/preproc/dwi/${IDPFX}_dwi.png
mv ${TMP_NII}/dwi_preproc.bvec           ${DIR_DWI}/preproc/dwi/${IDPFX}_dwi.bvec
mv ${TMP_NII}/dwi_preproc.bval           ${DIR_DWI}/preproc/dwi/${IDPFX}_dwi.bval
mv ${TMP_NII}/b0_mean_coreg.nii.gz       ${DIR_DWI}/preproc/b0/${IDPFX}_b0.nii.gz
mv ${TMP_NII}/b0_mean_coreg.png          ${DIR_DWI}/preproc/b0/${IDPFX}_b0.png
mv ${TMP_NII}/b0_mask_coreg.nii.gz       ${DIR_DWI}/preproc/mask/${IDPFX}_mask-brain+b0.nii.gz
mv ${TMP_NII}/${IDPFX}_mask-brain+b0.png ${DIR_DWI}/preproc/mask/${IDPFX}_mask-brain+b0.png
mv ${TMP_NII}/T1_spacing-DWI.nii.gz      ${DIR_ANAT}/native/dwi/${IDPFX}_space-dwi_T1w.nii.gz

## save XFMs to TKNI folders ---------------------------------------------------
mv ${TMP_XFM}/xfm_0GenericAffine.mat ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-affine.mat
mv ${TMP_XFM}/xfm_1Warp.nii.gz ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-syn.nii.gz
mv ${TMP_XFM}/xfm_1InverseWarp.nii.gz ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-syn+inverse.nii.gz
mv ${TMP_NII}/${IDPFX}_from-b0_to-native_overlay.png ${DIR_XFM}/

# Clean scratch folder and save MRTRIX for next steps --------------------------
rm ${TMP_NII}/*
rmdir ${TMP_NII}/
rm ${TMP_XFM}/*
rmdir ${TMP_XFM}/

#DIR_MRTRIX=${DIR_PROJECT}/derivatives/mrtrix/${IDDIR}
mkdir -p ${DIR_MRTRIX}
mv ${TMP_DWI}/b0_mask_coreg.mif ${DIR_MRTRIX}/
mv ${TMP_DWI}/b0_mean_coreg.mif ${DIR_MRTRIX}/
mv ${TMP_DWI}/dwi_preproc_coreg.mif ${DIR_MRTRIX}/

## save QC images
mkdir -p ${DIR_DWI}/preproc/qc
mv ${TMP_DWI}/${IDPFX}_bias.nii.gz ${DIR_DWI}/preproc/qc/
mv ${TMP_DWI}/${IDPFX}_noise.nii.gz ${DIR_DWI}/preproc/qc/
mv ${TMP_DWI}/${IDPFX}_residual.nii.gz ${DIR_DWI}/preproc/qc/
mv ${TMP_DWI}/${IDPFX}_residualUnring.nii.gz ${DIR_DWI}/preproc/qc/
mv ${TMP_DWI}/percentageOutliers.txt ${DIR_DWI}/preproc/qc/${IDPFX}_pctOutliers.txt

# set status file --------------------------------------------------------------
mkdir -p ${DIR_SAVE}/status/${PIPE}${FLOW}
touch ${DIR_SAVE}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> QC check file status set"
fi

#===============================================================================
# end of Function
#===============================================================================
exit 0

