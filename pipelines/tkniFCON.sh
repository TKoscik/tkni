#!/bin/bash -e
#===============================================================================
# Run TKNI Functional Connectivity Pipeline
# Required: MRtrix3, ANTs, FSL
# Description: Motion corrected and nuisance regressed residual time-series are
#              required as input
# Output:
#  1) Resting-State functional connectivity parameters
#     -3dRSFC (ALFF, mALFF, fALFF, RSFA, etc.)
#  2) Mean residual time-series for each label in a label set
#  3) connectivity matrix for a label set
#     -Pearson
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
id:,dir-id:,\
ts:,\
label:,label-name:,lut-orig:,lut-sort:,\
do-rsfc,con-metric:,\
no-z,z-lo:,z-hi:,\
dir-save:,dir-scratch:,\
help,verbose,loquacious,requires:,force,no-png,no-rmd -n 'parse-options' -- "$@")
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
DIR_SAVE=
DIR_XFM=
IDPFX=
IDDIR=

TS=
LABEL=hcpmmp1+MALF
LABEL_NAME=
LUT_ORIG="default"
LUT_SORT="default"
DO_RSFC="false"
CON_METRIC="pearson"
#CON_METRIC="pearson,mutualInformation,transferEntropy,dynamicTimeWarping,euclidean,manhattan"

NO_Z="false"
Z_LO=0
Z_HI=1

HELP=false
VERBOSE=false
LOQUACIOUS=false
NO_PNG=false
NO_RMD=false
KEEP=false

PIPE=tkni
FLOW=FCON
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF,tkniMATS,tkniFUNK"
FORCE=false

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
    --ts) TS="$2" ; shift 2 ;;
    --label) LABEL="$2" ; shift 2 ;;
    --label-name) LABEL_NAME="$2" ; shift 2 ;;
    --lut-orig) LUT_ORIG="$2" ; shift 2 ;;
    --lut-sort) LUT_SORT="$2" ; shift 2 ;;
    --con-metric) CON_METRIC="$2" ; shift 2 ;;
    --do-rsfc) DO_RSFC="true" ; shift ;;
    --no-z) NO_Z="true" ; shift ;;
    --z-lo) Z_LO="$2" ; shift 2 ;;
    --z-hi) Z_HI="$2" ; shift 2 ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    -- ) shift ; break ;;
    * ) break ;;
  esac
done

# Usage Help -------------------------------------------------------------------
if [[ "${HELP}" == "true" ]]; then
    echo '------------------------------------------------------------------------'
    echo " TKNI Pipeline: ${PIPE}:${FLOW}"
    echo ' DESCRIPTION: ROI Time-series Extraction & Functional Connectivity'
    echo '------------------------------------------------------------------------'
    echo ' REQUIRED ARGUMENTS:'
    echo '  --pi <name>           PI folder name (no underscores)'
    echo '  --project <name>      Project name (preferably CamelCase)'
    echo '  --id <string>         Participant identifier (BIDS prefix)'
    echo ''
    echo ' INPUTS & LABELING:'
    echo '  --ts <file>           Residual BOLD time-series (NIfTI)'
    echo '                        (Default: task-rest_residual in derivatives)'
    echo '  --label <file/str>    Label set/Atlas for extraction'
    echo '                        (Default: hcpmmp1+MALF)'
    echo '  --label-name <str>    Base name for labeling (e.g., DKT)'
    echo '  --lut-orig <file>     Original Lookup Table (LUT) for label conversion'
    echo '  --lut-sort <file>     Target ordered LUT for matrix sorting'
    echo '                        (Use "rank" to sort by label frequency)'
    echo ''
    echo ' CONNECTIVITY OPTIONS:'
    echo '  --con-metric <list>   Connectivity metrics: pearson, mutualInformation,'
    echo '                        transferEntropy, dynamicTimeWarping, etc.'
    echo '                        (Default: pearson)'
    echo '  --do-rsfc             Enable AFNI 3dRSFC parameters (ALFF, fALFF, RSFA)'
    echo ''
    echo ' TEMPORAL METRICS:'
    echo '  --no-z                Skip temporal Z-score calculation'
    echo '  --z-lo <float>        Lower bound for tensorZ clipping (default: 0)'
    echo '  --z-hi <float>        Upper bound for tensorZ clipping (default: 1)'
    echo ''
    echo ' PATHS & GLOBAL:'
    echo '  --dir-save <path>     Directory to save derivatives (default: derivatives/tkni)'
    echo '  --dir-project <path>  Base project directory'
    echo '  --dir-scratch <path>  Override default temporary workspace'
    echo '  -h | --help           Display this help'
    echo '  -v | --verbose        Enable console logging'
    echo '  --force               Force re-run and overwrite status'
    echo ''
    NO_LOG=true
    exit 0
fi


#===============================================================================
# Start of Function
#===============================================================================
if [[ ${VERBOSE} == "true" ]]; then echo "TKNI BOLD Preprocessing Pipeline"; fi

# set project defaults ---------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [${PIPE}${FLOW}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [${PIPE}${FLOW}] PROJECT must be provided"
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
  echo "ERROR [${PIPE}${FLOW}] ID Prefix must be provided"
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
  echo -e "ID:\t${IDPFX}"
  echo -e "SUBDIR:\t${IDDIR}"
fi

# Check if Prerequisites are run and QC'd --------------------------------------
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

# Set Up Directories -----------------------------------------------------------
#DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
#if [[ -z ${DIR_SAVE} ]]; then
#  DIR_SAVE=${DIR_PIPE}/func
#fi
mkdir -p ${DIR_SCRATCH}

if [[ -z ${TS} ]]; then
  TS=${DIR_PIPE}/func/residual_native/${IDPFX}_task-rest_residual.nii.gz
fi
if [[ ! -f ${TS} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] TS not found, please check"
  echo -e ${TS}
  exit 1
fi
cp ${TS} ${DIR_SCRATCH}/
TS=${DIR_SCRATCH}/$(basename ${TS})

if [[ ! -f ${LABEL} ]]; then
  TLAB=(${LABEL//\+/ })
  LAB_PIPE=${TLAB[-1]}
  LAB_DIR=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/${LAB_PIPE}
  LABEL=${LAB_DIR}/${IDPFX}_label-${LABEL}.nii.gz
fi
LABEL_NAME=$(getField -i ${LABEL} -f label)
LABEL_NAME=(${LABEL_NAME//+/ })
LABEL_NAME=${LABEL_NAME[0]}
if [[ ! -f ${LABEL} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] LABEL file not found."
  exit 2
fi

# Extract Time-series ----------------------------------------------------------
## order labels
cp ${LABEL} ${DIR_SCRATCH}/labels.nii.gz
if [[ ${LUT_SORT} == "rank" ]]; then
  3dRank -prefix ${DIR_SCRATCH}/labels.nii.gz \
    -input ${DIR_SCRATCH}/labels.nii.gz
  rm ${DIR_SCRATCH}/labels.nii.gz.rankmap.1D
  echo "ranked"
elif [[ ${LUT_ORIG} == "default" ]]; then
    # if LUT does exists or use default ----------------------------------------
    LUT_ORIG=${TKNIPATH}/lut/${LABEL_NAME}_original.txt
    if [[ ${LUT_SORT} == "default" ]]; then
      TLAB=$(getField -i ${LABEL} -f label)
      TLAB=(${TLAB//+/ })
      LUT_SORT=${TKNIPATH}/lut/${LABEL_NAME}_ordered_tkni.txt
    fi
    cp ${LUT_ORIG} ${DIR_SCRATCH}/lut_orig.txt
    cp ${LUT_SORT} ${DIR_SCRATCH}/lut_sort.txt
    labelconvert ${DIR_SCRATCH}/labels.nii.gz \
      ${DIR_SCRATCH}/lut_orig.txt \
      ${DIR_SCRATCH}/lut_sort.txt \
      ${DIR_SCRATCH}/labels.nii.gz -force
    echo "default"
else
  cp ${LUT_ORIG} ${DIR_SCRATCH}/lut_orig.txt
  cp ${LUT_SORT} ${DIR_SCRATCH}/lut_sort.txt
  labelconvert ${DIR_SCRATCH}/labels.nii.gz \
    ${DIR_SCRATCH}/lut_orig.txt \
    ${DIR_SCRATCH}/lut_sort.txt \
    ${DIR_SCRATCH}/labels.nii.gz -force
  echo "manual"
fi
## push labels to fMRI space
3dcalc -a ${TS}[0] -expr a -prefix ${DIR_SCRATCH}/ref.nii.gz
antsApplyTransforms -d 3 -n MultiLabel \
  -i ${DIR_SCRATCH}/labels.nii.gz \
  -o ${DIR_SCRATCH}/labels.nii.gz \
  -t identity \
  -r ${DIR_SCRATCH}/ref.nii.gz
## extract time series
roiTS --ts-bold ${TS} --label ${DIR_SCRATCH}/labels.nii.gz \
  --label-text ${LABEL_NAME} \
  --dir-save ${DIR_SCRATCH}/ts_${LABEL_NAME}

# calculate connectivity metrics -----------------------------------------------
PFX=$(getBidsBase -i ${TS} -s)
mkdir -p ${DIR_SCRATCH}/connectivity
Rscript ${TKNIPATH}/R/connectivity.R \
  "ts" ${DIR_SCRATCH}/ts_${LABEL_NAME}/${PFX}_ts-${LABEL_NAME}.csv \
  ${CON_METRIC//,/ } \
  "dirsave" ${DIR_SCRATCH}/connectivity

# Get temporal Z-score ---------------------------------------------------------
if [[ ${NO_Z} == "false" ]]; then
  tensorZ --image ${TS} --lo ${Z_LO} --hi ${Z_HI} --dir-save ${DIR_SCRATCH}/tensorZ
  niimath ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z.nii.gz \
    -nan ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z.nii.gz

  niimath ${DIR_SCRATCH}/labels.nii.gz -bin ${DIR_SCRATCH}/mask.nii.gz -odt char
  3dmaskave -quiet -mask ${DIR_SCRATCH}/mask.nii.gz \
    ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z.nii.gz \
    > ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_mean.1D
  3dmaskave -quiet -sigma -mask ${DIR_SCRATCH}/mask.nii.gz \
    ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z.nii.gz \
    > ${DIR_SCRATCH}/tmp.1D
  cut -d\  -f2- ${DIR_SCRATCH}/tmp.1D > ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_sigma.1D
  sed -i -r 's/\s+//g' ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_sigma.1D
  3dmaskave -quiet -enorm -mask ${DIR_SCRATCH}/mask.nii.gz \
    ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z.nii.gz \
    > ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_enorm.1D
  3dmaskave -quiet -median -mask ${DIR_SCRATCH}/mask.nii.gz \
    ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z.nii.gz \
    > ${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_median.1D

  PLOTLS="${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_mean.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_sigma.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_enorm.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tensorZ/${PFX}_mod-residual_tensor-z_median.1D"
  regressorPlot --regressor ${PLOTLS} --title 'Time-series Metrics'
fi

# Extract FC Metrics (if requested) --------------------------------------------
if [[ ${DO_RSFC} == "true" ]]; then
  if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == "false" ]]; then
    mapRSFC --ts ${TS} --dir-save ${DIR_SCRATCH}/rsfc_parameters
  else
    mapRSFC --ts ${TS} --dir-save ${DIR_SCRATCH}/rsfc_parameters --no-png
  fi
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
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
  echo 'library(downloadthis)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## '${PIPE}${FLOW}': Functional Connectivity' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  # Show output file tree ------------------------------------------------------
  echo '' >> ${RMD}
  echo '### BOLD fMRI Preprocessing Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_SAVE} >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  # ts-processing
  echo '## Time-series Preprocessing {.tabset}' >> ${RMD}
  unset TPNG
  TPNG=($(ls ${DIR_SAVE}/func/qc/${IDDIR}/${IDPPFX}*ts-processing.png))
  for (( i=0; i<${#TPNG[@]}; i++ )); do
    BNAME=$(getBidsBase -i ${TPNG[$i]} -s)
    BNAME=${BNAME//${IDPFX}_}
    echo "### ${BNAME}" >> ${RMD}
    echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
    echo '' >> ${RMD}
  done

  # coregistration
  echo '## Connectivity {.tabset}' >> ${RMD}
  unset TPNG TCSV
  TCSV=($(ls ${DIR_SCRATCH}/connectivity/${IDPFX}*.csv))
  TPNG=($(ls ${DIR_SCRATCH}/connectivity/${IDPFX}*.png))
  for (( i=0; i<${#TPNG[@]}; i++ )); do
    BNAME=$(getBidsBase -i ${TPNG[${i}]})
    BNAME=${BNAME//${IDPFX}_}
    FNAME=$(basename ${TCSV[${i}]})
    FNAME=${FNAME%%.*}
    echo "### ${BNAME}" >> ${RMD}
    echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
    echo '' >> ${RMD}
    echo '```{r}' >> ${RMD}
    echo 'data <- read.csv("'${TCSV}'")' >> ${RMD}
    echo 'download_this(.data=data,' >> ${RMD}
    echo '  output_name = "'${FNAME}'",' >> ${RMD}
    echo '  output_extension = ".csv",' >> ${RMD}
    echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
    echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
    echo '```' >> ${RMD}
    echo '' >> ${RMD}
  done

  if [[ ${NO_Z} == "false" ]]; then
    echo '## Time-series Metrics {.tabset}' >> ${RMD}
    TPNG=($(ls ${DIR_SCRATCH}/tensorZ/${IDPFX}*.png))
    for (( i=0; i<${#TPNG[@]}; i++ )); do
      BNAME=$(getBidsBase -i ${TPNG[$i]})
      BNAME=${BNAME//${IDPFX}_}
      echo "### ${BNAME}" >> ${RMD}
      echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  # Extract FC Metrics (if requested) --------------------------------------------
  if [[ ${DO_RSFC} == "true" ]]; then
    echo '## RSFC Parameters {.tabset}' >> ${RMD}
    TPNG=($(ls ${DIR_SCRATCH}/rsfc_parameters/${IDPFX}*.png))
    for (( i=0; i<${#TPNG[@]}; i++ )); do
      BNAME=$(getBidsBase -i ${TPNG[$i]})
      BNAME=${BNAME//${IDPFX}_}
      echo "### ${BNAME}" >> ${RMD}
      echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
      echo '' >> ${RMD}
    done
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

# Save Output ------------------------------------------------------------------
mkdir -p ${DIR_SAVE}/func/ts_${LABEL_NAME}
mv ${DIR_SCRATCH}/ts_${LABEL_NAME}/* ${DIR_SAVE}/func/
mkdir -p ${DIR_SAVE}/func/connectivity
mv ${DIR_SCRATCH}/connectivity/* ${DIR_SAVE}/func/connectivity/
if [[ ${NO_Z} == "false" ]]; then
  mkdir -p ${DIR_SAVE}/func/tensorZ
  mv ${DIR_SCRATCH}/tensorZ/* ${DIR_SAVE}/func/tensorZ/
fi
if [[ ${DO_RSFC} == "true" ]]; then
  mkdir -p ${DIR_SAVE}/func/rsfc_parameters
  mv ${DIR_SCRATCH}/rsfc_parameters/* ${DIR_SAVE}/func/rsfc_parameters/
fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> QC check file status set"
fi

#===============================================================================
# End of function
#===============================================================================
exit 0

