#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      FSSYNTH
# DESCRIPTION:   FreeSurfer recon-all-clinical.sh
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-08
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
OPTS=$(getopt -o hvn --long pi:,project:,dir-project:,\
id:,dir-id:,image:,nthreads:,labels:,\
requires:,force,\
dir-scratch:,dir-fs:,dir-save:,\
help,verbose,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_FS=
DIR_TKNI=
DIR_SCRATCH=
IDPFX=
IDDIR=

IMAGE=
MOD="T1w"
NTHREADS=4
LABELS=("aparc.a2009s+aseg" "aparc.DKTatlas+aseg" "aparc+aseg" "wmparc")

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

FSPIPE=freesurfer
PIPE=tkni
FLOW=${FCN_NAME//${PIPE}}
REQUIRES="tkniDICOM,tkniAINIT"
FORCE="false"

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image) IMG="$2" ; shift 2 ;;
    --mod) MOD="$2" ; shift 2 ;;
    --labels) LABELS="$2" ; shift 2 ;;
    --nthreads) NTHREADS="$2" ; shift 2 ;;
    --dir-fs) DIR_FS="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    -- ) shift ; break ;;
    * ) break ;;
  esac
done

# Usage Help -------------------------------------------------------------------
if [[ "${HELP}" == "true" ]]; then
    echo '------------------------------------------------------------------------'
    echo " TKNI Pipeline: ${PIPE^^}:${FLOW}"
    echo ' DESCRIPTION: FreeSurfer recon-all & Surface Reconstruction'
    echo '------------------------------------------------------------------------'
    echo ' REQUIRED ARGUMENTS:'
    echo '  --pi <name>           PI folder name (no underscores)'
    echo '  --project <name>      Project name (preferably CamelCase)'
    echo '  --id <string>         Participant identifier (BIDS prefix)'
    echo ''
    echo ' INPUT & PERFORMANCE:'
    echo '  --image <file>        Input image (default: native T1w)'
    echo '  --mod <string>        Input modality label (default: T1w)'
    echo '  --nthreads <int>      Number of CPU threads to use (default: 4)'
    echo ''
    echo ' ATLAS & LABELLING:'
    echo '  --labels <list>       Space-separated labels to convert'
    echo '                        (default: aparc.a2009s+aseg, aparc.DKTatlas+aseg,'
    echo '                        aparc+aseg, wmparc)'
    echo ''
    echo ' PATHING & DIRECTORIES:'
    echo '  --dir-fs <path>       Directory for FreeSurfer subject data'
    echo '  --dir-save <path>     Directory for TKNI derivatives'
    echo '  --dir-project <path>  Base project directory'
    echo '  --dir-scratch <path>  Override default temporary workspace'
    echo ''
    echo ' PIPELINE FLAGS:'
    echo '  -h | --help           Display this help message'
    echo '  -v | --verbose        Enable console logging'
    echo '  -n | --no-png         Disable generation of QC images & renderings'
    echo '  -r | --no-rmd         Disable HTML report generation'
    echo '  --force               Force re-run and overwrite existing status'
    echo '  --requires <list>     Prerequisite workflows (default: tkniDICOM,tkniAINIT)'
    echo ''
    NO_LOG=true
    exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
# set project defaults ---------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] PROJECT must be provided"
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
  echo "ERROR [${PIPE}:${FLOW}] ID Prefix must be provided"
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

## Check if Prerequisites are run and QC'd -------------------------------------
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

# set up directories -----------------------------------------------------------
#DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
if [[ -z ${DIR_FS} ]]; then
  DIR_FS=${DIR_PROJECT}/derivatives/${FSPIPE}
fi
#if [[ ! -d ${DIR_FS}/fsaverage ]]; then
#  cp -r ${FREESURFER_HOME}/subjects/fsaverage ${DIR_FS}/
#fi
##if [[ -z ${DIR_TKNI} ]]; then
##  DIR_TKNI=${DIR_PROJECT}/derivatives/tkni
##fi
#DIR_PREP=${DIR_PIPE}/prep/${IDDIR}/${FCN_NAME}
#if [[ -z ${DIR_SAVE} ]]; then
#  DIR_SAVE=${DIR_PIPE}
#fi
#mkdir -p ${DIR_PREP}
mkdir -p ${DIR_SCRATCH}
cp -r ${FREESURFER_HOME}/subjects/fsaverage ${DIR_SCRATCH}/

# parse image inputs -----------------------------------------------------------
if [[ -z ${IMAGE} ]]; then
  IMAGE=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/${IDPFX}_${MOD}.nii.gz
fi
cp ${IMAGE} ${DIR_SCRATCH}/
#IMAGE=${DIR_SCRATCH}/${PIPE}/anat/native/${IDPFX}_${MOD}.nii.gz
IMAGE=${DIR_SCRATCH}/${IDPFX}_${MOD}.nii.gz

# Recon-all-clinical -----------------------------------------------------------
CHK_FS_VERSION=$(recon-all -version)
if [[ ${CHK_FS_VERSION} == *"x86_64-8."* ]]; then
  recon-all -subjid ${IDPFX} -i ${IMAGE} -sd ${DIR_SCRATCH} -all
else
  echo "ERROR [${PIPE}:${FLOW}] Freesurfer version 8 is required"
  exit 1
fi
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> RECON-ALL Clinical COMPLETE"; fi

# Add subregion segmentations --------------------------------------------------
## Thalamic Nuclei
segment_subregions thalamus --cross ${IDPFX} --sd ${DIR_SCRATCH}
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/ThalamicNuclei.mgz \
  ${DIR_SCRATCH}/${IDPFX}_label-thalamicNuclei.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-thalamicNuclei.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-thalamicNuclei.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="5:z"
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_label-thalamicNuclei.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_label-thalamicNuclei.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=50,85:cyc=5/6:random" \
    --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-thalamicNuclei \
    --dir-save ${DIR_SCRATCH}
fi

## Hippocampus Amygdala
segment_subregions hippo-amygdala --cross ${IDPFX} --sd ${DIR_SCRATCH}
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/lh.hippoAmygLabels.mgz \
  ${DIR_SCRATCH}/${IDPFX}_label-mtl+lh.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-mtl+lh.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-mtl+lh.nii.gz
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/rh.hippoAmygLabels.mgz \
  ${DIR_SCRATCH}/${IDPFX}_label-mtl+rh.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-mtl+rh.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-mtl+rh.nii.gz
niimath ${DIR_SCRATCH}/${IDPFX}_label-mtl+rh.nii.gz -bin ${DIR_SCRATCH}/tmp_mask.nii.gz -odt char
niimath ${DIR_SCRATCH}/${IDPFX}_label-mtl+rh.nii.gz \
  -add 1000 -mas ${DIR_SCRATCH}/tmp_mask.nii.gz \
  -add ${DIR_SCRATCH}/${IDPFX}_label-mtl+lh.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_label-mtl.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="5:z"
  3dRank -overwrite -prefix ${DIR_SCRATCH}/TLABEL.nii.gz \
    -input ${DIR_SCRATCH}/${IDPFX}_label-mtl.nii.gz
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/TLABEL.nii.gz \
    --fg-mask ${DIR_SCRATCH}/TLABEL.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=50,85:cyc=11/6:random" \
    --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-mtl \
    --dir-save ${DIR_SCRATCH}
fi
rm ${DIR_SCRATCH}/tmp*.nii.gz

segment_subregions brainstem --cross ${IDPFX} --sd ${DIR_SCRATCH}
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/brainstemSsLabels.mgz \
  ${DIR_SCRATCH}/${IDPFX}_label-brainstem.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-brainstem.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-brainstem.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="5:x"
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_label-brainstem.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_label-brainstem.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=50,85:cyc=5/6:random" \
    --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-brainstem \
    --dir-save ${DIR_SCRATCH}
fi

mri_segment_hypothalamic_subunits --s ${IDPFX} --sd ${DIR_SCRATCH}
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/hypothalamic_subunits_seg.v1.mgz \
  ${DIR_SCRATCH}/${IDPFX}_label-hypothalamus.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-hypothalamus.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-hypothalamus.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="5:x"
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_label-hypothalamus.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_label-hypothalamus.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=50,85:cyc=5/6;random" \
    --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-hypothalamus \
    --dir-save ${DIR_SCRATCH}
fi

if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Subregion segmentation complete"; fi

## Add HCPMMP1 annotations -----------------------------------------------------
mri_surf2surf --srcsubject fsaverage --trgsubject ${IDPFX} --sd ${DIR_SCRATCH} \
              --hemi lh --sval-annot ${DIR_SCRATCH}/fsaverage/label/lh.HCP-MMP1.annot \
              --tval ${DIR_SCRATCH}/${IDPFX}/label/lh.HCP-MMP1.annot
mri_surf2surf --srcsubject fsaverage --trgsubject ${IDPFX} --sd ${DIR_SCRATCH} \
              --hemi rh --sval-annot ${DIR_SCRATCH}/fsaverage/label/rh.HCP-MMP1.annot \
              --tval ${DIR_SCRATCH}/${IDPFX}/label/rh.HCP-MMP1.annot
mri_aparc2aseg --s ${IDPFX} --sd ${DIR_SCRATCH} --annot HCP-MMP1 \
               --o ${DIR_SCRATCH}/${IDPFX}/mri/hcpmmp1.mgz
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/hcpmmp1.mgz \
  ${DIR_SCRATCH}/${IDPFX}_label-hcpmmp1.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-hcpmmp1.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-hcpmmp1.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="7:z;7:z;7:z"
  3dRank -overwrite -prefix ${DIR_SCRATCH}/TLABEL.nii.gz \
    -input ${DIR_SCRATCH}/${IDPFX}_label-hcpmmp1.nii.gz
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/TLABEL.nii.gz \
    --fg-mask ${DIR_SCRATCH}/TLABEL.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=35,85:cyc=35/6:random" \
    --fg-alpha 50 \
    --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-hcpmmp1 \
    --dir-save ${DIR_SCRATCH}
fi
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> HCPMMP1 Annotations transferred"; fi

# convert native_synth ---------------------------------------------------------
## mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/synthSR.raw.mgz \
##   ${DIR_SCRATCH}/${IDPFX}_synthT1w.nii.gz
## antsApplyTransforms -d 3 -n BSpline[3] -t identity -r ${IMAGE} \
##   -i ${DIR_SCRATCH}/${IDPFX}_synthT1w.nii.gz \
##   -o ${DIR_SCRATCH}/${IDPFX}_synthT1w.nii.gz
## if [[ "${NO_PNG}" == "false" ]]; then
##   make3Dpng --bg ${DIR_SCRATCH}/${IDPFX}_synthT1w.nii.gz --bg-threshold "2.5,97.5"
## fi
## if [[ ${VERBOSE} == "true" ]]; then
##   echo -e ">>>>> Converted to Native space NIFTI"
## fi

# convert stats output to CSV --------------------------------------------------
HEMI=("lh" "rh")
for j in {0..1}; do
  TH=${HEMI[${j}]}
  for (( i=0; i<${#LABELS[@]}; i ++ )); do
    LAB=(${LABELS[${i}]//+/ })
    STATS=${DIR_SCRATCH}/${IDPFX}/stats/${TH}.${LAB}.stats
    CSV=${DIR_SCRATCH}/${IDPFX}/stats/${TH}.${LAB}.csv
    if [[ -f ${STATS} ]]; then
      cp ${STATS} ${CSV}
      sed -i '1,/^# ColHeaders StructName NumVert SurfArea GrayVol ThickAvg ThickStd MeanCurv GausCurv FoldInd CurvInd$/d' ${CSV}
      sed -i '1s/^/StructName NumVert SurfArea GrayVol ThickAvg ThickStd MeanCurv GausCurv FoldInd CurvInd\n/' ${CSV}
      sed -i 's/ \{1,\}/,/g' ${CSV}
    fi
  done
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> converting output stats to CSV"
fi

# Extract GM Ribbon ------------------------------------------------------------
mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/ribbon.mgz ${DIR_SCRATCH}/tmp.nii.gz
niimath ${DIR_SCRATCH}/tmp.nii.gz -thr 3 -uthr 3 -bin \
  ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz -odt char
niimath ${DIR_SCRATCH}/tmp.nii.gz -thr 42 -uthr 42 -bin -mul 2 \
  -add ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz -odt char
rm ${DIR_SCRATCH}/tmp.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="7:z;7:z;7:z"
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_label-ribbon.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=50,50:cyc=4/6" \
    --fg-alpha 50 \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-ribbon \
    --fg-cbar "false" \
    --dir-save ${DIR_SCRATCH}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> GM ribbon extracted to NIFTI"
fi

# convert labels ---------------------------------------------------------------
for (( i=0; i<${#LABELS[@]}; i ++ )); do
  LAB=${LABELS[${i}]}
  if [[ ${LAB} == *"a2009s"* ]]; then FSLAB="aparc.a2009s+aseg"; fi
  if [[ ${LAB} == *"DKT"* ]]; then FSLAB="aparc.DKTatlas+aseg"; fi
  if [[ ${LAB} == *"aparc"* ]]; then FSLAB="aparc+aseg"; fi
  if [[ ${LAB} == *"wmparc"* ]]; then FSLAB="wmparc"; fi
  mri_convert ${DIR_SCRATCH}/${IDPFX}/mri/${FSLAB}.mgz \
    ${DIR_SCRATCH}/${IDPFX}_label-${LAB}.nii.gz
  antsApplyTransforms -d 3 -n MultiLabel \
   -i ${DIR_SCRATCH}/${IDPFX}_label-${LAB}.nii.gz \
   -o ${DIR_SCRATCH}/${IDPFX}_label-${LAB}.nii.gz \
    -r ${IMAGE} \
    -t identity
  if [[ "${NO_PNG}" == "false" ]]; then
    3dRank -overwrite -prefix ${DIR_SCRATCH}/TLABEL.nii.gz \
      -input ${DIR_SCRATCH}/${IDPFX}_label-${LAB}.nii.gz
    make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
      --fg ${DIR_SCRATCH}/TLABEL.nii.gz \
      --fg-mask ${DIR_SCRATCH}/TLABEL.nii.gz \
      --fg-color "timbow:random" \
      --fg-cbar "false" --fg-alpha 50 \
      --layout "7:z;7:z;7:z" \
      --filename ${IDPFX}_label-${LAB} --dir-save ${DIR_SCRATCH}
  fi
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> labels converted to NIFTI"
fi

# create masks -----------------------------------------------------------------
niimath ${DIR_SCRATCH}/${IDPFX}_label-wmparc.nii.gz \
  -thr 24 -uthr 24 -binv \
  -mul ${DIR_SCRATCH}/${IDPFX}_label-wmparc.nii.gz -bin \
  ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz
if [[ "${NO_PNG}" == "false" ]]; then
  TLAYOUT="7:y;7:y;7:y"
  make3Dpng --bg ${IMAGE} \
    --fg ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz \
    --fg-color "timbow:random" --fg-alpha 50 --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_mask-brain+${FSPIPE} \
    --dir-save ${DIR_SCRATCH}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> brain masks generated"
fi

# create surface ---------------------------------------------------------------
mri_tessellate ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz 1 ${DIR_SCRATCH}/${IDPFX}_tmp
mris_convert ${DIR_SCRATCH}/${IDPFX}_tmp ${DIR_SCRATCH}/${IDPFX}_surface-brain+${FSPIPE}.stl
rm ${DIR_SCRATCH}/${IDPFX}_tmp
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> surface tessalation completed for 3D printing"
fi

# create surface renderings ----------------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  makeSURFpng --dir-fs ${DIR_SCRATCH} --dir-id ${IDPFX} --surface pial --dir-save ${DIR_SCRATCH}
  makeSURFpng --dir-fs ${DIR_SCRATCH} --dir-id ${IDPFX} --surface white --dir-save ${DIR_SCRATCH}
  for (( i=0; i<${#LABELS[@]}; i ++ )); do
    LAB=(${LABELS[${i}]//+/ })
    if [[ -f "${DIR_SCRATCH}/${IDPFX}/label/lh.${LAB}.annot" ]]; then
      makeSURFpng --dir-fs ${DIR_SCRATCH} --dir-id ${IDPFX} \
        --surface pial --label ${LAB} --dir-save ${DIR_SCRATCH}
    fi
  done
  makeSURFpng --dir-fs ${DIR_SCRATCH} --dir-id ${IDPFX} --surface inflated --overlay thickness \
    --dir-save ${DIR_SCRATCH}
  makeSURFpng --dir-fs ${DIR_SCRATCH} --dir-id ${IDPFX} --surface inflated --overlay area \
    --dir-save ${DIR_SCRATCH}
  makeSURFpng --dir-fs ${DIR_SCRATCH} --dir-id ${IDPFX} \
    --surface inflated --overlay curv --over-color colorwheel \
    --dir-save ${DIR_SCRATCH}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> surfaces rendered for QC"
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  RMD=${DIR_SCRATCH}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd
  HEMI=("lh" "rh")

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

  echo '## Freesurfer Recon-All Pipeline' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Pipeline Information {.tabset}' >> ${RMD}
  echo '#### Click for Details ->' >> ${RMD}
  echo '#### Description' >> ${RMD}
    echo 'Cortical reconstruction and volumetric segmentation performed using the Freesurfer software suite. The automated `recon-all` processes structural images through intensity normalization, non-brain tissue removal (skull-stripping), and automated topology correction. The pipeline segments subcortical white matter and deep gray matter structures, and subsequently reconstructs the pial and gray/white matter boundaries. To achieve highly localized anatomical quantification, the standard pipeline was augmented with specialized sub-parcellation modules. Deep gray matter and brainstem substructures were automatically segmented using the FreeSurfer sub-region modules for the thalamic nuclei, the hippocampus and amygdala, the brainstem, and the hypothalamus. Cortical thickness is calculated at each vertex across the cortical ribbon as the closest distance between these two surfaces. The resulting surfaces are inflation-corrected and non-linearly registered to a spherical atlas to enable vertex-wise and region-of-interest morphometric analyses across subjects. For detailed cortical mapping, the Human Connectome Project Multi-Modal Parcellation (HCP-MMP1) atlas was mapped to each individual reconstructed surface mantle via spherical registration.\' >> ${RMD}
  echo '#### Version' >> ${RMD}
    echo 'recon-all\' >> ${RMD}
    cat $FREESURFER_HOME/build-stamp.txt >> ${RMD}
  echo '#### Citations' >> ${RMD}
    echo '##### FreeSurfer' >> ${RMD}
      echo 'Fischl B. FreeSurfer. Neuroimage. 2012;62: 774–781. doi:10.1016/j.neuroimage.2012.01.021\' >> ${RMD}
      echo '' >> ${RMD}
      echo 'Dale AM, Fischl B, Sereno MI. Cortical surface-based analysis. I. Segmentation and surface reconstruction. Neuroimage. 1999;9: 179–194. doi:10.1006/nimg.1998.0395\' >> ${RMD}
      echo '' >> ${RMD}
      echo 'Fischl B, Sereno MI, Dale AM. Cortical surface-based analysis. II: Inflation, flattening, and a surface-based coordinate system. Neuroimage. 1999;9: 195–207. doi:10.1006/nimg.1998.0396\' >> ${RMD}
      echo '' >> ${RMD}
    echo '##### Human Connectome Multimodal Parcellation (HCP-MMP1)' >> ${RMD}
      echo 'Glasser MF, Coalson TS, Robinson EC, Hacker CD, Harwell J, Yacoub E, et al. A multi-modal parcellation of human cerebral cortex. Nature. 2016;536: 171–178. doi:10.1038/nature18933\' >> ${RMD}
      echo '' >> ${RMD}
    echo '##### Sub-Region Modules' >> ${RMD}
      echo 'Thalamus:\' >> ${RMD}
      echo 'Iglesias JE, Insausti R, Lerma-Usabiaga G, Bocchetta M, Van Leemput K, Greve DN, et al. A probabilistic atlas of the human thalamic nuclei combining ex vivo MRI and histology. Neuroimage. 2018;183: 314–326. doi:10.1016/j.neuroimage.2018.08.012\' >> ${RMD}
      echo '' >> ${RMD}
      echo 'Hippocampus:\' >> ${RMD}
      echo 'Iglesias JE, Augustinack JC, Nguyen K, Player CM, Player A, Wright M, et al. A computational atlas of the hippocampal formation using ex vivo, ultra-high resolution MRI: Application to adaptive segmentation of in vivo MRI. Neuroimage. 2015;115: 117–137. doi:10.1016/j.neuroimage.2015.04.042\' >> ${RMD}
      echo '' >> ${RMD}
      echo 'Amygdala:\' >> ${RMD}
      echo 'Saygin ZM, Kliemann D, Iglesias JE, van der Kouwe AJW, Boyd E, Reuter M, et al. High-resolution magnetic resonance imaging reveals nuclei of the human amygdala: manual segmentation to automatic atlas. Neuroimage. 2017;155: 370–382. doi:10.1016/j.neuroimage.2017.04.046\' >> ${RMD}
      echo '' >> ${RMD}
      echo 'Brainstem:\' >> ${RMD}
      echo 'Iglesias JE, Van Leemput K, Bhatt P, Casillas C, Dutt S, Schuff N, et al. Bayesian segmentation of brainstem structures in MRI. Neuroimage. 2015;113: 184–195. doi:10.1016/j.neuroimage.2015.02.065\' >> ${RMD}
      echo '' >> ${RMD}
      echo 'Hypothalamus:\' >> ${RMD}
      echo 'Billot B, Bocchetta M, Todd E, Dalca AV, Rohrer JD, Iglesias JE. Automated segmentation of the hypothalamus and associated subunits in brain MRI. Neuroimage. 2020;223: 117287. doi:10.1016/j.neuroimage.2020.117287\' >> ${RMD}
      echo '' >> ${RMD}

  echo '### Anatomical Images {.tabset}' >> ${RMD}
  echo '#### Cortical Segmentation' >> ${RMD}
    TPNG=${DIR_SCRATCH}/${IDPFX}_label-ribbon.png
    echo '!['${LAB}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  echo '#### Input' >> ${RMD}
    TNII=${IMAGE}
    TPNG=${IMAGE//\.nii\.gz}.png
    if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII}; fi
    echo '![Input Anatomical]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  echo '#### Brain Mask' >> ${RMD}
    TPNG=${DIR_SCRATCH}/${IDPFX}_mask-brain+${FSPIPE}.png
    echo '![Brain Mask]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

  echo '### Surfaces {.tabset}' >> ${RMD}
  echo '#### Pial' >> ${RMD}
    TPNG=${DIR_SCRATCH}/${IDPFX}_surface-pial.png
    echo '![Pial Surface]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  echo '#### White Matter' >> ${RMD}
    TPNG=${DIR_SCRATCH}/${IDPFX}_surface-white.png
    echo '![WM Surface]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  OUTLS=("thickness" "area" "curv")
  for k in {0..2}; do
    OUT=${OUTLS[${k}]}
    echo '#### '${OUT^} >> ${RMD}
    TPNG=${DIR_SCRATCH}/${IDPFX}_surface-inflated_overlay-${OUT}.png
    echo '!['${OUT^}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
    for (( i=0; i<${#LABELS[@]}; i ++ )); do
      LAB=(${LABELS[${i}]//+/ })
      for j in {0..1}; do
        TH=${HEMI[${j}]}
        CSV="${DIR_SCRATCH}/${IDPFX}/stats/${TH}.${LAB}.csv"
        if [[ -f ${CSV} ]]; then
          FNAME="${IDPFX}_hemi-${TH}_label-${LAB}_${OUT}"
          echo '```{r}' >> ${RMD}
          echo 'data'${i}${j}${k}' <- read.csv("'${CSV}'")' >> ${RMD}
          echo 'download_this(.data=data'${i}${j}${k}',' >> ${RMD}
          echo '  output_name = "'${FNAME}'",' >> ${RMD}
          echo '  output_extension = ".csv",' >> ${RMD}
          echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
          echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
          echo '```' >> ${RMD}
          echo '' >> ${RMD}
        fi
      done
    done
  done

  echo '### Labels {.tabset}' >> ${RMD}
    for (( i=0; i<${#LABELS[@]}; i ++ )); do
      LAB=(${LABELS[${i}]//+/ })
      TPNG=${DIR_SCRATCH}/${IDPFX}_surface-pial_label-${LAB}.png
      TVOL=${DIR_SCRATCH}/${IDPFX}_label-${LABELS[${i}]}.png
      if [[ -f ${TPNG} ]]; then
        echo "#### ${LAB}" >> ${RMD}
        echo '!['${LAB}']('${TPNG}')' >> ${RMD}
        echo '!['${LAB}']('${TVOL}')' >> ${RMD}
        echo '' >> ${RMD}
      fi
    done
    LAB="HCP-MMP1"
    TPNG=${DIR_SCRATCH}/${IDPFX}_label-hcpmmp1.png
    if [[ -f ${TPNG} ]]; then
      echo "#### ${LAB}" >> ${RMD}
      echo '!['${LAB}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi
    LAB="Thalamic Nuclei"
    TPNG=${DIR_SCRATCH}/${IDPFX}_label-thalamicNuclei.png
    if [[ -f ${TPNG} ]]; then
      echo "#### ${LAB}" >> ${RMD}
      echo '!['${LAB}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi
    LAB="Medial Temporal Lobe"
    TPNG=${DIR_SCRATCH}/${IDPFX}_label-mtl.png
    if [[ -f ${TPNG} ]]; then
      echo "#### ${LAB}" >> ${RMD}
      echo '!['${LAB}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi
    LAB="Brainstem"
    TPNG=${DIR_SCRATCH}/${IDPFX}_label-brainstem.png
    if [[ -f ${TPNG} ]]; then
      echo "#### ${LAB}" >> ${RMD}
      echo '!['${LAB}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi
    LAB="Hypothalamus"
    TPNG=${DIR_SCRATCH}/${IDPFX}_label-hypothalamus.png
    if [[ -f ${TPNG} ]]; then
      echo "#### ${LAB}" >> ${RMD}
      echo '!['${LAB}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi

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

# Save output to appropriate locations -----------------------------------------
mkdir -p ${DIR_FS}
mv ${DIR_SCRATCH}/${IDPFX} ${DIR_FS}/
mkdir -p ${DIR_SAVE}/anat/label/${FSPIPE}
mkdir -p ${DIR_SAVE}/anat/mask/${FSPIPE}
mkdir -p ${DIR_SAVE}/anat/surface/png
mv ${DIR_SCRATCH}/${IDPFX}_label* ${DIR_SAVE}/anat/label/${FSPIPE}/
mv ${DIR_SCRATCH}/${IDPFX}_mask* ${DIR_SAVE}/anat/mask/${FSPIPE}/
mv ${DIR_SCRATCH}/${IDPFX}_surface-brain+${FSPIPE}.stl ${DIR_SAVE}/anat/surface/
mv ${DIR_SCRATCH}/${IDPFX}_surface*.png ${DIR_SAVE}/anat/surface/png/
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> output moved to BIDS-esque locations"
fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_SAVE}/status/${PIPE}${FLOW}
touch ${DIR_SAVE}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
