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
cp ${IMG} ${DIR_PREP}/${IDPFX}_prep-reorient_${BASE_MOD}.nii.gz
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Reoriented to RPI"; fi

# Denoise image ----------------------------------------------------------------
ricianDenoise --image ${IMG} --dir-save ${DIR_SCRATCH}
mv ${DIR_SCRATCH}/${IDPFX}_prep-denoise_${BASE_MOD}.nii.gz ${IMG}
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Rician denoised"; fi

# Get Foreground mask ----------------------------------------------------------
brainExtraction --image ${IMG} \
  --method "automask" --automask-clip ${FG_CLIP} \
  --label "fg" --dir-save ${DIR_SCRATCH}
MASK_FG=${DIR_SCRATCH}/${IDPFX}_mask-fg+AUTO.nii.gz
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> FG mask generated"; fi

# Non-uniformity Correction ----------------------------------------------------
inuCorrection --image ${IMG} --method N4 --mask ${MASK_FG} --dir-save ${DIR_SCRATCH} --keep
mv ${DIR_SCRATCH}/${IDPFX}_prep-biasN4_${BASE_MOD}.nii.gz ${IMG}
rm ${DIR_SCRATCH}/${IDPFX}_mod-${BASE_MOD}_prep-biasN4_biasField.nii.gz
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Non-uniformity corrected"; fi

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
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Rigid alignment"; fi

# Rescale intensity ------------------------------------------------------------
rescaleIntensity --image ${IMG} --mask ${MASK_FG} --dir-save ${DIR_SCRATCH}
mv ${DIR_SCRATCH}/${IDPFX}_prep-rescale_${BASE_MOD}.nii.gz ${IMG}
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Rescale Intensity"; fi

# Brain extraction -------------------------------------------------------------
#brainExtraction --image ${IMG} \
#  --method "skullstrip,bet,ants,synth" \
#  --ants-template ${ANTS_TEMPLATE} \
#  --dir-save ${DIR_SCRATCH}
brainExtraction --image ${IMG} \
  --method "synth" \
  --ants-template ${ANTS_TEMPLATE} \
  --dir-save ${DIR_SCRATCH}
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Multi-approach brain extraction"; fi

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
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Native space PNGs"; fi

# Calculate QC -----------------------------------------------------------------
## push raw to native space for fair comparisons
niimath ${DIR_PREP}/${IDPFX}_prep-reorient_${BASE_MOD}.nii.gz -add 1 -bin \
  ${DIR_SCRATCH}/${IDPFX}_mask-frame.nii.gz
if [[ -z ${ALIGN_MANUAL} ]]; then
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${DIR_PREP}/${IDPFX}_prep-reorient_${BASE_MOD}.nii.gz \
    -o ${DIR_PREP}/${IDPFX}_prep-raw_${BASE_MOD}.nii.gz \
    -r ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    -t identity -t ${DIR_XFM}/${IDPFX}_mod-T1w_from-raw_to-ACPC_xfm-rigid.mat
  antsApplyTransforms -d 3 -n GenericLabel \
    -i ${DIR_SCRATCH}/${IDPFX}_mask-frame.nii.gz \
    -o ${DIR_PREP}/${IDPFX}_mask-frame.nii.gz \
    -r ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    -t identity -t ${DIR_XFM}/${IDPFX}_mod-T1w_from-raw_to-ACPC_xfm-rigid.mat
else
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${DIR_PREP}/${IDPFX}_prep-reorient_${BASE_MOD}.nii.gz \
    -o ${DIR_PREP}/${IDPFX}_prep-raw_${BASE_MOD}.nii.gz \
    -r ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    -t identity -t ${ALIGN_MANUAL}
  antsApplyTransforms -d 3 -n GenericLabel \
    -i ${DIR_SCRATCH}/${IDPFX}_mask-frame.nii.gz \
    -o ${DIR_PREP}/${IDPFX}_mask-frame.nii.gz \
    -r ${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz \
    -t identity -t ${ALIGN_MANUAL}
fi
IMG_NOPROC=${DIR_PREP}/${IDPFX}_prep-raw_${BASE_MOD}.nii.gz
IMG_NATIVE=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
MASK_FRAME=${DIR_PREP}/${IDPFX}_mask-frame.nii.gz
MASK_FG=${DIR_ANAT}/mask/${FLOW}/${IDPFX}_mask-fg+AUTO.nii.gz
MASK_BRAIN=${DIR_ANAT}/mask/${FLOW}/${IDPFX}_mask-brain+SYNTH.nii.gz

EFC_RAW=($(qc_efc --image ${IMG_NOPROC} --framemask ${MASK_FRAME}))
EFC_NTV=($(qc_efc --image ${IMG_NATIVE} --framemask ${MASK_FRAME}))
FBER_RAW=($(qc_fber --image ${IMG_NOPROC} --mask ${MASK_FG}))
FBER_NTV=($(qc_fber --image ${IMG_NATIVE} --mask ${MASK_FG}))
SNR_RAW_FR=($(qc_snr --image ${IMG_NOPROC} --mask ${MASK_FRAME}))
SNR_RAW_FG=($(qc_snr --image ${IMG_NOPROC} --mask ${MASK_FG}))
SNR_RAW_BR=($(qc_snr --image ${IMG_NOPROC} --mask ${MASK_BRAIN}))
SNR_NTV_FR=($(qc_snr --image ${IMG_NATIVE} --mask ${MASK_FRAME}))
SNR_NTV_FG=($(qc_snr --image ${IMG_NATIVE} --mask ${MASK_FG}))
SNR_NTV_BR=($(qc_snr --image ${IMG_NATIVE} --mask ${MASK_BRAIN}))
SNRD_RAW=($(qc_snrd --image ${IMG_NOPROC} --fg ${MASK_FG}))
SNRD_NTV=($(qc_snrd --image ${IMG_NATIVE} --fg ${MASK_FG}))
D_RAW_FG=($(Rscript ${TKNIPATH}/R/qc_descriptives.R -i ${IMG_NOPROC} -m ${MASK_FG}))
D_RAW_BR=($(Rscript ${TKNIPATH}/R/qc_descriptives.R -i ${IMG_NOPROC} -m ${MASK_BRAIN}))
D_NTV_FG=($(Rscript ${TKNIPATH}/R/qc_descriptives.R -i ${IMG_NATIVE} -m ${MASK_FG}))
D_NTV_BR=($(Rscript ${TKNIPATH}/R/qc_descriptives.R -i ${IMG_NATIVE} -m ${MASK_BRAIN}))
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> QC Metrics"; fi

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
  echo '#### Click to View -->' >> ${RMD}
  echo '#### Step-by-Step' >> ${RMD}
  echo '1. Reorient to RPI  ' >> ${RMD}
  echo '2. Denoise Image  ' >> ${RMD}
  echo '3. Generate Foreground Mask  ' >> ${RMD}
  echo '4. Non-Uniformity Correction  ' >> ${RMD}
  echo '5. Rigid Alignment, Base Image to Template  ' >> ${RMD}
  echo '  - Apply to Foreground Mask  ' >> ${RMD}
  echo '  - Alternatively Use Manual Rigid/Affine Transformation  ' >> ${RMD}
  echo '6. Rescale Intensity  ' >> ${RMD}
  echo '7. Multi-Approach Brain Extraction  ' >> ${RMD}
  echo '  - AFNI skullstrip, ANTs Brain Extraction, FSL BET, SAMSEG  ' >> ${RMD}
  echo '8. Save Results  ' >> ${RMD}
  echo '  - Native Space, Clean, Base Image  ' >> ${RMD}
  echo '  - Foreground Mask  ' >> ${RMD}
  echo '  - Brain Masks  ' >> ${RMD}
  echo '  - Rigid Alignment Transform  ' >> ${RMD}
  echo '9. Generate PNGs, QC Metrics, and HTML Report  ' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Procedure' >> ${RMD}
  echo 'The base anatomical image, '${BASE_MOD}' was processed using a robust, standaradized protocol that utilizes multiple neuroimaging software packages including AFNI [1,2], Advanced Normalization Tools (ANTs) [3,4], FreeSurfer [5], and FSL [6] (note that FSL is not used in commercial applications due to license encumberance). In addition, we utilize a variety of helper-functions, wrappers, pipelines and workflows available in our TKNI package [7]. First, images are conformed to standard RPI orientation. Second, images are denoised using a non-local, spatially adaptive procedure [8] implemented in ANTs. Third, we generate a binary foreground mask using an automated clipping procedure based on image intensity implemented in AFNI (3dAutomask). This foreground mask asists in constraining the region for subsequent steps to a reasonable representation of the individuals head and provides an initial focal region for subsequent alignment. Fourth, MRI images often contain low frequency intensity nonuniformity, or bias. We use the N4 algorithm [9] implemented in ANTs which essentially fits low frequency intensity variations with a B--spline model, which can then be subtracted from the image. Fifth, typically neuroimages are aligned to an arbitrary line connecting the anterior and posterior commissures, ACPC alignment. Identification of these landmarks may require manual intervention and neuroanatomical expertise. Instead of ACPC alignment, we leverage modern advancements in image registration and perform a rigid body alignment to a common space template using ANTs. This has the advantage of eliminating manual intervention and rigid transformations do not distort native brain shape or size. For cases where rigid alignment fail, while rare, manual ACPC alignment is substituted. Six, some of the preceding steps include interpolation of the image data and may be rescaled by the software packages. To eliminate this as a factor all images are rescaled such that values range from 0 to 10000 and are stored as signed 16-bit integers. Seven, segmentation of brain from non-brain tissue is critical for neuro-analysis. Unfortunately, all brain segmentation tools fail under certain circumstances and cases. Fortunately, different brain segmentation tools tend to fail in distinct ways. Hence, we leverage these distinct errors in brain segmentation using a joint label fusion technique [10] in order to cancel out non-shared errors across brain segmentation tools [1,3,11,12]. (Note: We are currently evaluating emerging machine learning methods that may supplant this method). Next, we use custom softwar to generate PNG images to represent our results using itk-SNAP c3d [13] and ImageMagick [14]. Lastly, we calculate image quality metrics based on MRIQC but implemented independently using neuroimaging software tools and niimath [15] for voxelwise operations.' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Citations' >> ${RMD}
  echo '[1] Cox RW. AFNI: software for analysis and visualization of functional magnetic resonance neuroimages. Comput Biomed Res. 1996;29: 162–173. Available: https://www.ncbi.nlm.nih.gov/pubmed/8812068  ' >> ${RMD}
  echo '[2] Cox RW, Hyde JS. Software tools for analysis and visualization of fMRI data. NMR Biomed. 1997;10: 171–178. doi:10.1002/(sici)1099-1492(199706/08)10:4/5&#60;171::aid-nbm453&#62;3.0.co;2-l  ' >> ${RMD}
  echo '[3] Tustison NJ, Cook PA, Holbrook AJ, Johnson HJ, Muschelli J, Devenyi GA, et al. The ANTsX ecosystem for quantitative biological and medical imaging. Sci Rep. 2021;11: 9068. doi:10.1038/s41598-021-87564-6  ' >> ${RMD}
  echo '[4] Tustison NJ, Yassa MA, Rizvi B, Cook PA, Holbrook AJ, Sathishkumar MT, et al. ANTsX neuroimaging-derived structural phenotypes of UK Biobank. Sci Rep. 2024;14: 8848. doi:10.1038/s41598-024-59440-6  ' >> ${RMD}
  echo '[5] Fischl B. FreeSurfer. Neuroimage. 2012;62: 774–781. doi:10.1016/j.neuroimage.2012.01.021  ' >> ${RMD}
  echo '[6] Smith SM, Jenkinson M, Woolrich MW, Beckmann CF, Behrens TEJ, Johansen-Berg H, et al. Advances in functional and structural MR image analysis and implementation as FSL. Neuroimage. 2004;23 Suppl 1: S208-19. doi:10.1016/j.neuroimage.2004.07.051  ' >> ${RMD}
  echo '[7] Koscik, TR. TKNI [Computer Software]. 2024. www.github.com/tkoscik/tkni.  ' >> ${RMD}
  echo '[8] Manjón JV, Coupé P, Martí-Bonmatí L, Collins DL, Robles M. Adaptive non-local means denoising of MR images with spatially varying noise levels. J Magn Reson Imaging. 2010;31: 192–203. doi:10.1002/jmri.22003  ' >> ${RMD}
  echo '[9] Tustison NJ, Avants BB, Cook PA, Zheng Y, Egan A, Yushkevich PA, et al. N4ITK: improved N3 bias correction. IEEE Trans Med Imaging. 2010;29: 1310–1320. doi:10.1109/TMI.2010.2046908  ' >> ${RMD}
  echo '[10] Wang H, Suh JW, Das SR, Pluta JB, Craige C, Yushkevich PA. Multi-Atlas Segmentation with Joint Label Fusion. IEEE Trans Pattern Anal Mach Intell. 2013;35: 611–623. doi:10.1109/TPAMI.2012.143  ' >> ${RMD}
  echo '[11] Smith SM. Fast robust automated brain extraction. Hum Brain Mapp. 2002;17: 143–155. doi:10.1002/hbm.10062  ' >> ${RMD}
  echo '[12] Puonti O, Iglesias JE, Van Leemput K. Fast and sequence-adaptive whole-brain segmentation using parametric Bayesian modeling. Neuroimage. 2016;143: 235–249. doi:10.1016/j.neuroimage.2016.09.011  ' >> ${RMD}
  echo '[13] Yushkevich PA, Piven J, Hazlett HC, Smith RG, Ho S, Gee JC, et al. User-guided 3D active contour segmentation of anatomical structures: significantly improved efficiency and reliability. Neuroimage. 2006;31: 1116–1128. doi:10.1016/j.neuroimage.2006.01.015  ' >> ${RMD}
  echo '[14] Mastering digital image alchemy. In: ImageMagick [Internet]. [cited 14 Feb 2025]. Available: https://imagemagick.org  ' >> ${RMD}
  echo '[15] Rorden C, Webster M, Drake C, Jenkinson M, Clayden JD, Li N, et al. Niimath and fslmaths: Replication as a method to enhance popular neuroimaging tools. Apert Neuro. 2024;4. doi:10.52294/001c.94384  ' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Cleaned' >> ${RMD}
  TNII=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
  TPNG=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII}; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Raw' >> ${RMD}
  BNAME=$(basename ${IMG_RAW})
  FNAME=${IMG_RAW//\.nii\.gz}
  if [[ ! -f "${FNAME}.png" ]]; then make3Dpng --bg ${IMG_RAW}; fi
  echo '!['${BNAME}']('${FNAME}'.png)' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Check Brain Extraction Quality' >> ${RMD}
  MASKPREF=("MALF" "SYNTH" "ANTs" "SAMSEG" "AFNI" "FSL")
  for (( i=0; i<${#MASKPREF[@]}; i++ )); do
    FCHK=${DIR_ANAT}/mask/${FLOW}/${IDPFX}_mask-brain+${MASKPREF[${i}]}.nii.gz
    if [[ -f "${FCHK}" ]]; then break; fi
  done
  TNII=${IDPFX}_mask-brain+${MASKPREF[${i}]}.nii.gz
  TPNG=${DIR_PREP}/${IDPFX}_mask-brain+${MASKPREF[${i}]}.png
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '### QC Statistics' >> ${RMD}
  echo '|Image|EFC|FBER|SNR (frame)|SNR (FG)|SNR (brain)|SNR Dietrich|' >> ${RMD}
  echo '|:----|----:|----:|----:|----:|----:|----:|' >> ${RMD}
  echo "|RAW|${EFC_RAW}|${FBER_RAW}|${SNR_RAW_FR}|${SNR_RAW_FG}|${SNR_RAW_BR}|${SNRD_RAW}|" >> ${RMD}
  echo "|CLEAN|${EFC_NTV}|${FBER_NTV}|${SNR_NTV_FR}|${SNR_NTV_FG}|${SNR_NTV_BR}|${SNRD_NTV}|" >> ${RMD}
  echo '' >> ${RMD}
  echo '|Image|ROI|Mean|SD|Median|MAD|Skew|Kurtosis|Q-5%|Q-95%|' >> ${RMD}
  echo '|:----|----:|----:|----:|----:|----:|----:|----:|----:|' >> ${RMD}
  echo "|RAW|FG|${D_RAW_FG[0]}|${D_RAW_FG[1]}|${D_RAW_FG[2]}|${D_RAW_FG[3]}|${D_RAW_FG[4]}|${D_RAW_FG[5]}|${D_RAW_FG[6]}|${D_RAW_FG[7]}|" >> ${RMD}
  echo "|RAW|Brain|${D_RAW_BR[0]}|${D_RAW_BR[1]}|${D_RAW_BR[2]}|${D_RAW_BR[3]}|${D_RAW_BR[4]}|${D_RAW_BR[5]}|${D_RAW_BR[6]}|${D_RAW_BR[7]}|" >> ${RMD}
  echo "|CLEAN|FG|${D_NTV_FG[0]}|${D_NTV_FG[1]}|${D_NTV_FG[2]}|${D_NTV_FG[3]}|${D_NTV_FG[4]}|${D_NTV_FG[5]}|${D_NTV_FG[6]}|${D_NTV_FG[7]}|" >> ${RMD}
  echo "|CLEAN|Brain|${D_NTV_BR[0]}|${D_NTV_BR[1]}|${D_NTV_BR[2]}|${D_NTV_BR[3]}|${D_NTV_BR[4]}|${D_NTV_BR[5]}|${D_NTV_BR[6]}|${D_NTV_BR[7]}|" >> ${RMD}
   echo '' >> ${RMD}

  echo '#### QC Descriptions and Citations {.tabset}' >> ${RMD}
  echo '##### Click to View -->' >> ${RMD}
  echo '##### EFC' >> ${RMD}
  echo 'Effective Focus Criterion  ' >> ${RMD}
  echo 'The EFC uses the Shannon entropy of voxel intensities as an indication of ghosting and blurring induced by head motion. Lower values are better. The original equation is normalized by the maximum entropy, so that the EFC can be compared across images with different dimensions.  ' >> ${RMD}
  echo -e '\tAtkinson, et al. 1997. http://dx.doi.org/10.1109/42.650886  ' >> ${RMD}
  echo '' >> ${RMD}

  echo '##### FBER' >> ${RMD}
  echo 'Foreground / Background Energy Ratio (FBER):  ' >> ${RMD}
  echo 'The mean energy of image values within the head relative to outside the head. Higher values are better, and an FBER=-1.0 indicates that there is no signal outside the head mask (e.g., a skull-stripped dataset).  ' >> ${RMD}
  echo -e '\tShehzad Z. 2015. http://dx.doi.org/10.3389/conf.fnins.2015.91.00047  ' >> ${RMD}
  echo '' >> ${RMD}

  echo '##### SNR' >> ${RMD}
  echo 'Signal-to-Noise Ratio:  ' >> ${RMD}
  echo 'The ratio of signal to noise calculated within a masked region.  ' >> ${RMD}
  echo '' >> ${RMD}

  echo '##### SNR Dietrich' >> ${RMD}
  echo 'Dietrich Signal-to-Noise Ratio:  ' >> ${RMD}
  echo 'The ratio of signal to noise calculated within a masked region. Uses the air background as a reference. Will return -1 if the background has been masked out and is all zero' >> ${RMD}
  echo -e '\tDietrich, et al. 2007. http://dx.doi.org/10.1002/jmri.20969' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Additional Cleaned Slice Images {.tabset}' >> ${RMD}
  echo '#### Click to View -->' >> ${RMD}
  TNII=${DIR_ANAT}/native/${IDPFX}_${BASE_MOD}.nii.gz
  if [[ -f "${DIR_ANAT}/native/${IDPFX}_slice-axial_${BASE_MOD}.png" ]]; then
    echo '#### Axial' >> ${RMD}
    TPNG=${DIR_ANAT}/native/${IDPFX}_slice-axial_${BASE_MOD}.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi
  if [[ -f "${DIR_ANAT}/native/${IDPFX}_slice-coronal_${BASE_MOD}.png" ]]; then
    echo '#### Coronal' >> ${RMD}
    TPNG=${DIR_ANAT}/native/${IDPFX}_slice-coronal_${BASE_MOD}.png
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi
  if [[ -f "${DIR_ANAT}/native/${IDPFX}_slice-sagittal_${BASE_MOD}.png" ]]; then
    echo '#### Sagittal' >> ${RMD}
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
