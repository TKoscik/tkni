#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      MALF
# DESCRIPTION:   TKNI anatomical multi-atlas labelling
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-07
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
OPTS=$(getopt -o hvlnrk --long pi:,project:,dir-project:,\
id:,dir-id:,\
image:,mask:,mod:,mask-dil:,\
atlas-name:,atlas-ref:,atlas-mask:,atlas-ex:,atlas-label:,atlas-dil:,\
no-premask,mask-restrict,no-jac,no-png,no-rmd,\
dir-scratch:,requires:,\
help,verbose,loquacious,force,keep -n 'parse-options' -- "$@")
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
IDPFX=
IDDIR=

IMAGE=
MASK=
MOD="T1w"
MASK_DIL=2

ATLAS_NAME="HCPYAX"
ATLAS_REF="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz"
ATLAS_MASK="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_mask-brain.nii.gz"
ATLAS_EX="${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-1_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-2_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-3_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-4_T1w.nii.gz,${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_ex-5_T1w.nii.gz"
ATLAS_LABEL="DKT,wmparc,hcpmmp1,cerebellum"
#MALF_LABELS="a2009s,DKTatlas,aparc,wmparc,hcpmmp1,cerebellum,hippocampus,subcortical"
# NOTE: MALF Labels must be in the same folder and differ form exemplar filenames by replacing the modality (e.g., T1w) with label-LABELNAME.nii.gz
ATLAS_DIL=2

MASKAPPLY="true"
MASKRESTRICT="syn"
NO_JAC=false

HELP=false
VERBOSE=false
LOQUACIOUS=false
NO_PNG=false
NO_RMD=false
KEEP=false

PIPE=tkni
FLOW=MALF
REQUIRES="tkniDICOM,tkniAINIT"
FORCE=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -l | --loquacious) LOQUACIOUS=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
    -k | --keep) KEEP=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image) IMG="$2" ; shift 2 ;;
    --mod) MOD="$2" ; shift 2 ;;
    --mask) MASK="$2" ; shift 2 ;;
    --mask-dil) MASK_DIL="$2" ; shift 2 ;;
    --atlas-name) ATLAS_NAME="$2" ; shift 2 ;;
    --atlas-ref) ATLAS_REF="$2" ; shift 2 ;;
    --atlas-mask) ATLAS_MASK="$2" ; shift 2 ;;
    --atlas-ex) ATLAS_EX="$2" ; shift 2 ;;
    --atlas-label) ATLAS_LABEL="$2" ; shift 2 ;;
    --atlas-dil) ATLAS_DIL="$2" ; shift 2 ;;
    --no-premask) MASKAPPLY="false" ; shift ;;
    --mask-restrict) MASKRESTRICT="$2" ; shift 2 ;;
    --no-jac) NO_JAC="true" ; shift ;;
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
  echo "${PIPE}${FLOW}"
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
  echo "ERROR [${PIPE}${FLOW}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [${PIPE}${FLOW}] PROJECT must be provided"
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

# Check ID ---------------------------------------------------------------------
if [[ -z ${IDPFX} ]]; then
  echo "ERROR [${PIPE}${FLOW}] ID Prefix must be provided"
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
if [[ -z ${DIR_XFM} ]]; then DIR_XFM=${DIR_PIPE}/xfm/${IDDIR}; fi
mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_ANAT}
mkdir -p ${DIR_XFM}

## Gather Inputs ---------------------------------------------------------------
## keep copy of original image for output image overlays
if [[ -z ${IMAGE} ]]; then IMAGE=${DIR_ANAT}/native/${IDPFX}_${MOD}.nii.gz; fi
if [[ -z ${MASK} ]]; then MASK=${DIR_ANAT}/mask/${IDPFX}_mask-brain.nii.gz; fi
cp ${IMAGE} ${DIR_SCRATCH}/image.nii.gz
cp ${IMAGE} ${DIR_SCRATCH}/image_orig.nii.gz
cp ${MASK} ${DIR_SCRATCH}/mask.nii.gz

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> gathered participant image and mask"
fi

# MALF =========================================================================
## Gather Atlas Inputs - -------------------------------------------------------
## keep a copy of the originals for output overlays
cp ${ATLAS_REF} ${DIR_SCRATCH}/atlas_ref.nii.gz
cp ${ATLAS_REF} ${DIR_SCRATCH}/atlas_ref_orig.nii.gz
cp ${ATLAS_MASK} ${DIR_SCRATCH}/atlas_mask.nii.gz
cp ${ATLAS_MASK} ${DIR_SCRATCH}/atlas_mask_orig.nii.gz
ATLAS_EX=(${ATLAS_EX//,/ })
NEX=${#ATLAS_EX[@]}
for (( i=0; i<${NEX}; i++ )); do
  cp ${ATLAS_EX[${i}]} ${DIR_SCRATCH}/atlas_ex-${i}.nii.gz
done
if [[ -z ${ATLAS_NAME} ]]; then
  TLAB=(${ATLAS_REF//_/ })
  ATLAS_NAME=${TLAB[0]}
fi

ATLAS_LABEL=(${ATLAS_LABEL//,/ })
for (( i=0; i<${#ATLAS_LABEL[@]}; i++ )); do
  LAB=${ATLAS_LABEL[${i}]}
  for (( j=0; j<${NEX}; j++ )); do
    TD=$(dirname ${ATLAS_EX[${j}]})
    TB=$(getBidsBase -i ${ATLAS_EX[${j}]} -s)
    cp ${TD}/${TB}_label-${LAB}.nii.gz \
      ${DIR_SCRATCH}/atlas_ex-${j}_label-${LAB}.nii.gz
  done
done

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> gathered atlas reference, exemplars, and labels"
fi

## Dilate Masks ----------------------------------------------------------------
if [[ ${MASK_DIL} -gt 0 ]]; then
  ImageMath 3 ${DIR_SCRATCH}/mask.nii.gz \
    MD ${DIR_SCRATCH}/mask.nii.gz ${MASK_DIL}
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> participant mask dilated"
  fi
fi
if [[ ${ATLAS_DIL} -gt 0 ]]; then
  ImageMath 3 ${DIR_SCRATCH}/atlas_mask.nii.gz \
    MD ${DIR_SCRATCH}/atlas_mask.nii.gz ${ATLAS_DIL}
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> atlas mask dilated"
  fi
fi

## Apply Masks -----------------------------------------------------------------
if [[ ${MASKAPPLY} == "true" ]]; then
  niimath ${DIR_SCRATCH}/image.nii.gz \
    -mas ${DIR_SCRATCH}/mask.nii.gz ${DIR_SCRATCH}/image.nii.gz
  niimath ${DIR_SCRATCH}/atlas_ref.nii.gz \
    -mas ${DIR_SCRATCH}/atlas_mask.nii.gz ${DIR_SCRATCH}/atlas_ref.nii.gz
  for (( i=0; i<${NEX}; i++ )); do
    niimath ${DIR_SCRATCH}/atlas_ex-${i}.nii.gz \
      -mas ${DIR_SCRATCH}/atlas_mask.nii.gz \
      ${DIR_SCRATCH}/atlas_ex-${i}.nii.gz
  done
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> masks applied before normalization"
  fi
fi

## Multi-Exemplar Normalization ------------------------------------------------
### Generate Normalization Function
MOVING=${DIR_SCRATCH}/image.nii.gz
MOVING_MASK=${DIR_SCRATCH}/mask.nii.gz
FIXED=${DIR_SCRATCH}/atlas_ref.nii.gz
FIXED_MASK=${DIR_SCRATCH}/atlas_mask.nii.gz
FIXED_EXEMPLAR=($(ls ${DIR_SCRATCH}/atlas_ex-*.nii.gz))
ANTSCALL="antsRegistration --dimensionality 3"
ANTSCALL="${ANTSCALL} --output ${DIR_SCRATCH}/xfm_"
ANTSCALL="${ANTSCALL} --write-composite-transform 0"
ANTSCALL="${ANTSCALL} --collapse-output-transforms 1"
ANTSCALL="${ANTSCALL} --initialize-transforms-per-stage 0"
ANTSCALL="${ANTSCALL} --initial-moving-transform [${FIXED},${MOVING},1]"
ANTSCALL="${ANTSCALL} --transform Rigid[0.1]"
ANTSCALL="${ANTSCALL} --metric Mattes[${FIXED},${MOVING},1,32,Regular,0.25]"
if [[ "${MASKRESTRICT,,}" == *"rigid"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [ 2000x2000x2000x2000x2000,1e-6,10 ]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 4x3x2x1x0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 8x8x4x2x1"
#ANTSCALL="${ANTSCALL} --convergence [1200x1200x100,1e-6,5]"
#ANTSCALL="${ANTSCALL} --smoothing-sigmas 2x1x0vox"
#ANTSCALL="${ANTSCALL} --shrink-factors 4x2x1"
ANTSCALL="${ANTSCALL} --transform Affine[0.1]"
#ANTSCALL="${ANTSCALL} --transform Affine[0.25]"
ANTSCALL="${ANTSCALL} --metric Mattes[${FIXED},${MOVING},1,32,Regular,0.25]"
if [[ "${MASKRESTRICT,,}" == *"affine"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [ 2000x2000x2000x2000x2000,1e-6,10 ]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 4x3x2x1x0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 8x8x4x2x1"
#ANTSCALL="${ANTSCALL} --convergence [200x20,1e-6,5]"
#ANTSCALL="${ANTSCALL} --smoothing-sigmas 1x0vox"
#ANTSCALL="${ANTSCALL} --shrink-factors 2x1"

ANTSCALL="${ANTSCALL} --transform SyN[0.2,3,0]"
ANTSCALL="${ANTSCALL} --metric CC[${FIXED},${MOVING},1,4]"
if [[ "${MASKRESTRICT,,}" == *"syn"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [ 40x20x0,1e-7,8 ]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 2x1x0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 4x2x1"

#ANTSCALL="${ANTSCALL} --transform SyN[0.1,3,0]"
##ANTSCALL="${ANTSCALL} --transform SyN[0.2,3,0]"
#for (( i=0; i<${NEX}; i++ )); do
#  ANTSCALL="${ANTSCALL} --metric CC[${FIXED_EXEMPLAR[${i}]},${MOVING},1,4]"
#done
#if [[ "${MASKRESTRICT,,}" == *"syn"* ]]; then
#  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
#elif [[ "${MASKRESTRICT,,}" != "none" ]]; then
#  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
#fi
#ANTSCALL="${ANTSCALL} --convergence [100x70x50x20,1e-6,10]"
#ANTSCALL="${ANTSCALL} --smoothing-sigmas 3x2x1x0vox"
#ANTSCALL="${ANTSCALL} --shrink-factors 8x4x2x1"

ANTSCALL="${ANTSCALL} --transform SyN[0.1,3,0]"
#ANTSCALL="${ANTSCALL} --transform SyN[0.2,3,0]"
for (( i=0; i<${NEX}; i++ )); do
  ANTSCALL="${ANTSCALL} --metric CC[${DIR_SCRATCH}/atlas_ex-${i}.nii.gz,${MOVING},1,4]"
done
if [[ "${MASKRESTRICT,,}" == *"syn"* ]]; then
  ANTSCALL="${ANTSCALL} --masks [${FIXED_MASK},${MOVING_MASK}]"
elif [[ "${MASKRESTRICT,,}" != "none" ]]; then
  ANTSCALL="${ANTSCALL} --masks [NULL,NULL]"
fi
ANTSCALL="${ANTSCALL} --convergence [20,1e-6,10]"
ANTSCALL="${ANTSCALL} --smoothing-sigmas 0vox"
ANTSCALL="${ANTSCALL} --shrink-factors 1"

ANTSCALL="${ANTSCALL} --use-histogram-matching 1"
ANTSCALL="${ANTSCALL} --winsorize-image-intensities [0.005,0.995]"
ANTSCALL="${ANTSCALL} --float 1"
if [[ ${LOQUACIOUS} == "true" ]]; then
  ANTSCALL="${ANTSCALL} --verbose 1"
else
  ANTSCALL="${ANTSCALL} --verbose 0"
fi
ANTSCALL="${ANTSCALL} --random-seed 41066609"
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> ANTs Normalization Function:"
  echo ${ANTSCALL}
fi

### Run Normalizations Function
eval ${ANTSCALL}

# save XFMs --------------------------------------------------------------------
XFM_AFFINE=${DIR_XFM}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-affine.mat
XFM_AFFINE_INV="[${XFM_AFFINE},1]"
XFM_SYN=${DIR_XFM}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn.nii.gz
XFM_SYN_INV=${DIR_XFM}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn+inverse.nii.gz
mv ${DIR_SCRATCH}/xfm_0GenericAffine.mat ${XFM_AFFINE}
mv ${DIR_SCRATCH}/xfm_1Warp.nii.gz ${XFM_SYN}
mv ${DIR_SCRATCH}/xfm_1InverseWarp.nii.gz ${XFM_SYN_INV}

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> normalization transforms saved"
fi

## Apply Transforms ------------------------------------------------------------
## normalized anatomical image (and save in output location)
DIR_REG=${DIR_ANAT}/reg_${ATLAS_NAME}
mkdir -p ${DIR_REG}
antsApplyTransforms -d 3 -n BSpline[3] \
  -i ${DIR_SCRATCH}/image_orig.nii.gz \
  -o ${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.nii.gz \
  -r ${DIR_SCRATCH}/atlas_ref.nii.gz \
  -t identity -t ${XFM_SYN} -t ${XFM_AFFINE}
if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == "false" ]]; then
  make3Dpng \
    --bg ${DIR_SCRATCH}/atlas_ref_orig.nii.gz \
      --bg-color "timbow:hue=#00FF00:lum=0,100:cyc=1/6" \
    --fg ${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.nii.gz \
      --fg-threshold "2.5,97.5" \
      --fg-color "timbow:hue=#FF00FF:lum=0,100:cyc=1/6" \
      --fg-alpha 50 --fg-cbar "false" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_from-native_to-${ATLAS_NAME}_overlay \
    --dir-save ${DIR_XFM}
  make3Dpng --bg ${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.nii.gz
fi

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> normalization applied to participant image"
fi

## MALF brain mask to native space
mkdir -p ${DIR_ANAT}/mask/${FLOW}
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${DIR_SCRATCH}/atlas_mask_orig.nii.gz \
  -o ${DIR_ANAT}/mask/${FLOW}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
  -r ${DIR_SCRATCH}/image_orig.nii.gz \
  -t identity -t ${XFM_AFFINE_INV} -t ${XFM_SYN_INV}
if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == "false" ]]; then
  make3Dpng --bg ${DIR_SCRATCH}/image_orig.nii.gz \
    --fg ${DIR_ANAT}/mask/${FLOW}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
    --fg-color "gradient:#FF0000" --fg-alpha 50 --fg-cbar "false" \
    --layout "11:x;11:x;11:x" \
    --filename ${IDPFX}_mask-brain+${FLOW} \
    --dir-save ${DIR_ANAT}/mask
fi

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> atlas mask pushed to native space"
fi

## Joint Label Fusion ----------------------------------------------------------
mkdir -p ${DIR_ANAT}/label/${FLOW}
### push exemplars to native space
for (( i=0; i<${NEX}; i++ )); do
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${DIR_SCRATCH}/atlas_ex-${i}.nii.gz \
    -o ${DIR_SCRATCH}/atlas_ex-${i}_native.nii.gz \
    -r ${DIR_SCRATCH}/image_orig.nii.gz \
    -t identity -t ${XFM_AFFINE_INV} -t ${XFM_SYN_INV}
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> atlas exemplars pushed to native space"
fi

for (( i=0; i<${#ATLAS_LABEL[@]}; i++ )); do
  LAB=${ATLAS_LABEL[${i}]}
  for (( j=0; j<${NEX}; j++ )); do
    antsApplyTransforms -d 3 -n MultiLabel \
      -i ${DIR_SCRATCH}/atlas_ex-${j}_label-${LAB}.nii.gz  \
      -o ${DIR_SCRATCH}/atlas_ex-${j}_label-${LAB}_native.nii.gz \
      -r ${DIR_SCRATCH}/image.nii.gz \
      -t identity -t ${XFM_AFFINE_INV} -t ${XFM_SYN_INV}
  done
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> atlas labels pushed to native space"
fi

for (( i=0; i<${#ATLAS_LABEL[@]}; i++ )); do
  LAB=${ATLAS_LABEL[${i}]}
  JLFCALL="antsJointFusion --image-dimensionality 3"
  if [[ ${VERBOSE} == "true" ]]; then
    JLFCALL="${JLFCALL} --verbose 1"
  else
    JLFCALL="${JLFCALL} --verbose 0"
  fi
  JLFCALL="${JLFCALL} --target-image ${DIR_SCRATCH}/image.nii.gz"
  JLFCALL="${JLFCALL} --output ${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz"
  for (( j=0; j<${NEX}; j++ )); do
    JLFCALL="${JLFCALL} --atlas-image ${DIR_SCRATCH}/atlas_ex-${j}_native.nii.gz"
    JLFCALL="${JLFCALL} --atlas-segmentation ${DIR_SCRATCH}/atlas_ex-${j}_label-${LAB}_native.nii.gz"
  done
  JLFCALL="${JLFCALL} --alpha 0.1 --beta 2.0"
  JLFCALL="${JLFCALL} --constrain-nonnegative 0"
  JLFCALL="${JLFCALL} --patch-radius 2 --patch-metric PC --search-radius 3"
  if [[ ${VERBOSE} == "true" ]]; then echo ${JLFCALL}; fi
  eval ${JLFCALL}

  if [[ ${NO_PNG} == "false" ]]; then
    make3Dpng --bg ${DIR_SCRATCH}/image_orig.nii.gz \
      --fg ${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz \
        --fg-color "timbow:random" \
        --fg-cbar "false" --fg-alpha 50 \
      --layout "7:x;7:x;7:y;7:y;7:z;7:z" \
      --filename ${IDPFX}_label-${LAB}+${FLOW} \
      --dir-save ${DIR_ANAT}/label/${FLOW}
  fi
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> joint label fusion complete for ${LAB} labels"
  fi

  # summarize output -----------------------------------------------------------
  summarize3D --stats volume --append false \
    --label ${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz \
    --lut ${TKNI_LUT}/lut-${LAB}.tsv
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> ${LAB} volumes calculated"
  fi

done

# calculate Jacobians ----------------------------------------------------------
if [[ ${NO_JAC} == "false" ]]; then
  XFM_NORIGID=${DIR_XFM}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-affine+norigid.mat
  AverageAffineTransformNoRigid 3 ${XFM_NORIGID} -i ${XFM_AFFINE}
  mapJacobian --prefix ${IDPFX} \
    --xfm "${XFM_SYN},${XFM_RIGID}" \
    --ref-image ${DIR_SCRATCH}/atlas_ref_orig.nii.gz \
    --from "native" --to ${ATLAS_NAME} \
    --dir-save ${DIR_PROJECT}/derivatives/${PIPE}/anat/outcomes
  DIR_JAC=${DIR_ANAT}/outcomes/jacobian_from-native_to-${ATLAS_NAME}
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> jacobian determinants of the normalization transform calculated"
  fi
  for (( i=0; i<${#ATLAS_LABEL[@]}; i++ )); do
    LAB=${ATLAS_LABEL[${i}]}
    antsApplyTransforms -d 3 -n MultiLabel \
      -i ${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz \
      -o ${DIR_SCRATCH}/${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}.nii.gz \
      -r ${DIR_SCRATCH}/atlas_ref.nii.gz \
      -t identity -t ${XFM_SYN} -t ${XFM_AFFINE}
    summarize3D --stats "mean,median,sigma" --append false \
      --label ${DIR_SCRATCH}/${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}.nii.gz \
      --value ${DIR_JAC}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn_jacobian.nii.gz \
      --lut ${TKNI_LUT}/lut-${LAB}.tsv
    #mv ${DIR_SCRATCH}/${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}_jacobian.tsv \
    #  ${DIR_JAC}/
    if [[ ${VERBOSE} == "true" ]]; then
      echo -e ">>>>> stats for jacobians by ${LAB} labels calculated"
    fi
  done
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

  echo '## '${PIPE}${FLOW}': Multi-Atlas Normalization and Label Fusion' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Multi-Atlas Normalization' >> ${RMD}

  echo '#### Normalized Participant Image' >> ${RMD}
  TNII=${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.nii.gz
  TPNG=${DIR_REG}/${IDPFX}_reg-${ATLAS_NAME}_${MOD}.png
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Atlas Target Image' >> ${RMD}
  TPNG="${ATLAS_REF//\.nii\.gz}.png"
  if [[ ! -f ${TPNG} ]]; then make3Dpng --bg ${ATLAS_REF}; fi
  echo '!['${ATLAS_REF}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Normalization Overlay' >> ${RMD}
  TPNG=${DIR_XFM}/${IDPFX}_from-native_to-${ATLAS_NAME}_overlay.png
  if [[ -f "${TPNG}" ]]; then
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  else
    echo '*PNG not found*\' >> ${RMD}
  fi

  if [[ ${NO_JAC} == "false" ]]; then
    echo '### Jacobian Determinants' >> ${RMD}
    DIR_JAC=${DIR_ANAT}/outcomes/jacobian_from-native_to-${ATLAS_NAME}
    TNII=${DIR_JAC}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn_jacobian.nii.gz
    TPNG=${DIR_JAC}/${IDPFX}_from-native_to-${ATLAS_NAME}_xfm-syn_jacobian.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  echo '### Labels {.tabset}' >> ${RMD}
  for (( i=0; i<${#ATLAS_LABEL[@]}; i++ )); do
    LAB=${ATLAS_LABEL[${i}]}
    TNII=${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz
    TPNG=${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.png
    TCSV=${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}_volume.tsv
    TJAC=${DIR_JAC}/${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}_jacobian.tsv
    echo '#### '${LAB} >> ${RMD}
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
    if [[ -f ${TCSV} ]]; then
      FNAME="${IDPFX}_label-${LAB}+${FLOW}_volume"
      echo '```{r}' >> ${RMD}
      EXT=${TCSV##*.}
      if [[ ${EXT} == "tsv" ]]; then
        echo 'data'${i}' <- read.csv("'${TCSV}'", sep="\t")' >> ${RMD}
      else
        echo 'data'${i}' <- read.csv("'${TCSV}'")' >> ${RMD}
      fi
      echo 'download_this(.data=data'${i}',' >> ${RMD}
      echo '  output_name = "'${FNAME}'",' >> ${RMD}
      echo '  output_extension = ".csv",' >> ${RMD}
      echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
      echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
      echo '```' >> ${RMD}
      echo '' >> ${RMD}
    fi
    if [[ -f ${TJAC} ]]; then
      FNAME="${IDPFX}_reg-${ATLAS_NAME}_label-${LAB}+${FLOW}_jacobian"
      echo '```{r}' >> ${RMD}
      EXT=${TJAC##*.}
      if [[ ${EXT} == "tsv" ]]; then
        echo 'JACdata'${i}' <- read.csv("'${TJAC}'", sep="\t")' >> ${RMD}
      else
        echo 'JACdata'${i}' <- read.csv("'${TJAC}'")' >> ${RMD}
      fi
      echo 'download_this(.data=JACdata'${i}',' >> ${RMD}
      echo '  output_name = "'${FNAME}'",' >> ${RMD}
      echo '  output_extension = ".csv",' >> ${RMD}
      echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
      echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
      echo '```' >> ${RMD}
      echo '' >> ${RMD}
    fi
  done

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

# keep temp files if selected --------------------------------------------------
if [[ ${KEEP} == "true" ]]; then
  mkdir -p ${DIR_PIPE}/prep/${IDDIR}/${FLOW}
  cp -R ${DIR_SCRATCH}/* ${DIR_PIPE}/prep/${IDDIR}/${FLOW}/
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0

