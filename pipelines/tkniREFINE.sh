#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      REFINE
# DESCRIPTION:   Refine cortical labels using cortical parcellation
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-08
# README:
#   Procedure:  (1) Dilate label segmentation
#               (2) Apply cortical segmentation mask
#               (3) Apply median filter
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
label:,mask-gm:,dil:,seg:,val-gm:,val-wm:,fmed:,\
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

LABEL=
VAL_GM=
VAL_WM=
VAL_KEEP=
DIL=5
SEG=
VAL_SEG=1,3
FMED=3

HELP=false
VERBOSE=false
NO_PNG=false

PIPE=tkni
FLOW=MATS
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF,tkniMATS"
FORCE=false

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
    --label) LABEL="$2" ; shift 2 ;;
    --val-gm) VAL_GM="$2" ; shift 2 ;;
    --val-wm) VAL_WM="$2" ; shift 2 ;;
    --dil) DIL="$2" ; shift 2 ;;
    --seg) SEG="$2" ; shift 2 ;;
    --val-seg) VAL_SEG="$2" ; shift 2 ;;
    --fmed) FMED="$2" ; shift 2 ;;
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
  DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
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
  if [[ -z ${TSES} ]]; then
    IDDIR="${IDDIR}/ses-${TSES}"
  fi
fi

# check label input ------------------------------------------------------------
if [[ ! -f ${LABEL} ]]; then
  TLAB=(${LABEL//\+/ })
  LAB_PIPE=${TLAB[-1]}
  LABEL=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/label/${LAB_PIPE}/${IDPFX}_label-${LABEL}.nii.gz
fi
if [[ ! -f ${LABEL} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] LABEL file not found."
  exit 2
fi

# check segmentation input -----------------------------------------------------
if [[ -z ${SEG} ]]; then
  SEG=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/label/${IDPFX}_label-tissue.nii.gz
fi
if [[ ! -f ${SEG} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] SEGMENTATION file not found."
  exit 2
fi

# set up directories -----------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/label/REFINE
fi
mkdir -p ${DIR_SCRATCH}

# isolate cortical and non cortical labels -------------------------------------
## extract just GM and WM and OTHER labels
if [[ ${VERBOSE} == "true" ]]; then echo "Extracting Tissue Labels"; fi

if [[ ${VAL_GM} == "" ]]; then
  if [[ ${LABEL} == *"aparc.a2009s+aseg"* ]]; then
    VAL_GM="11000,17:18,53:54"
  elif [[ ${LABEL} == *"aparc.DKTatlas+aseg"* ]] \
    || [[ ${LABEL} == *"aparc+aseg"* ]] \
    || [[ ${LABEL} == *"hcpmmp1"* ]] \
    || [[ ${LABEL} == *"wmparc"* ]]; then
    VAL_GM="1000:2999,17:18,53:54"
  else
    echo "ERROR [TKNI: ${FCN_NAME}] GM Label values to refine must be specified"
    exit 3
  fi
fi
if [[ ${VAL_WM} == "" ]]; then
  if [[ ${LABEL} == *"aparc.a2009s+aseg"* ]] \
    || [[ ${LABEL} == *"aparc.DKTatlas+aseg"* ]] \
    || [[ ${LABEL} == *"aparc+aseg"* ]] \
    || [[ ${LABEL} == *"hcpmmp1"* ]]; then
    VAL_WM="2,41,251:255"
  elif [[ ${LABEL} == *"wmparc"* ]]; then
    VAL_WM="3000:5002,251:255"
  else
    echo "ERROR [TKNI: ${FCN_NAME}] WM Label values to refine must be specified"
    exit 4
  fi
fi
if [[ ${VAL_KEEP} == "" ]]; then
  if [[ ${LABEL} == *"aparc.a2009s+aseg"* ]] \
    || [[ ${LABEL} == *"aparc.DKTatlas+aseg"* ]] \
    || [[ ${LABEL} == *"aparc+aseg"* ]] \
    || [[ ${LABEL} == *"hcpmmp1"* ]] \
    || [[ ${LABEL} == *"wmparc"* ]]; then
    VAL_KEEP="7:8,10:13,16,26,28,46:47,49:52,58,60"
  else
    echo "ERROR [TKNI: ${FCN_NAME}] WM Label values to refine must be specified"
    exit 4
  fi
fi

MASK_GM=${DIR_SCRATCH}/mask_gm.nii.gz
MASK_WM=${DIR_SCRATCH}/mask_wm.nii.gz
MASK_KEEP=${DIR_SCRATCH}/mask_keep.nii.gz
MASK_NA=${DIR_SCRATCH}/mask_na.nii.gz
fslmaths ${LABEL} -mul 0 ${MASK_GM} -odt char
cp ${MASK_GM} ${MASK_WM}
cp ${MASK_GM} ${MASK_KEEP}
cp ${MASK_GM} ${MASK_NA}
VAL_GM=(${VAL_GM//,/ })
for (( i=0; i<${#VAL_GM[@]}; i++ )); do
  TVAL=${VAL_GM[${i}]}
  TVAL=(${TVAL//:/ })
  fslmaths ${LABEL} -thr ${TVAL[0]} -uthr ${TVAL[-1]} -bin -add ${MASK_GM} ${MASK_GM} -odt char
done

VAL_WM=(${VAL_WM//,/ })
for (( i=0; i<${#VAL_WM[@]}; i++ )); do
  TVAL=${VAL_WM[${i}]}
  TVAL=(${TVAL//:/ })
  fslmaths ${LABEL} -thr ${TVAL[0]} -uthr ${TVAL[-1]} -bin -add ${MASK_WM} ${MASK_WM} -odt char
done

VAL_KEEP=(${VAL_KEEP//,/ })
for (( i=0; i<${#VAL_KEEP[@]}; i++ )); do
  TVAL=${VAL_KEEP[${i}]}
  TVAL=(${TVAL//:/ })
  fslmaths ${LABEL} -thr ${TVAL[0]} -uthr ${TVAL[-1]} -bin -add ${MASK_KEEP} ${MASK_KEEP} -odt char
done

fslmaths ${MASK_GM} -add ${MASK_WM} -add ${MASK_KEEP} -binv -mul ${LABEL} -bin ${MASK_NA} -odt char
LABEL_GM=${DIR_SCRATCH}/label_gm.nii.gz
LABEL_WM=${DIR_SCRATCH}/label_wm.nii.gz
LABEL_KEEP=${DIR_SCRATCH}/label_keep.nii.gz
LABEL_NA=${DIR_SCRATCH}/label_na.nii.gz
fslmaths ${LABEL} -mas ${MASK_GM} ${LABEL_GM}
fslmaths ${LABEL} -mas ${MASK_WM} ${LABEL_WM}
fslmaths ${LABEL} -mas ${MASK_KEEP} ${LABEL_KEEP}
fslmaths ${LABEL} -mas ${MASK_NA} ${LABEL_NA}

# Dilate GM and WM labels ------------------------------------------------------
## dilate tissue mask, then propagate labels through it
MASK_GM_DIL=${DIR_SCRATCH}/mask_gm_dil.nii.gz
MASK_WM_DIL=${DIR_SCRATCH}/mask_wm_dil.nii.gz
LABEL_GM_DIL=${DIR_SCRATCH}/label_gm_dil.nii.gz
LABEL_WM_DIL=${DIR_SCRATCH}/label_wm_dil.nii.gz
if [[ ${VERBOSE} == "true" ]]; then echo "Dilating Tissue Masks"; fi
ImageMath 3 ${MASK_GM_DIL} MD ${MASK_GM} ${DIL}
ImageMath 3 ${MASK_WM_DIL} MD ${MASK_WM} ${DIL}
if [[ ${VERBOSE} == "true" ]]; then echo "Propagating Labels"; fi
ImageMath 3 ${LABEL_GM_DIL} PropagateLabelsThroughMask ${MASK_GM_DIL} ${LABEL_GM} ${DIL} 0
ImageMath 3 ${LABEL_WM_DIL} PropagateLabelsThroughMask ${MASK_WM_DIL} ${LABEL_WM} ${DIL} 0

# Apply cortical segmentation mask to dilated GM labels ------------------------
MASK_GM_SEG=${DIR_SCRATCH}/mask_gm_seg.nii.gz
MASK_WM_SEG=${DIR_SCRATCH}/mask_wm_seg.nii.gz
REFINE_GM=${DIR_SCRATCH}/label_gm_refine.nii.gz
REFINE_WM=${DIR_SCRATCH}/label_wm_refine.nii.gz
VAL_SEG=(${VAL_SEG//,/ })
if [[ ${VERBOSE} == "true" ]]; then echo "Extracting Segmentation Masks"; fi
fslmaths ${SEG} -thr ${VAL_SEG[0]} -uthr ${VAL_SEG[0]} -bin ${MASK_GM_SEG} -odt char
fslmaths ${SEG} -thr ${VAL_SEG[1]} -uthr ${VAL_SEG[1]} -bin ${MASK_WM_SEG} -odt char
if [[ ${VERBOSE} == "true" ]]; then echo "Refining Labels"; fi
fslmaths ${LABEL_GM_DIL} -mas ${MASK_GM_SEG} ${REFINE_GM}
fslmaths ${LABEL_WM_DIL} -mas ${MASK_WM_SEG} ${REFINE_WM}

# Recombine Labels -------------------------------------------------------------
## make sure NON GM or WM voxels interfere or add to refined WM and GM labels
REFINE_NA=${DIR_SCRATCH}/label_na_refine.nii.gz
REFINED=${DIR_SCRATCH}/label_refine.nii.gz
if [[ ${VERBOSE} == "true" ]]; then echo "Recombining Label Set"; fi
#####
## get mask of labels to be untouched
fslmaths ${MASK_KEEP} -binv ${MASK_KEEP} -odt char
fslmaths ${REFINE_GM} -add ${REFINE_WM} -mas ${MASK_KEEP} -add ${LABEL_KEEP} ${REFINED}
fslmaths ${REFINED} -binv -mul ${LABEL} ${REFINE_NA}
fslmaths ${REFINED} -add ${REFINE_NA} ${REFINED}

# Apply median filter ----------------------------------------------------------
if [[ ${FMED} -gt 0 ]]; then
  if [[ ${VERBOSE} == "true" ]]; then echo "Applying Median Filter"; fi
  fslmaths ${REFINED} -kernel boxv ${FMED} -fmedian ${REFINED}
fi

# save result ------------------------------------------------------------------
mkdir -p ${DIR_SAVE}
NEWLAB=$(getField -i ${LABEL} -f label)
NEWLAB=(${NEWLAB//+/ })
NEWLAB="${NEWLAB}+REFINE"
NEWNAME=$(modField -i $(getBidsBase -i ${LABEL}) -r -f label)
NEWNAME=$(modField -i $(getBidsBase -i ${NEWNAME}) -a -f label -v ${NEWLAB})
mv ${REFINED} ${DIR_SAVE}/${NEWNAME}.nii.gz

# generate PNGs of labels ------------------------------------------------------
if [[ ${NO_PNG} == "false" ]]; then
  BG=${DIR_PROJECT}/derivatives/${PIPELINE}/anat/native/${IDPFX}_T1w.nii.gz
  if [[ -f ${BG} ]]; then
    make3Dpng --bg ${BG} \
      --fg ${DIR_ANAT}/label/${FLOW}/${IDPFX}_label-${LAB}+${FLOW}.nii.gz \
        --fg-color "timbow" --fg-order random --fg-discrete \
        --fg-cbar "false" --fg-alpha 50 \
      --layout "7:x;7:x;7:y;7:y;7:z;7:z" --offset "0,0,0" \
      --filename ${IDPFX}_label-${LAB}+${FLOW} \
      --dir-save ${DIR_ANAT}/label/${FLOW}
  else
  fi
fi

#===============================================================================
# End of Function
#===============================================================================
if [[ ${VERBOSE} == "true" ]]; then echo "Label Refinement Complete"; fi
exit 0
