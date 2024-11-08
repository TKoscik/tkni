#!/bin/bash -e
#===============================================================================
# Run TK_BRAINLab Diffusion Preprocessing Pipeline for EVANDERPLAS UNITCALL
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
PIPELINE="tkni"
PROC_NAME="prepDWI"
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S%N)
OPERATOR=$(whoami)
KEEP=false
NO_LOG=false
umask 007

# egress function --------------------------------------------------------------
## clear scratch, write logs
function egress {
  EXIT_CODE=$?
  ## Safely remove scratch folder
  if [[ "${KEEP}" == "false" ]]; then
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

  ## write logs
  if [[ "${NO_LOG}" == "false" ]]; then
    unset LOGSTR
    LOGSTR="${OPERATOR},${HOSTNAME},${HOSTTYPE},${MACHTYPE},${OSTYPE},\
    ${PI},${PROJECT},${PID},${SID},\
    ${PROC_NAME},${PROC_START},${PROC_STOP},${EXIT_CODE}"
    LOGSTR=${LOGSTR// }
    FCN_LOG=${HOME}/tkni_log/tkni_benchmark_$(date +FY%Y)Q$((($(date +%-m)-1)/3+1)).log
    echo ${LOGSTR} >> ${FCN_LOG}
    echo ${LOGSTR} >> ${DIR_PROJECT}/log/tkni_processing.log
  fi
}
trap egress EXIT

# Parse inputs -----------------------------------------------------------------
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,\
pid:,sid:,aid:,dwi:,t1:,mask-brain:,dir-scratch:,dir-save:,\
help,verbose -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=unkPI
PROJECT=unkProject
DIR_PROJECT=${HOME}/${PI}/${PROJECT}
DIR_SCRATCH=${HOME}/scratch/${PROC_NAME}_${DATE_SUFFIX}
DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPELINE}/dwi
PID=
SID=
AID=
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
    --dwi) DWILS="$2" ; shift 2 ;;
    --t1) T1="$2" ; shift 2 ;;
    --ap) AP="$2" ; shift 2 ;;
    --pa) PA="$2" ; shift 2 ;;
    --mask-brain) MASK_BRAIN="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --dir-save) DIR_SCRATCH="$2" ; shift 2 ;;
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
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
# check PI/Project specific inputs ---------------------------------------------
if [[ -z ${PI} ]];

# process newest participant or set identifiers --------------------------------
if [[ -z ${PID} ]]; then
  PIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f participant_id))
  SIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f session_id))
  AIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f assessment_id))
  PID=${PIDLS[-1]}
  SID=${SIDLS[-1]}
  AID=${AIDLS[-1]}
fi
PIDSTR=sub-${PID}_ses-${SID}
if [[ -n ${AID} ]]; then PIDSTR=${PIDSTR}_aid-${AID}; fi
DIRPID=sub-${PID}/ses-${SID}

# set scratch directories ------------------------------------------------------
mkdir -p ${DIR_SCRATCH}/DWI
mkdir -p ${DIR_SCRATCH}/FMAP
mkdir -p ${DIR_SCRATCH}/T1

# convert input files ----------------------------------------------------------
if [[ -z ${DWILS} ]]; then
  DWILS=($(ls ${DIR_PROJECT}/rawdata/${DIRPID}/dwi/${PIDSTR}*dwi.nii.gz))
fi
DWILS=(${DWILS//,/ })
cd ${DIR_SCRATCH}/DWI
## convert to DWI to mif
for (( i=0; i<${#DWILS[@]}; i++ )); do
  DWI=${DWILS[${i}]}
  PFX=$(getBidsBase -i ${DWI})
  DNAME=$(dirname ${DWI})
  BVAL="${DNAME}/${PFX}.bval"
  BVEC="${DNAME}/${PFX}.bvec"
  mrconvert ${DWI} dwi_${i}.mif -fslgrad ${BVEC} ${BVAL}
done
## concatenate DWI
if [[ ${#DWILS[@]} -gt 1 ]]; then
  mrcat $(ls dwi_*.mif) dwi_raw.mif
else
  mv dwi_0.mif dwi_raw.mif
fi

if [[ -z ${T1} ]]; then
  T1=${DIR_PROJECT}/derivatives/tkni/anat/native/${PIDSTR}_T1w.nii.gz
fi
if [[ -z ${MASK_BRAIN} ]]; then
  MASK_BRAIN=${DIR_PROJECT}/derivatives/tkni/anat/mask/${PIDSTR}_mask-brain.nii.gz
fi

# Denoise ----------------------------------------------------------------------
dwidenoise dwi_raw.mif dwi_den.mif -noise noise.mif
mrcalc dwi_raw.mif dwi_den.mif -subtract residual.mif

# Unringing --------------------------------------------------------------------
mrdegibbs dwi_den.mif dwi_den_unr.mif -axes 0,1
mrcalc dwi_den.mif dwi_den_unr.mif -subtract residualUnringed.mif

# Motion and Distortion Correction ---------------------------------------------
if [[ -n ${AP} ]]; then
  mrconvert ${AP} b0_AP.mif
  mrconvert ${PA} b0_PA.mif
  mrcat ${AP} ${PA} -axis 3 b0_pair.mif
  dwipreproc dwi_den_unr.mif \
    dwi_den_unr_preproc.mif \
    -nocleanup -pe_dir j -rpe_pair -se_epi b0_pair.mif \
    -eddy_options " --slm=linear --data_is_shelled"
else
  dwifslpreproc dwi_den_unr.mif dwi_den_unr_preproc.mif \
    -nocleanup -pe_dir j -rpe_none \
    -eddy_options " --slm=linear --data_is_shelled"
fi

## Check "dwi_post_eddy.eddy_outlier_map", where 1's represent outlier slices
## due to motion, eddy currents, or something else.
## Courtesy of Andy's Brain Book
cd dwifslpreproc-tmp-*
totalSlices=`mrinfo dwi.mif | grep Dimensions | awk '{print $6 * $8}'`
totalOutliers=`awk '{ for(i=1;i<=NF;i++)sum+=$i } END { print sum }' dwi_post_eddy.eddy_outlier_map`
echo "If the following number is greater than 10, you may have to discard this subject because of too much motion or corrupted slices"
echo "scale=5; ($totalOutliers / $totalSlices * 100)/1" | bc | tee percentageOutliers.txt
cd ..

# Bias Field Correction --------------------------------------------------------
dwibiascorrect ants dwi_den_unr_preproc.mif \
  dwi_den_unr_preproc_unbiased.mif \
  -bias bias.mif

# Brain Mask Estimation --------------------------------------------------------
dwi2mask dwi_den_unr_preproc_unbiased.mif mask_den_unr_preproc_unb.mif

# Anatomical Coregistration ----------------------------------------------------
## extract B0
dwiextract -bzero dwi_den_unr_preproc_unbiased.mif b0_all.mif
mrmath b0_all.mif mean b0_mean.mif -axis 3
mrconvert b0_mean.mif ${DIR_TMP}/src/b0_mean.nii.gz
MOVING=${DIR_TMP}/src/b0_mean.nii.gz

## extract brain
if [[ ${MD} -gt 0 ]]; then
  ImageMath 3 ${DIR_TMP}/src/mask-brain_MD.nii.gz MD ${MASK_BRAIN} ${MD}
  MASK_BRAIN=${DIR_TMP}/src/mask-brain_MD.nii.gz
fi
fslmaths ${T1} -mas ${MASK_BRAIN} ${DIR_TMP}/src/T1_roi-brain.nii.gz
FIXED=${DIR_TMP}/src/T1_roi-brain.nii.gz

## coregister to anatomical T1w
antsRegistration \
  --dimensionality 3 \
  --output ${DIR_TMP}/src/xfm_ \
  --write-composite-transform 0 \
  --collapse-output-transforms 1 \
  --initialize-transforms-per-stage 0 \
  --initial-moving-transform [${FIXED},${MOVING},1] \
  --transform Rigid[0.1] \
    --metric Mattes[${FIXED},${MOVING},1,32,Regular,0.2] \
    --convergence [1200x1200x100,1e-6,5] \
    --smoothing-sigmas 2x1x0vox \
    --shrink-factors 4x2x1 \
  --transform Affine[0.25] \
    --metric Mattes[${FIXED},${MOVING},1,32,Regular,0.2] \
    --convergence [200x20,1e-6,5] \
    --smoothing-sigmas 1x0vox \
    --shrink-factors 2x1 \
  --transform SyN[0.2,3,0] \
    --metric Mattes[${FIXED},${MOVING},1,32] \
    --convergence [40x20x0,1e-7,8] \
    --smoothing-sigmas 2x1x0vox \
    --shrink-factors 4x2x1 \
  --use-histogram-matching 0 \
  --winsorize-image-intensities [0.005,0.995] \
  --float 1 \
  --verbose 1 \
  --random-seed 13311800

## resample T1w to DWI spacing
DIMS_DWI=$(niiInfo -i ${DIR_TMP}/src/b0_mean.nii.gz -f spacing)
DIMS_DWI=${DIMS_DWI// /x}
ResampleImage 3 ${FIXED} ${DIR_TMP}/src/T1w_spacing-DWI.nii.gz ${DIMS_DWI} 0 0 2
REF_IMG=${DIR_TMP}/src/T1w_spacing-DWI.nii.gz

## apply transforms to B0
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_TMP}/src/b0_raw_mean.nii.gz \
  -o ${DIR_TMP}/src/b0_mean_coreg.nii.gz \
  -t identity \
  -t ${DIR_TMP}/src/xfm_1Warp.nii.gz \
  -t ${DIR_TMP}/src/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${DIR_TMP}/src/b0_mean_coreg.nii.gz ${DIR_TMP}/src/b0_mean_coreg.mif

## apply transforms to B0 mask
mrconvert mask_den_unr_preproc_unb.mif ${DIR_TMP}/src/b0_mask.nii.gz
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${DIR_TMP}/src/b0_mask.nii.gz \
  -o ${DIR_TMP}/src/b0_mask_coreg.nii.gz \
  -t identity \
  -t ${DIR_TMP}/src/xfm_1Warp.nii.gz \
  -t ${DIR_TMP}/src/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${DIR_TMP}/src/b0_mask_coreg.nii.gz ${DIR_TMP}/src/b0_mask_coreg.mif

## apply transforms to preprocessed DWI data
mrconvert dwi_den_unr_preproc_unbiased.mif ${DIR_TMP}/src/dwi_preproc.nii.gz
antsApplyTransforms -d 3 -e 3 -n Linear \
  -i ${DIR_TMP}/src/dwi_preproc.nii.gz \
  -o ${DIR_TMP}/src/dwi_preproc_coreg.nii.gz \
  -t identity \
  -t ${DIR_TMP}/src/xfm_1Warp.nii.gz \
  -t ${DIR_TMP}/src/xfm_0GenericAffine.mat \
  -r ${REF_IMG}
mrconvert ${DIR_TMP}/src/dwi_preproc_coreg.nii.gz \
  dwi_preproc_coreg.mif -fslgrad ${DWI_BVEC} ${DWI_BVAL}

# Save Output for QC and Next Processing Steps ---------------------------------
## Save T1w as MIF and NIfTI in DWI spacing
mkdir -p ${DIR_SAVE}/dwi/native_anat
mrconvert ${DIR_TMP}/src/${PIDSTR}_T1w.nii.gz \
  ${DIR_SAVE}/dwi/native_anat/${PIDSTR}_T1w.mif
cp ${DIR_TMP}/src/T1w_spacing-DWI.nii.gz \
  ${DIR_SAVE}/dwi/native_anat/${PIDSTR}_proc-dwiSpace_T1w.nii.gz

## Save preprocessed DWI
mkdir -p ${DIR_SAVE}/dwi/preproc/mask
mkdir -p ${DIR_SAVE}/dwi/preproc/qc
cp ${DIR_TMP}/dwi/dwi_preproc_coreg.mif \
  ${DIR_SAVE}/dwi/preproc/${PIDSTR}_dwi.mif
cp ${DIR_TMP}/src/b0_mask_coreg.mif \
  ${DIR_SAVE}/dwi/preproc/mask/${PIDSTR}_mask-brain+b0.mif
cp ${DIR_TMP}/src/b0_mean_coreg.mif \
  ${DIR_SAVE}/dwi/preproc/${PIDSTR}_proc-mean_b0.mif

## save QC images
mrconvert bias.mif ${DIR_SAVE}/dwi/preproc/qc/${PIDSTR}_bias.nii.gz
mrconvert noise.mif ${DIR_SAVE}/dwi/preproc/qc/${PIDSTR}_noise.nii.gz
mrconvert residual.mif ${DIR_SAVE}/dwi/preproc/qc/${PIDSTR}_noise.nii.gz
mrconvert residualUnringed.mif ${DIR_SAVE}/dwi/preproc/qc/${PIDSTR}_noise.nii.gz
mrconvert ${DIR_TMP}/src/b0_mean_coreg.mif \
  ${DIR_SAVE}/dwi/preproc/qc/${PIDSTR}_proc-mean_b0.nii.gz

#===============================================================================
# end of Function
#===============================================================================
exit 0

