#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      AINIT
# DESCRIPTION:   TKNI initial anatomical processing pipeline
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-01-31
# README:
#     Procedure:
#     (1) Reorient to RPI
#     (2) Denoise
#     (3) Rigid alignment to template, pseudo ACPC alignment
#     (4) preliminary run through FreeSurfer's recon-all-clinical
#         -extract synthT1w, preliminary brain mask, and brain surface model
#         -surface model sufficient for printing for participants
#     (5) Non-uniformity Correction
#     (6) Multi-tool brain extraction
#         -result is Venn, MajorityVote, Intersection, and Union masks from:
#           -AFNI 3dSkullStrip; antsBrainExtraction; FSL bet; FreeSurfer samseg
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
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,\
id:,dir-id:,base-img:,base-mod:,\
align-manual:,align-to:,\
fg-clip:,ants-template:,\
dir-scratch:,requires:,\
help,verbose,force -n 'parse-options' -- "$@")
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
BASE_IMG=
BASE_MOD="T1w"
ALIGN_MANUAL=
ALIGN_TO=${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz
FG_CLIP=0.5
ANTS_TEMPLATE="OASIS"
HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES="tkniDICOM"
FORCE=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --base-img) BASE_IMG="$2" ; shift 2 ;;
    --base-mod) BASE_MOD="$2" ; shift 2 ;;
    --align-manual) ALIGN_MANUAL="$2" ; shift 2 ;;
    --align-to) ALIGN_TO="$2" ; shift 2 ;;
    --fg-clip) FG_CLIP="$2" ; shift 2 ;;
    --ants-template) ANTS_TEMPLATE="$2" ; shift 2 ;;
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
  echo '  --base-img         image to process as the subject/session base image'
  echo '  --base-mod         modality, e.g., T1w (default), of base image'
  echo '  --align-manual     if automated ACPC alignment does not work, an'
  echo '                     rigid transform can be applied from a manual or'
  echo '                     other transform instead'
  echo '  --align-to         reference image to align to'
  echo '                     default=${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz'
  echo '  --fg-clip          set the clip fraction for AFNIs automask that is'
  echo '                     used to generate a foreground mask.'
  echo '                       default=0.5'
  echo '  --ants-template    which ants brain extraction template to use, this'
  echo '                     has been set up with a different (BIDS-esque)'
  echo '                     naming convention relative to the default'
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
if [[ -f ${FCHK} ]] || [[ -f ${FDONE} ]]; then
  echo -e "${IDPFX}\n\tWARNING [${PIPE}:${FLOW}] already run"
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

# set directories --------------------------------------------------------------
DIR_RAW=${DIR_PROJECT}/rawdata/${IDDIR}/anat
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
DIR_ANAT=${DIR_PIPE}/anat
DIR_PREP=${DIR_PIPE}/prep/${IDDIR}/${FLOW}
DIR_XFM=${DIR_PIPE}/xfm/${IDDIR}

mkdir -p ${DIR_PREP}
mkdir -p ${DIR_SCRATCH}

# Check for base image ---------------------------------------------------------
if [[ -z ${BASE_IMG} ]]; then
  TLS=($(ls ${DIR_RAW}/${IDPFX}*${BASE_MOD}.nii.gz))
  IMG_RAW=${TLS[0]}
else
  IMG_RAW=${BASE_IMG}
fi
if [[ -z ${IMG_RAW} ]] || [[ ! -f ${IMG_RAW} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] base ${MOD} not found"
  exit 1
fi
IMG=${DIR_SCRATCH}/${IDPFX}_${BASE_MOD}.nii.gz
cp ${IMG_RAW} ${IMG}

# Rorient to RPI ---------------------------------------------------------------
reorientRPI --image ${IMG} --dir-save ${DIR_SCRATCH}
mv ${DIR_SCRATCH}/${IDPFX}_prep-reorient_${BASE_MOD}.nii.gz ${IMG}

# Denoise image ----------------------------------------------------------------
ricianDenoise --image ${IMG} --dir-save ${DIR_SCRATCH}
mv ${DIR_SCRATCH}/${IDPFX}_prep-denoise_${BASE_MOD}.nii.gz ${IMG}

# Get Foreground mask ----------------------------------------------------------
brainExtraction --image ${IMG} \
  --method "automask" --automask-clip ${FG_CLIP} \
  --label "fg" --dir-save ${DIR_SCRATCH}
MASK_FG=${DIR_SCRATCH}/${IDPFX}_mask-fg+AUTO.nii.gz

# Non-uniformity Correction ----------------------------------------------------
inuCorrection --image ${IMG} --method N4 --mask ${MASK_FG} --dir-save ${DIR_SCRATCH} --keep
mv ${DIR_SCRATCH}/${IDPFX}_prep-biasN4_${BASE_MOD}.nii.gz ${IMG}
rm ${DIR_SCRATCH}/${IDPFX}_mod-${BASE_MOD}_prep-biasN4_biasField.nii.gz

# rigid alignment, base to template --------------------------------------------
if [[ -z ${ALIGN_MANUAL} ]]; then
  SPACE_TRG=$(niiInfo -i ${IMG} -f space)
  SPACE_TRG="${SPACE_TRG// /x}mm"
  coregistrationChef --recipe-name align \
    --fixed ${ALIGN_TO} --space-source ${SPACE_SRC} --space-target ${SPACE_TRG} \
    --moving ${IMG}  --label-from raw --label-to ACPC \
    --dir-save ${DIR_SCRATCH} --dir-xfm ${DIR_SCRATCH}
  antsApplyTransforms --d 3 -n GenericLabel \
    -i ${MASK_FG} -o ${MASK_FG} \
    -r ${DIR_SCRATCH}/${IDPFX}_reg-align+ACPC_${BASE_MOD}.nii.gz \
    -t identity -t ${DIR_SCRATCH}/${IDPFX}_mod-T1w_from-raw_to-ACPC_xfm-rigid.mat
else
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${IMG} \
    -o ${DIR_SCRATCH}/${IDPFX}_reg-align+ACPC_${BASE_MOD}.nii.gz \
    -r ${ALIGN_TO} \
    -t identity -t ${ALIGN_MANUAL}
  antsApplyTransforms --d 3 -n GenericLabel \
    -i ${MASK_FG} -o ${MASK_FG} -r ${ALIGN_TO} \
    -t identity -t ${ALIGN_MANUAL}
  make3Dpng --bg ${DIR_SCRATCH}/${IDPFX}_reg-align+ACPC_${BASE_MOD}.nii.gz \
    --bg-threshold "2.5,97.5" \
    --dir-save ${DIR_PREP}
  make3Dpng \
    --bg ${ALIGN_TO} \
      --bg-color "timbow:hue=#00FF00:lum=0,100:cyc=1/6" \
      --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_reg-align+ACPC_${BASE_MOD}.nii.gz \
      --fg-threshold "2.5,97.5" \
      --fg-color "timbow:hue=#FF00FF:lum=0,100:cyc=1/6" \
      --fg-alpha 50 \
      --fg-cbar "false"\
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_from-raw_to-ACPC \
    --dir-save ${DIR_PREP}
fi
mv ${DIR_SCRATCH}/${IDPFX}_reg-align+ACPC_${BASE_MOD}.nii.gz ${IMG}

# Rescale intensity ------------------------------------------------------------
rescaleIntensity --image ${IMG} --mask ${MASK_FG} --dir-save ${DIR_SCRATCH}
mv ${DIR_SCRATCH}/${IDPFX}_prep-rescale_${BASE_MOD}.nii.gz ${IMG}

# Brain extraction -------------------------------------------------------------
brainExtraction --image ${IMG} \
  --method "skullstrip,ants,bet,samseg" \
  --ants-template ${ANTS_TEMPLATE} \
  --dir-save ${DIR_SCRATCH}

# Save results -----------------------------------------------------------------
mkdir -p ${DIR_ANAT}/native
mkdir -p ${DIR_XFM}
mkdir -p ${DIR_ANAT}/mask/${FLOW}
mv ${IMG} ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
mv ${DIR_SCRATCH}/*.png ${DIR_PREP}/
mv ${DIR_SCRATCH}/*.mat ${DIR_XFM}/
mv ${DIR_SCRATCH}/*.nii.gz ${DIR_ANAT}/mask/${FLOW}/

# Make native PNG --------------------------------------------------------------
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
  make3Dpng --bg ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    --bg-threshold "2.5,97.5" --layout "9:x;9:x;9:x" \
    --filename ${IDPFX}_slice-sagittal_${BASE_MOD}
  make3Dpng --bg ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    --bg-threshold "2.5,97.5" --layout "9:y;9:y;9:y" \
    --filename ${IDPFX}_slice-coronal_${BASE_MOD}
  make3Dpng --bg ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    --bg-threshold "2.5,97.5" --layout "9:z;9:z;9:z" \
    --filename ${IDPFX}_slice-axial_${BASE_MOD}
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  mkdir -p ${DIR_PIPE}/qc/${PIPE}${FLOW}
  RMD=${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd

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

  echo '## Initial Anatomical Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Anatomical Processing Results {.tabset}' >> ${RMD}
  echo '#### Cleaned' >> ${RMD}
  TNII=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
  TPNG=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII}; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Raw' >> ${RMD}
  BNAME=$(basename ${IMG_RAW})
  FNAME=${IMG_RAW//\.nii\.gz}
  if [[ ! -f "${FNAME}.png" ]]; then make3Dpng --bg ${IMG_RAW}; fi
  echo '!['${BNAME}']('${FNAME}'.png)' >> ${RMD}
  echo '' >> ${RMD}

  TNII=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
  if [[ -f "${DIR_ANAT}/native/${IDPFX}_slice-axial_${BASE_MOD}.png" ]]; then
    echo '#### Cleaned - Axial' >> ${RMD}
    TPNG=${DIR_ANAT}/native/${IDPFX}_slice-axial_${BASE_MOD}.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi
  if [[ -f "${DIR_ANAT}/native/${IDPFX}_slice-coronal_${BASE_MOD}.png" ]]; then
    echo '#### Cleaned - Coronal' >> ${RMD}
    TPNG=${DIR_ANAT}/native/${IDPFX}_slice-coronal_${BASE_MOD}.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi
  if [[ -f "${DIR_ANAT}/native/${IDPFX}_slice-sagittal_${BASE_MOD}.png" ]]; then
    echo '#### Cleaned - Sagittal' >> ${RMD}
    TPNG=${DIR_ANAT}/native/${IDPFX}_slice-sagittal_${BASE_MOD}.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  echo '### Processing Steps {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### RPI Reorientation' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_prep-reorient_${BASE_MOD}.png
  echo '![RPI Reoriented]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Denoising' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_prep-noise_${BASE_MOD}.png
  echo '![Noise]('${TPNG}')' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_prep-denoise_${BASE_MOD}.png
  echo '![Denoised]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Foreground Mask' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_mask-fg+AUTO.png
  echo '![FG Mask]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### INU Correction' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_mod-${BASE_MOD}_prep-biasN4_biasField.png
  echo '![Bias Field]('${TPNG}')' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_prep-biasN4_${BASE_MOD}.png
  echo '![INU Corrected]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Rigid Alignment (ACPCish)' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_reg-align+ACPC.png
  echo '![Alignment]('${TPNG}')' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_reg-align+ACPC_${BASE_MOD}.png
  echo '![Aligned]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Intensity Rescale' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_prep-rescale_${BASE_MOD}.png
  echo '![Rescaled]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Brain Mask {.tabset}' >> ${RMD}
  PNGLS=($(ls ${DIR_PREP}/*mask-brain*.png))
  for (( i=0; i<${#PNGLS[@]}; i++ )); do
    TPNG=${PNGLS[${i}]}
    MNAME=$(getField -i ${TPNG} -f mask)
    MNAME=(${MNAME//\+/ })
    echo '##### '${MNAME[1]} >> ${RMD}
    echo '!['${MNAME[1]}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  done

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
