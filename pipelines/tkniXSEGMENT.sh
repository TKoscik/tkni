#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkniXSEGMENT
# WORKFLOW:      UHR Ex-Vivo Secondary Processing and Segmentation
# DESCRIPTION:   Re-cleaning UHR images using manual brain mask, additional
#                processing and intermediates for segmentation, Laplacian of the
#                Gaussian-based Watershed segmentation and refinement.
# PROCESS:       1) Anisotropic Smooth
#                2) Calculate Difference of Gaussians
#                   -default using K=1.6 to approximate the Laplacian of the
#                    Gaussian
#                   -k=5 might be a reasonable value as well which may
#                    approximate retinal ganglion cells
#                   -output zero-crossings
#                3) Calculate the Signed Distance Transform to the the zero-
#                   crossings
#                4) Watershed Clustering
#                   -threshold at desired "altitude" to produce non-connected
#                    clusters, default is >= 2 voxels from DoG zero-crossing
#                   -generate clusters with 6-neighbor connectivity
#                   -flood fill up to "datum", default is 1 voxel from zero-
#                    crossing
#                   -add smaller peaks that do not reach initial separating
#                    altitude
#                5) Merge clusters, touching neighbors with significantly
#                   overlapping intensity probability distribution functions
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-08-08
# README:
# DATE MODIFIED: 2026-01-14
# CHANGELOG:     [20260114]
#                  -harmonized with updates from XINIT, i.e., additional
#                   preprocessing is no longer needed.
#                  -updated with newer PDF merge function.
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
OPTS=$(getopt -o hkvnr --long pi:,project:,dir-project:,\
id:,dir-id:,id-field:,\
image:,mask:,\
no-anisosmooth,aniso-conductance:,aniso-iter:,\
dog_g1:,dog_k:,\
datum:,no-merge,merge-threshold:,merge-weights:,\
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
MASK=

NO_SMOOTH="false"
SMOOTH_CONDUCTANCE=0.5
SMOOTH_ITER=20

DOG_G1=0
DOG_K=1.6

DATUM=
NO_MERGE="false"
MERGE_THRESHOLD=1.25
MERGE_WEIGHTS="1,2,1.5,1,1"

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
    -k | --keep) KEEP="true" ; shift ;;
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
    --no-anisosmooth) NO_SMOOTH="true"; shift ;;
    --aniso-conductance) SMOOTH_CONDUCTANCE="$2" ; shift 2 ;;
    --aniso-iter) SMOOTH_ITER="$2" ; shift 2 ;;
    --dog_g1) DOG_G1="$2" ; shift 2 ;;
    --dog_k) DOG_K="$2" ; shift 2 ;;
    --datum) DATUM="$2" ; shift 2 ;;
    --no-merge) NO_MERGE="true" ; shift ;;
    --merge-threshold) MERGE_THRESHOLD="$2" ; shift 2 ;;
    --merge-weights) MERGE_WEIGHTS="$2" ; shift 2 ;;
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
  echo '  --aniso-conductance'
  echo '  --aniso-iter'
  echo '  --dog_g1'
  echo '  --dog_k'
  echo '  --altitude'
  echo '  --datum'
  echo '  --no-merge'
  echo ''
  echo 'Procedure: '
  echo '(1) Anisotropic Smooth'
  echo '(2) Calculate Difference of Gaussians'
  echo '    -default using K=1.6 to approximate the Laplacian of the'
  echo '     Gaussian'
  echo '    -k=5 might be a reasonable value as well which may'
  echo '     approximate retinal ganglion cells'
  echo '    -output zero-crossings'
  echo '(3) Calculate the Signed Distance Transform to the the zero-'
  echo '    crossings'
  echo '(4) Watershed Clustering'
  echo '    -threshold at desired "altitude" to produce non-connected'
  echo '     clusters, default is >= 2 voxels from DoG zero-crossing'
  echo '    -generate clusters with 6-neighbor connectivity'
  echo '    -flood fill up to "datum", default is 1 voxel from zero-'
  echo '     crossing'
  echo '    -add smaller peaks that do not reach initial separating'
  echo '     altitude'
  echo '(5) Merge clusters, touching neighbors with significantly'
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
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/xsegment
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> Saving to: ${DIR_SAVE}"
fi

# Locate Inputs ----------------------------------------------------------------
if [[ -z ${IMAGE} ]]; then
  IMAGE=($(ls ${DIR_PROJECT}/derivatives/${PIPE}/anat/native/${IDPFX}*swi.nii.gz))
else
  IMAGE=(${IMAGE//,/ })
fi
NIMG=${#IMAGE[@]}

if [[ -z ${MASK} ]]; then
  for (( i=0; i<${NIMG}; i++ )); do
    TPFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
    MASK="${MASK},${DIR_PROJECT}/derivatives/tkni/anat/mask/${TPFX}_mask-brain.nii.gz"
  done
fi
MASK=(${MASK//,/ })

for (( i=0; i<${NIMG}; i++ )); do
  if [[ ! -f ${MASK[${i}]} ]]; then
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
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>processing image $((${i} + 1)) of ${NIMG}"; fi
  PFX=$(getBidsBase -i ${IMAGE[${i}]} -s)
  IMG=${DIR_SCRATCH}/${PFX}_swi.nii.gz
  MSK=${DIR_SCRATCH}/${PFX}_mask-brain.nii.gz

  # Copy files to scratch ------------------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>copying files to scratch"; fi
  cp ${IMAGE[${i}]} ${IMG}
  cp ${MASK[${i}]} ${MSK}

  if [[ "${NO_RMD}" == "false" ]] || [[ "${NO_PNG}" == "false" ]]; then
    DIM=($(niiInfo -i ${IMG} -f "voxels"))
    if [[ ${DIM[0]} -lt ${DIM[1]} ]] && [[ ${DIM[0]} -lt ${DIM[2]} ]]; then PLANE="x"; fi
    if [[ ${DIM[1]} -lt ${DIM[0]} ]] && [[ ${DIM[1]} -lt ${DIM[2]} ]]; then PLANE="y"; fi
    if [[ ${DIM[2]} -lt ${DIM[0]} ]] && [[ ${DIM[2]} -lt ${DIM[1]} ]]; then PLANE="z"; fi
    if [[ -z ${PLANE} ]]; then PLANE="z"; fi
    LAYOUT="9:${PLANE};9:${PLANE};9:${PLANE}"
    make3Dpng --bg ${IMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}"
  fi

  # (1) Anisotropic Smooth -----------------------------------------------------
  if [[ ${NO_SMOOTH} == "false" ]]; then
    if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>anisotropic smoothing"; fi
    c3d ${IMG} \
      -ad ${SMOOTH_CONDUCTANCE} ${SMOOTH_ITER} \
      -o ${DIR_SCRATCH}/${PFX}_anisoSmooth.nii.gz
    if [[ "${NO_RMD}" == "false" ]] || [[ "${NO_PNG}" == "false" ]]; then
      make3Dpng --bg ${DIR_SCRATCH}/${PFX}_anisoSmooth.nii.gz --layout "${LAYOUT}"
    fi
  fi

  # (2) Calculate Difference of Gaussians --------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>calculating difference of gaussians"; fi
  if [[ ${DOG_G1} -eq 0 ]]; then
    TSZ=($(niiInfo -i ${IMG} -f space))
    SZ=${TSZ[0]}
    if [[ $(echo "${SZ} > ${TSZ[1]}" | bc) -eq 1 ]]; then SZ=${TSZ[1]}; fi
    if [[ $(echo "${SZ} > ${TSZ[2]}" | bc) -eq 1 ]]; then SZ=${TSZ[2]}; fi
    DOG_G2=$(echo "scale=6; ${SZ} * ${DOG_K}" | bc -l)
  fi
  niimath ${DIR_SCRATCH}/${PFX}_anisoSmooth.nii.gz \
    -dog ${DOG_G1} ${DOG_G2} -mas ${MSK} \
    ${DIR_SCRATCH}/${PFX}_diffGauss.nii.gz
  if [[ "${NO_RMD}" == "false" ]] || [[ "${NO_PNG}" == "false" ]]; then
    make3Dpng --bg ${DIR_SCRATCH}/${PFX}_diffGauss.nii.gz --layout "${LAYOUT}"
  fi

  # (3) Calculate the Signed Distance Transform --------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>calculating signed distance transform"; fi
  c3d ${DIR_SCRATCH}/${PFX}_diffGauss.nii.gz -sdt \
    -o ${DIR_SCRATCH}/${PFX}_distance.nii.gz
  if [[ "${NO_RMD}" == "false" ]] || [[ "${NO_PNG}" == "false" ]]; then
    make3Dpng --bg ${DIR_SCRATCH}/${PFX}_distance.nii.gz --bg-mask ${MSK} --layout "${LAYOUT}"
  fi

  # (4) Watershed Clustering ---------------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>watershed clustering"; fi
  watershedFCN="clusterWatershed.py"
  watershedFCN="${watershedFCN} --input ${DIR_SCRATCH}/${PFX}_distance.nii.gz"
  watershedFCN="${watershedFCN} --mask ${MSK}"
  watershedFCN="${watershedFCN} --output ${DIR_SCRATCH}/${PFX}_label-watershed.nii.gz"
  if [[ -n ${DATUM} ]]; then
    watershedFCN="${watershedFCN} --datum ${DATUM}"
  fi
  echo ${watershedFCN}
  eval ${watershedFCN}
  if [[ "${NO_RMD}" == "false" ]] || [[ "${NO_PNG}" == "false" ]]; then
    make3Dpng --bg ${IMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}" \
      --fg ${DIR_SCRATCH}/${PFX}_label-watershed.nii.gz \
      --fg-mask ${MSK} --fg-color "timbow" --fg-cbar "false" --fg-alpha 50 \
      --dir-save ${DIR_SCRATCH} --filename ${PFX}_label-watershed
  fi

  # (5) Merge clusters ---------------------------------------------------------
  ## using a regional adjacency graph based approach with hierarchical merging
  ## with weighted centrality moments as cluster merging criteria
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>>merging based on PDF overlap"; fi
  clusterMerge.py --image ${IMG} --mask ${MSK} \
    --label ${DIR_SCRATCH}/${PFX}_label-watershed.nii.gz \
    --output ${DIR_SCRATCH}/${PFX}_label-watershedMerged.nii.gz \
    --threshold ${MERGE_THRESHOLD} \
    --weights ${MERGE_WEIGHTS//,/ }
  if [[ "${NO_RMD}" == "false" ]] || [[ "${NO_PNG}" == "false" ]]; then
    make3Dpng --bg ${IMG} --bg-threshold "2.5,97.5" --layout "${LAYOUT}" \
      --fg ${DIR_SCRATCH}/${PFX}_label-watershedMerged.nii.gz \
      --fg-mask ${MSK} --fg-color "timbow" --fg-cbar "false" --fg-alpha 50 \
      --dir-save ${DIR_SCRATCH} --filename ${PFX}_label-watershedMerged
  fi

  # generate HTML QC report ------------------------------------------------------
  if [[ "${NO_RMD}" == "false" ]]; then
    echo "### *${PFX}_swi.nii.gz*" >> ${RMD}
    echo '#### Cleaned Native Anatomical Image' >> ${RMD}
    BNAME=$(basename ${IMG})
    FNAME=${IMG//\.nii\.gz}
    echo -e '!['${BNAME}']('${FNAME}'.png)\n' >> ${RMD}
    echo '#### Watershed Segmentation' >> ${RMD}
    echo -e "![Watershed Clusters](${DIR_SCRATCH}/${PFX}_label-watershed.png)\n" >> ${RMD}
    if [[ ${NO_MERGE} == "false" ]]; then
      echo '#### Merged Segmentation' >> ${RMD}
      echo -e "![Merged Clusters](${DIR_SCRATCH}/${PFX}_label-watershedMerged.png)\n" >> ${RMD}
    fi
    echo '#### Processing Steps {.tabset}' >> ${RMD}
    echo '##### Click to View ->' >> ${RMD}
    if [[ ${NO_SMOOTH} == "false" ]]; then
      echo '##### Anisotropic Smoothing' >> ${RMD}
      echo -e "![Anisotropic Smoothed](${DIR_SCRATCH}/${PFX}_anisoSmooth.png)\n" >> ${RMD}
    fi
    echo '##### Difference of Gaussians' >> ${RMD}
    echo -e "![Difference of Gaussians](${DIR_SCRATCH}/${PFX}_diffGauss.png)\n" >> ${RMD}
    echo '##### Signed Distance Transform' >> ${RMD}
    echo -e "![Distance Transform](${DIR_SCRATCH}/${PFX}_distance.png)\n" >> ${RMD}
  fi
  echo ">>>>> DONE PROCESSING: ${PFX}_swi.nii.gz"
done

echo ">>>>> DONE Processing, knitting RMD"
## knit RMD
if [[ "${NO_RMD}" == "false" ]]; then
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
fi

# Save output ------------------------------------------------------------------
echo ">>>>> EXPORTING Results"
mkdir -p ${DIR_SAVE}
if [[ ${KEEP} == "true" ]]; then
  echo ">>>>> EXPORTING Intermediates"
  mv ${DIR_SCRATCH}/*_anisoSmooth.* ${DIR_SAVE}/
  mv ${DIR_SCRATCH}/*_diffGauss.* ${DIR_SAVE}/
  mv ${DIR_SCRATCH}/*_distance.* ${DIR_SAVE}/
fi
echo ">>>>>> EXPORTING labels"
mv ${DIR_SCRATCH}/*_label-watershed.* ${DIR_SAVE}/
mv ${DIR_SCRATCH}/*_label-watershedMerged.* ${DIR_SAVE}/

# set status file --------------------------------------------------------------
echo ">>>>>> UPDATING Processing Status"
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
echo -e ">>>>>> EXITING\n\n\n"
exit 0
