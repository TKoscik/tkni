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
OPTS=$(getopt -o hkvn --long pi:,project:,dir-project:,\
id:,dir-id:,id-field:,\
image:,uhr-thresh:,threads:,hi-fg-clfrac:,lo-fg-clfrac:,\
hi-debias-resample:,hi-debias-bspline:,hi-debias-shrink:,hi-debias-convergence:,hi-debias-histmatch:\
hi-denoise-model:,hi-denoise-shrink:,hi-denoise-patch:,hi-denoise-radius:,\
lo-debias-resample:,lo-debias-bspline:,lo-debias-shrink:,lo-debias-convergence:,lo-debias-histmatch:\
lo-denoise-model:,lo-denoise-shrink:,lo-denoise-patch:,lo-denoise-radius:,\
segment-rescale:,segment-init:,segment-n:,segment-form:,\
segment-convergence:,segment-likelihood:,segment-mrf:,segment-random:,\
dir-save:,dir-scratch:,requires:,\
keep,help,verbose,no-png,no-rmd,force -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
IDPFX=
IDDIR=
IDFIELD="uid,ses"

IMAGE=
MOD="swi"
UHR_THRESH=0.1
THREADS=4

BIMG_RESCALE=0.5x0.5x0.5

HI_FG_CLFRAC=0.15
HI_N4_RESAMPLE=1
HI_N4_BSPLINE="[200,3]"
HI_N4_SHRINK=32
HI_N4_CONVERGENCE="[50x50x50x50,0.0]"
HI_N4_HISTMATCH="[0.15,0.01,200]"
HI_DN_MODEL="Rician"
HI_DN_SHRINK=1
HI_DN_PATCH=1
HI_DN_RADIUS=2

LO_FG_CLFRAC=0.15
LO_N4_RESAMPLE=1
LO_N4_BSPLINE="[200,3]"
LO_N4_SHRINK=8
LO_N4_CONVERGENCE="[50x50x50x50,0.0]"
LO_N4_HISTMATCH="[0.15,0.01,200]"
LO_DN_MODEL="Rician"
LO_DN_SHRINK=1
LO_DN_PATCH=1
LO_DN_RADIUS=2

SG_INIT=KMeans
SG_N=12
SG_FORM=Socrates[0]
SG_CONVERGENCE=[5,0.001]
SG_LIKELIHOOD=Gaussian
SG_MRF=[0.1,1x1x1]
SG_RANDOM=1

DIR_SAVE=
DIR_SCRATCH=

KEEP="false"
HELP="false"
VERBOSE="false"
NO_PNG="false"
NO_RMD="false"

PIPE=tkni
FLOW=${FCN_NAME//${PIPE}}
REQUIRES="tkniDICOM"
FORCE=false

while true; do
  case "$1" in
    -h | --help) HELP="true" ; shift ;;
    -v | --verbose) VERBOSE="true" ; shift ;;
    -n | --no-png) NO_PNG="true" ; shift ;;
    -r | --no-rmd) NO_PNG="true" ; shift ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --id-field) IDFIELD="$2" ; shift 2 ;;
    --image) IMAGE="$2" ; shift 2 ;;
    --uhr-thresh) UHR_THRESH="$2" ; shift 2 ;;
    --threads) threads="$2" ; shift 2 ;;
    --hi-fg-clfrac) HI_FG_CLFRAC="$2" ; shift 2 ;;
    --hi-debias-resample) HI_N4_RESAMPLE="$2" ; shift 2 ;;
    --hi-debias-bspline) HI_N4_BSPLINE="$2" ; shift 2 ;;
    --hi-debias-shrink) HI_N4_SHRINK="$2" ; shift 2 ;;
    --hi-debias-convergence) HI_N4_CONVERGENCE="$2" ; shift 2 ;;
    --hi-debias-histmatch) HI_N4_HISTMATCH="$2" ; shift 2 ;;
    --hi-denoise-model) HI_DN_MODEL="$2" ; shift 2 ;;
    --hi-denoise-shrink) HI_DN_SHRINK="$2" ; shift 2 ;;
    --hi-denoise-patch) HI_DN_PATCH="$2" ; shift 2 ;;
    --hi-denoise-radius) HI_DN_RADIUS="$2" ; shift 2 ;;
    --lo-fg-clfrac) FG_CLFRAC="$2" ; shift 2 ;;
    --lo-debias-resample) LO_N4_RESAMPLE="$2" ; shift 2 ;;
    --lo-debias-bspline) LO_N4_BSPLINE="$2" ; shift 2 ;;
    --lo-debias-shrink) LO_N4_SHRINK="$2" ; shift 2 ;;
    --lo-debias-convergence) LO_N4_CONVERGENCE="$2" ; shift 2 ;;
    --lo-debias-histmatch) LO_N4_HISTMATCH="$2" ; shift 2 ;;
    --lo-denoise-model) LO_DN_MODEL="$2" ; shift 2 ;;
    --lo-denoise-shrink) LO_DN_SHRINK="$2" ; shift 2 ;;
    --lo-denoise-patch) LO_DN_PATCH="$2" ; shift 2 ;;
    --lo-denoise-radius) LO_DN_RADIUS="$2" ; shift 2 ;;
    --segment-rescale) SG_RESCALE="$2" ; shift 2 ;;
    --segment-init) SG_INIT="$2" ; shift 2 ;;
    --segment-n) SG_N="$2" ; shift 2 ;;
    --segment-form) SG_FORM="$2" ; shift 2 ;;
    --segment-convergence) SG_CONVERGENCE="$2" ; shift 2 ;;
    --segment-likelihood) SG_LIKELIHOOD="$2" ; shift 2 ;;
    --segment-mrf) SG_MRF="$2" ; shift 2 ;;
    --segment-random) SG_RANDOM="$2" ; shift 2 ;;
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
  echo '  --dir-project'
  echo '  --id'
  echo '  --dir-id'
  echo '  --id-field'
  echo '  --image'
  echo '  --reorient-code'
  echo '  --reorient-deoblique'
  echo '  --segment-rescale'
  echo '  --segment-maskclfrac'
  echo '  --segment-init'
  echo '  --segment-n'
  echo '  --segment-form'
  echo '  --segment-convergence'
  echo '  --segment-likelihood'
  echo '  --segment-mrf'
  echo '  --segment-random'
  echo ''
  echo 'Procedure: '
  echo '(1) Reorient'
  echo '(2) Debias'
  echo '(3) Denoise'
  echo '(4) Intensity Segmentation'
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
if [[ -z ${DIR_PROJECT} ]]; then
  DIR_PROJECT=/data/x/projects/${PI}/${PROJECT}
fi
if [[ -z ${DIR_SCRATCH} ]]; then
  DIR_SCRATCH=${TKNI_SCRATCH}/${FLOW}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi

# Check ID ---------------------------------------------------------------------
if [[ -z ${IDPFX} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] ID Prefix must be provided"
  exit 1
fi
if [[ -z ${IDDIR} ]]; then
  TFIELD=(${IDFIELD//,/ })
  TID=$(getField -i ${IDPFX} -f ${TFIELD[0]})
  IDDIR="${TFIELD[0]}-${TID}"
  for (( i=1; i<${#TFIELD[@]}; i++)); do
    unset TID
    TID=$(getField -i ${IDPFX} -f ${TFIELD[${i}]})
    if [[ -n ${TID} ]]; then
      IDDIR="${IDDIR}/${TFIELD[${i}]}-${TID}"
    fi
  done
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e "\tID:\t${IDPFX}"
  echo -e "\tDIR_SUBJECT:\t${IDDIR}"
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

# Default save directory -------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}; fi

# Identify UHR Inputs ----------------------------------------------------------
if [[ -z ${IMAGE} ]]; then
  IMAGE=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/anat/${IDPFX}*${MOD}.nii.gz))
else
  IMGTMP=(${IMAGE//,/ })
  MISSING="false"
  unset IMAGE
  for (( i=0; i<${#IMGTMP[@]}; i++ )); do
    if [[ -d ${IMGTMP[${i}]} ]]; then
      IMAGE+=($(ls ${IMGTMP[${i}]}/*.nii.gz))
    else
      if [[ -f ${IMGTMP[${i}]} ]]; then
        IMAGE+=${IMGTMP[${i}]}
      else
        if [[ ${MISSING} == "false" ]]; then
          echo "ERROR [${PIPE}:${FLOW}] Specified Input file not found"
        fi
        echo "   Could not find: ${IMGTMP[${i}]}"
        MISSING="true"
      fi
    fi
  done
fi
if [[ ${MISSING} == "true" ]]; then
  exit 1
fi
NIMG=${#IMAGE[@]}

if [[ ${VERBOSE} == "true" ]]; then
  echo -e "##### ${PIPE}: ${FLOW} #####"
  echo -e "PI:\t\t${PI}"
  echo -e "PROJECT:\t${PROJECT}"
  echo ">>>>>processing ${NIMG} image"
  for (( i=0; i<${NIMG}; i++ )); do
    echo -e "IMAGE:\t${IMAGE[${i}]}"
  done
fi

DIRTMP=${DIR_SCRATCH}/tmp
DIROUT=${DIR_SCRATCH}/out
mkdir -p ${DIRTMP}
mkdir -p ${DIROUT}/add
mkdir -p ${DIROUT}/base
mkdir -p ${DIROUT}/xfm

# Identify highest resolution image --------------------------------------------
WHICH_PARAMS=
LO_VAL=10
BWHICH=0
for (( i=0; i<${NIMG}; i++ )); do
  IMG=${IMAGE[${i}]}
  SZ=$(niiInfo -i ${IMG} -f mm3)

  WHICH_PARAMS[${i}]="LO"
  if [[ $(echo "${SZ} < ${UHR_THRESH}" | bc) -eq 1 ]]; then
    WHICH_PARAMS[${i}]="HI"
  fi

  if [[ $(echo "${SZ} < ${LO_VAL}" | bc) -eq 1 ]]; then
    LO_VAL=${SZ}
    BWHICH=${i}
  fi
done

# Process lowest resolution image as base image ================================
cp ${IMAGE[${BWHICH}]} ${DIRTMP}/image_base.nii.gz
PFX=$(getBidsBase -i ${IMAGE[${BWHICH}]} -s)
MOD=$(getField -i ${IMAGE[${BWHICH}]} -f modality)

# Extract FG -------------------------------------------------------------------
FG_CLFRAC="${LO_FG_CLFRAC}"
if [[ ${WHICH_PARAMS[${BWHICH}]} == "HI" ]]; then
  FG_CLFRAC="${HI_FG_CLFRAC}"
fi
3dAutomask -clfrac ${FG_CLFRAC} -overwrite -q \
  -prefix ${DIRTMP}/mask-fg_base.nii.gz \
  ${DIRTMP}/image_base.nii.gz

# Debias -----------------------------------------------------------------------
n4_fcn="N4BiasFieldCorrection -d 3"
if [[ ${WHICH_PARAMS[${BWHICH}]} == "HI" ]]; then
  n4_fcn="${n4_fcn} -r ${HI_N4_RESAMPLE}"
  n4_fcn="${n4_fcn} -s ${HI_N4_SHRINK}"
  n4_fcn="${n4_fcn} -c ${HI_N4_CONVERGENCE}"
  n4_fcn="${n4_fcn} -b ${HI_N4_BSPLINE}"
else
  n4_fcn="${n4_fcn} -r ${LO_N4_RESAMPLE}"
  n4_fcn="${n4_fcn} -s ${LO_N4_SHRINK}"
  n4_fcn="${n4_fcn} -c ${LO_N4_CONVERGENCE}"
  n4_fcn="${n4_fcn} -b ${LO_N4_BSPLINE}"
fi
n4_fcn="${n4_fcn} -i ${DIRTMP}/image_base.nii.gz"
n4_fcn="${n4_fcn} -x ${DIRTMP}/mask-fg_base.nii.gz"
n4_fcn="${n4_fcn} -o ${DIRTMP}/image_base.nii.gz"
echo -e "\nDebiasing Base Image\n${n4_fcn}\n\n"
eval ${n4_fcn}

# Denoise ----------------------------------------------------------------------
dn_fcn="DenoiseImage -d 3"
if [[ ${WHICH_PARAMS[${BWHICH}]} == "HI" ]]; then
  dn_fcn="${dn_fcn} -n ${HI_DN_MODEL}"
  dn_fcn="${dn_fcn} -s ${HI_DN_SHRINK}"
  dn_fcn="${dn_fcn} -p ${HI_DN_PATCH}"
  dn_fcn="${dn_fcn} -r ${HI_DN_RADIUS}"
else
  dn_fcn="${dn_fcn} -n ${LO_DN_MODEL}"
  dn_fcn="${dn_fcn} -s ${LO_DN_SHRINK}"
  dn_fcn="${dn_fcn} -p ${LO_DN_PATCH}"
  dn_fcn="${dn_fcn} -r ${LO_DN_RADIUS}"
fi
dn_fcn="${dn_fcn} -i ${DIRTMP}/image_base.nii.gz"
dn_fcn="${dn_fcn} -x ${DIRTMP}/mask-fg_base.nii.gz"
dn_fcn="${dn_fcn} -o ${DIRTMP}/image_base.nii.gz"
echo -e "\nDenoising Base Image\n${dn_fcn}\n\n"
eval ${dn_fcn}

# Intensity Segmentation -------------------------------------------------------
if [[ ${BIMG_RESCALE} != "false" ]]; then
  ResampleImage 3 ${DIRTMP}/image_base.nii.gz \
    ${DIRTMP}/image_resample.nii.gz ${BIMG_RESCALE} 0 4
  antsApplyTransforms -d 3 -n GenericLabel \
    -i ${DIRTMP}/mask-fg_base.nii.gz \
    -o ${DIRTMP}/mask-fg_base_resample.nii.gz \
    -r ${DIRTMP}/image_resample.nii.gz
fi
Atropos --image-dimensionality 3 \
  --intensity-image ${DIRTMP}/image_resample.nii.gz \
  --mask-image ${DIRTMP}/mask-fg_base_resample.nii.gz \
  --initialization ${SG_INIT}[${SG_N}] \
  --posterior-formulation ${SG_FORM} \
  --convergence ${SG_CONVERGENCE} \
  --likelihood-model ${SG_LIKELIHOOD} \
  --mrf ${SG_MRF} \
  --use-random-seed ${SG_RANDOM} \
  --output ${DIRTMP}/label_base.nii.gz

# move base image to output folder ---------------------------------------------
mv ${DIRTMP}/image_base.nii.gz ${DIROUT}/base/${PFX}_${MOD}.nii.gz
mv ${DIRTMP}/mask-fg_base.nii.gz ${DIROUT}/base/${PFX}_mask-fg+INIT.nii.gz
mv ${DIRTMP}/image_resample.nii.gz ${DIROUT}/base/${PFX}_proc-resample_${MOD}.nii.gz
mv ${DIRTMP}/label_base.nii.gz ${DIROUT}/base/${PFX}_proc-resample_label-atropos+${SG_N}.nii.gz
rm ${DIRTMP}/mask-fg_base_resample.nii.gz

BIMG=${DIROUT}/base/${PFX}_${MOD}.nii.gz
BMASK=${DIROUT}/base/${PFX}_mask-fg+INIT.nii.gz

# Loop over ADDITIONAL images --------------------------------------------------
for (( i=0; i<${NIMG}; i++ )); do
  if [[ ${i} -ne ${BWHICH} ]]; then
    cp ${IMAGE[${i}]} ${DIRTMP}/image_add.nii.gz
    PFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
    MOD=$(getField -i ${IMAGE[${i}]} -f modality)

    # Extract FG ---------------------------------------------------------------
    FG_CLFRAC="${LO_FG_CLFRAC}"
    if [[ ${WHICH_PARAMS[${i}]} == "HI" ]]; then FG_CLFRAC="${HI_FG_CLFRAC}"; fi
    3dAutomask -clfrac ${FG_CLFRAC} -overwrite -q \
      -prefix ${DIRTMP}/mask-fg_add.nii.gz \
      ${DIRTMP}/image_add.nii.gz

    # Debias -------------------------------------------------------------------
    n4_fcn="N4BiasFieldCorrection -d 3"
    if [[ ${WHICH_PARAMS[${i}]} == "HI" ]]; then
      n4_fcn="${n4_fcn} -r ${HI_N4_RESAMPLE}"
      n4_fcn="${n4_fcn} -s ${HI_N4_SHRINK}"
      n4_fcn="${n4_fcn} -c ${HI_N4_CONVERGENCE}"
      n4_fcn="${n4_fcn} -b ${HI_N4_BSPLINE}"
    else
      n4_fcn="${n4_fcn} -r ${LO_N4_RESAMPLE}"
      n4_fcn="${n4_fcn} -s ${LO_N4_SHRINK}"
      n4_fcn="${n4_fcn} -c ${LO_N4_CONVERGENCE}"
      n4_fcn="${n4_fcn} -b ${LO_N4_BSPLINE}"
    fi
    n4_fcn="${n4_fcn} -i ${DIRTMP}/image_add.nii.gz"
    n4_fcn="${n4_fcn} -x ${DIRTMP}/mask-fg_add.nii.gz"
    n4_fcn="${n4_fcn} -o ${DIRTMP}/image_add.nii.gz"
    echo -e "\nDebiasing Base Image\n${n4_fcn}\n\n"
    eval ${n4_fcn}

    # Denoise ------------------------------------------------------------------
    dn_fcn="DenoiseImage -d 3"
    if [[ ${WHICH_PARAMS[${i}]} == "HI" ]]; then
      dn_fcn="${dn_fcn} -n ${HI_DN_MODEL}"
      dn_fcn="${dn_fcn} -s ${HI_DN_SHRINK}"
      dn_fcn="${dn_fcn} -p ${HI_DN_PATCH}"
      dn_fcn="${dn_fcn} -r ${HI_DN_RADIUS}"
    else
      dn_fcn="${dn_fcn} -n ${LO_DN_MODEL}"
      dn_fcn="${dn_fcn} -s ${LO_DN_SHRINK}"
      dn_fcn="${dn_fcn} -p ${LO_DN_PATCH}"
      dn_fcn="${dn_fcn} -r ${LO_DN_RADIUS}"
    fi
    dn_fcn="${dn_fcn} -i ${DIRTMP}/image_add.nii.gz"
    dn_fcn="${dn_fcn} -x ${DIRTMP}/mask-fg_add.nii.gz"
    dn_fcn="${dn_fcn} -o ${DIRTMP}/image_add.nii.gz"
    echo -e "\nDenoising Base Image\n${dn_fcn}\n\n"
    eval ${dn_fcn}

    # Coregister to base image -------------------------------------------------
    coregistrationChef --recipe-name "rigid" --no-png \
      --fixed ${BIMG} --fixed-mask ${BMASK} \
      --moving ${DIRTMP}/image_add.nii.gz \
      --moving-mask ${DIRTMP}/mask-fg_add.nii.gz \
      --space-target "MOVING" \
      --prefix "${PFX}" \
      --label-from "raw" --label-to "base" \
      --dir-save ${DIRTMP} \
      --dir-xfm ${DIRTMP} --verbose --ants-verbose

    # copy to output folder
    mv ${DIRTMP}/${PFX}_reg-rigid+base_add.nii.gz \
      ${DIROUT}/add/${PFX}_reg-rigid+base_${MOD}.nii.gz
    mv ${DIRTMP}/${PFX}_mod-add_from-raw_to-base_xfm-rigid.mat \
      ${DIROUT}/xfm/${PFX}_from-raw_to-base_xfm-rigid.mat
    rm ${DIRTMP}/image_add.nii.gz
    rm ${DIRTMP}/mask-fg_add.nii.gz
  fi
done

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}
  RMD=${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd

  echo -e '---\ntitle: "&nbsp;"\noutput: html_document\n---\n' > ${RMD}
  echo '```{r setup, include=FALSE}' >> ${RMD}
  echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
  echo 'knitr::include_graphics("'${TKNIPATH}'/TK_BRAINLab_logo.png")' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## Initial *Ex-vivo* Anatomical Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "*" -Rn --prune '${DIROUT} >> ${RMD}
  echo -e '```\n' >> ${RMD}

  # base image
  DIM=($(niiInfo -i ${BIMG} -f "voxels"))
  if [[ ${DIM[0]} -lt ${DIM[1]} ]] && [[ ${DIM[0]} -lt ${DIM[2]} ]]; then PLANE="x"; fi
  if [[ ${DIM[1]} -lt ${DIM[0]} ]] && [[ ${DIM[1]} -lt ${DIM[2]} ]]; then PLANE="y"; fi
  if [[ ${DIM[2]} -lt ${DIM[0]} ]] && [[ ${DIM[2]} -lt ${DIM[1]} ]]; then PLANE="z"; fi
  if [[ -z ${PLANE} ]]; then PLANE="z"; fi
  LAYOUT="9:${PLANE};9:${PLANE};9:${PLANE}"

  echo '### Base Anatomical Image {.tabset}' >> ${RMD}
  echo '#### Clean' >> ${RMD}
  BNAME=$(basename ${BIMG})
  FNAME=${BIMG//\.nii\.gz}
  make3Dpng --bg ${BIMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}"
  echo -e '!['${BNAME}']('${FNAME}'.png)\n' >> ${RMD}

  echo '#### Raw' >> ${RMD}
  BRAW=${IMAGE[${BWHICH}]}
  BNAME=$(basename ${BRAW})
  make3Dpng --bg ${BRAW} --bg-threshold "2.5,97.5" --layout "${LAYOUT}" \
    --filename "raw_base_image" --dir-save ${DIRTMP}
  echo -e '!['${BNAME}']('${DIRTMP}'/raw_base_image.png)\n' >> ${RMD}

  if [[ ${NIMG} -gt 1 ]]; then
    echo '### Additional Anatomical Images' >> ${RMD}
    for (( i=0; i<${NIMG}; i++ )); do
      if [[ ${i} -ne ${BWHICH} ]]; then
        PFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
        MOD=$(getField -i ${IMAGE[${i}]} -f modality)
        DIM=($(niiInfo -i ${IMAGE[${i}]} -f "voxels"))
        if [[ ${DIM[0]} -lt ${DIM[1]} ]] && [[ ${DIM[0]} -lt ${DIM[2]} ]]; then PLANE="x"; fi
        if [[ ${DIM[1]} -lt ${DIM[0]} ]] && [[ ${DIM[1]} -lt ${DIM[2]} ]]; then PLANE="y"; fi
        if [[ ${DIM[2]} -lt ${DIM[0]} ]] && [[ ${DIM[2]} -lt ${DIM[1]} ]]; then PLANE="z"; fi
        if [[ -z ${PLANE} ]]; then PLANE="z"; fi
        LAYOUT="9:${PLANE};9:${PLANE};9:${PLANE}"
        make3Dpng --bg ${DIROUT}/add/${PFX}_reg-rigid+base_${MOD}.nii.gz \
          --bg-threshold "2.5,97.5" --layout "${LAYOUT}"
        make3Dpng --bg ${IMAGE[${i}]} --bg-threshold "2.5,97.5" --layout "${LAYOUT}" \
          --filename raw_image_${i} --dir-save ${DIRTMP}
        echo "#### ${PFX}_${MOD}.nii.gz {.tabset}" >> ${RMD}
        echo '##### Click to View -->' >> ${RMD}
        echo '##### Clean' >> ${RMD}
        echo -e '![Cleaned]('${DIROUT}'/add/'${PFX}'_reg-rigid+base_'${MOD}'.png)\n' >> ${RMD}
        echo '##### Raw' >> ${RMD}
        echo -e '![Raw]('${DIRTMP}'/raw_image_'${i}'.png)\n' >> ${RMD}
      fi
    done
  fi

  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
fi

# Save result ------------------------------------------------------------------
mkdir -p ${DIR_SAVE}/xinit
mv ${DIROUT}/base/* ${DIR_SAVE}/xinit/base/
mv ${DIROUT}/add/* ${DIR_SAVE}/xinit/add/
mkdir -p ${DIR_SAVE}/xfm/${IDDIR}
mv ${DIROUT}/xfm/* ${DIR_SAVE}/xfm/${IDDIR}/

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0

