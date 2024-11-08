#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkniUHR
# WORKFLOW:      UHRClean
# DESCRIPTION:   TKNI anatomical multi-atlas labelling
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-07
# README:
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
OPTS=$(getopt -o hkvn --long pi:,project:,dir-project:,pipeline:,\
image:,threads:,\
dir-save:,dir-scratch:,\
keep,help,verbose,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=tkoscik
PROJECT=brainARK
PIPELINE=tkniUHR
DIR_PROJECT=/data/x/projects/${PI}/${PROJECT}
IMAGE=
THREADS=4
DIR_SAVE=
DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
KEEP="false"
HELP="false"
VERBOSE="false"
NO_PNG="false"

while true; do
  case "$1" in
    -h | --help) HELP="true" ; shift ;;
    -v | --verbose) VERBOSE="true" ; shift ;;
    -n | --no-png) NO_PNG="true" ; shift ;;
    -k | --keep) KEEP="true" ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --pipeline) PIPELINE="$2" ; shift 2 ;;
    --image) IMAGE="$2" ; shift 2 ;;
    --threads) THREADS="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
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
  echo '  --pid              unique individual identifier'
  echo '  --sid              session identifier'
  echo '  --input-dcm        full path to DICOMs, may be directory or zip-file'
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  echo 'Procedure: '
  echo '(1) denoise image'
  echo '(2) rough tissue segmentation for WM mask using synthseg'
  echo '(3) intensity debias'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================

if [[ ${VERBOSE} == "true" ]]; then
  echo -e "##### TKNI: ${FCN_NAME} #####"
  echo -e "PI:\t\t${PI}"
  echo -e "PROJECT:\t${PROJECT}"
  echo -e "PIPELINE:\t${PIPELINE}\n"
fi

# setup output directories -----------------------------------------------------
DIR_CLEAN=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/cleaned
mkdir -p ${DIR_CLEAN}/label
mkdir -p ${DIR_CLEAN}/mask
mkdir -p ${DIR_CLEAN}/posterior
mkdir -p ${DIR_SCRATCH}

# initialize outputs -----------------------------------------------------------
PFX=$(getBidsBase -i ${IMAGE} -s)
MOD=$(getField -i ${IMAGE} -f modality)

# Copy RAW image to scratch ----------------------------------------------------
cp ${IMAGE} ${DIR_SCRATCH}/image.nii.gz

# Denoise ----------------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>Denoising"; fi
DenoiseImage -d 3 -n Rician \
  -i ${DIR_SCRATCH}/image.nii.gz \
  -o ${DIR_SCRATCH}/image.nii.gz
fslmaths ${DIR_SCRATCH}/image.nii.gz ${DIR_SCRATCH}/image.nii.gz -odt short

# Tissue Segmentation ----------------------------------------------------------
## -generate WM posterior for debiasing as well as mask of brain region.
## -resample to native space not 1mm space
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>synthSeg"; fi
mri_synthseg --i ${DIR_SCRATCH}/image.nii.gz \
  --o ${DIR_SCRATCH}/label-synthseg.nii.gz \
  --post ${DIR_SCRATCH}/posterior-synthseg.nii.gz \
  --robust --threads ${THREADS}

## extract WM posterior
if [[ ${VERBOSE} == "true" ]]; then echo "   >>>extract WM posterior"; fi
fslsplit ${DIR_SCRATCH}/posterior-synthseg.nii.gz ${DIR_SCRATCH}/tpost_ -t
fslmaths ${DIR_SCRATCH}/tpost_0001.nii.gz \
  -add ${DIR_SCRATCH}/tpost_0005.nii.gz \
  -add ${DIR_SCRATCH}/tpost_0019.nii.gz \
  -add ${DIR_SCRATCH}/tpost_0023.nii.gz \
  ${DIR_SCRATCH}/posterior-wm.nii.gz
rm ${DIR_SCRATCH}/tpost_*

# rescale to native size
if [[ ${VERBOSE} == "true" ]]; then echo "   >>>rescale synthSeg output to image spacing"; fi
antsApplyTransforms -d 3 -n MultiLabel -t identity \
  -i ${DIR_SCRATCH}/label-synthseg.nii.gz \
  -o ${DIR_SCRATCH}/label-synthseg.nii.gz \
  -r ${DIR_SCRATCH}/image.nii.gz
antsApplyTransforms -d 3 -n Linear -t identity \
  -i ${DIR_SCRATCH}/posterior-wm.nii.gz \
  -o ${DIR_SCRATCH}/posterior-wm.nii.gz \
  -r ${DIR_SCRATCH}/image.nii.gz

## extract FG and Brain mask
if [[ ${VERBOSE} == "true" ]]; then echo "   >>>extract FG and Brain mask"; fi
fslmaths ${DIR_SCRATCH}/label-synthseg.nii.gz \
  -bin ${DIR_SCRATCH}/mask-fg.nii.gz -odt char
fslmaths ${DIR_SCRATCH}/label-synthseg.nii.gz \
  -thr 24 -uthr 24 -binv -mul ${DIR_SCRATCH}/label-synthseg.nii.gz -bin \
  ${DIR_SCRATCH}/mask-brain.nii.gz -odt char

# Intensity Debias -------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>Intensity debias"; fi
N4BiasFieldCorrection -d 3 \
  -i ${DIR_SCRATCH}/image.nii.gz \
  -o ${DIR_SCRATCH}/image.nii.gz \
  --weight-image ${DIR_SCRATCH}/posterior-wm.nii.gz \
  --bspline-fitting [200,3,0.0,0.5] \
  --shrink-factor 8 \
  --convergence [50x50x50,0] \
  --histogram-sharpening [0.3,0.01,200]
fslmaths ${DIR_SCRATCH}/image.nii.gz ${DIR_SCRATCH}/image.nii.gz -odt short

# Anisotropic Filtering ------------------------------------------------------
SIF_CIVET="/data/neuroimage_containers/civet_v2.1.1.sif"
gunzip ${DIR_SCRATCH}/image.nii.gz
singularity instance start --bind ${DIR_SCRATCH}:/mnt ${SIF_CIVET} civet
singularity exec instance://civet nii2mnc /mnt/image.nii /mnt/tmp.mnc
singularity exec instance://civet geo_smooth 0.0004 6 /mnt/tmp.mnc /mnt/tmpsmooth.mnc
singularity exec instance://civet mnc2nii /mnt/tmpsmooth.mnc /mnt/smooth.nii
singularity instance stop civet
gzip ${DIR_SCRATCH}/smooth.nii
reorientRPI --image ${DIR_SCRATCH}/smooth.nii.gz
mv ${DIR_SCRATCH}/smooth.nii.gz ${DIR_SCRATCH}/image.nii.gz
rm ${DIR_SCRATCH}/tmp*

# rename move output to native -----------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>Rename and save output"; fi
cp ${DIR_SCRATCH}/image.nii.gz \
  ${DIR_CLEAN}/${PFX}_${MOD}.nii.gz
cp ${DIR_SCRATCH}/mask-fg.nii.gz \
  ${DIR_CLEAN}/mask/${PFX}_mask-fg+synthseg.nii.gz
cp ${DIR_SCRATCH}/mask-brain.nii.gz \
  ${DIR_CLEAN}/mask/${PFX}_mask-brain+synthseg.nii.gz
cp ${DIR_SCRATCH}/label-synthseg.nii.gz \
  ${DIR_CLEAN}/label/${PFX}_label-synthseg.nii.gz
cp ${DIR_SCRATCH}/posterior-wm.nii.gz \
  ${DIR_CLEAN}/posterior/${PFX}_posterior-wm+synthseg.nii.gz

# generate PNG of output -------------------------------------------------------
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${DIR_CLEAN}/${PFX}_${MOD}.nii.gz
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0

