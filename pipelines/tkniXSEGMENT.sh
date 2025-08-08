#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkniXSEGMENT
# WORKFLOW:      UHR Ex-Vivo Secondary Processing and Segmentation
# DESCRIPTION:   Re-cleaning UHR images using manual brain mask, additional
#                processing and intermediates for segmentation, Laplacian of the
#                Gaussian-based Watershed segmentation and refinement.
# PROCESS:       1) Additional N4 Debiasing
#                2) Additional Rician Denoising
#                3) Threshold, Stretch, Mask, convert to SHORT
#                4) Anisotropic Smooth
#                5) Calculate Difference of Gaussians
#                   -default using K=1.6 to approximate the Laplacian of the
#                    Gaussian
#                   -k=5 might be a reasonable value as well which may
#                    approximate retinal ganglion cells
#                   -output zero-crossings
#                6) Calculate the Signed Distance Transform to the the zero-
#                   crossings
#                7) Watershed Clustering
#                   -threshold at desired "altitude" to produce non-connected
#                    clusters, default is >= 2 voxels from DoG zero-crossing
#                   -generate clusters with 6-neighbor connectivity
#                   -flood fill up to "datum", default is 1 voxel from zero-
#                    crossing
#                   -add smaller peaks that do not reach initial separating
#                    altitude
#                8) Merge clusters, touching neighbors with significantly
#                   overlapping intensity probability distribution functions
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-08-08
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
image:,mask:,dir-xinit:,\
debias-resample:,debias-bspline:,debias-shrink:,debias-convergence:,debias-histmatch:\
denoise-model:,denoise-shrink:,denoise-patch:,denoise-radius:,\
rescale-lo-pct:,rescale-hi-pct:,rescale-lo-val:,rescale-hi-val:,stretch-lo:,stretch-hi:,\
aniso-conductance:,aniso-iter:,\
dog_g1:,dog_k:,\
altitude:,datum:,no-merge,pdf-overlap:,\
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
MASK=
DIR_XINIT=

N4_RESAMPLE=1
N4_BSPLINE="[200,3]"
N4_SHRINK=32
N4_CONVERGENCE="[50x50x50x50,0.0]"
N4_HISTMATCH="[0.15,0.01,200]"
DN_MODEL="Rician"
DN_SHRINK=1
DN_PATCH=1
DN_RADIUS=2

RESCALE_LO_PCT=0.1
RESCALE_HI_PCT=99.9
RESCALE_LO_VAL=
RESCALE_HI_VAL=
STRETCH_LO=1000
STRETCH_HI=21000

SMOOTH_CONDUCTANCE=0.5
SMOOTH_ITER=20

DOG_G1=0
DOG_K=1.6

ALTITUDE="2vox"
DATUM="1vox"
CONNECTIVITY=6

NO_MERGE="false"
PDF_OVERLAP=0.25

DIR_SAVE=
DIR_SCRATCH=

KEEP="false"
HELP="false"
VERBOSE="false"
NO_PNG="false"
NO_RMD="false"

PIPE=tkni
FLOW=${FCN_NAME//${PIPE}}
REQUIRES="tkniDICOM,tkniXINIT"
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
    --mask) MASK="$2" ; shift 2 ;;
    --debias-resample) N4_RESAMPLE="$2" ; shift 2 ;;
    --debias-bspline) N4_BSPLINE="$2" ; shift 2 ;;
    --debias-shrink) N4_SHRINK="$2" ; shift 2 ;;
    --debias-convergence) N4_CONVERGENCE="$2" ; shift 2 ;;
    --debias-histmatch) N4_HISTMATCH="$2" ; shift 2 ;;
    --denoise-model) DN_MODEL="$2" ; shift 2 ;;
    --denoise-shrink) DN_SHRINK="$2" ; shift 2 ;;
    --denoise-patch) DN_PATCH="$2" ; shift 2 ;;
    --denoise-radius) DN_RADIUS="$2" ; shift 2 ;;
    --rescale-lo-pct) RESCALE_LO_PCT="$2" ; shift 2 ;;
    --rescale-hi-pct) RESCALE_HI_PCT="$2" ; shift 2 ;;
    --rescale-lo-val) RESCALE_LO_VAL="$2" ; shift 2 ;;
    --rescale-hi-val) RESCALE_HI_VAL="$2" ; shift 2 ;;
    --stretch-lo) STRETCH_LO="$2" ; shift 2 ;;
    --stretch-hi) STRETCH_HI="$2" ; shift 2 ;;
    --aniso-conductance) SMOOTH_CONDUCTANCE="$2" ; shift 2 ;;
    --aniso-iter) SMOOTH_ITER="$2" ; shift 2 ;;
    --dog_g1) DOG_G1="$2" ; shift 2 ;;
    --dog_k) DOG_K="$2" ; shift 2 ;;
    --altitude) ALTITUDE="$2" ; shift 2 ;;
    --datum) DATUM="$2" ; shift 2 ;;
    --no-merge) NO_MERGE="true" ; shift ;;
    --pdf-overlap) PDF_OVERLAP="$2" ; shift 2 ;;
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
  echo '  --mask-brain'
  echo '  --debias-resample'
  echo '  --debias-bspline'
  echo '  --debias-shrink'
  echo '  --debias-convergence'
  echo '  --debias-histmatch'
  echo '  --denoise-model'
  echo '  --denoise-shrink'
  echo '  --denoise-patch'
  echo '  --denoise-radius'
  echo '  --rescale-lo-pct'
  echo '  --rescale-hi-pct'
  echo '  --rescale-lo-val'
  echo '  --rescale-hi-val'
  echo '  --stretch-lo'
  echo '  --stretch-hi'
  echo '  --aniso-conductance'
  echo '  --aniso-iter'
  echo '  --dog_g1'
  echo '  --dog_k'
  echo '  --altitude'
  echo '  --datum'
  echo '  --no-merge'
  echo ''
  echo 'Procedure: '
  echo '(1) Additional N4 Debiasing'
  echo '(2) Additional Rician Denoising'
  echo '(3) Threshold, Stretch, Mask, convert to SHORT'
  echo '(4) Anisotropic Smooth'
  echo '(5) Calculate Difference of Gaussians'
  echo '    -default using K=1.6 to approximate the Laplacian of the'
  echo '     Gaussian'
  echo '    -k=5 might be a reasonable value as well which may'
  echo '     approximate retinal ganglion cells'
  echo '    -output zero-crossings'
  echo '(6) Calculate the Signed Distance Transform to the the zero-'
  echo '    crossings'
  echo '(7) Watershed Clustering'
  echo '    -threshold at desired "altitude" to produce non-connected'
  echo '     clusters, default is >= 2 voxels from DoG zero-crossing'
  echo '    -generate clusters with 6-neighbor connectivity'
  echo '    -flood fill up to "datum", default is 1 voxel from zero-'
  echo '     crossing'
  echo '    -add smaller peaks that do not reach initial separating'
  echo '     altitude'
  echo '(8) Merge clusters, touching neighbors with significantly'
  echo '    overlapping intensity probability distribution functions'
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

# Locate Inputs ----------------------------------------------------------------
if [[ -z ${IMAGE} ]]; then
  if [[ -z ${DIR_XINIT} ]]; then
    DIR_XINIT="${DIR_PROJECT}/derivatives/tkni/xinit/base"
  fi
  IMAGE=($(ls ${DIR_XINIT}/${IDPFX}*swi.nii.gz))
else
  IMAGE=(${IMAGE//,/ })
fi
NIMG=${#IMAGE[@]}

if [[ -z ${MASK} ]]; then
  if [[ -z ${DIR_XINIT} ]]; then
    DIR_XINIT="${DIR_PROJECT}/derivatives/tkni/xinit/base"
  fi
  for (( i=0; i<${NIMG}; i++ )); do
    TPFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
    MASK+=("${DIR_PROJECT}/derivatives/tkni/xinit/base/${TPFX}_mask-brain.nii.gz")
  done
else
  MASK=(${MASK//,/ })
fi
for (( i=0; i<${NIMG}; i++ )); do
  if [[! -f ${MASK[${i}]} ]]; then
    echo "ERROR [${PIPE}:${FLOW}] Brain Mask Specified Input file not found"
    echo -e "\t${MASK[${i}]}"
    exit 2
  fi
done

mkdir -p ${DIR_SCRATCH}

# Initialize RMD output --------------------------------------------------------
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

  echo '## *Ex-vivo* Anatomical Segmentation' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}
fi

## Start loop over images ======================================================
for (( i=0; i<${NIMG}; i++ )); do
  PFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
  IMG=${DIR_SCRATCH}/${PFX}_swi.nii.gz
  MSK=${DIR_SCRATCH}/${PFX}_mask-brain.nii.gz

  # Copy files to scratch ------------------------------------------------------
  cp ${IMAGE[${i}]} ${IMG}
  cp ${MASK[${i}]} ${MSK}

  # (1) Debias -----------------------------------------------------------------
  N4BiasFieldCorrection -d 3 \
    -r ${N4_RESAMPLE} -s ${N4_SHRINK} -c ${N4_CONVERGENCE} -b ${N4_BSPLINE} \
    -i ${IMG} -x ${MSK} -o ${DIRTMP}/temp_image.nii.gz

  # (2) Denoise ----------------------------------------------------------------
  DenoiseImage -d 3 \
    -n ${HI_DN_MODEL} -s ${HI_DN_SHRINK} -p ${HI_DN_PATCH} -r ${HI_DN_RADIUS} \
    -i ${DIRTMP}/temp_image.nii.gz -x ${MSK} -o ${IMG}

  # (3) Threshold, Stretch, Mask, convert to SHORT -----------------------------
  IMLO=${RESCALE_LO_VAL}
  if [[ -n ${IMLO} ]]; then
    IMLO=($(3dBrickStat -mask ${MSK} -slow -perclist 1 ${RESCALE_LO_PCT}))
    IMLO=${IMLO[1]}
  fi
  IMHI=${RESCALE_HI_VAL}
  if [[ -n ${IMHI} ]]; then
    IMHI=($(3dBrickStat -mask ${MSK} -slow -perclist 1 ${RESCALE_HI_PCT}))
    IMHI=${IMHI[1]}
  fi
  c3d ${IMG} -stretch ${IMLO} ${IMHI} 1000 21000 -type short -o ${IMG}
  niimath ${IMG} -mas ${MSK} ${IMG}

  # Copy preprocessed image and brain mask as native anat output ---------------
  mkdir -p ${DIR_SAVE}/native
  mkdir -p ${DIR_SAVE}/mask
  cp ${IMG} ${DIR_SAVE}/native/
  cp ${MSK} ${DIR_SAVE}/mask/

  # (4) Anisotropic Smooth -----------------------------------------------------
  c3d ${IMG} -ad ${SMOOTH_CONDUCTANCE} ${SMOOTH_ITER} -o ${DIR_SCRATCH}/tmp_smooth.nii.gz

  # (5) Calculate Difference of Gaussians --------------------------------------
  if [[ ${DOG_G1} -eq 0 ]]; then
    TSZ=($(niiInfo -i ${IMG} -f space))
    SZ=${TSZ[1]}
    if [[ $(echo "${SZ} > ${TSZ[2]}" | bc) -eq 1 ]]; then SZ=${TSZ[2]}; fi
    if [[ $(echo "${SZ} > ${TSZ[3]}" | bc) -eq 1 ]]; then SZ=${TSZ[3]}; fi
    DOG_G2=$(echo "scale=6; ${SZ} * ${DOG_K}" | bc -l)
  fi
  niimath ${DIR_SCRATCH}/tmp_smooth.nii.gz \
    -dog ${DOG_G1} ${DOG_G2} -mas ${MSK} \
    ${DIR_SCRATCH}/tmp_dog.nii.gz

  # (6) Calculate the Signed Distance Transform --------------------------------
  c3d ${DIR_SCRATCH}/tmp_dog.nii.gz -sdt -o ${DIR_SCRATCH}/tmp_distance.nii.gz

  # Unzip files for processing with nifti.io in R ------------------------------
  gunzip ${DIR_SCRATCH}/tmp_distance.nii.gz
  gunzip ${MSK}

  # (7) Watershed Clustering ---------------------------------------------------
  Rscript ${TKNIPATH}/R/clusterWatershed.R \
    "distance" "${DIR_SCRATCH}/tmp_distance.nii" \
    "mask" "${DIR_SCRATCH}/${PFX}_mask-brain.nii" \
    "connectivity" "${CONNECTIVITY}" \
    "altitude" "${ALTITUDE}" \
    "datum" "${DATUM}" \
    "dir-save" "${DIR_SCRATCH}" \
    "filename" "${PFX}_segmentation.nii"
  mkdir -p ${DIR_SAVE}/label
  cp ${DIR_SCRATCH}/${PFX}_segmentation.nii ${DIR_SAVE}/label/
  gzip ${DIR_SAVE}/label/${PFX}_segmentation.nii

  # (8) Merge clusters, touching neighbors with significantly ------------------
  if [[ ${NO_MERGE} == "false" ]]; then
    Rscript ${TKNIPATH}/R/clusterPDFmerge.R \
      "intensity" ${IMG} \
      "segmentation" "${DIR_SCRATCH}/${PFX}_segmentation.nii" \
      "overlap" "${PDF_OVERLAP}" \
      "dir-save" "${DIR_SCRATCH}" \
      "filename" "${PFX}_segmentation+pdfmerge.nii"
    mkdir -p ${DIR_SAVE}/label
    cp ${DIR_SCRATCH}/${PFX}_segmentation+pdfmerge.nii ${DIR_SAVE}/label/
    gzip ${DIR_SAVE}/label/${PFX}_segmentation+pdfmerge.nii
  fi

  # generate HTML QC report ------------------------------------------------------
  if [[ "${NO_RMD}" == "false" ]]; then
    BIMG=${DIR_SAVE}/native/${PFX}_swi.nii.gz
    DIM=($(niiInfo -i ${BIMG} -f "voxels"))
    if [[ ${DIM[0]} -lt ${DIM[1]} ]] && [[ ${DIM[0]} -lt ${DIM[2]} ]]; then PLANE="x"; fi
    if [[ ${DIM[1]} -lt ${DIM[0]} ]] && [[ ${DIM[1]} -lt ${DIM[2]} ]]; then PLANE="y"; fi
    if [[ ${DIM[2]} -lt ${DIM[0]} ]] && [[ ${DIM[2]} -lt ${DIM[1]} ]]; then PLANE="z"; fi
    if [[ -z ${PLANE} ]]; then PLANE="z"; fi
    LAYOUT="9:${PLANE};9:${PLANE};9:${PLANE}"

    echo '### *${PFX}_swi.nii.gz*' >> ${RMD}
    echo '#### Cleaned Native Anatomical Image' >> ${RMD}
    BNAME=$(basename ${BIMG})
    FNAME=${BIMG//\.nii\.gz}
    make3Dpng --bg ${BIMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}"
    echo -e '!['${BNAME}']('${FNAME}'.png)\n' >> ${RMD}

    echo '#### Watershed Segmentation' >> ${RMD}
    TIMG=${DIR_SAVE}/label/${PFX}_segmentation.nii.gz
    BNAME=$(basename ${TIMG})
    FNAME=${TIMG//\.nii\.gz}
    make3Dpng --bg ${BIMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}" \
      --fg ${TIMG} --fg-color "timbow:random" --fg-cbar "false" --fg-alpha 50 \
      --dir.save ${DIR_SAVE}/label --filename ${FNAME}
    echo -e '!['${BNAME}']('${FNAME}'.png)\n' >> ${RMD}

    if [[ ${NO_MERGE} == "false" ]]; then
      echo '#### PDF Merged Segementation' >> ${RMD}
      TIMG=${DIR_SAVE}/label/${PFX}_segmentation+pdfmerge.nii.gz
      BNAME=$(basename ${TIMG})
      FNAME=${TIMG//\.nii\.gz}
      make3Dpng --bg ${BIMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}" \
        --fg ${TIMG} --fg-color "timbow:random" --fg-cbar "false" --fg-alpha 50 \
        --dir.save ${DIR_SAVE}/label --filename ${FNAME}
      echo -e '!['${BNAME}']('${FNAME}'.png)\n' >> ${RMD}
    fi
  fi
done

if [[ "${NO_RMD}" == "false" ]]; then
  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
