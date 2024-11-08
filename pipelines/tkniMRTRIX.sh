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
image-dwi:,image-ap:,image-pa:,image-anat:,mask-brain:,dir-scratch:,\
help,verbose -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
PIPELINE=tkni
DIR_PROJECT=
DIR_SCRATCH=
DIR_ANAT=
DIR_DWI=
DIR_XFM=
IDPFX=
IDDIR=

IMAGE_DWI=
IMAGE_AP=
IMAGE_PA=
IMAGE_ANAT=
MASK_BRAIN=
MASK_DIL=2

CON_LABEL=
SEG_5TT=
FS_LABEL=false
DIR_FS=

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
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image-dwi) IMAGE_DWI="$2" ; shift 2 ;;
    --image-ap) IMAGE_AP="$2" ; shift 2 ;;
    --image-pa) IMAGE_PA="$2" ; shift 2 ;;
    --image-anat) IMAGE_ANAT="$2" ; shift 2 ;;
    --mask-brain) MASK_BRAIN="$2" ; shift 2 ;;
    --mask-dil) MASK_DIL="$2" ; shift 2 ;;
    --dir-anat) DIR_ANAT="$2" ; shift 2 ;;
    --dir-dwi) DIR_DWI="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
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
# set project defaults ---------------------------------------------------------
if [[ -z ${MRTRIXPATH} ]]; then
  MRTRIXPATH=/usr/lib/mrtrix3/bin
fi
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
  DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi
TMP_ANAT=${DIR_SCRATCH}/ANAT
TMP_DWI=${DIR_SCRATCH}/DWI
TMP_NII=${DIR_SCRATCH}/NII
TMP_XFM=${DIR_SCRATCH}/XFM
mkdir -p ${TMP_ANAT}
mkdir -p ${TMP_DWI}
mkdir -p ${TMP_NII}
mkdir -p ${TMP_XFM}

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

# Additional default values ----------------------------------------------------
if [[ -z ${DIR_ANAT} ]]; then
  DIR_ANAT=${DIR_PROJECT}/derivatives/${PIPELINE}/anat
fi
if [[ -z ${DIR_DWI} ]]; then
  DIR_DWI=${DIR_PROJECT}/derivatives/${PIPELINE}/dwi
fi
if [[ -z ${DIR_DWI} ]]; then
  DIR_XFM=${DIR_PROJECT}/derivatives/${PIPELINE}/xfm/${IDDIR}
fi
if [[ -z ${CON_LABEL} ]]; then
  CON_LABEL=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/label/${IDPFX}_label-hcpmmp1+refine.nii.gz
fi
if [[ -z ${IMAGE_ANAT} ]]; then
  IMAGE_ANAT=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/native/${IDPFX}_T1w.nii.gz
fi
if [[ ! -f ${IMAGE_ANAT} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] Anatomical image not found."
  exit 1
fi
if [[ -z ${MASK_BRAIN} ]]; then
  MASK_BRAIN=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/mask/${IDPFX}_mask-brain+tkniMALF.nii.gz
fi
if [[ ! -f ${MASK_BRAIN} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] Brain Mask image not found."
  exit 2
fi

# convert input files ----------------------------------------------------------
if [[ -z ${IMAGE_DWI} ]]; then
  IMAGE_DWI=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/dwi/${IDPFX}*dwi.nii.gz))
else
  IMAGE_DWI=(${IMAGE_DWI//,/ })
fi
N_DWI=${#IMAGE_DWI[@]}

# copy all files to scratch ----------------------------------------------------
for (( i=0; i<${N_DWI}; i++ )); do
  DWI=${IMAGE_DWI[${i}]}
  PFX=$(getBidsBase -i ${DWI})
  DNAME=$(dirname ${DWI})
  cp ${DNAME}/${PFX}.bval ${TMP_NII}/dwi_${i}.bval
  cp ${DNAME}/${PFX}.bvec ${TMP_NII}/dwi_${i}.bvec
  cp ${DNAME}/${PFX}.json ${TMP_NII}/dwi_${i}.json
  cp ${DWI} ${TMP_NII}/dwi_${i}.nii.gz
done

# check image dimensions and pad if uneven -------------------------------------
for (( i=0; i<${N_DWI} i++ )); do
  unset TDIM
  TDIM=$(PrintHeader ${TMP_NII}/dwi_${i}.nii.gz 2)
  echo -e "${i}: ${TDIM}"
  TDIM=(${TDIM//x/ })
  DIMCHK=0
  for j in {0..2}; do
    if [ $((${TDIM[${j}]}%2)) -eq 1 ]; then
      TDIM[${j}]=$((${TDIM[${j}]} + 1))
      DIMCHK=1
    fi
  done
  if [ ${DIMCHK} -eq 1 ]; then
    fslroi ${TMP_NII}/dwi_${i}.nii.gz \
      ${TMP_NII}/dwi_${i}.nii.gz \
      0 ${TDIM[0]} 0 ${TDIM[1]} 0 ${TDIM[2]}
  fi
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
dwidenoise ${TMP_DWI}/dwi_raw.mif ${TMP_DWI}/dwi_den.mif \
  -noise ${TMP_DWI}/noise.mif
mrcalc ${TMP_DWI}/dwi_raw.mif ${TMP_DWI}/dwi_den.mif \
  -subtract ${TMP_DWI}/residual.mif

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
    -nocleanup -pe_dir j -rpe_pair -se_epi ${TMP_DWI}/b0_pair.mif \
    -eddy_options " --slm=linear --data_is_shelled"
else
  ${MRTRIXPATH}/dwifslpreproc ${TMP_DWI}/dwi_den_unr.mif \
    ${TMP_DWI}/dwi_den_unr_preproc.mif \
    -nocleanup -rpe_header \
    -eddy_options " --slm=linear --data_is_shelled"
#else
#  dwifslpreproc ${TMP_DWI}/dwi_den_unr.mif ${TMP_DWI}/dwi_den_unr_preproc.mif \
#    -nocleanup -pe_dir j -rpe_none \
#    -eddy_options " --slm=linear --data_is_shelled"
fi

## Check "dwi_post_eddy.eddy_outlier_map", where 1's represent outlier slices
## due to motion, eddy currents, or something else.
## Courtesy of Andy's Brain Book
TDIR=$(find ${DIR_SCRATCH}/dwifslpreproc-tmp-* -maxdepth 0 -type d)
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

# Brain Mask Estimation --------------------------------------------------------
dwi2mask ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif \
  ${TMP_DWI}/mask_den_unr_preproc_unb.mif

# Anatomical Coregistration ----------------------------------------------------
## extract B0
dwiextract -bzero ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif ${TMP_DWI}/b0_all.mif
mrmath ${TMP_DWI}/b0_all.mif mean ${TMP_DWI}/b0_mean.mif -axis 3
mrconvert ${TMP_DWI}/b0_mean.mif ${TMP_DWI}//b0_mean.nii.gz
MOVING=${TMP_DWI}/b0_mean.nii.gz

## extract brain
if [[ ${MASK_DIL} -gt 0 ]]; then
  ImageMath 3 ${TMP_ANAT}/mask-brain_MD.nii.gz MD ${MASK_BRAIN} ${MASK_DIL}
  MASK_BRAIN=${TMP_ANAT}/mask-brain_MD.nii.gz
fi
fslmaths ${T1} -mas ${MASK_BRAIN} ${TMP_ANAT}/T1_roi-brain.nii.gz
FIXED=${TMP_ANAT}/T1_roi-brain.nii.gz

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
  --verbose 1 \
  --random-seed 13311800

## resample T1w to DWI spacing
DIMS_DWI=$(niiInfo -i ${TMP_DWI}/b0_mean.nii.gz -f spacing)
DIMS_DWI=${DIMS_DWI// /x}
ResampleImage 3 ${FIXED} ${TMP_ANAT}/T1_spacing-DWI.nii.gz ${DIMS_DWI} 0 0 2
REF_IMG=${TMP_ANAT}/T1_spacing-DWI.nii.gz

## apply transforms to B0
antsApplyTransforms -d 3 -n Linear \
  -i ${TMP_DWI}/b0_mean.nii.gz \
  -o ${TMP_DWI}/b0_mean_coreg.nii.gz \
  -t identity \
  -t ${TMP_XFM}/xfm_1Warp.nii.gz \
  -t ${TMP_XFM}/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${TMP_DWI}/b0_mean_coreg.nii.gz ${TMP_DWI}/b0_mean_coreg.mif

## apply transforms to B0 mask
mrconvert ${TMP_DWI}/mask_den_unr_preproc_unb.mif ${TMP_DWI}/b0_mask.nii.gz
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${TMP_DWI}/b0_mask.nii.gz \
  -o ${TMP_DWI}/b0_mask_coreg.nii.gz \
  -t identity \
  -t ${TMP_XFM}/xfm_1Warp.nii.gz \
  -t ${TMP_XFM}/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${TMP_DWI}/b0_mask_coreg.nii.gz ${TMP_DWI}/b0_mask_coreg.mif

## apply transforms to preprocessed DWI data
mrconvert ${TMP_DWI}/dwi_den_unr_preproc_unbiased.mif \
  ${TMP_DWI}/dwi_preproc.nii.gz \
  -export_grad_fsl ${TMP_DWI}/dwi_preproc.bvec ${TMP_DWI}/dwi_preproc.bval
antsApplyTransforms -d 3 -e 3 -n Linear \
  -i ${TMP_DWI}/dwi_preproc.nii.gz \
  -o ${TMP_DWI}/dwi_preproc_coreg.nii.gz \
  -t identity \
  -t ${TMP_XFM}/xfm_1Warp.nii.gz \
  -t ${TMP_XFM}/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${TMP_DWI}/dwi_preproc_coreg.nii.gz \
  ${TMP_DWI}/dwi_preproc_coreg.mif \
  -fslgrad ${TMP_DWI}/dwi_preproc.bvec ${TMP_DWI}/dwi_preproc.bval

## save XFMs to TKNI folders ---------------------------------------------------
cp ${TMP_XFM}/xfm_0GenericAffine.mat \
  ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-affine.mat
cp ${TMP_XFM}/xfm_1Warp.nii.gz \
  ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-syn.nii.gz
cp ${TMP_XFM}/xfm_1InverseWarp.nii.gz \
  ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-syn+inverse.nii.gz

# Save Output for QC and Next Processing Steps ---------------------------------
## Save T1w as MIF and NIfTI in DWI spacing
mkdir -p ${DIR_SAVE}/native_anat
#mrconvert ${TMP_ANAT}/${IDPFX}_T1w.nii.gz \
#  ${DIR_SAVE}/native_anat/${IDPFX}_T1w.mif
cp ${TMP_ANAT}/T1_spacing-DWI.nii.gz \
  ${DIR_ANAT}/native_dwi/${IDPFX}_proc-dwiSpace_T1w.nii.gz
if [[ ${NO_PNG} == "false" ]]; then
fi

## Save preprocessed DWI
mkdir -p ${DIR_SAVE}/preproc/mask
mkdir -p ${DIR_SAVE}/preproc/qc
cp ${TMP_DWI}/dwi_preproc_coreg.mif \
  ${DIR_SAVE}/preproc/${IDPFX}_dwi.mif
cp ${TMP_DWI}/b0_mask_coreg.mif \
  ${DIR_SAVE}/preproc/mask/${IDPFX}_mask-brain+b0.mif
cp ${TMP_DWI}/b0_mean_coreg.mif \
  ${DIR_SAVE}/preproc/${IDPFX}_proc-mean_b0.mif

## save QC images
mrconvert ${TMP_DWI}/bias.mif ${DIR_DWI}/preproc/qc/${IDPFX}_bias.nii.gz
mrconvert ${TMP_DWI}/noise.mif ${DIR_DWI}/preproc/qc/${IDPFX}_noise.nii.gz
mrconvert ${TMP_DWI}/residual.mif ${DIR_DWI}/preproc/qc/${IDPFX}_residual.nii.gz
mrconvert ${TMP_DWI}/residualUnringed.mif \
  ${DIR_DWI}/preproc/qc/${IDPFX}_residualUnring.nii.gz
mrconvert ${TMP_DWI}/b0_mean_coreg.mif \
  ${DIR_DWI}/preproc/qc/${IDPFX}_proc-mean_b0.nii.gz

if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${DIR_DWI}/preproc/qc/${IDPFX}_bias.nii.gz --bg-color magma
  make3Dpng --bg ${DIR_DWI}/preproc/qc/${IDPFX}_noise.nii.gz --bg-color viridis
  make3Dpng --bg ${DIR_DWI}/preproc/qc/${IDPFX}_proc-mean_b0.nii.gz
  make4Dpng --fg ${DIR_DWI}/preproc/qc/${IDPFX}_residual.nii.gz \
    --layout 5x5 --fg-color grayscale
  make4Dpng --fg ${DIR_DWI}/preproc/qc/${IDPFX}_residualUnring.nii.gz \
    --layout 5x5 --fg-color grayscale
  make3Dpng \
    --bg ${DIR_ANAT}/native_dwi/${IDPFX}_proc-dwiSpace_T1w.nii.gz \
      --bg-color "#000000,#00FF00,#FFFFFF" --bg-thresh "2.5,97.5" \
    --fg ${DIR_DWI}/preproc/qc/${IDPFX}_proc-mean_b0.nii.gz \
      --fg-color "#000000,#FF00FF,#FFFFFF" --fg-thresh "2.5,97.5" \
      --fg-alpha 50 --fg-cbar "false" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --offset "0,0,0" \
    --filename ${IDPFX}_from-b0_to-native_overlay \
    --dir-save ${DIR_DWI}/preproc/qc
fi

# Fiber Orientation Distribution ===============================================
# Response Function Estimation ------------------------------------------------
## Purpose: Estimate different response functions for the three different tissue
## types: white matter (WM), gray matter (GM), and cerebrospinal fluid (CSF).
## Main reference: Dhollander et al., 2016
dwi2response dhollander ${TMP_DWI}/dwi_preproc_coreg.mif \
  ${TMP_DWI}/wm.txt ${TMP_DWI}/gm.txt ${TMP_DWI}/csf.txt \
  -voxels ${TMP_DWI}/voxels.mif

# Estimation of Fiber Orientation Distributions (FOD) --------------------------
## Purpose: In every voxel, estimate the orientation of all fibers crossing that
## voxel.
## Main reference(s): Tournier et al., 2004, 2007
dwi2fod msmt_csd ${TMP_DWI}/dwi_preproc_coreg.mif \
  -mask ${TMP_DWI}/b0_mask_coreg.mif \
  ${TMP_DWI}/wm.txt ${TMP_DWI}/wmfod.mif \
  ${TMP_DWI}/gm.txt ${TMP_DWI}/gmfod.mif \
  ${TMP_DWI}/csf.txt ${TMP_DWI}/csffod.mif

# Intensity Normalization -----------------------------------------------------
## Purpose: Correct for global intensity differences (especially important when
## performing group studies!)
mtnormalise ${TMP_DWI}/wmfod.mif ${TMP_DWI}/wmfod_norm.mif \
  ${TMP_DWI}/gmfod.mif ${TMP_DWI}/gmfod_norm.mif \
  ${TMP_DWI}/csffod.mif ${TMP_DWI}/csffod_norm.mif \
  -mask ${TMP_DWI}/b0_mask_coreg.mif

# Whole-Brain Tractogram =======================================================
# Preparing Anatomically Constrained Tractography (ACT) ------------------------
## Purpose: Increase the biological plausibility of downstream streamline creation.
## Main reference(s): Smith et al., 2012

if [[ -n ${SEG_5TT} ]]; then
 cp ${SEG_5TT} ${TMP_ANAT}/5tt.nii.gz
else
  # Preparing a mask for streamline termination
  mrconvert ${TMP_ANAT}/T1_roi-brain.nii.gz ${TMP_ANAT}/T1_raw.mif
  5ttgen fsl ${TMP_ANAT}/T1_raw.mif ${TMP_ANAT}/5tt.mif -premasked
  mrconvert ${TMP_ANAT}/5tt.mif ${TMP_ANAT}/5tt.nii.gz
  ## save tissue segmentation in native anatomical space
  mkdir -p ${DIR_ANAT}/posterior/5TT
  cp ${TMP_ANAT}/5tt.nii.gz ${DIR_ANAT}/posterior/5TT/${IDPFX}_posterior-tissue+5tt.nii.gz
fi
antsApplyTransforms -d 3 -e 3 -n Linear \
  -i ${TMP_ANAT}/5tt.nii.gz -o ${TMP_ANAT}/5tt_spacing-DWI.nii.gz \
  -r ${TMP_ANAT}/T1_spacing-DWI.nii.gz
mrconvert ${TMP_ANAT}/5tt_spacing-DWI.nii.gz ${TMP_ANAT}/5tt_spacing-DWI.mif

# Preparing a mask of streamline seeding
5tt2gmwmi ${TMP_ANAT}/5tt_spacing-DWI.mif ${TMP_ANAT}/gmwmSeed.mif

# Creating streamlines ---------------------------------------------------------
tckgen -act ${TMP_ANAT}/5tt_spacing-DWI.mif \
  -backtrack -seed_gmwmi ${TMP_ANAT}/gmwmSeed.mif \
  -select 10000000 ${TMP_DWI}/wmfod_norm.mif ${TMP_DWI}/tracks_10mio.tck

## simplify to display
#tckedit ${TMP_DWI}/tracks_10mio.tck -number 200k ${TMP_DWI}/smallerTracks_200k.tck
#mrview ${TMP_DWI}/dwi_preproc_coreg.mif \
#  -tractography.load ${TMP_DWI}/smallerTracks_200k.tck

# Reducing the number of streamlines -------------------------------------------
## Purpose: Filtering the tractograms to reduce CSD-based bias in overestimation
## of longer tracks compared to shorter tracks; reducing the number of streamlines
## Main reference: Smith et al., 2013
tcksift -act ${TMP_ANAT}/5tt_spacing-DWI.mif  \
  -term_number 1000000 ${TMP_DWI}/tracks_10mio.tck \
  ${TMP_DWI}/wmfod_norm.mif ${TMP_DWI}/sift_1mio.tck

## simplify for viewing
#tckedit ${TMP_DWI}/sift_1mio.tck -number 200k ${TMP_DWI}/smallerSIFT_200k.tck

# make glass brain for rendering images

mrview ${TMP_DWI}/dwi_preproc_coreg.mif -imagevisible false \
  -tractography.load ${TMP_DWI}/smallerSIFT_200k.tck \
  -capture.folder ${TMP_PNG} \
  -capture.prefix tracks_sift_200k_ \
  -mode 3 -noannotations -size 1000,1000 -autoscale \
  -plane 0 -capture.grab \
  -plane 1 -capture.grab \
  -plane 2 -capture.grab \
  -exit

# Region-of-interest filtering of tractograms ----------------------------------
## *** Figure this out when needed
#mrview dwi_preproc_coreg.mif –tractography.load smallerSIFT_200k.tck &
#tckedit–include -0.6,-16.5,-16.0,3 sift_1mio.tck cst.tck

# Extract Diffusion Scalars ====================================================
## Need to figure out what volumes correspond to what tensors, and pull out the
## desired values.
mkdir -p ${DIR_DWI}/scalar
mkdir -p ${DIR_DWI}/tensor
dwi2tensor \
  -mask ${TMP_DWI}/b0_mask_coreg.mif \
  -b0 ${TMP_DWI}/dwi_b0.nii.gz \
  -dkt ${DIR_DWI}/tensor/${IDPFX}_tensor-kurtosis.nii.gz \
  ${TMP_DWI}/dwi_preproc_coreg.mif \
  ${DIR_DWI}/tensor/${IDPFX}_tensor-diffusion.nii.gz
tensor2metric -mask ${TMP_DWI}/b0_mask_coreg.mif \
  -adc ${DIR_DWI}/scalar/${IDPFX}_scalar-adc.nii.gz \
  -fa ${DIR_DWI}/scalar/${IDPFX}_scalar-fa.nii.gz \
  -ad ${DIR_DWI}/scalar/${IDPFX}_scalar-ad.nii.gz \
  -rd ${DIR_DWI}/scalar/${IDPFX}_scalar-rd.nii.gz \
  ${DIR_DWI}/tensor/${IDPFX}_tensor-diffusion.nii.gz

## extract mean kurtosis (mk), axial kurtosis (ak), and radial kurtosis (rk)
## KURTOSIS NOT IMPLEMENTED
#tensor2metric -mask ${TMP_DWI}/b0_mask_coreg.mif\
#  -dkt ${TMP_DWI}/dwi_kurtosis.nii.gz \
#  -mk ${TMP_DWI}/dwi_mk.nii.gz \
#  -ak ${TMP_DWI}/dwi_ak.nii.gz \
#  -rk ${TMP_DWI}/dwi_rk.nii.gz

# Connectome construction ======================================================
# Preparing an atlas for structural connectivity analysis ----------------------
## Purpose: Obtain a volumetric atlas-based parcellation image, co-registered to
## diffusion space for downstream structural connectivity (SC) matrix generation
## Main reference: Glasser et al., 2016a (for the atlas used here for SC generation)
if [[ ${FS_LABEL} == "true" ]]; then
  ## Map annotation files of the HCP MMP 1.0 Atlas from the fsaverage to the
  ## participant (both hemispheres)
  if [[ -z ${DIR_FS} ]];
    DIR_FS==${DIR_PROJECT}/derivatives/fsSynth
  fi
  export SUBJECTS_DIR=${DIR_FS}
  if [[ ! -d ${SUBJECTS_DIR}/fsaverage ]]; then
    cp -R $FREESURFER_HOME/subjects/fsaverage ${SUBJECTS_DIR}/fsaverage
  fi
  mri_surf2surf --srcsubject fsaverage \
    --trgsubject ${IDPFX} --hemi lh \
    --sval-annot ${SUBJECTS_DIR}/fsaverage/label/lh.hcpmmp1.annot \
    --tval ${SUBJECTS_DIR}/${IDPFX}/label/lh.hcpmmp1.annot
  mri_surf2surf --srcsubject fsaverage \
    --trgsubject ${IDPFX} --hemi rh \
    --sval-annot ${SUBJECTS_DIR}/fsaverage/label/rh.hcpmmp1.annot \
    --tval ${SUBJECTS_DIR}/${IDPFX}/label/rh.hcpmmp1.annot
  ## Convert the
  ## resulting file to .mif format (use datatype uint32, which is liked
  ## best by MRtrix).
  mri_aparc2aseg --old-ribbon --s ${IDPFX} --annot hcpmmp1 \
    --o ${SUBJECTS_DIR}/${IDPFX}/mri/hcpmmp1.mgz
  CON_LABEL=${SUBJECTS_DIR}/${IDPFX}/mri/hcpmmp1.mgz
fi
mrconvert -datatype uint32 ${CON_LABEL} ${TMP_ANAT}/hcpmmp1.mif

# Replace the random integers of the hcpmmp1.mif file with integers that start
## at 1 and increase by 1.
HCPMMP_ORIG=${TKNIPATH}/lut/hcpmmp1_original.txt
HCPMMP_SORT=${TKNIPATH}/lut/hcpmmp1_ordered.txt
labelconvert ${TMP_ANAT}/hcpmmp1.mif ${HCPMMP_ORIG} ${HCPMMP_SORT} \
  ${TMP_ANAT}/hcpmmp1_parcels.mif

mrconvert ${TMP_ANAT}/hcpmmp1_parcels.mif ${TMP_ANAT}/hcpmmp1_parcels.nii.gz
antsApplyTransforms -d 3 -n MultiLabel \
  -i ${TMP_ANAT}/hcpmmp1_parcels.nii.gz \
  -o ${TMP_ANAT}/hcpmmp1_parcels_coreg.nii.gz \
  -r ${TMP_ANAT}/T1_spacing-DWI.nii.gz
mrconvert -datatype uint32 ${TMP_ANAT}/hcpmmp1_parcels_coreg.nii.gz \
  ${TMP_ANAT}/hcpmmp1_parcels_coreg.mif

# Register the ordered atlas-based volumetric parcellation to diffusion space.
#mrtransform hcpmmp1_parcels_nocoreg.mif \
#  -linear diff2struct_mrtrix.txt -inverse -datatype uint32 \
#  hcpmmp1_parcels_coreg.mif

# Matrix Generation ------------------------------------------------------------
## Purpose: Gain quantitative information on how strongly each atlas region is
## connected to all others; represent it in matrix format
tck2connectome -symmetric -zero_diagonal \
  -scale_invnodevol ${TMP_DWI}/sift_1mio.tck \
  ${TMP_ANAT}/hcpmmp1_parcels_coreg.mif ${DIR_SCRATCH}/hcpmmp1.csv \
  -out_assignment ${DIR_SCRATCH}/assignments_hcpmmp1.csv

connectome2tck ${TMP_DWI}/sift_1mio.tck \
  ${DIR_SCRATCH}/assignments_hcpmmp1.csv exemplar \
  -files single \
  -exemplars ${TMP_ANAT}/hcpmmp1_parcels_coreg.mif

# Create Mesh Node Geometry ----------------------------------------------------
label2mesh ${TMP_ANAT}/hcpmmp1_parcels_coreg.mif ${TMP_ANAT}/hcpmmp1_mesh.obj

# Selecting Connections of Interest --------------------------------------------
## Pick nodes from lookup table
## The HCP MMP 1.0 atlas, which we used in this tutorial, subdivides the motor
## cortices into several subregions (see the supplementary material of the
## original article: Glasser et al., 2016b). Looking at that article, we find
## that one core region of the motor cortex is simply called “4”. Since the
## atlas is symmetric across hemispheres, there is a region “4” on the left and
## the right hemisphere, called “L_4” and “R_4” respectively. We next have to
## identify the indices assigned to those regions in our atlas-based
## parcellation image (hcpmmp1_parcels_coreg.mif). To do that, open the color
## lookup table (the ordered version: hcpmmp1_ordered.txt). Look for regions
## “L_4” and “R_4”. You will see that they correspond to indices 8 and 188.

## Extracting streamlines between atlas regions
#connectome2tck -nodes 8,188 -exclusive \
#  sift_1mio.tck assignments_hcpmmp1.csv \
#  moto

## Extracting streamlines emerging from a region of interest
#connectome2tck -nodes 362,372 \
#  sift_1mio.tck assignments_hcpmmp1.csv \
#  -files per_node thalamus

# Save Results output ---------------------------------------------------------
## Export QC
cp ${TMP_DWI}/percentageOutliers.txt

## Transforms
## 5tt labels
cp ${TMP_ANAT}/5tt.nii.gz ${DIR_PROJECT}/derivatives/
## Connectome

.
├── ANAT
│   ├── 5tt_coreg.mif
│   ├── 5tt.mif
│   ├── 5tt.nii.gz
│   ├── 5tt_nocoreg.nii.gz
│   ├── 5tt_spacing-DWI.mif
│   ├── 5tt_spacing-DWI.nii.gz
│   ├── diff2struct_affine_mrtrix.txt
│   ├── diff2struct_fsl_affine.mat
│   ├── exemplar.tck
│   ├── gmwmSeed_coreg.mif
│   ├── gmwmSeed.mif
│   ├── hcpmmp1_mesh.obj
│   ├── hcpmmp1.mif
│   ├── hcpmmp1.nii.gz
│   ├── hcpmmp1_parcels_coreg.mif
│   ├── hcpmmp1_parcels_coreg.nii.gz
│   ├── hcpmmp1_parcels.mif
│   ├── hcpmmp1_parcels.nii.gz
│   ├── mask-brain_MD.nii.gz
│   ├── T1_coreg.mif
│   ├── T1_raw.mif
│   ├── T1_roi-brain.nii.gz
│   ├── T1_spacing-DWI.mif
│   └── T1_spacing-DWI.nii.gz
├── assignments_hcpmmp1.csv
├── dki_test
│   └── dwi_kurtosis.nii.gz
├── DWI
│   ├── b0_all.mif
│   ├── b0_mask_coreg.mif
│   ├── b0_mask_coreg.nii.gz
│   ├── b0_mask.nii.gz
│   ├── b0_mean_coreg.mif
│   ├── b0_mean_coreg.nii.gz
│   ├── b0_mean.mif
│   ├── b0_mean.nii.gz
│   ├── bias.mif
│   ├── csffod.mif
│   ├── csffod_norm.mif
│   ├── csf.txt
│   ├── dwi_adc.nii.gz
│   ├── dwi_ad.nii.gz
│   ├── dwi_b0.nii.gz
│   ├── dwi_den.mif
│   ├── dwi_den_unr.mif
│   ├── dwi_den_unr_preproc.mif
│   ├── dwi_den_unr_preproc_unbiased.mif
│   ├── dwi_extract_b0.mif
│   ├── dwi_fa.nii.gz
│   ├── dwi_kurtosis.nii.gz
│   ├── dwi_preproc.bval
│   ├── dwi_preproc.bvec
│   ├── dwi_preproc_coreg.mif
│   ├── dwi_preproc_coreg.nii.gz
│   ├── dwi_preproc.nii.gz
│   ├── dwi_raw.mif
│   ├── dwi_rd.nii.gz
│   ├── dwi_tensor.nii.gz
│   ├── gmfod.mif
│   ├── gmfod_norm.mif
│   ├── gm.txt
│   ├── mask_den_unr_preproc_unb.mif
│   ├── mean_b0_preprocessed.mif
│   ├── mean_b0_preprocessed.nii.gz
│   ├── noise.mif
│   ├── percentageOutliers.txt
│   ├── residual.mif
│   ├── residualUnringed.mif
│   ├── sift_1mio.tck
│   ├── smallerSIFT_200k.tck
│   ├── smallerTracks_200k.tck
│   ├── tracks_10mio.tck
│   ├── voxels.mif
│   ├── wmfod.mif
│   ├── wmfod_norm.mif
│   └── wm.txt
├── dwifslpreproc-tmp-29QDJY
│   ├── bvals
│   ├── bvecs
│   ├── command.txt
│   ├── cwd.txt
│   ├── dwi.json
│   ├── dwi_manual_pe_scheme.txt
│   ├── dwi.mif
│   ├── dwi_post_eddy.eddy_command_txt
│   ├── dwi_post_eddy.eddy_movement_rms
│   ├── dwi_post_eddy.eddy_outlier_map
│   ├── dwi_post_eddy.eddy_outlier_n_sqr_stdev_map
│   ├── dwi_post_eddy.eddy_outlier_n_stdev_map
│   ├── dwi_post_eddy.eddy_outlier_report
│   ├── dwi_post_eddy.eddy_parameters
│   ├── dwi_post_eddy.eddy_post_eddy_shell_alignment_parameters
│   ├── dwi_post_eddy.eddy_post_eddy_shell_PE_translation_parameters
│   ├── dwi_post_eddy.eddy_restricted_movement_rms
│   ├── dwi_post_eddy.eddy_rotated_bvecs
│   ├── dwi_post_eddy.eddy_values_of_all_input_parameters
│   ├── dwi_post_eddy.nii.gz
│   ├── eddy_config.txt
│   ├── eddy_indices.txt
│   ├── eddy_in.nii
│   ├── eddy_mask.nii
│   ├── eddy_output.txt
│   ├── grad.b
│   ├── log.txt
│   ├── output.json
│   └── result.mif
├── FMAP
├── hcpmmp1.csv
└── XFM
    ├── xfm_0GenericAffine.mat
    ├── xfm_1InverseWarp.nii.gz
    └── xfm_1Warp.nii.gz




#===============================================================================
# end of Function
#===============================================================================
exit 0

