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
image:,threads:,\
debias-bspline:,debias-shrink:,debias-convergence:,debias-histmatch:\
segment-rescale:,segment-maskclfrac:,segment-init:,segment-n:,segment-form:,\
segment-convergence:,segment-likelihood:,segment-mrf:,segment-random:,\
dir-save:,dir-scratch:,\
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
UHR_THRESH=0.1
THREADS=4

DEBIAS_BSPLINE="[300,3,0.0,0.5]"
DEBIAS_SHRINK=16
DEBIAS_CONVERGENCE="[500x500x500x500,0.001]"
DEBIAS_HISTMATCH="[0.3,0.01,200]"

SEGMENT_RESCALE=1x1x1
SEGMENT_MASKCLFRAC=0.15
SEGMENT_INIT=KMeans
SEGMENT_N=12
SEGMENT_FORM=Socrates[0]
SEGMENT_CONVERGENCE=[5,0.001]
SEGMENT_LIKELIHOOD=Gaussian
SEGMENT_MRF=[0.1,1x1x1]
SEGMENT_RANDOM=1

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
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --id-field) IDFIELD="$2" ; shift 2 ;;
    --image) IMAGE="$2" ; shift 2 ;;
    --no-reorient) NO_REORIENT="true" ; shift ;;
    --reorient-code) REORIENT_CODE="$2" ; shift 2 ;;
    --reorient-deoblique) REORIENT_DEOBLIQUE="true" ; shift ;;
    --segment-rescale) SEGMENT_RESCALE="$2" ; shift 2 ;;
    --segment-maskclfrac) SEGMENT_MASKCLFRAC="$2" ; shift 2 ;;
    --segment-init) SEGMENT_INIT="$2" ; shift 2 ;;
    --segment-n) SEGMENT_N="$2" ; shift 2 ;;
    --segment-form) SEGMENT_FORM="$2" ; shift 2 ;;
    --segment-convergence) SEGMENT_CONVERGENCE="$2" ; shift 2 ;;
    --segment-likelihood) SEGMENT_LIKELIHOOD="$2" ; shift 2 ;;
    --segment-mrf) SEGMENT_MRF="$2" ; shift 2 ;;
    --segment-random) SEGMENT_RANDOM="$2" ; shift 2 ;;
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
  IMAGE=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/anat/${IDPFX}*swi.nii.gz))
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
mkdir -p ${DIROUT}

# Identify UHR images ----------------------------------------------------------
UHR_THRESH=0.1
unset UHRLS
for (( i=0; i<${NIMG}; i++ )); do
  SZ=$(niiInfo -i ${IMAGE[${i}]} -f mm3)
  if [[ $(echo "${SZ} < ${UHR_THRESH}" | bc) -eq 1 ]]; then
    UHRLS+=(${IMAGE[${i}]})
  fi
done
NUHR=${#UHRLS[@]}

if [[ ${NO_RMD} == "false" ]]; then
  RMD=${DIR_SCRATCH}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd
  echo -e '---\ntitle: "&nbsp;"\noutput: html_document\n---\n' > ${RMD}
  echo '```{r setup, include=FALSE}' >> ${RMD}
  echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
  echo 'knitr::include_graphics("'${TKNIPATH}'/TK_BRAINLab_logo.png")' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '```{r, echo=FALSE}' >> ${RMD}
  echo 'library(DT)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}
  echo '## Initial Ultra-High Resolution Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}
fi

for (( i=0; i<${NUHR}; i++ )); do
  IMG=${UHRLS[${i}]}

  # initialize outputs ---------------------------------------------------------
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)

  # get Image Dimensions, and plane of acquisition -------------------------
  DIM=($(niiInfo -i ${IMG} -f "voxels"))
  if [[ ${DIM[0]} -lt ${DIM[1]} ]] && [[ ${DIM[0]} -lt ${DIM[2]} ]]; then PLANE="x"; fi
  if [[ ${DIM[1]} -lt ${DIM[0]} ]] && [[ ${DIM[1]} -lt ${DIM[2]} ]]; then PLANE="y"; fi
  if [[ ${DIM[2]} -lt ${DIM[0]} ]] && [[ ${DIM[2]} -lt ${DIM[1]} ]]; then PLANE="z"; fi
  if [[ -z ${PLANE} ]]; then PLANE="z"; fi

  # Copy RAW image to scratch --------------------------------------------------
  TIMG=${DIRTMP}/image_raw.nii.gz
  cp ${IMG} ${DIRTMP}/image_raw.nii.gz

  # Intensity Segmentation -----------------------------------------------------
  ## Debias first
  MIN=$(3dBrickStat -slow -min ${DIRTMP}/image_raw.nii.gz)
  niimath ${DIRTMP}/image_raw.nii.gz -add ${MIN//-} -add 10 ${DIRTMP}/image_tmp.nii.gz
  N4BiasFieldCorrection -d 3 \
    -i ${DIRTMP}/image_tmp.nii.gz \
    -o ${DIRTMP}/image_debias.nii.gz \
    --bspline-fitting ${DEBIAS_BSPLINE} \
    --shrink-factor ${DEBIAS_SHRINK} \
    --convergence ${DEBIAS_CONVERGENCE} \
    --histogram-sharpening ${DEBIAS_HISTMATCH}
  ResampleImage 3 ${DIRTMP}/image_debias.nii.gz \
    ${DIRTMP}/image_downsample.nii.gz ${SEGMENT_RESCALE} 0 4
  3dAutomask -prefix ${DIRTMP}/image_mask-fg.nii.gz \
    -overwrite -clfrac ${SEGMENT_MASKCLFRAC} \
    ${DIRTMP}/image_downsample.nii.gz
  Atropos --image-dimensionality 3 \
    --intensity-image ${DIRTMP}/image_downsample.nii.gz \
    --mask-image ${DIRTMP}/image_mask-fg.nii.gz \
    --initialization ${SEGMENT_INIT}[${SEGMENT_N}] \
    --posterior-formulation ${SEGMENT_FORM} \
    --convergence ${SEGMENT_CONVERGENCE} \
    --likelihood-model ${SEGMENT_LIKELIHOOD} \
    --mrf ${SEGMENT_MRF} \
    --use-random-seed ${SEGMENT_RANDOM} \
    --verbose 1 \
    --output ${DIRTMP}/image_label-atropos+${SEGMENT_N}.nii.gz
  if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == false ]]; then
    make3Dpng --bg ${DIRTMP}/image_downsample.nii.gz \
      --fg ${DIRTMP}/image_label-atropos+${SEGMENT_N}.nii.gz \
      --fg-mask ${DIRTMP}/image_label-atropos+${SEGMENT_N}.nii.gz \
      --fg-color "timbow:rnd" \
      --fg-alpha 50 --fg-cbar "false" \
      --layout "1:${PLANE}" --max-pixels 1024 \
      --filename ${PFX}_label-atropos+${SEGMENT_N} \
      --dir-save ${DIR_SCRATCH}
    if [[ ${NO_RMD} == false ]]; then
      echo -e '#### Intensity Segmentation' >> ${RMD}
      echo -e '![Segmentation]('${DIR_SCRATCH}'/'${PFX}'_label-atropos+'${SEGMENT_N}'.png)\n' >> ${RMD}
    fi
  fi

  # Save result ----------------------------------------------------------------
  ResampleImage 3 ${DIRTMP}/image_raw.nii.gz ${DIROUT}/${PFX}_${MOD}.nii.gz ${SEGMENT_RESCALE} 0 4
  mv ${DIRTMP}/image_label-atropos+${SEGMENT_N}.nii.gz \
     ${DIROUT}/${PFX}_label-atropos+${SEGMENT_N}.nii.gz
  rm ${DIRTMP}/*
done

mkdir -p ${DIR_SAVE}/anat/init
mv ${DIROUT}/* ${DIR_SAVE}/anat/init

## knit RMD
Rscript -e "rmarkdown::render('${RMD}')"
mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
mv ${DIR_SCRATCH}/*.html ${DIR_PROJECT}/qc/${PIPE}${FLOW}/

mkdir -p ${DIR_SAVE}/prep/${IDDIR}/${PIPE}${FLOW}
mv ${DIR_SCRATCH}/*.png ${DIR_SAVE}/prep/${IDDIR}/${PIPE}${FLOW}/

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0

