#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      MATS
# DESCRIPTION:   TKNI anatomical multi-approach tissue segmentation
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-04-11
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
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S)
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
OPTS=$(getopt -o hvlnr --long pi:,project:,dir-project:,\
id:,dir-id:,\
image:,mod:,mask:,mask-dil:,\
method:,atlas:,roi:,prob:,prior:,k-class:,\
weight-ants:,weight-5tt:,weight-synth:,pthresh:,fmed:,\
no-keep,no-jac,no-thickness,refine:,no-png,no-rmd,\
dir-scratch:,requires:,\
help,verbose,loquacious,force -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_SCRATCH=
DIR_SAVE=
IDPFX=
IDDIR=

IMAGE=
MASK=
MOD="T1w"

METHOD="ants,5tt,synthseg"
ATLAS="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_T1w.nii.gz"
ROI="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_roi-brain_T1w.nii.gz"
PROB="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_prob-brain.nii.gz"
PRIOR="${TKNI_TEMPLATE}/ANTS/OASIS/ANTS_OASIS_prior-%d+5tt.nii.gz"
K=3
WEIGHT_ANTS=0
WEIGHT_5TT=0
WEIGHT_SYNTH=0
PTHRESH=0
MASK_DIL=2
FMED=3

NO_JAC="false"
NO_THICKNESS="false"

REFINE="false"
#REFINE="DKT+MALF,wmparc+MALF,hcpmmp1+MALF"

HELP=false
VERBOSE=false
KEEP_PARTS=true
NO_PNG=false
NO_RMD=false

PIPE=tkni
FLOW=MATS
REQUIRES="tkniDICOM,tkniAINIT"
FORCE=false
ROIS=("gm" "gmDeep" "wm" "csf")
HUE=("#FF0000" "#00FF00" "#0000FF" "#FFFF00" "#00FFFF" "#FF00FF")
#CBARS=("#000000,#7b0031,#6a5700,#008a3c,#00a7b2,#b9afff"\
#       "#000000,#1c4400,#006360,#0075e7,#ff49d9,#ffa277"\
#       "#000000,#003f5f,#9e009f,#e32f00,#a19b00,#00d292"\
#       "#000000,#4c3900,#036700,#008587,#7e8eff,#ff97d8")
#CLABS=("#000000,#FF0000,#00FF00,#0000FF,#FFFF00")

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image) IMG="$2" ; shift 2 ;;
    --mod) MOD="$2" ; shift 2 ;;
    --mask) MASK="$2" ; shift 2 ;;
    --mask-dil) MASK_DIL="$2" ; shift 2 ;;
    --method) METHOD="$2" ; shift 2 ;;
    --atlas) ATLAS="false" ; shift ;;
    --roi) ROI="$2" ; shift 2 ;;
    --prob) PROB="$2" ; shift 2 ;;
    --prior) PRIOR="$2" ; shift 2 ;;
    --k-class) K="$2" ; shift 2 ;;
    --weight-ants) WEIGHT_ANTS="$2" ; shift 2 ;;
    --weight-5tt) WEIGHT_5TT="$2" ; shift 2 ;;
    --weight-synth) WEIGHT_SYNTH="$2" ; shift 2 ;;
    --no-keep) KEEP_PARTS="false" ; shift ;;
    --no-thickness) NO_THICKNESS="true" ; shift ;;
    --refine) REFINE="$2" ; shift 2 ;;
    --keep-parts) KEEP_PARTS="true" ; shift ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
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
  DIR_SCRATCH=${TKNI_SCRATCH}/${PIPE}${FLOW}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi

if [[ ${VERBOSE} == "true" ]]; then
  echo "Running ${PIPE}${FLOW}"
  echo -e "PI:\t${PI}\nPROJECT:\t${PROJECT}"
  echo -e "PROJECT DIRECTORY:\t${DIR_PROJECT}"
  echo -e "SCRATCH DIRECTORY:\t${DIR_SCRATCH}"
  echo -e "Start Time:\t${PROC_START}"
fi
ANTS_VERBOSE=0
if [[ ${LOQUACIOUS} == "true" ]]; then ANTS_VERBOSE=1; fi

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

if [[ ${VERBOSE} == "true" ]]; then
  echo -e "ID:\t${IDPFX}"
  echo -e "SUBDIR:\t${IDDIR}"
fi

## Check if Prerequisites are run and QC'd -------------------------------------
if [[ ${REQUIRES} != "null" ]]; then
  REQUIRES=(${REQUIRES//,/ })
  ERROR_STATE=0
  for (( i=0; i<${#REQUIRES[@]}; i++ )); do
    REQ=${REQUIRES[${i}]}
    FCHK=${DIR_PROJECT}/status/${REQ}/DONE_${REQ}_${IDPFX}.txt
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
FCHK=${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
FDONE=${DIR_PROJECT}/status/${PIPE}${FLOW}/DONE_${PIPE}${FLOW}_${IDPFX}.txt
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

# Set Up Directories -----------------------------------------------------------
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
if [[ -z ${DIR_ANAT} ]]; then DIR_ANAT=${DIR_PIPE}/anat; fi
mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_ANAT}

# Gather Inputs ----------------------------------------------------------------
## keep copy of original image for output image overlays
if [[ -z ${IMAGE} ]]; then IMAGE=${DIR_ANAT}/native/${IDPFX}_${MOD}.nii.gz; fi
if [[ -z ${MASK} ]]; then MASK=${DIR_ANAT}/mask/${IDPFX}_mask-brain.nii.gz; fi
cp ${IMAGE} ${DIR_SCRATCH}/image.nii.gz
cp ${MASK} ${DIR_SCRATCH}/mask.nii.gz
cp ${DIR_SCRATCH}/image.nii.gz ${DIR_SCRATCH}/image_orig.nii.gz
IMAGE=${DIR_SCRATCH}/image.nii.gz
MASK=${DIR_SCRATCH}/mask.nii.gz

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> gathered participant image and mask"
fi

# Dilate and apply masks to images before segmentation -------------------------
if [[ ${MASK_DIL} -gt 0 ]]; then ImageMath 3 ${MASK} MD ${MASK} ${MASK_DIL}; fi
niimath ${IMAGE} -mas ${MASK} ${IMAGE}

# Multi-Tool Tissue Segmentation ===============================================
## ANTs Cortical Thickness (short circuit brain extraction phase) --------------
## short circuit brain extraction phase
if [[ ${METHOD^^} == *"ANTS"* ]]; then
  TM="ANTS"
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> running ${TM}"; fi
  TDIR=${DIR_SCRATCH}/${TM}
  mkdir -p ${DIR_SCRATCH}/${TM}/antscx
  cp ${MASK} ${TDIR}/antscx/ANTSCX_BrainExtractionMask.nii.gz
  cp ${IMAGE} ${TDIR}/antscx/ANTSCX_BrainExtractionBrain.nii.gz
  cp ${ROI} ${TDIR}/antscx/ANTSCX_ExtractedTemplateBrain.nii.gz
  touch ${TDIR}/antscx/ANTSCX_ACTStage1Complete.txt

  MOVING=${TDIR}/antscx/ANTSCX_BrainExtractionMask.nii.gz
  FIXED=${TDIR}/antscx/ANTSCX_ExtractedTemplateBrain.nii.gz
  antsRegistration --dimensionality 3 --float 1 --verbose ${ANTS_VERBOSE} \
    --random-seed 41066609 \
    --write-composite-transform 0 \
    --collapse-output-transforms 1 \
    --initialize-transforms-per-stage 0 \
    --use-histogram-matching 1 \
    --winsorize-image-intensities [ 0.005,0.995 ] \
    --output ${TDIR}/antscx/ANTSCX_BrainExtractionPrior \
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
    -e ${ATLAS} -m ${PROB} -p ${PRIOR} \
    -o ${TDIR}/antscx/ANTSCX_

  ## posteriors
  TLS=($(ls ${TDIR}/antscx/ANTSCX_BrainSegmentationPosteriors*.nii.gz))
  PLAB=("csf" "gm" "wm" "gmDeep")
  for (( i=0; i<${#TLS[@]}; i++ )); do
    PNUM=$((${i}+1))
    cp ${TDIR}/antscx/ANTSCX_BrainSegmentationPosteriors${PNUM}.nii.gz \
      ${TDIR}/${IDPFX}_posterior-${PLAB[${i}]}+${TM}.nii.gz
  done
  ImageMath 3 ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz MostLikely ${PTHRESH} \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  ImageMath 4 ${TDIR}/${IDPFX}_posterior-tissue+${TM}.nii.gz \
    TimeSeriesAssemble 1 0 \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz

  if [[ ${WEIGHT_ANTS} -eq 0 ]]; then WEIGHT_ANTS=1; fi

  if [[ "${KEEP_PARTS}" == "true" ]]; then
    if [[ ${NO_PNG} == "false" ]]; then
      for (( i=0; i<${#ROIS[@]}; i++ )); do
        ROI=${ROIS[${i}]}
        niimath ${TDIR}/${IDPFX}_posterior-${ROI}+${TM}.nii.gz \
          -thr 0.2 -bin ${TDIR}/mask-png-fg.nii.gz -odt char
        make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz \
          --fg ${TDIR}/${IDPFX}_posterior-${ROI}+${TM}.nii.gz \
          --fg-mask ${TDIR}/mask-png-fg.nii.gz \
          --fg-color "timbow:hue=${HUE[${i}]}:lum=0,85" \
          --fg-cbar "true" --fg-alpha 50 \
          --layout "9:z;9:z;9:z" \
          --filename ${IDPFX}_posterior-${ROI}+${TM} \
          --dir-save ${TDIR}
      done
      niimath ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz \
        -bin ${TDIR}/mask-png-fg.nii.gz -odt char
      make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz\
        --fg ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz \
        --fg-color "timbow:hue=#FF0000;lum=65,65:cyc=4/6" \
        --fg-cbar "false" --fg-alpha 75 \
        --layout "9:z;9:z;9:z" \
        --filename ${IDPFX}_label-tissue+${TM} \
          --dir-save ${TDIR}
    fi
  fi
fi

## 5TT Segmentation ------------------------------------------------------------
if [[ ${METHOD^^} == *"5TT"* ]]; then
  TM="5TT"
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> running ${TM}"; fi
  TDIR=${DIR_SCRATCH}/${TM}
  mkdir -p ${TDIR}
  mrconvert ${DIR_SCRATCH}/image.nii.gz ${TDIR}/image.mif
  5ttgen fsl ${TDIR}/image.mif ${TDIR}/posterior-${TM}.mif -premasked
  mrconvert ${TDIR}/posterior-${TM}.mif ${TDIR}/posterior-${TM}.nii.gz
  antsApplyTransforms -d 3 -e 3 -n Linear \
    -i ${TDIR}/posterior-${TM}.nii.gz \
    -o ${TDIR}/posterior-${TM}.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz \
    -t identity
  ## get Tissue probability maps as separate files
  3dTsplit4D -prefix ${TDIR}/tvol.nii.gz ${TDIR}/posterior-${TM}.nii.gz
  mv ${TDIR}/tvol.0.nii.gz ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz
  mv ${TDIR}/tvol.1.nii.gz ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz
  mv ${TDIR}/tvol.2.nii.gz ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz
  mv ${TDIR}/tvol.3.nii.gz ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  ImageMath 3 ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz MostLikely ${PTHRESH} \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  ImageMath 4 ${TDIR}/${IDPFX}_posterior-tissue+${TM}.nii.gz \
    TimeSeriesAssemble 1 0 \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  if [[ ${WEIGHT_5TT} -eq 0 ]]; then WEIGHT_5TT=1; fi

  if [[ "${KEEP_PARTS}" == "true" ]]; then
    if [[ ${NO_PNG} == "false" ]]; then
      for (( i=0; i<${#ROIS[@]}; i++ )); do
        ROI=${ROIS[${i}]}
        niimath ${TDIR}/${IDPFX}_posterior-${ROI}+${TM}.nii.gz \
          -thr 0.2 -bin ${TDIR}/mask-png-fg.nii.gz -odt char
        make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz \
          --fg ${TDIR}/${IDPFX}_posterior-${ROI}+${TM}.nii.gz \
          --fg-mask ${TDIR}/mask-png-fg.nii.gz \
          --fg-color "timbow:hue=${HUE[${i}]}:lum=0,85" \
          --fg-cbar "true" --fg-alpha 50 \
          --layout "9:z;9:z;9:z" \
          --filename ${IDPFX}_posterior-${ROI}+${TM} \
          --dir-save ${TDIR} -v
      done
      niimath ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz \
        -bin ${TDIR}/mask-png-fg.nii.gz -odt char
      make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz\
        --fg ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz \
        --fg-color "timbow:hue=#FF0000;lum=65,65:cyc=4/6" \
        --fg-cbar "false" --fg-alpha 75 \
        --layout "9:z;9:z;9:z" \
        --filename ${IDPFX}_label-tissue+${TM} \
          --dir-save ${TDIR} -v
    fi
  fi
fi

## SynthSeg --------------------------------------------------------------------
if [[ ${METHOD^^} == *"SYNTH"* ]]; then
  TM="SYNTHSEG"
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> running ${TM}"; fi
  TDIR=${DIR_SCRATCH}/${TM}
  mkdir -p ${TDIR}
  mri_synthseg --i ${DIR_SCRATCH}/image.nii.gz \
    --o ${TDIR}/label-tissue+${TM}.nii.gz \
    --post ${TDIR}/posterior-${TM}.nii.gz \
    --robust --threads 4 --cpu
  antsApplyTransforms -d 3 -n MultiLabel \
    -i ${TDIR}/label-tissue+${TM}.nii.gz \
    -o ${TDIR}/label-tissue+${TM}.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz -t identity
  antsApplyTransforms -d 3 -e 3 -n Linear \
    -i ${TDIR}/posterior-${TM}.nii.gz \
    -o ${TDIR}/posterior-${TM}.nii.gz \
    -r ${DIR_SCRATCH}/image.nii.gz -t identity
  3dTsplit4D -prefix ${TDIR}/tvol.nii.gz ${TDIR}/posterior-${TM}.nii.gz
  ## CSF
  niimath ${TDIR}/tvol.03.nii.gz -add ${TDIR}/tvol.04.nii.gz \
    -add ${TDIR}/tvol.11.nii.gz -add ${TDIR}/tvol.12.nii.gz \
    -add ${TDIR}/tvol.16.nii.gz -add ${TDIR}/tvol.21.nii.gz \
    -add ${TDIR}/tvol.22.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  ## GM
  niimath ${TDIR}/tvol.02.nii.gz -add ${TDIR}/tvol.14.nii.gz \
    -add ${TDIR}/tvol.06.nii.gz -add ${TDIR}/tvol.15.nii.gz \
    -add ${TDIR}/tvol.18.nii.gz -add ${TDIR}/tvol.20.nii.gz \
    -add ${TDIR}/tvol.24.nii.gz -add ${TDIR}/tvol.29.nii.gz \
    -add ${TDIR}/tvol.30.nii.gz -add ${TDIR}/tvol.32.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz
  ## WM
  niimath ${TDIR}/tvol.01.nii.gz -add ${TDIR}/tvol.05.nii.gz \
    -add ${TDIR}/tvol.13.nii.gz -add ${TDIR}/tvol.19.nii.gz \
    -add ${TDIR}/tvol.23.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz
  ## Deep GM
  niimath ${TDIR}/tvol.07.nii.gz -add ${TDIR}/tvol.08.nii.gz \
    -add ${TDIR}/tvol.09.nii.gz -add ${TDIR}/tvol.10.nii.gz \
    -add ${TDIR}/tvol.17.nii.gz -add ${TDIR}/tvol.25.nii.gz \
    -add ${TDIR}/tvol.26.nii.gz -add ${TDIR}/tvol.27.nii.gz \
    -add ${TDIR}/tvol.28.nii.gz -add ${TDIR}/tvol.31.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz
  ImageMath 3 ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz MostLikely ${PTHRESH} \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  ImageMath 4 ${TDIR}/${IDPFX}_posterior-tissue+${TM}.nii.gz \
    TimeSeriesAssemble 1 0 \
    ${TDIR}/${IDPFX}_posterior-gm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-wm+${TM}.nii.gz \
    ${TDIR}/${IDPFX}_posterior-csf+${TM}.nii.gz
  if [[ ${WEIGHT_SYNTH} -eq 0 ]]; then WEIGHT_SYNTH=1; fi

  if [[ "${KEEP_PARTS}" == "true" ]]; then
    if [[ ${NO_PNG} == "false" ]]; then
      for (( i=0; i<${#ROIS[@]}; i++ )); do
        ROI=${ROIS[${i}]}
        niimath ${TDIR}/${IDPFX}_posterior-${ROI}+${TM}.nii.gz \
          -thr 0.2 -bin ${TDIR}/mask-png-fg.nii.gz -odt char
        make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz \
          --fg ${TDIR}/${IDPFX}_posterior-${ROI}+${TM}.nii.gz \
          --fg-mask ${TDIR}/mask-png-fg.nii.gz \
          --fg-color "timbow:hue=${HUE[${i}]}:lum=0,85" \
          --fg-cbar "true" --fg-alpha 50 \
          --layout "9:z;9:z;9:z" \
          --filename ${IDPFX}_posterior-${ROI}+${TM} \
          --dir-save ${TDIR}
      done
      niimath ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz \
        -bin ${TDIR}/mask-png-fg.nii.gz -odt char
      make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz\
        --fg ${TDIR}/${IDPFX}_label-tissue+${TM}.nii.gz \
        --fg-color "timbow:hue=#FF0000;lum=65,65:cyc=4/6" \
        --fg-cbar "false" --fg-alpha 75 \
        --layout "9:z;9:z;9:z" \
        --filename ${IDPFX}_label-tissue+${TM} \
          --dir-save ${TDIR}
    fi
  fi
fi

## Combine Posteriors ----------------------------------------------------------
### Weighted Average Posterior - - - - - - - - - - - - - - - - - - - - - - - - -
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> weighting posteriors"
fi
TCLASS=("csf" "gm" "gmDeep" "wm")
TWEIGHT=$(($((${WEIGHT_ANTS} + ${WEIGHT_5TT})) + ${WEIGHT_SYNTH}))
POST_C=(${DIR_SCRATCH}/${IDPFX}_posterior-csf.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_posterior-gm.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_posterior-gmDeep.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_posterior-wm.nii.gz)
niimath ${DIR_SCRATCH}/image.nii.gz -mul 0 ${POST_C[0]} -odt flt
for i in {1..3}; do cp ${POST_C[0]} ${POST_C[${i}]}; done
if [[ ${METHOD^^} == *"ANTS"* ]]; then
  TM="ANTS"
  for j in {0..3}; do
    TP=${DIR_SCRATCH}/${TM}/${IDPFX}_posterior-${TCLASS[${j}]}+${TM}.nii.gz
    TW=${DIR_SCRATCH}/${TM}/weight-${TCLASS[${j}]}+${TM}.nii.gz
    niimath ${TP} -mul ${WEIGHT_ANTS} -div ${TWEIGHT} ${TW}
    niimath ${POST_C[${j}]} -add ${TW} ${POST_C[${j}]}
  done
fi
if [[ ${METHOD^^} == *"5TT"* ]]; then
  TM="5TT"
  for j in {0..3}; do
    TP=${DIR_SCRATCH}/${TM}/${IDPFX}_posterior-${TCLASS[${j}]}+${TM}.nii.gz
    TW=${DIR_SCRATCH}/${TM}/weight-${TCLASS[${j}]}+${TM}.nii.gz
    niimath ${TP} -mul ${WEIGHT_5TT} -div ${TWEIGHT} ${TW}
    niimath ${POST_C[${j}]} -add ${TW} ${POST_C[${j}]}
  done
fi
if [[ ${METHOD^^} == *"SYNTH"* ]]; then
  TM="SYNTHSEG"
  for j in {0..3}; do
    TP=${DIR_SCRATCH}/${TM}/${IDPFX}_posterior-${TCLASS[${j}]}+${TM}.nii.gz
    TW=${DIR_SCRATCH}/${TM}/weight-${TCLASS[${j}]}+${TM}.nii.gz
    niimath ${TP} -mul ${WEIGHT_SYNTH} -div ${TWEIGHT} ${TW}
    niimath ${POST_C[${j}]} -add ${TW} ${POST_C[${j}]}
  done
fi

### Most Likely Label - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> most likely label"
fi
LABEL_C=${DIR_SCRATCH}/${IDPFX}_label-tissue.nii.gz
ImageMath 3 ${LABEL_C} MostLikely ${PTHRESH} ${POST_C[@]}

### Median Filter - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
if [[ ${FMED} -gt 0 ]]; then
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> applying median filter"
  fi
  niimath ${LABEL_C} -kernel boxv ${FMED} -fmedian ${LABEL_C} -odt char
fi

### Merge into multi-volume posterior file -------------------------------------
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> merge into multivolume posterior"
fi
DIR_POSTERIOR=${DIR_ANAT}/posterior
mkdir -p ${DIR_POSTERIOR}
ImageMath 4 ${DIR_POSTERIOR}/${IDPFX}_posterior-tissue.nii.gz \
  TimeSeriesAssemble 1 0 \
  ${DIR_SCRATCH}/${IDPFX}_posterior-gm.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_posterior-gmDeep.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_posterior-wm.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_posterior-csf.nii.gz

## generate PNGs ---------------------------------------------------------------
if [[ ${NO_PNG} == "false" ]]; then
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> generating PNGs"
  fi
  for (( i=0; i<${#ROIS[@]}; i++ )); do
    ROI=${ROIS[${i}]}
    niimath ${DIR_SCRATCH}/${IDPFX}_posterior-${ROI}.nii.gz \
      -thr 0.2 -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
    make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz \
      --fg ${DIR_SCRATCH}/${IDPFX}_posterior-${ROI}.nii.gz \
      --fg-mask ${DIR_SCRATCH}/mask-png-fg.nii.gz \
      --fg-color "timbow:hue=${HUE[${i}]}:lum=0,85" \
      --fg-cbar "true" --fg-alpha 50 \
      --layout "9:z;9:z;9:z" \
      --filename ${IDPFX}_posterior-${ROI}
  done
  niimath ${DIR_SCRATCH}/${IDPFX}_label-tissue.nii.gz \
    -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
  make3Dpng --bg ${DIR_SCRATCH}/image.nii.gz --bg-threshold 2.5,97.5 \
    --fg ${DIR_SCRATCH}/${IDPFX}_label-tissue.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_label-tissue.nii.gz \
    --fg-color "timbow:hue=#FF0000;lum=65,65:cyc=4/6" \
    --fg-cbar "true" --fg-alpha 75 \
    --layout "9:z;9:z;9:z" \
    --filename ${IDPFX}_label-tissue
fi

## Deformation based cortical thickness ----------------------------------------
if [[ ${NO_THICKNESS} == "false" ]]; then
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> calculating cortical thickness"
  fi
  KellyKapowski -d 3 --verbose ${ANTS_VERBOSE} \
    -s [ ${LABEL_C},2,4 ] \
    -g ${POST_C[1]} -w ${POST_C[3]} \
    -o ${DIR_SCRATCH}/${IDPFX}_thickness.nii.gz \
    -c [ 45,0.0,10 ] -r 0.025 -m 1.5 -n 10 -b 0 -t 10

  if [[ ${NO_PNG} == "false" ]]; then
    niimath ${DIR_SCRATCH}/${IDPFX}_thickness.nii.gz \
      -bin ${DIR_SCRATCH}/mask-png-fg.nii.gz -odt char
    make3Dpng --bg ${IMAGE} \
      --fg ${DIR_SCRATCH}/${IDPFX}_thickness.nii.gz \
      --fg-mask ${DIR_SCRATCH}/mask-png-fg.nii.gz \
      --fg-color "hot" --fg-cbar "true" --fg-alpha 50 \
      --layout "9:z;9:z;9:z" \
      --filename ${IDPFX}_thickness \
      --dir-save ${DIR_SCRATCH}
  fi
fi

## Refine Labels if requested --------------------------------------------------
if [[ ${REFINE} != "false" ]]; then
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> refine existing labels"
  fi
  LABELS=(${REFINE//,/ })
  for (( i=0; i<${#LABELS[@]}; i++ )); do
    TLABEL=${LABELS[${i}]}
    TFLOW=(${TLABEL//\+/ })
    if [[ ! -f ${TLABEL} ]]; then
      TLABEL=${DIR_ANAT}/label/${TFLOW[1]}/${IDPFX}_label-${TLABEL}.nii.gz
    fi
    if [[ ! -f ${TLABEL} ]]; then
      echo "ERROR [${PIPE}:${FLOW}] Label file ${TLABEL} not found"
    else
      labelRefine --label ${TLABEL} --seg ${LABEL_C} \
        --anat ${DIR_SCRATCH}/image_orig.nii.gz \
        --dir-save ${DIR_SCRATCH}
    fi
  done
fi

## Move results to OUTPUT folder -----------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> copy output"
fi
mkdir -p ${DIR_ANAT}/label/MATS
if [[ ${KEEP_PARTS} == "true" ]]; then
  if [[ ${METHOD^^} == *"ANTS"* ]]; then mkdir -p ${DIR_POSTERIOR}/ANTS; fi
  if [[ ${METHOD^^} == *"5TT"* ]]; then mkdir -p ${DIR_POSTERIOR}/5TT; fi
  if [[ ${METHOD^^} == *"SYNTH"* ]]; then mkdir -p ${DIR_POSTERIOR}/SYNTHSEG; fi
fi

mv ${DIR_SCRATCH}/${IDPFX}_posterior-* ${DIR_POSTERIOR}/
mv ${DIR_SCRATCH}/${IDPFX}_label-tissue* ${DIR_ANAT}/label/

if [[ ${REFINE} != "false" ]]; then
  mv ${DIR_SCRATCH}/${IDPFX}_label-* ${DIR_ANAT}/label/MATS/
fi

if [[ ${KEEP_PARTS} == "true" ]]; then
  if [[ ${METHOD^^} == *"ANTS"* ]]; then
    mv ${DIR_SCRATCH}/ANTS/${IDPFX}_posterior-* ${DIR_POSTERIOR}/ANTS/
    mv ${DIR_SCRATCH}/ANTS/${IDPFX}_label* ${DIR_ANAT}/label/MATS/
  fi
  if [[ ${METHOD^^} == *"5TT"* ]]; then
    mv ${DIR_SCRATCH}/5TT/${IDPFX}_posterior-* ${DIR_POSTERIOR}/5TT/
    mv ${DIR_SCRATCH}/5TT/${IDPFX}_label* ${DIR_ANAT}/label/MATS/
  fi
  if [[ ${METHOD^^} == *"SYNTH"* ]]; then
    mv ${DIR_SCRATCH}/SYNTHSEG/${IDPFX}_posterior-* ${DIR_POSTERIOR}/SYNTHSEG/
    mv ${DIR_SCRATCH}/SYNTHSEG/${IDPFX}_label* ${DIR_ANAT}/label/MATS/
  fi
fi

if [[ ${NO_THICKNESS} == "false" ]]; then
  mkdir -p ${DIR_ANAT}/outcomes/thickness
  mv ${DIR_SCRATCH}/${IDPFX}_thickness.* ${DIR_ANAT}/outcomes/thickness
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}
  RMD=${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}.Rmd

  echo -e '---\ntitle: "&nbsp;"\noutput: html_document\n---\n' > ${RMD}
  echo '```{r setup, include=FALSE}' >> ${RMD}
  echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
  echo 'knitr::include_graphics("'${TKNIPATH}'/TK_BRAINLab_logo.png")' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, echo=FALSE}' >> ${RMD}
  echo 'library(DT)' >> ${RMD}
  echo 'library(downloadthis)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## '${PIPE}${FLOW}': Multi-Approach Tissue Segmentation' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '## Tissue Segmentation' >> ${RMD}
  TNII=${DIR_ANAT}/label/${IDPFX}_label-tissue.nii.gz
  TPNG=${DIR_ANAT}/label/${IDPFX}_label-tissue.png
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '## Tissue Posterior Probabilities {.tabset}' >> ${RMD}
  echo '### Click to View ->' >> ${RMD}
  echo '### Gray Matter' >> ${RMD}
    TNII=${DIR_POSTERIOR}/${IDPFX}_posterior-gm.nii.gz
    TPNG=${DIR_POSTERIOR}/${IDPFX}_posterior-gm.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  echo '### White Matter' >> ${RMD}
    TNII=${DIR_POSTERIOR}/${IDPFX}_posterior-wm.nii.gz
    TPNG=${DIR_POSTERIOR}/${IDPFX}_posterior-wm.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  echo '### Deep Gray Matter' >> ${RMD}
    TNII=${DIR_POSTERIOR}/${IDPFX}_posterior-gmDeep.nii.gz
    TPNG=${DIR_POSTERIOR}/${IDPFX}_posterior-gmDeep.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  echo '### Cerebrospinal Fluid' >> ${RMD}
    TNII=${DIR_POSTERIOR}/${IDPFX}_posterior-csf.nii.gz
    TPNG=${DIR_POSTERIOR}/${IDPFX}_posterior-csf.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

  if [[ ${NO_THICKNESS} == "false" ]]; then
    echo '## Cortical Thickness' >> ${RMD}
      TNII=${DIR_ANAT}/outcomes/thickness/${IDPFX}_thickness.nii.gz
      TPNG=${DIR_ANAT}/outcomes/thickness/${IDPFX}_thickness.png
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
  fi

  if [[ ${KEEP_PARTS} == "true" ]]; then
    echo '### Preliminary Segmentations by Approach {.tabset}' >> ${RMD}
    echo '#### Click to View ->' >> ${RMD}
    if [[ ${METHOD^^} == *"ANTS"* ]]; then
      TM="ANTS"
      echo '#### ANTs {.tabset}' >> ${RMD}
      echo '##### Tissue Segmentation' >> ${RMD}
        TNII=${DIR_ANAT}/label/MATS/${IDPFX}_label-tissue+${TM}.nii.gz
        TPNG=${DIR_ANAT}/label/MATS/${IDPFX}_label-tissue+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Gray Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gm+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gm+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### White Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-wm+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-wm+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Deep Gray Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gmDeep+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Cerebrospinal Fluid' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-csf+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-csf+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
    fi
    if [[ ${METHOD^^} == *"5TT"* ]]; then
      TM="5TT"
      echo '#### 5TT (MRTrix3, FSL) {.tabset}' >> ${RMD}
      echo '##### Tissue Segmentation' >> ${RMD}
        TNII=${DIR_ANAT}/label/MATS/${IDPFX}_label-tissue+${TM}.nii.gz
        TPNG=${DIR_ANAT}/label/MATS/${IDPFX}_label-tissue+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Gray Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gm+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gm+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### White Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-wm+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-wm+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Deep Gray Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gmDeep+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Cerebrospinal Fluid' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-csf+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-csf+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
    fi
    if [[ ${METHOD^^} == *"SYNTH"* ]]; then
      TM="SYNTHSEG"
      echo '#### Freesurfer SynthSeg {.tabset}' >> ${RMD}
      echo '##### Tissue Segmentation' >> ${RMD}
        TNII=${DIR_ANAT}/label/MATS/${IDPFX}_label-tissue+${TM}.nii.gz
        TPNG=${DIR_ANAT}/label/MATS/${IDPFX}_label-tissue+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Gray Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gm+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gm+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### White Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-wm+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-wm+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Deep Gray Matter' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gmDeep+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-gmDeep+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
      echo '##### Cerebrospinal Fluid' >> ${RMD}
        TNII=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-csf+${TM}.nii.gz
        TPNG=${DIR_POSTERIOR}/${TM}/${IDPFX}_posterior-csf+${TM}.png
        echo '!['${TNII}']('${TPNG}')' >> ${RMD}
        echo '' >> ${RMD}
    fi
  fi

  if [[ ${REFINE} != "false" ]]; then
    echo '### Refined Labels {.tabset}' >> ${RMD}
    echo '#### Click to View ->' >> ${RMD}
    LABELS=(${REFINE//,/ })
    for (( i=0; i<${#LABELS[@]}; i++ )); do
      echo "#### ${LABELS[${i}]}" >> ${RMD}
      TNII=${DIR_ANAT}/label/MATS/${IDPFX}_label-${LABELS[${i}]}_prep-refine.nii.gz
      TPNG=${DIR_ANAT}/label/MATS/${IDPFX}_label-${LABELS[${i}]}_prep-refine.png
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> HTML summary of ${PIPE}${FLOW} generated:"
    echo -e "\t${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}.html"
  fi
fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> QC check file status set"
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0

