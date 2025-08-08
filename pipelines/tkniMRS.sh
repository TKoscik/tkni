#!/bin/bash -e
#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      MRS
# DESCRIPTION:   TKNI Magnetic Resonance Spectroscopy Pipeline
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-02-28
# README:
#     Procedure:
#     (1) Coregister anatomical localizer to NATIVE
#     (2) Push tissue segmentation to MRS space
#     (3) Use SPANT to fit MRS spectrum
#         (a) load MRS data from Siemens TWIX/dat file
#         (b) get VOI, push VOI to space of localizer
#         (c) use VOI in localizer space to get tissue composition
#         (d) output VOI to localizer space NIFF
#         (e) fit MRS data
#             - use HSVD water removal, eddy correction, and dynamic
#               frequency and phase correction.
#     (4) Push MRS VOI to native for PNG
#     (5) Save results
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
id:,dir-id:,\
mrs:,mrs-loc:,mrs-mask:,mrs-unsuppressed,\
native:,native-mask:,tissue:,tissue-val:,\
coreg-recipe:,no-hsvd,no-eddy,no-dfp,\
dir-save:,dir-scratch:,requires:,\
help,verbose,force,no-png,no-rmd,force -n 'parse-options' -- "$@")
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

MRS=
MRS_LOC=
MRS_MASK=
MRS_UNSUPPRESS="false"
NATIVE=
NATIVE_MASK=
TISSUE=
TISSUE_VAL="1;2,3;4"

#MOL="2hg,a_glc,ace,ala,asc,asp,tp_31p,b_glc,bhb,cho,cho_rt,cit,cr_ch2_rt,cr_ch3_rt,cr,gaba_jn,gaba,gaba_rt,glc,gln,glu,glu_rt,gly,glyc,gpc_31p,gpc,gpe_31p,gsh,h2o,ins,ins_rt,lac,lac_rt,lip09,lip13a,lip13b,lip20,m_cr_ch2,mm_3t,mm09,mm12,mm14,mm17,mm20,msm,naa,naa_rt,naa2,naag_ch3,naag,nadh_31p,nadp_31p,pch_31p,pch,pcr_31p,pcr,pe_31p,peth,pi_31p,pyr,ser,sins,suc,tau,thr,val"

COREG_RECIPE="intermodalSyn"
NO_HSVD=false
NO_EDDY=false
NO_DFP=false

DIR_SAVE=
DIR_SCRATCH=

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES="tkniDICOM,tkniAINIT,tkniMATS"
FORCE=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_PNG=true ; shift ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --mrs) MRS="$2" ; shift 2 ;;
    --mrs-loc) MRS_LOC="$2" ; shift 2 ;;
    --mrs-mask) MRS_MASK="$2" ; shift 2 ;;
    --mrs-unsuppressed) MRS_UNSUPPRESS="true" ; shift ;;
    --native) NATIVE="$2" ; shift 2 ;;
    --native-mask) NATIVE_MASK="$2" ; shift 2 ;;
    --tissue) TISSUE="$2" ; shift 2 ;;
    --tissue-val) TISSUE_VAL="$2" ; shift 2 ;;
    --coreg-recipe) COREG_RECIPE="$2" ; shift 2 ;;
    --no-hsvd) NO_HSVD="true" ; shift ;;
    --no-eddy) NO_EDDY="true" ; shift ;;
    --no-dfp) NO_DFP="true" ; shift ;;
    --dir-save) DIR_PROJECT="$2" ; shift 2 ;;
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
  echo '  --id'
  echo '  --dir-id'
  echo '  --mrs'
  echo '  --native'
  echo '  --native-mask'
  echo '  --tissue'
  echo '  --tissue-val'
  echo '  --no-hsvd'
  echo '  --no-eddy'
  echo '  --no-dfp'
  echo '  --dir-xfm'
  echo '  --dir-save'
  echo '  --dir-scratch'
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

# Identify Inputs --------------------------------------------------------------
echo ">>>>> ${MRS_UNSUPPRESS} "
if [[ -z ${MRS} ]]; then
  if [[ ${MRS_UNSUPPRESS} == "false" ]]; then
    if ls ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/*PRESS35.dat 1> /dev/null 2>&1; then
      MRS=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/*PRESS35.dat))
    fi
  else
    if ls ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/*PRESS35_unsupp*.dat 1> /dev/null 2>&1; then
      MRS=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/*PRESS35_unsupp*.dat))
    fi
  fi
fi
if [[ ! -f ${MRS} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] MRS data not found."
  echo -e "\t\t${MRS}"
  exit 1
fi

if [[ -z ${MRS_LOC} ]]; then
  MRS_LOC=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/${IDPFX}_acq-mrsLoc+axi_T2w.nii.gz))
fi
if [[ ! -f ${MRS} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] MRS localizer image not found."
  exit 1
fi

if [[ -n ${MRS_MASK} ]]; then
  if [[ ! -f ${MRS_MASK} ]]; then
    echo -e "\tERROR [${PIPE}:${FLOW}] MRS mask not found."
    exit 1
  fi
fi

if [[ -z ${NATIVE} ]]; then
  NATIVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/${IDPFX}_T1w.nii.gz
fi
if [[ ! -f ${NATIVE} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] NATIVE image not found."
  exit 2
fi

if [[ -z ${NATIVE_MASK} ]]; then
  NATIVE_MASK=${DIR_PROJECT}/derivatives/${PIPE}/anat/mask/${IDPFX}_mask-brain.nii.gz
fi
if [[ ! -f ${NATIVE_MASK} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] NATIVE_MASK image not found."
  exit 3
fi

if [[ -z ${TISSUE} ]]; then
  TISSUE=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/${IDPFX}_label-tissue.nii.gz
fi
if [[ ! -f ${TISSUE} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] TISSUE segmentation not found."
  exit 4
fi

# set directories --------------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}; fi
mkdir -p ${DIR_SCRATCH}

# Copy data to scratch and gunzip as needed ------------------------------------
#cp ${MRS} ${DIR_SCRATCH}/
#MRS=($(ls ${DIR_SCRATCH}/*PRESS35.dat))

# Coregister anatomical localizer to NATIVE ------------------------------------
## get brain mask for localizer to focus registration, if not provided
if [[ -z ${MRS_MASK} ]]; then
  if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>generating brain mask for localizer"; fi
  MRS_MASK=${DIR_SCRATCH}/mrs-localizer_mask-brain.nii.gz
  mri_synthstrip -i ${MRS_LOC} -m ${MRS_MASK}
fi

## run coregistation
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>coregistering localizer to native anatomical"; fi
TMOD=($(getField -i ${MRS_LOC} -f modality))
coregistrationChef --recipe-name ${COREG_RECIPE} \
  --fixed ${NATIVE} --fixed-mask ${NATIVE_MASK} \
  --moving ${MRS_LOC} --moving-mask ${MRS_MASK} \
  --space-target "fixed" --interpolation "Linear" \
  --prefix ${IDPFX} --label-from "mrs" --label-to "native" \
  --dir-save ${DIR_SCRATCH} \
  --dir-xfm ${DIR_SCRATCH}/xfm #--no-png

XFM_FWD_STR="-t identity"
XFM_REV_STR="-t identity"
if ls ${DIR_SCRATCH}/xfm/${IDPFX}_*.mat 1> /dev/null 2>&1; then
  XFM_AFF=($(ls ${DIR_SCRATCH}/xfm/${IDPFX}_*.mat))
fi
if ls ${DIR_SCRATCH}/xfm/${IDPFX}_*.nii.gz 1> /dev/null 2>&1; then
  SYNLS=($(ls ${DIR_SCRATCH}/xfm/${IDPFX}_*.nii.gz))
fi
if [[ ${#SYNLS[@]} -gt 0 ]]; then
  if [[ ${SYNLS[0]} == *"inverse"* ]]; then
    XFM_SYN=${SYNLS[1]}
    XFM_INV=${SYNLS[0]}
  else
    XFM_SYN=${SYNLS[0]}
    XFM_INV=${SYNLS[1]}
  fi
fi
if [[ ${#SYNLS[@]} -gt 0 ]]; then XFM_FWD_STR="${XFM_FWD_STR} -t ${XFM_SYN}"; fi
if [[ -f ${XFM_AFF} ]]; then
  XFM_FWD_STR="${XFM_FWD_STR} -t ${XFM_AFF}"
  XFM_REV_STR="${XFM_REV_STR} -t [${XFM_AFF},1]"
fi
if [[ ${#SYNLS[@]} -gt 0 ]]; then XFM_REV_STR="${XFM_REV_STR} -t ${XFM_INV}"; fi

# get MRS VOI in native space --------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>pushing VOI to native space"; fi
if [[ ${VERBOSE} == "true" ]]; then
  echo Rscript ${TKNIPATH}/R/getMRSvoi.R "nii" ${MRS_LOC} "mrs" ${MRS} \
  "file" ${IDPFX}_mask-mrsVOI "dir.save" ${DIR_SCRATCH}
fi
Rscript ${TKNIPATH}/R/getMRSvoi.R "nii" ${MRS_LOC} "mrs" ${MRS} \
  "file" ${IDPFX}_mask-mrsVOI "dir.save" ${DIR_SCRATCH}
gzip ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  -r ${NATIVE} ${XFM_FWD_STR}
make3Dpng --bg ${NATIVE} --bg-thresh "2.5,97.5" \
  --fg ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  --fg-mask ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  --fg-color "timbow:hue=#00FF00:lum=65,65:cyc=1/6" \
  --fg-alpha 50 --fg-cbar "false" \
  --filename ${IDPFX}_mask-mrsVOI --dir-save ${DIR_SCRATCH}

# Calculate partial volumes from tissue segmentation within VOI ----------------
## split tisse segmentation into CSF, GM, and WM components
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>calculating partial volumes"; fi
TVALS=(${TISSUE_VAL//;/ })
CSF=(${TVALS[0]//,/ })
TCSF=${DIR_SCRATCH}/mask-csf.nii.gz
niimath ${TISSUE} -mul 0 ${TCSF}
for (( i=0; i<${#CSF[@]}; i++ )); do
  niimath ${TISSUE} -thr ${CSF[${i}]} -uthr ${CSF[${i}]} -bin -add ${TCSF} ${TCSF} -odt char
done
COUNT_CSF=$(3dBrickStat -mask ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz -sum ${TCSF})
echo -e ">>>>>CSF Count\t${COUNT_CSF}"

GM=(${TVALS[1]//,/ })
TGM=${DIR_SCRATCH}/mask-gm.nii.gz
niimath ${TISSUE} -mul 0 ${TGM}
for (( i=0; i<${#GM[@]}; i++ )); do
  niimath ${TISSUE} -thr ${GM[${i}]} -uthr ${GM[${i}]} -bin -add ${TGM} ${TGM} -odt char
done
COUNT_GM=$(3dBrickStat -mask ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz -sum ${TGM})
echo -e ">>>>>GM Count\t${COUNT_GM}"

WM=(${TVALS[2]//,/ })
TWM=${DIR_SCRATCH}/mask-wm.nii.gz
niimath ${TISSUE} -mul 0 ${TWM}
for (( i=0; i<${#WM[@]}; i++ )); do
  niimath ${TISSUE} -thr ${WM[${i}]} -uthr ${WM[${i}]} -bin -add ${TWM} ${TWM} -odt char
done
COUNT_WM=$(3dBrickStat -mask ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz -sum ${TWM})
echo -e ">>>>>WM Count\t${COUNT_WM}"

TOTAL_V=$(echo "scale=0; ${COUNT_CSF} + ${COUNT_GM} + ${COUNT_WM}" | bc -l)
CSF_PCT=$(echo "scale=4; (${COUNT_CSF} / ${TOTAL_V}) * 100" | bc -l)
GM_PCT=$(echo "scale=4; (${COUNT_GM} / ${TOTAL_V}) * 100" | bc -l)
WM_PCT=$(echo "scale=4; (${COUNT_WM} / ${TOTAL_V}) * 100" | bc -l)

if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>> VOI Partial Volumes"
  echo -e "\tCSF:\t${CSF_PCT}%"
  echo -e "\tGM:\t${GM_PCT}%"
  echo -e "\tWM:\t${WM_PCT}%"
fi

#  Use SPANT to fit MRS spectrum -----------------------------------------------
#  (a) load MRS data from Siemens TWIX/dat file
#  (b) get VOI, push VOI to space of localizer
#  (c) use VOI in localizer space to get tissue composition
#  (d) output VOI to localizer space NIFF
#  (e) fit MRS data
#      - use HSVD water removal, eddy correction, and dynamic
#        frequency and phase correction.

if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>> running spant for MRS fitting"
  echo Rscript ${TKNIPATH}/R/fitMRS_spant.R "mrs" ${MRS} \
    "no-hsvd" ${NO_HSVD} "no-eddy" ${NO_EDDY} "no-dfp" ${NO_DFP} \
    "csf" ${CSF_PCT} "gm" ${GM_PCT} "wm" ${WM_PCT} \
    "dir.save" ${DIR_SCRATCH}
fi

Rscript ${TKNIPATH}/R/fitMRS_spant.R "mrs" ${MRS} \
  "no-hsvd" ${NO_HSVD} "no-eddy" ${NO_EDDY} "no-dfp" ${NO_DFP} \
  "csf" ${CSF_PCT} "gm" ${GM_PCT} "wm" ${WM_PCT} \
  "dir.save" ${DIR_SCRATCH}/spant

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
  echo 'library(spant)' >> ${RMD}
  echo 'library(DT)' >> ${RMD}
  echo 'library(downloadthis)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## Magnetic Resonance Spectroscopy Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -----------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  ## VOI -----------------------------------------------------------------------
  echo '### MRS Volume' >> ${RMD}
  TNII="${IDPFX}_mask-mrsVOI.nii.gz"
  TPNG="${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.png"
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  # add data download buttons --------------------------------------------------
  TCSV="${DIR_SCRATCH}/spant/fit_res_tCr_ratio.csv"
  FNAME="${IDPFX}_ratio-tCr_MRSfit"
  echo '```{r}' >> ${RMD}
  echo 'data <- read.csv("'${TCSV}'")' >> ${RMD}
  echo 'download_this(.data=data,' >> ${RMD}
  echo '  output_name = "'${FNAME}'",' >> ${RMD}
  echo '  output_extension = ".csv",' >> ${RMD}
  echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
  echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  TCSV="${DIR_SCRATCH}/spant/fit_res_unscaled.csv"
  FNAME="${IDPFX}_MRSfit"
  echo '```{r}' >> ${RMD}
  echo 'data <- read.csv("'${TCSV}'")' >> ${RMD}
  echo 'download_this(.data=data,' >> ${RMD}
  echo '  output_name = "'${FNAME}'",' >> ${RMD}
  echo '  output_extension = ".csv",' >> ${RMD}
  echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
  echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  TCSV="${DIR_SCRATCH}/spant/svs_results.rds"
  FNAME="${IDPFX}_MRSfit"
  echo '```{r}' >> ${RMD}
  echo 'data <- readRDS("'${TCSV}'")' >> ${RMD}
  echo 'download_this(.data=data,' >> ${RMD}
  echo '  output_name = "'${FNAME}'",' >> ${RMD}
  echo '  output_extension = ".rds",' >> ${RMD}
  echo '  button_label = "Download '${FNAME}' RDS",' >> ${RMD}
  echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
  echo '```' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # Coregistration Results
  echo "### Coregistration to Native Space {.tabset}" >> ${RMD}
  echo "#### Click to View -->"  >> ${RMD}
  echo "#### Coregistration Overlay"  >> ${RMD}
  TPNG=($(ls ${DIR_SCRATCH}/xfm/${IDPFX}*.png))
  echo '![Overlay]('${TPNG[0]}')' >> ${RMD}
  echo '' >> ${RMD}

  # load spant results ---------------------------------------------------------
  echo '### SPANT SVS Analysis Results' >> ${RMD}

  echo '```{r}' >> ${RMD}
  echo 'params <- readRDS("'${DIR_SCRATCH}/spant/svs_results.rds'")' >> ${RMD}
  echo 'argg <- readRDS("'${DIR_SCRATCH}/spant/svs_argg.rds'")' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  echo '# {.tabset}' >> ${RMD}
  echo '## Fit plots {.tabset}' >> ${RMD}
  echo '### Standard' >> ${RMD}
  echo '```{r fitplot, fig.width=7, fig.height=6}' >> ${RMD}
  echo 'plot(params$fit_res, xlim = params$plot_ppm_xlim)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '### Stackplot' >> ${RMD}
  echo '```{r stackplot, fig.width=7, fig.height=8}' >> ${RMD}
  echo 'stackplot(params$fit_res, y_offset = 3, combine_lipmm = TRUE, labels = TRUE,' >> ${RMD}
  echo '          xlim = params$plot_ppm_xlim)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '```{r basisplot, results = "asis", fig.width=7, fig.height=6}' >> ${RMD}
  echo '# basis_names <- params$fit_res$basis$names' >> ${RMD}
  echo 'basis_names <- colnames(params$fit_res$fits[[1]][-1:-4])' >> ${RMD}
  echo 'for (n in 1:length(basis_names)) {' >> ${RMD}
  echo '  cat("\n### ", basis_names[n], "\n", sep = "")' >> ${RMD}
  echo '  plot(params$fit_res, plot_sigs = basis_names[n], main = basis_names[n],' >> ${RMD}
  echo '       xlim = params$plot_ppm_xlim)' >> ${RMD}
  echo '  cat("\n")' >> ${RMD}
  echo '}' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '```{r, results = "asis"}' >> ${RMD}
  echo 'if (!is.null(params$summary_tab)) {' >> ${RMD}
  echo '  cat("## Summary table\n")' >> ${RMD}
  echo '  col.names <- c("Name", "Value")' >> ${RMD}
  echo '  kable_table <- kableExtra::kbl(params$summary_tab, col.names = col.names,' >> ${RMD}
  echo '                                 align = c("l", "r"))' >> ${RMD}
  echo '  boot_opts <- c("striped", "hover", "condensed")' >> ${RMD}
  echo '  kableExtra::kable_styling(kable_table, full_width = FALSE, position = "left",' >> ${RMD}
  echo '                            bootstrap_options = boot_opts)' >> ${RMD}
  echo '}' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '## Results table' >> ${RMD}
  echo '```{r}' >> ${RMD}
  echo 'ratio_str   <- params$output_ratio[1]' >> ${RMD}
  echo 'if (params$w_ref_available) {' >> ${RMD}
  echo '  col_names <- c("amps", "CI95")' >> ${RMD}
  echo '  res_tab   <- sv_res_table(params$res_tab_molal, format_out = TRUE)' >> ${RMD}
  echo '  out_tab   <- res_tab[col_names]' >> ${RMD}
  echo '  col.names <- c("Name", "Amp. (mmol/kg)", "95% CI (mmol/kg)")' >> ${RMD}
  echo '  ' >> ${RMD}
  echo '  if (!is.null(params$res_tab_legacy)) {' >> ${RMD}
  echo '    res_tab   <- sv_res_table(params$res_tab_legacy, format_out = TRUE)' >> ${RMD}
  echo '    out_tab   <- cbind(out_tab, res_tab[col_names])' >> ${RMD}
  echo '    col.names <- c(col.names, "Amp. (mmol/kg)", "95% CI (mmol/kg)")' >> ${RMD}
  echo '  }' >> ${RMD}
  echo '  ' >> ${RMD}
  echo '  if (!is.null(ratio_str)) {' >> ${RMD}
  echo '    res_tab   <- sv_res_table(params$res_tab_ratio, format_out = TRUE)' >> ${RMD}
  echo '    out_tab   <- cbind(out_tab, res_tab[col_names])' >> ${RMD}
  echo '    col.names <- c(col.names, paste0("Amp. (/", ratio_str, ")"),' >> ${RMD}
  echo '                              paste0("95% CI (/", ratio_str, ")"))' >> ${RMD}
  echo '  }' >> ${RMD}
  echo '  out_tab   <- cbind(out_tab, res_tab["sds_perc"])' >> ${RMD}
  echo '  col.names <- c(col.names, "SD %")' >> ${RMD}
  echo '} else {' >> ${RMD}
  echo '  col_names <- c("amps", "CI95", "sds_perc")' >> ${RMD}
  echo '  if (is.null(ratio_str)) {' >> ${RMD}
  echo '    res_tab   <- sv_res_table(params$res_tab_unscaled, format_out = TRUE)' >> ${RMD}
  echo '    out_tab   <- res_tab[col_names]' >> ${RMD}
  echo '    col.names <- c("Name", "Amp. (a.u.)", "95% CI (a.u.)", "SD %")' >> ${RMD}
  echo '  } else {' >> ${RMD}
  echo '    res_tab   <- sv_res_table(params$res_tab_ratio, format_out = TRUE)' >> ${RMD}
  echo '    out_tab   <- res_tab[col_names]' >> ${RMD}
  echo '    col.names <- c("Name", paste0("Amp. (/", ratio_str, ")"),' >> ${RMD}
  echo '                   paste0("95% CI (/", ratio_str, ")"), "SD %")' >> ${RMD}
  echo '  }' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'boot_opts <- c("striped", "hover", "condensed")' >> ${RMD}
  echo '' >> ${RMD}
  echo 'kable_table <- kableExtra::kbl(out_tab, col.names = col.names,' >> ${RMD}
  echo '                               align = rep("r", 10))' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (params$w_ref_available & !is.null(params$res_tab_legacy)) {' >> ${RMD}
  echo '  extra_cols  <- ifelse(is.null(ratio_str), 1, 3)' >> ${RMD}
  echo '  header_str  <- c(" " = 1, "standard concentration scaling" = 2,' >> ${RMD}
  echo '                   "legacy concentration scaling" = 2, " " = extra_cols)' >> ${RMD}
  echo '  ' >> ${RMD}
  echo '  kable_table <- kableExtra::add_header_above(kable_table, header_str)' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'kableExtra::kable_styling(kable_table, full_width = FALSE, position = "left",' >> ${RMD}
  echo '                          bootstrap_options = boot_opts)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '```{r, results = "'asis'"}' >> ${RMD}
  echo 'if (params$w_ref_available) {' >> ${RMD}
  echo 'cat("See the [spant User Guide](https://spantdoc.wilsonlab.co.uk/water_scaling) for details on water scaling.\n")' >> ${RMD}
  echo '#  cat("^1^ Concentrations listed in molal units: moles of solute / mass of solvent. See the following papers for details :\n\nGasparovic C, Chen H, Mullins PG. Errors in 1H-MRS estimates of brain metabolite concentrations caused by failing to take into account tissue-specific signal relaxation. NMR Biomed. 2018 Jun;31(6):e3914. https://doi.org/10.1002/nbm.3914\n\nGasparovic C, Song T, Devier D, Bockholt HJ, Caprihan A, Mullins PG, Posse S, Jung RE, Morrison LA. Use of tissue water as a concentration reference for proton spectroscopic imaging. Magn Reson Med. 2006 Jun;55(6):1219-26. https://doi.org/10.1002/mrm.20901\n\n")  ' >> ${RMD}
  echo '#  cat("^2^ Concentrations listed in pseduo-molar units: moles of solute / (mass of solvent + mass of tissue). These values are included for legacy puposes, for example to directly compare results from the default scaling method used by LCModel and TARQUIN. See sections 1.3 and 10.2 of the [LCModel manual](http://s-provencher.com/pub/LCModel/manual/manual.pdf) for details.")' >> ${RMD}
  echo '}' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '```{r, results = "asis", fig.width=7, fig.height=7}' >> ${RMD}
  echo 'if (!is.null(params$dyn_data_uncorr)) {' >> ${RMD}
  echo '  cat("## Dynamic plots {.tabset}\n")' >> ${RMD}
  echo '  if (!is.null(params$dyn_data_corr)) {' >> ${RMD}
  echo '    cat("### Spectrogram with dynamic correction\n")' >> ${RMD}
  echo '    if (is.null(params$plot_ppm_xlim)) {' >> ${RMD}
  echo '      image(params$dyn_data_corr, xlim = c(4, 0.5))' >> ${RMD}
  echo '    } else {' >> ${RMD}
  echo '      image(params$dyn_data_corr, xlim = params$plot_ppm_xlim)' >> ${RMD}
  echo '    }' >> ${RMD}
  echo '  }' >> ${RMD}
  echo '  cat("\n\n### Spectrogram without dynamic correction\n")' >> ${RMD}
  echo '  if (is.null(params$plot_ppm_xlim)) {' >> ${RMD}
  echo '    image(params$dyn_data_uncorr, xlim = c(4, 0.5))' >> ${RMD}
  echo '  } else {' >> ${RMD}
  echo '    image(params$dyn_data_uncorr, xlim = params$plot_ppm_xlim)' >> ${RMD}
  echo '  }' >> ${RMD}
  echo '}' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '## Spectral plots {.tabset}' >> ${RMD}
  echo '' >> ${RMD}
  echo '### Processed cropped' >> ${RMD}
  echo '```{r, fig.width=7, fig.height=6}' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$phase)) {' >> ${RMD}
  echo '  phase_offset <- params$fit_res$res_tab$phase' >> ${RMD}
  echo '} else {' >> ${RMD}
  echo '  phase_offset <- 0' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$phi1)) {' >> ${RMD}
  echo '  phi1_offset <- params$fit_res$res_tab$phi1' >> ${RMD}
  echo '} else {' >> ${RMD}
  echo '  phi1_offset <- 0' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$shift)) {' >> ${RMD}
  echo '  shift_offset <- params$fit_res$res_tab$shift' >> ${RMD}
  echo '} else {' >> ${RMD}
  echo '  shift_offset <- 0' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'proc_spec <- params$fit_res$data' >> ${RMD}
  echo 'proc_spec <- phase(proc_spec, phase_offset, phi1_offset)' >> ${RMD}
  echo 'proc_spec <- shift(proc_spec, shift_offset, units = "ppm")' >> ${RMD}
  echo 'proc_spec <- zf(proc_spec)' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (is.null(params$plot_ppm_xlim)) {' >> ${RMD}
  echo '  plot(proc_spec, xlim = c(4, 0.2))' >> ${RMD}
  echo '} else {' >> ${RMD}
  echo '  plot(proc_spec, xlim = params$plot_ppm_xlim)' >> ${RMD}
  echo '}' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '### Processed full' >> ${RMD}
  echo '```{r, fig.width=7, fig.height=6}' >> ${RMD}
  echo 'plot(proc_spec)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '```{r, results = "asis", fig.width=7, fig.height=6}' >> ${RMD}
  echo 'if (params$w_ref_available) {' >> ${RMD}
  echo '  cat("### Water reference resonance\n")' >> ${RMD}
  echo '  # w_ref_proc <- shift(w_ref, shift_offset, units = "ppm")' >> ${RMD}
  echo '  w_ref_proc <- auto_phase(w_ref, xlim = c(5.3, 4))' >> ${RMD}
  echo '  w_ref_proc <- zf(w_ref_proc)' >> ${RMD}
  echo '  plot(w_ref_proc, xlim = c(5.3, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '## Diagnostics table' >> ${RMD}
  echo '```{r}' >> ${RMD}
  echo 'name  <- NULL' >> ${RMD}
  echo 'value <- NULL' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$SNR)) {' >> ${RMD}
  echo '  name  <- c(name, "Spectral signal to noise ratio")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$SNR, 2))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$SRR)) {' >> ${RMD}
  echo '  name  <- c(name, "Spectral signal to residual ratio")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$SRR, 2))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$FWHM)) {' >> ${RMD}
  echo '  name  <- c(name, "Spectral linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$FWHM, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$tNAA_lw)) {' >> ${RMD}
  echo '  name  <- c(name, "tNAA linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$tNAA_lw, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$NAA_lw)) {' >> ${RMD}
  echo '  name  <- c(name, "NAA linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$NAA_lw, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$tCho_lw)) {' >> ${RMD}
  echo '  name  <- c(name, "tCho linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$tCho_lw, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$Cho_lw)) {' >> ${RMD}
  echo '  name  <- c(name, "Cho linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$Cho_lw, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$tCr_lw)) {' >> ${RMD}
  echo '  name  <- c(name, "tCr linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$tCr_lw, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$Cr_lw)) {' >> ${RMD}
  echo '  name  <- c(name, "Cr linewidth (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$Cr_lw, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$phase)) {' >> ${RMD}
  echo '  name  <- c(name, "Zero-order phase (degrees)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$phase, 1))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$phi1)) {' >> ${RMD}
  echo '  name  <- c(name, "First-order phase (ms)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$phi1, 3))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (!is.null(params$fit_res$res_tab$shift)) {' >> ${RMD}
  echo '  name  <- c(name, "Frequency offset (ppm)")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$shift, 4))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (params$w_ref_available) {' >> ${RMD}
  echo '  name  <- c(name,  "Water amplitude", "Water suppression efficiency (%)")' >> ${RMD}
  echo '  value <- c(value, format(params$res_tab_molal$w_amp),' >> ${RMD}
  echo '             spant:::round_dp(params$res_tab_molal$ws_eff, 3))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'if (params$fit_res$method == "ABFIT") {' >> ${RMD}
  echo '  name  <- c(name, "Fit quality number (FQN)",' >> ${RMD}
  echo '             "Baseline effective d.f. per ppm",' >> ${RMD}
  echo '             "Lineshape asymmetry")' >> ${RMD}
  echo '  value <- c(value, spant:::round_dp(params$fit_res$res_tab$FQN, 2),' >> ${RMD}
  echo '             spant:::round_dp(params$fit_res$res_tab$bl_ed_pppm, 2),' >> ${RMD}
  echo '             spant:::round_dp(params$fit_res$res_tab$asym, 2))' >> ${RMD}
  echo '}' >> ${RMD}
  echo '' >> ${RMD}
  echo 'diag_tab <- data.frame(name, value)' >> ${RMD}
  echo 'kableExtra::kable_styling(kableExtra::kbl(diag_tab, align = c("l", "r"),' >> ${RMD}
  echo '                                          col.names = c("Name", "Value")),' >> ${RMD}
  echo '                          full_width = FALSE, position = "left",' >> ${RMD}
  echo '                          bootstrap_options = boot_opts)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '## Provenance' >> ${RMD}
  echo '```{r, echo = TRUE}' >> ${RMD}
  echo 'packageVersion("spant")' >> ${RMD}
  echo 'Sys.time()' >> ${RMD}
  echo 'print(params$fit_res$data, full = TRUE)' >> ${RMD}
  echo 'print(params$w_ref, full = TRUE)' >> ${RMD}
  echo 'print(argg)' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}
  echo '# {-}' >> ${RMD}
  echo '' >> ${RMD}
  echo '**Please cite the following if you found ABfit and spant useful in your research:**' >> ${RMD}
  echo '' >> ${RMD}
  echo 'Wilson M. Adaptive baseline fitting for 1H MR spectroscopy analysis. Magn Reson Med. 2021 Jan;85(1):13-29. https://doi.org/10.1002/mrm.28385  ' >> ${RMD}
  echo '' >> ${RMD}
  echo 'Wilson, M. spant: An R package for magnetic resonance spectroscopy analysis. Journal of Open Source Software. 2021 6(67), 3646. https://doi.org/10.21105/joss.03646  ' >> ${RMD}
  echo '' >> ${RMD}
  echo 'Wilson M. Robust retrospective frequency and phase correction for single-voxel MR spectroscopy. Magn Reson Med. 2019 May;81(5):2878-2886. https://doi.org/10.1002/mrm.27605' >> ${RMD}

  ## knit RMD
  Rscript -e "Sys.setenv(RSTUDIO_PANDOC=\"/usr/bin/pandoc\"); rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>> HTML summary of ${PIPE}${FLOW} generated:"
    echo -e "\t${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}.html"
  fi
fi

#  Save results ----------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>saving fit"; fi
mkdir -p ${DIR_SAVE}/mrs
cp ${DIR_SCRATCH}/spant/fit_res_tCr_ratio.csv ${DIR_SAVE}/mrs/${IDPFX}_ratio-tCr_MRSfit.csv
cp ${DIR_SCRATCH}/spant/fit_res_unscaled.csv ${DIR_SAVE}/mrs/${IDPFX}_MRSfit.csv
cp ${DIR_SCRATCH}/spant/svs_results.rds ${DIR_SAVE}/mrs/${IDPFX}_MRSfit.rds

if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>saving VOI"; fi
mkdir -p ${DIR_SAVE}/mrs/mask
cp ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.* ${DIR_SAVE}/mrs/mask/

mkdir -p ${DIR_SAVE}/xfm/${IDDIR}
cp ${DIR_SCRATCH}/xfm/* ${DIR_SAVE}/xfm/${IDDIR}/

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> QC check file status set"
fi

#===============================================================================
# End of Function
#===============================================================================
exit 0
