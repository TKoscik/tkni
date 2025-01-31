#!/bin/bash -e
#===============================================================================
# Run Whole-Brain Tractogram and Connectogram
# Required: MRtrix3, ANTs, FSL
# Description:
# Author: Timothy R. Koscik, PhD
# Date Created: 2023-10-31
# Date Modified: 2024-09-11
# CHANGE_LOG: -modified to include output of tkniDCON to include a whole brain
#              connectogram no point in stopping
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
id:,dir-id:,dir-mrtrix:,\
image-dwi:,posterior-5tt:,image-t1-dwi:,image-t1-native:,mask-brain-native:,\
label:,lut-orig:,lut-sort:,\
keep-10mil,no-afd,no-tract,\
dir-scratch:,dir-save:,requires:,force,\
help,verbose -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_SCRATCH=
DIR_MRTRIX=
IDPFX=
IDDIR=

IMAGE_DWI=
POST_5TT=
IMAGE_T1_DWI=
IMAGE_T1_NATIVE=
MASK_BRAIN_NATIVE=

KEEP_10MIL="false"
NO_AFD="false"
NO_TRACT="false"

DIR_SAVE=
LABEL=hcpmmp1+MALF
LUT_ORIG=${TKNIPATH}/lut/hcpmmp1_original.txt
LUT_SORT=${TKNIPATH}/lut/hcpmmp1_ordered_tkni.txt

PIPE=tkni
FLOW=DTRACT
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF,tkniDPREP"
FORCE=false

HELP=false
VERBOSE=false
LOQUACIOUS=false
FORCE=false
NO_PNG=false
NO_RMD=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --force) FORCE=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image-dwi) IMAGE_DWI="$2" ; shift 2 ;;
    --posterior-5tt) POST_5TT="$2" ; shift 2 ;;
    --image-t1-dwi) IMAGE_T1_DWI="$2" ; shift 2 ;;
    --image-t1-native) IMAGE_T1_NATIVE="$2" ; shift 2 ;;
    --mask-brain-native) MASK_BRAIN_NATIVE="$2" ; shift 2 ;;
    --label) LABEL="$2" ; shift 2 ;;
    --lut-orig) LUT_ORIG="$2" ; shift 2 ;;
    --lut-sort) LUT_SORT="$2" ; shift 2 ;;
    --keep-10mil) KEEP_10MIL="true" ; shift 2 ;;
    --no-afd) NO_AFD="true" ; shift 2 ;;
    --no-tract) NO_TRACT="true" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
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
if [[ ${VERBOSE} == "true" ]]; then echo "TKNI DWI Tractography Pipeline"; fi
if [[ ${LOQUACIOUS} == "true" ]]; then ANTS_VERBOSE=1; else ANTS_VERBOSE=0; fi

# set project defaults ---------------------------------------------------------
if [[ -z ${MRTRIXPATH} ]]; then
  MRTRIXPATH=/usr/lib/mrtrix3/bin
fi
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
  DIR_SCRATCH=${TKNI_SCRATCH}/${PIPE}${FLOW}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo "Running ${PIPE}${FLOW}"
  echo -e "PI:\t${PI}\nPROJECT:\t${PROJECT}"
  echo -e "PROJECT DIRECTORY:\t${DIR_PROJECT}"
  echo -e "SCRATCH DIRECTORY:\t${DIR_SCRATCH}"
  echo -e "Start Time:\t${PROC_START}"
fi

TMP_ANAT=${DIR_SCRATCH}/ANAT
TMP_DWI=${DIR_SCRATCH}/DWI
TMP_FOD=${DIR_SCRATCH}/FOD
TMP_TCK=${DIR_SCRATCH}/TCK
mkdir -p ${TMP_ANAT}
mkdir -p ${TMP_DWI}
mkdir -p ${TMP_FOD}
mkdir -p ${TMP_TCK}

# Check ID ---------------------------------------------------------------------
if [[ -z ${IDPFX} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] ID Prefix must be provided"
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

# Additional default values ----------------------------------------------------
if [[ -z ${DIR_MRTRIX} ]]; then
  DIR_MRTRIX=${DIR_PROJECT}/derivatives/mrtrix/${IDDIR}
fi
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/dwi
fi
if [[ -z ${POST_5TT} ]]; then
  if [[ -z ${IMAGE_T1_NATIVE} ]]; then
    echo "ERROR [TKNI:${FCN_NAME}] 5 tissue posteriors or native space T1w must be provided"
    exit 1
  fi
fi
if [[ -z ${IMAGE_T1_DWI} ]]; then
  IMAGE_T1_DWI=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/dwi/${IDPFX}_space-dwi_T1w.nii.gz
fi
if [[ ! -f ${LABEL} ]]; then
  TLAB=(${LABEL//\+/ })
  LAB_PIPE=${TLAB[-1]}
  LAB_DIR=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/${LAB_PIPE}
  LABEL=${LAB_DIR}/${IDPFX}_label-${LABEL}.nii.gz
fi
if [[ ! -f ${LABEL} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] LABEL file not found."
  exit 2
fi

# copy data to scratch
cp -r ${DIR_MRTRIX}/* ${TMP_DWI}/

# Fiber Orientation Distribution ===============================================
# Response Function Estimation ------------------------------------------------
## Purpose: Estimate different response functions for the three different tissue
## types: white matter (WM), gray matter (GM), and cerebrospinal fluid (CSF).
## Main reference: Dhollander et al., 2016
dwi2response dhollander ${TMP_DWI}/dwi_preproc_coreg.mif \
  ${TMP_FOD}/wm.txt ${TMP_FOD}/gm.txt ${TMP_FOD}/csf.txt \
  -voxels ${TMP_FOD}/voxels.mif

# Estimation of Fiber Orientation Distributions (FOD) --------------------------
## Purpose: In every voxel, estimate the orientation of all fibers crossing that
## voxel.
## Main reference(s): Tournier et al., 2004, 2007
dwi2fod msmt_csd ${TMP_DWI}/dwi_preproc_coreg.mif \
  -mask ${TMP_DWI}/b0_mask_coreg.mif \
  ${TMP_FOD}/wm.txt ${TMP_FOD}/wmfod.mif \
  ${TMP_FOD}/gm.txt ${TMP_FOD}/gmfod.mif \
  ${TMP_FOD}/csf.txt ${TMP_FOD}/csffod.mif

# Intensity Normalization -----------------------------------------------------
## Purpose: Correct for global intensity differences (especially important when
## performing group studies!)
mtnormalise ${TMP_FOD}/wmfod.mif ${TMP_FOD}/wmfod_norm.mif \
  ${TMP_FOD}/gmfod.mif ${TMP_FOD}/gmfod_norm.mif \
  ${TMP_FOD}/csffod.mif ${TMP_FOD}/csffod_norm.mif \
  -mask ${TMP_DWI}/b0_mask_coreg.mif

# Calculate AFD and Dispersion -------------------------------------------------
if [[ "${NO_AFD}" == "false" ]]; then
  mkdir -p ${TMP_FOD}/wmfixel
  mkdir -p ${TMP_FOD}/gmfixel
  fod2fixel -fmls_no_thresholds ${TMP_FOD}/wmfod_norm.mif ${TMP_FOD}/wmfixel \
    -afd wm_afd.mif -disp wm_disp.mif -force
  fod2fixel -fmls_no_thresholds ${TMP_FOD}/gmfod_norm.mif ${TMP_FOD}/gmfixel \
    -afd gm_afd.mif -disp gm_disp.mif -force
  ## convert FIXEL to NIFTI
  mkdir -p ${DIR_SAVE}/scalar/AFD
  mkdir -p ${DIR_SAVE}/scalar/Dispersion
  fixel2voxel -weighted ${TMP_FOD}/wmfixel/wm_afd.mif \
    ${TMP_FOD}/wmfixel/wm_afd.mif mean \
    ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-wm_AFD.nii.gz -force
  fixel2voxel -weighted ${TMP_FOD}/wmfixel/wm_afd.mif \
    ${TMP_FOD}/wmfixel/wm_afd.mif complexity \
    ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-wm_AFDcomplexity.nii.gz -force
  fixel2voxel -weighted ${TMP_FOD}/wmfixel/wm_disp.mif \
    ${TMP_FOD}/wmfixel/wm_disp.mif mean \
    ${DIR_SAVE}/scalar/Dispersion/${IDPFX}_roi-wm_Dispersion.nii.gz -force
  fixel2voxel -weighted ${TMP_FOD}/gmfixel/gm_afd.mif \
    ${TMP_FOD}/gmfixel/gm_afd.mif mean \
    ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-gm_AFD.nii.gz -force
  fixel2voxel -weighted ${TMP_FOD}/gmfixel/gm_afd.mif \
    ${TMP_FOD}/gmfixel/gm_afd.mif complexity \
    ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-gm_AFDcomplexity.nii.gz -force
  fixel2voxel -weighted ${TMP_FOD}/gmfixel/gm_disp.mif \
    ${TMP_FOD}/gmfixel/gm_disp.mif mean \
    ${DIR_SAVE}/scalar/Dispersion/${IDPFX}_roi-gm_Dispersion.nii.gz -force
  make3Dpng --bg ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-wm_AFD.nii.gz \
    --bg-color "timbow:hue=#FF0000" --layout "9:z;9:z;9:z"
  make3Dpng --bg ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-wm_AFDcomplexity.nii.gz \
    --bg-color "timbow:hue=#00FF00" --layout "9:z;9:z;9:z"
  make3Dpng --bg ${DIR_SAVE}/scalar/Dispersion/${IDPFX}_roi-wm_Dispersion.nii.gz \
    --bg-color "timbow:hue=#0000FF" --layout "9:z;9:z;9:z"
  make3Dpng --bg ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-gm_AFD.nii.gz \
    --bg-color "timbow:hue=#FF0000" --layout "9:z;9:z;9:z"
  make3Dpng --bg ${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-gm_AFDcomplexity.nii.gz \
    --bg-color "timbow:hue=#00FF00" --layout "9:z;9:z;9:z"
  make3Dpng --bg ${DIR_SAVE}/scalar/Dispersion/${IDPFX}_roi-gm_Dispersion.nii.gz \
    --bg-color "timbow:hue=#0000FF" --layout "9:z;9:z;9:z"
fi

# Whole-Brain Tractogram =======================================================
# Preparing Anatomically Constrained Tractography (ACT) ------------------------
## Purpose: Increase the biological plausibility of downstream streamline creation.
## Main reference(s): Smith et al., 2012

if [[ "${NO_TRACT}" == "false" ]]; then
  ## Preparing a mask for streamline termination
  if [[ -n ${POST_5TT} ]]; then
   cp ${POST_5TT} ${TMP_ANAT}/5tt.nii.gz
   NVOL=$(niiInfo -i ${TMP_ANAT}/5tt.nii.gz -f volumes)
    if [[ ${NVOL} -eq 4 ]]; then
      fslsplit ${TMP_ANAT}/5tt.nii.gz ${TMP_ANAT}/tvol -t
      fslmaths ${TMP_ANAT}/tvol0000.nii.gz -mul 0 ${TMP_ANAT}/tvol0004.nii.gz
      fslmerge -t ${TMP_ANAT}/5tt.nii.gz ${TMP_ANAT}/tvol*.nii.gz
      rm ${TMP_ANAT}/tvol*.nii.gz
    fi
  else
    niimath ${IMAGE_T1_NATIVE} -mas ${MASK_BRAIN_NATIVE} ${TMP_ANAT}/T1_roi-brain.nii.gz
    mrconvert ${TMP_ANAT}/T1_roi-brain.nii.gz ${TMP_ANAT}/T1_raw.mif
    5ttgen fsl ${TMP_ANAT}/T1_raw.mif ${TMP_ANAT}/5tt.mif -premasked
    mrconvert ${TMP_ANAT}/5tt.mif ${TMP_ANAT}/5tt.nii.gz
  fi
  antsApplyTransforms -d 3 -e 3 -n Linear \
    -i ${TMP_ANAT}/5tt.nii.gz -o ${TMP_ANAT}/5tt_spacing-DWI.nii.gz \
    -r ${IMAGE_T1_DWI}
  mrconvert ${TMP_ANAT}/5tt_spacing-DWI.nii.gz ${TMP_ANAT}/5tt_spacing-DWI.mif

  ## Preparing a mask of streamline seeding
  5tt2gmwmi ${TMP_ANAT}/5tt_spacing-DWI.mif ${TMP_ANAT}/gmwmSeed.mif

  # Creating streamlines ---------------------------------------------------------
  tckgen -act ${TMP_ANAT}/5tt_spacing-DWI.mif \
    -backtrack -seed_gmwmi ${TMP_ANAT}/gmwmSeed.mif \
    -select 10000000 ${TMP_FOD}/wmfod_norm.mif ${TMP_TCK}/tracks_10mio.tck

  # Reducing the number of streamlines -------------------------------------------
  ## Purpose: Filtering the tractograms to reduce CSD-based bias in overestimation
  ## of longer tracks compared to shorter tracks; reducing the number of streamlines
  ## Main reference: Smith et al., 2013
  tcksift -act ${TMP_ANAT}/5tt_spacing-DWI.mif  \
    -term_number 1000000 ${TMP_TCK}/tracks_10mio.tck \
    ${TMP_FOD}/wmfod_norm.mif ${TMP_TCK}/sift_1mio.tck

  ## simplify for viewing
  tckedit ${TMP_TCK}/sift_1mio.tck -number 200k ${TMP_TCK}/smallerSIFT_200k.tck

  if [[ ${NO_PNG} == "false" ]]; then
    mrview ${TMP_DWI}/dwi_preproc_coreg.mif -imagevisible false \
      -tractography.load ${TMP_TCK}/smallerSIFT_200k.tck \
      -tractography.opacity 0.05 \
      -capture.folder ${TMP_TCK} \
      -capture.prefix smallerSIFT_200k_ \
      -mode 3 -noannotations -size 1000,1000 -autoscale \
      -plane 0 -capture.grab \
      -plane 1 -capture.grab \
      -plane 2 -capture.grab \
      -exit
    montage \
      ${TMP_TCK}/smallerSIFT_200k_0000.png \
      ${TMP_TCK}/smallerSIFT_200k_0001.png \
      ${TMP_TCK}/smallerSIFT_200k_0002.png \
      -tile x1 -geometry +0+0 -gravity center -background '#000000' \
      ${TMP_TCK}/${IDPFX}_200k_streamlines.png
  fi

  # Save tractography output -----------------------------------------------------
  cp -r ${TMP_ANAT} ${DIR_MRTRIX}/
  cp -r ${TMP_FOD} ${DIR_MRTRIX}/
  if [[ ${KEEP_10MIL} == "false" ]]; then rm ${TMP_TCK}/tracks_10mio.tck; fi
  cp -r ${TMP_TCK} ${DIR_MRTRIX}/

  # Connectome construction ======================================================
  # Preparing an atlas for structural connectivity analysis ----------------------
  ## Purpose: Obtain a volumetric atlas-based parcellation image, co-registered to
  ## diffusion space for downstream structural connectivity (SC) matrix generation
  ## Main reference: Glasser et al., 2016a (for the atlas used here for SC generation)
  TCK=${TMP_TCK}/sift_1mio.tck
  #TCK=${DIR_MRTRIX}/TCK/sift_1mio.tck

  # convert labels to DWI space
  antsApplyTransforms -d 3 -n MultiLabel \
    -i ${LABEL} -o ${DIR_SCRATCH}/labels.nii.gz -r ${IMAGE_T1_DWI}

  ## Replace the random integers of the hcpmmp1.mif file with integers that start
  ## at 1 and increase by 1.
  #HCPMMP_ORIG=${TKNIPATH}/lut/hcpmmp1_original.txt
  #HCPMMP_SORT=${TKNIPATH}/lut/hcpmmp1_ordered.txt
  labelconvert ${DIR_SCRATCH}/labels.nii.gz \
    ${LUT_ORIG} ${LUT_SORT} ${DIR_SCRATCH}/labels.mif

  # Matrix Generation ------------------------------------------------------------
  ## Purpose: Gain quantitative information on how strongly each atlas region is
  ## connected to all others; represent it in matrix format
  tck2connectome -symmetric -zero_diagonal \
    -scale_invnodevol ${TCK} \
    ${DIR_SCRATCH}/labels.mif \
    ${DIR_SCRATCH}/connectome.csv \
    -out_assignment ${DIR_SCRATCH}/assignments.csv

  connectome2tck ${TCK} \
    ${DIR_SCRATCH}/assignments.csv ${DIR_SCRATCH}/exemplar \
    -files single \
    -exemplars ${DIR_SCRATCH}/labels.mif

  # Create Mesh Node Geometry ----------------------------------------------------
  label2mesh ${DIR_SCRATCH}/labels.mif ${DIR_SCRATCH}/labels_mesh.obj

  # Save Results output ---------------------------------------------------------
  LABNAME=$(getField -i ${LABEL} -f label)
  LABNAME=(${LABNAME//+/ })

  mkdir -p ${DIR_SAVE}/connectome
  cp ${DIR_SCRATCH}/connectome.csv ${DIR_SAVE}/connectome/${IDPFX}_connectome-${LABNAME[0]}.csv
  mkdir -p ${DIR_MRTRIX}/CON
  cp ${DIR_SCRATCH}/assignments.csv ${DIR_MRTRIX}/CON
  cp ${DIR_SCRATCH}/connectome.csv ${DIR_MRTRIX}/CON
  cp ${DIR_SCRATCH}/exemplar.tck ${DIR_MRTRIX}/CON
  cp ${DIR_SCRATCH}/labels_mesh.obj ${DIR_MRTRIX}/CON
  cp ${DIR_SCRATCH}/labels.mif ${DIR_MRTRIX}/CON
  cp ${DIR_SCRATCH}/labels.nii.gz ${DIR_MRTRIX}/CON

  Rscript ${TKNIPATH}/R/connectivityPlot.R \
    ${DIR_SAVE}/connectome/${IDPFX}_connectome-${LABNAME[0]}.csv
fi

# generate HTML QC report ======================================================
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

  TSTR="DWI"
  if [[ "${NO_AFD}" == "false" ]]; then TSTR="${TSTR}, Apparent Fiber Density"; fi
  if [[ "${NO_TRACT}" == "false" ]]; then TSTR="${TSTR}, Tractography and Connectogram"; fi
  echo '## '${PIPE}${FLOW}': '${TSTR} >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  # Show output file tree ------------------------------------------------------
  echo '' >> ${RMD}
  echo '### DWI Processing Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### TKNI File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_SAVE} >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '#### MRTRIX File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -Rn '${DIR_MRTRIX} >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  if [[ "${NO_AFD}" == "false" ]]; then
    echo "### Apparent Fiber Density {.tabset}" >> ${RMD}
    echo "#### WM Mean AFD" >> ${RMD}
    TPNG=${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-wm_AFD.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo "#### WM Complexity AFD" >> ${RMD}
    TPNG=${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-wm_AFDcomplexity.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo "#### WM Dispersion" >> ${RMD}
    TPNG=${DIR_SAVE}/scalar/Dispersion/${IDPFX}_roi-wm_Dispersion.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo "#### GM Mean AFD" >> ${RMD}
    TPNG=${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-gm_AFD.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo "#### GM Complexity AFD" >> ${RMD}
    TPNG=${DIR_SAVE}/scalar/AFD/${IDPFX}_roi-gm_AFDcomplexity.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    echo "#### GM Dispersion" >> ${RMD}
    TPNG=${DIR_SAVE}/scalar/Dispersion/${IDPFX}_roi-gm_Dispersion.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  if [[ "${NO_TRACT}" == "false" ]]; then
    # Tractography ---------------------------------------------------------------
    echo "### Whole Brain Tractography" >> ${RMD}
    TPNG=${DIR_MRTRIX}/TCK/${IDPFX}_200k_streamlines.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    # Connectogram ---------------------------------------------------------------
    echo "### Connectogram" >> ${RMD}
    TPNG=${DIR_SAVE}/connectome/${IDPFX}_connectome-${LABNAME[0]}.png
    echo '![]('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}

    ## add download button to download CSV
    TCSV=${DIR_SAVE}/connectome/${IDPFX}_connectome-${LABNAME[0]}.csv
    FNAME=${IDPFX}_connectome-${LABNAME[0]}
    echo '```{r}' >> ${RMD}
    echo 'data <- read.csv("'${TCSV}'")' >> ${RMD}
    echo 'download_this(.data=data,' >> ${RMD}
    echo '  output_name = "'${FNAME}'",' >> ${RMD}
    echo '  output_extension = ".csv",' >> ${RMD}
    echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
    echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
    echo '```' >> ${RMD}
    echo '' >> ${RMD}
  fi
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

#===============================================================================
# end of Function
#===============================================================================
exit 0
