#!/bin/bash -e
#===============================================================================
# Run TKNI Extract Diffusion Tensors and Scalars
# Required: MRtrix3, ANTs, FSL
# Description:
# Author: Timothy R. Koscik, PhD
# Date Created: 2023-10-31
# Date Modified:
# CHANGE_LOG:
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
image-dwi:,mask-roi:,no-scalar,no-tensor,no-kurtosis,do-b0,\
dir-scratch:,dir-save:,requires:,\
help,verbose,force -n 'parse-options' -- "$@")
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
MASK_ROI=
DIR_SAVE=
NO_SCALAR="false"
NO_TENSOR="false"
NO_KURTOSIS="false"
NO_B0="false"

PIPE=tkni
FLOW=DSCALE
REQUIRES="tkniDICOM,tkniAINIT,tkniDPREP"
FORCE=false
HELP=false
VERBOSE=false
LOQUACIOUS=false
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
    --mask-roi) MASK_ROI="$2" ; shift 2 ;;
    --no-scalar) DO_SCALAR="false" ; shift ;;
    --no-tensor) DO_TENSOR="false" ; shift ;;
    --no-kurtosis) DO_KURTOSIS="false" ; shift 2 ;;
    --do-b0) DO_B0="true" ; shift 2 ;;
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
if [[ ${VERBOSE} == "true" ]]; then echo "TKNI DWI Scalar Pipeline"; fi
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
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/dwi
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
#mkdir -p ${DIR_SCRATCH}

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
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Process DWI images for the following participant:"
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

# Additional default values ----------------------------------------------------
if [[ -z ${DIR_MRTRIX} ]]; then
  DIR_MRTRIX=${DIR_PROJECT}/derivatives/mrtrix/${IDDIR}
fi
if [[ -z ${IMAGE_DWI} ]]; then
  IMAGE_DWI=${DIR_MRTRIX}/dwi_preproc_coreg.mif
fi
EXT="${IMAGE_DWI##*.}"
if [[ ${EXT} != "mif" ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] DWI must be in MRTRIX mif format"
  exit 1
fi
if [[ ! -f ${IMAGE_DWI} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] DWI image not found."
  exit 1
fi

# Extract Diffusion Scalars ====================================================
mkdir -p ${DIR_SCRATCH}

## setup brain mask ------------------------------------------------------------
if [[ -z ${MASK_ROI} ]]; then
  MASK_ROI=${DIR_MRTRIX}/b0_mask_coreg.mif
else
  TX=(${MASK_ROI//\./ })
  if [[ "${TX[-1]}" == "nii" ]] || [[ "${TX[-2]}" == "nii" ]]; then
     mrconvert ${MASK_ROI} ${DIR_SCRATCH}/mask_roi.mif
     MASK_ROI=${DIR_SCRATCH}/mask_roi.mif
  fi
fi
if [[ ! -f ${MASK_ROI} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] ROI MASK image not found. calculating over whole image"
fi

## Extract Tensor --------------------------------------------------------------
mkdir -p ${DIR_SAVE}/tensor

TMPFCN="dwi2tensor -force"
if [[ -n ${MASK_ROI} ]]; then
  TMPFCN="${TMPFCN} -mask ${MASK_ROI}"
fi
if [[ ${NO_B0} == "false" ]]; then
  mkdir -p ${DIR_SAVE}/scalar
  TMPFCN="${TMPFCN} -b0 ${DIR_SAVE}/scalar/${IDPFX}_b0.nii.gz"
fi
if [[ ${NO_KURTOSIS} == "false" ]]; then
  TMPFCN="${TMPFCN} -dkt ${DIR_SAVE}/tensor/${IDPFX}_tensor-kurtosis.nii.gz"
fi
TMPFCN="${TMPFCN} ${IMAGE_DWI}"
TMPFCN="${TMPFCN} ${DIR_SCRATCH}/${IDPFX}_tensor-diffusion.nii.gz"
echo ${TMPFCN}
eval ${TMPFCN}

if [[ ${NO_PNG} == "false" ]] || [[ ${NO_PNG} == "false" ]]; then
  mrconvert ${MASK_ROI} ${DIR_SCRATCH}/mask.nii.gz -force
fi

if [[ ${NO_SCALAR} == "false" ]]; then
  mkdir -p ${DIR_SAVE}/scalar
  tensor2metric -mask ${MASK_ROI} \
    -adc ${DIR_SAVE}/scalar/${IDPFX}_scalar-adc.nii.gz \
    -fa ${DIR_SAVE}/scalar/${IDPFX}_scalar-fa.nii.gz \
    -ad ${DIR_SAVE}/scalar/${IDPFX}_scalar-ad.nii.gz \
    -rd ${DIR_SAVE}/scalar/${IDPFX}_scalar-rd.nii.gz \
    ${DIR_SCRATCH}/${IDPFX}_tensor-diffusion.nii.gz -force
  if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == "false" ]]; then
#    CBARS=("#000000,#7b0031,#6a5700,#008a3c,#00a7b2,#b9afff"\
#           "#000000,#1c4400,#006360,#0075e7,#ff49d9,#ffa277"\
#           "#000000,#003f5f,#9e009f,#e32f00,#a19b00,#00d292"\
#           "#000000,#4c3900,#036700,#008587,#7e8eff,#ff97d8"\
#           "#000000,#00433e,#005c97,#d700c5,#ff6714,#b8c100"\
#           "#000000,#6b0076,#b3002e,#867800,#00ad67,#00cbe2"\
#           "#000000,#7b0031,#9400b9,#0082a1,#00ac83,#b8c100"\
#           "#000000,#1c4400,#765200,#e4008d,#ae7dff,#00cbe2"\
#           "#000000,#003f5f,#006457,#628100,#de8000,#ff97d8"\
#           "#000000,#4c3900,#ae005c,#b428ff,#00a6c2,#00d292"\
#           "#000000,#00433e,#3d6200,#a66a00,#ff53ba,#b9afff"\
#           "#000000,#6b0076,#005f80,#00876f,#8ba100,#ffa277")
    make3Dpng --bg ${DIR_SAVE}/scalar/${IDPFX}_scalar-adc.nii.gz \
      --bg-color "timbow:hue=#FF0000" --bg-threshold 2.5,97.5 --bg-cbar \
      --color-decimal 4 --layout "5:z;5:z;5:z;5:z;5:z"
    make3Dpng --bg ${DIR_SAVE}/scalar/${IDPFX}_scalar-fa.nii.gz \
      --bg-color "timbow:hue=#00FF00" --bg-threshold 2.5,97.5 --bg-cbar \
      --layout "5:z;5:z;5:z;5:z;5:z"
    make3Dpng --bg ${DIR_SAVE}/scalar/${IDPFX}_scalar-ad.nii.gz \
      --bg-color "timbow:hue=#0000FF" --bg-threshold 2.5,97.5 --bg-cbar \
      --color-decimal 4 --layout "5:z;5:z;5:z;5:z;5:z"
    make3Dpng --bg ${DIR_SAVE}/scalar/${IDPFX}_scalar-rd.nii.gz \
      --bg-color "timbow:hue=#FFFF00" --bg-threshold 2.5,97.5 --bg-cbar \
      --color-decimal 4 --layout "5:z;5:z;5:z;5:z;5:z"
  fi
fi

if [[ ${NO_TENSOR} == "false" ]]; then
  cp ${DIR_SCRATCH}/${IDPFX}_tensor-diffusion.nii.gz ${DIR_SAVE}/tensor/
  if [[ ${NO_PNG} == "false" ]] || [[ ${NO_PNG} == "false" ]]; then
    TNII=${DIR_SAVE}/tensor/${IDPFX}_tensor-diffusion.nii.gz
    TPNG=${DIR_SAVE}/tensor/${IDPFX}_tensor-diffusion.png
    NVOL=$(niiInfo -i ${TNII} -f volumes)
    montage_fcn="montage"
    for (( j=1; j<=${NVOL}; j++ )); do
      make3Dpng --bg ${TNII} --bg-vol ${j} \
        --bg-mask ${DIR_SCRATCH}/mask.nii.gz \
        --bg-color "timbow" --bg-threshold "2.5,97.5" --bg-cbar "true" \
        --layout "9:z" \
        --filename vol${j} --dir-save ${DIR_SCRATCH}
      montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
    done
    montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
    montage_fcn=${montage_fcn}' -background "#FFFFFF"'
    montage_fcn="${montage_fcn} ${TPNG}"
    eval ${montage_fcn}
    rm ${DIR_SCRATCH}/vol*.png
  fi
fi

if [[ ${NO_KURTOSIS} == "false" ]]; then
  #cp ${DIR_SCRATCH}/${IDPFX}_tensor-kurtosis.nii.gz ${DIR_SAVE}/tensor/
  if [[ ${NO_PNG} == "false" ]] || [[ ${NO_PNG} == "false" ]]; then
    TNII=${DIR_SAVE}/tensor/${IDPFX}_tensor-kurtosis.nii.gz
    TPNG=${DIR_SAVE}/tensor/${IDPFX}_tensor-kurtosis.png
    NVOL=$(niiInfo -i ${TNII} -f volumes)
    montage_fcn="montage"
    for (( j=1; j<=${NVOL}; j++ )); do
      make3Dpng --bg ${TNII} --bg-vol ${j} \
        --bg-mask ${DIR_SCRATCH}/mask.nii.gz \
        --bg-color "timbow" --bg-threshold "2.5,97.5" --bg-cbar "true" \
        --layout "9:z" \
        --filename vol${j} --dir-save ${DIR_SCRATCH}
      montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
    done
    montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
    montage_fcn=${montage_fcn}' -background "#FFFFFF"'
    montage_fcn="${montage_fcn} ${TPNG}"
    eval ${montage_fcn}
    rm ${DIR_SCRATCH}/vol*.png
  fi
fi

## extract mean kurtosis (mk), axial kurtosis (ak), and radial kurtosis (rk)
## KURTOSIS NOT IMPLEMENTED
#tensor2metric -mask ${TMP_DWI}/b0_mask_coreg.mif\
#  -dkt ${TMP_DWI}/dwi_kurtosis.nii.gz \
#  -mk ${TMP_DWI}/dwi_mk.nii.gz \
#  -ak ${TMP_DWI}/dwi_ak.nii.gz \
#  -rk ${TMP_DWI}/dwi_rk.nii.gz

# generate HTML QC report ------------------------------------------------------
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

  echo '## '${PIPE}${FLOW}': DWI Scalars' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  # Show output file tree ------------------------------------------------------
  echo '' >> ${RMD}
  echo '### DWI Tensors Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_SAVE} >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  # Diffusion Scalars ----------------------------------------------------------
  if [[ ${NO_SCALAR} == "false" ]]; then
    echo '### Scalars {.tabset}' >> ${RMD}
    SLS=("fa" "adc" "ad" "rd")
    SLAB=("Fractional Anisotropy" "Apparent Diffusivity Coefficient (Mean Diffusivity)" "Axial Diffusivity" "Radial Diffusivity")
    for i in {0..3}; do
      echo "#### ${SLAB[${i}]}" >> ${RMD}
      TPNG=${DIR_SAVE}/scalar/${IDPFX}_scalar-${SLS[${i}]}.png
      TNII=${DIR_SAVE}/scalar/${IDPFX}_scalar-${SLS[${i}]}.nii.gz
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  # Diffusion Tensor -----------------------------------------------------------
  if [[ ${NO_TENSOR} == "false" ]] || [[ ${NO_KURTOSIS} == "false" ]]; then
    echo '### Tensors {.tabset}' >> ${RMD}
  fi
  if [[ ${NO_TENSOR} == "false" ]]; then
    echo "#### Diffusion Tensor" >> ${RMD}
    TPNG=${DIR_SAVE}/tensor/${IDPFX}_tensor-diffusion.png
    TNII=${DIR_SAVE}/tensor/${IDPFX}_tensor-diffusion.nii.gz
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  # Diffusion Kurtosis ---------------------------------------------------------
  if [[ ${NO_KURTOSIS} == "false" ]]; then
    echo "#### Kurtosis Tensor" >> ${RMD}
    TPNG=${DIR_SAVE}/tensor/${IDPFX}_tensor-kurtosis.png
    TNII=${DIR_SAVE}/tensor/${IDPFX}_tensor-kurtosis.nii.gz
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
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
