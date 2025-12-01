#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkniXINIT
# WORKFLOW:      UHR Ex-Vivo Initial Processing
# DESCRIPTION:   Cleaning ultra-high-resolution ex-vivo MRI images results are
#                initially debiased and denoised, and intensity segmented to
#                facilitate manual brain masking.
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-07-01ish
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
image:,mod:,redo-mask,uhr-thresh:,\
debias-resample:,debias-bspline:,debias-shrink:,debias-convergence:,debias-histmatch:\
denoise-model:,denoise-shrink:,denoise-patch:,denoise-radius:,\
softmask-kernel:,\
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
IDFIELD="pid,ses"

IMAGE=
MOD="swi"
REDO_MASK="false"
UHR_THRESH=0.1
N4_RESAMPLE=1
N4_BSPLINE="[85,3]"
N4_SHRINK=4
N4_CONVERGENCE="[100x100x100x100,0.001]"
N4_HISTMATCH="[0.15,0.01,200]"
DN_MODEL="Rician"
DN_SHRINK=1
DN_PATCH=1
DN_RADIUS=2
SOFTMASK_KERNEL=1

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
    --mod) MOD="$2" ; shift 2 ;;
    --redo-mask) REDO_MASK="true" ; shift ;;
    --uhr-thresh) UHR_THRESH="$2" ; shift 2 ;;
    --threads) threads="$2" ; shift 2 ;;
    --debias-resample) N4_RESAMPLE="$2" ; shift 2 ;;
    --debias-bspline) N4_BSPLINE="$2" ; shift 2 ;;
    --debias-shrink) N4_SHRINK="$2" ; shift 2 ;;
    --debias-convergence) N4_CONVERGENCE="$2" ; shift 2 ;;
    --debias-histmatch) N4_HISTMATCH="$2" ; shift 2 ;;
    --denoise-model) DN_MODEL="$2" ; shift 2 ;;
    --denoise-shrink) DN_SHRINK="$2" ; shift 2 ;;
    --denoise-patch) DN_PATCH="$2" ; shift 2 ;;
    --denoise-radius) DN_RADIUS="$2" ; shift 2 ;;
    --softmask-kernel) SOFTMASK_KERNEL="$2" ; shift 2 ;;
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
  echo ''
  echo 'Procedure: '
  echo '(1) nnUNet Brain Mask'
  echo '(2) Debias'
  echo '(3) Denoise'
  echo '(4) Rescale Intensity'
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
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/anat; fi

# Identify Ex Vivo Images ------------------------------------------------------
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

# Include only images at UHR ---------------------------------------------------
IS_UHR=
NOT_UHR=
for (( i=0; i<${#IMAGE[@]}; i++ )); do
  IMG=${IMAGE[${i}]}
  SZ=$(niiInfo -i ${IMG} -f mm3)
  if [[ $(echo "${SZ} < ${UHR_THRESH}" | bc) -eq 1 ]]; then
    IS_UHR+=(${IMAGE[${i}]})
  else
    NOT_UHR+=(${IMAGE[${i}]})
  fi
done
IMAGE=(${IS_UHR[@]})
NIMG=${#IMAGE[@]}

if [[ ${VERBOSE} == "true" ]]; then
  echo -e "##### ${PIPE}: ${FLOW} #####"
  echo -e "PI:\t\t${PI}"
  echo -e "PROJECT:\t${PROJECT}"
  echo ">>>>>processing ${NIMG} image(s)"
  for (( i=0; i<${NIMG}; i++ )); do
    echo -e "IMAGE:\t${IMAGE[${i}]}"
  done
  echo ">>>>>NOT processing ${#NOT_UHR[@]} image(s)"
  for (( i=0; i<${#NOT_UHR[@]}; i++ )); do
    echo -e "IMAGE:\t${NOT_UHR[${i}]}"
  done
fi

DIRTMP=${DIR_SCRATCH}/tmp
DIROUT=${DIR_SCRATCH}/out
mkdir -p ${DIRTMP}
mkdir -p ${DIROUT}/native
mkdir -p ${DIROUT}/mask

# Process High Resolution Images ===============================================
for (( i=0; i<${NIMG}; i++ )); do
  cp ${IMAGE[${i}]} ${DIRTMP}/
  IMG=${DIRTMP}/$(basename ${IMAGE[${i}]})
  PFX=$(getBidsBase -i ${IMG} -s)

  ## Ex Vivo Brain Extraction --------------------------------------------------
  ## Save brain mask to output directory right away and reload if it exists
  mkdir -p ${DIR_SAVE}/mask
  MASK=${DIR_SAVE}/mask/${PFX}_mask-brain.nii.gz
  if [[ ! -f ${MASK} ]] || [[ ${REDO_MASK} == "true" ]]; then
    exvivoBEX --image ${IMG} --no-png
    mv ${DIRTMP}/${PFX}_mask-brain.nii.gz ${MASK}
  fi
  echo ">>>>>>Brain Extraction Complete"

  ## Debias --------------------------------------------------------------------
  N4BiasFieldCorrection -d 3 -i ${IMG} -x ${MASK} -o ${IMG} \
    -r ${N4_RESAMPLE} \
    -s ${N4_SHRINK} \
    -c ${N4_CONVERGENCE} \
    -b ${N4_BSPLINE} \
    -t ${N4_HISTMATCH}
  echo ">>>>>>Debiased"

  ## Denoise -------------------------------------------------------------------
  DenoiseImage -d 3 -i ${IMG} -x ${MASK} -o ${IMG} \
    -n ${DN_MODEL} \
    -s ${DN_SHRINK} \
    -p ${DN_PATCH} \
    -r ${DN_RADIUS}
  echo ">>>>>>Denoised"

  # generate brain mask before it is applied to the image ----------------------
  if [[ ${NO_PNG} == "false" ]]; then
    make3Dpng --bg ${IMG} --bg-threshold "0.1,99.9" \
    --fg ${MASK} --fg-mask ${MASK} --fg-alpha 50 --fg-cbar "false" \
    --fg-color "timbow:hue=#FF0000:sat=100:lum=65,65" \
    --layout "9:x;9:x;9:y;9:y;9:z;9:z" \
    --filename ${PFX}_mask-brain \
    --dir-save ${DIR_SAVE}/mask
  fi

  ## Apply Soft Mask -----------------------------------------------------------
  softMask --image ${IMG} --mask ${MASK} \
    --kernel ${SOFTMASK_KERNEL} --no-png \
    --filename $(basename ${IMG})
  echo ">>>>>>Soft Mask"

  ## Rescale Intensity ---------------------------------------------------------
  rescaleIntensity --image ${IMG} --mask ${MASK} \
    --dir-save ${DIRTMP} --filename $(getBidsBase -i ${IMG}) --no-png
  echo ">>>>>>Intensity Rescaled"

  ## Generate PNG --------------------------------------------------------------
  if [[ ${NO_PNG} == "false" ]]; then
    make3Dpng --bg ${IMG} --bg-threshold "0.1,99.9"
    make3Dpng --bg ${IMG} --bg-threshold "0.1,99.9" \
      --layout "9:x;9:x;9:x" --filename ${PFX}_axial
    make3Dpng --bg ${IMG} --bg-threshold "0.1,99.9" \
      --layout "9:y;9:y;9:y" --filename ${PFX}_coronal
    make3Dpng --bg ${IMG} --bg-threshold "0.1,99.9" \
      --layout "9:z;9:z;9:z" --filename ${PFX}_sagittal
  fi

  ## Save Result ---------------------------------------------------------------
  #mv ${DIRTMP}/*mask-brain* ${DIROUT}/mask/
  mv ${IMG} ${DIROUT}/native/
  mv ${DIRTMP}/*.png ${DIROUT}/native/
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
  echo '* Images <'${UHR_THRESH}'mm^3' >> ${RMD}
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

  for (( i=0; i<${NIMG}; i++ )); do
    PFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
    RAW_NII=${IMAGE[${i}]}
    RAW_PNG="$(dirname ${RAW_NII})/${PFX}_${MOD}.png"
    CLN_NII=${DIROUT}/native/${PFX}_${MOD}.nii.gz
    CLN_PNG=${DIROUT}/native/${PFX}_${MOD}.png
    CLN_AXI=${DIROUT}/native/${PFX}_axial.png
    CLN_COR=${DIROUT}/native/${PFX}_coronal.png
    CLN_SAG=${DIROUT}/native/${PFX}_sagittal.png
    MASK_PNG=${DIR_SAVE}/mask/${PFX}_mask-brain.png

    make3Dpng --bg ${RAW_NII} --bg-threshold "2.5,97.5"

    echo '### '${PFX}' {.tabset}' >> ${RMD}
    echo '#### Clean vs. Raw Image' >> ${RMD}
      echo "##### Clean" >> ${RMD}
      echo '![Clean]('${CLN_PNG}')' >> ${RMD}
      echo '' >> ${RMD}
      echo "##### Raw" >> ${RMD}
      echo '![Raw]('${RAW_PNG}')' >> ${RMD}
      echo '' >> ${RMD}
    echo "#### Brain Mask" >> ${RMD}
      echo '![Brain Mask]('${MASK_PNG}')' >> ${RMD}
      echo '' >> ${RMD}
    echo '#### Axial' >> ${RMD}
      echo '![Axial Clean]('${CLN_AXI}')' >> ${RMD}
      echo '' >> ${RMD}
    echo '#### Coronal' >> ${RMD}
      echo '![Coronal Clean]('${CLN_COR}')' >> ${RMD}
      echo '' >> ${RMD}
    echo '#### Sagittal' >> ${RMD}
      echo '![Sagittal Clean]('${CLN_SAG}')' >> ${RMD}
      echo '' >> ${RMD}
  done

  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
fi

# Save result ------------------------------------------------------------------
mkdir -p ${DIR_SAVE}/native
#mkdir -p ${DIR_SAVE}/mask
mv ${DIROUT}/native/* ${DIR_SAVE}/native/
#mv ${DIROUT}/mask/* ${DIR_SAVE}/mask/

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0

