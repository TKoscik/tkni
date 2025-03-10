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
mrs:,mrs-loc:,mrs-mask:,native:,native-mask:,tissue:,tissue-val:,\
no-hsvd,no-eddy,no-dfp,\
dir-save:,dir-scratch:,requires:,\
help,verbose,force,no-png,no-rmd -n 'parse-options' -- "$@")
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
NATIVE=
NATIVE_MASK=
TISSUE=
TISSUE_VAL="1;2,3;4"

COREG_RECIPE="intermodalSyn"
NO_HSVD=
NO_EDDY=
NO_DFP=

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
    --native) NATIVE="$2" ; shift 2 ;;
    --native-mask) NATIVE_MASK="$2" ; shift 2 ;;
    --tissue) TISSUE="$2" ; shift 2 ;;
    --tissue-val) TISSUE_VAL="$2" ; shift 2 ;;
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
if [[ -z ${BDIR} ]]; then BDIR=${DIR_PROJECT}/derivatives/${PIPE}/anat/native; fi
if [[ -z ${BIMG} ]]; then BIMG=${BDIR}/${IDPFX}_${BMOD}.nii.gz; fi
if [[ ! -f ${BIMG} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] Base image not found."
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
if [[ -z ${MRS} ]]; then
  MRS=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/*PRESS35.dat))
fi
if [[ ! -f ${MRS} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] MRS data not found."
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
  NATIVE=${DIR_PROJECT}/derivatives/${PIPE}/${FLOW}/native/${IDPFX}_T1w.nii.gz
fi
if [[ ! -f ${NATIVE} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] NATIVE image not found."
  exit 2
fi

if [[ -z ${NATIVE_MASK} ]]; then
  NATIVE_MASK=${DIR_PROJECT}/derivatives/${PIPE}/${FLOW}/mask/${IDPFX}_mask-brain.nii.gz
fi
if [[ ! -f ${NATIVE_MASK} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] NATIVE_MASK image not found."
  exit 3
fi

if [[ -z ${TISSUE} ]]; then
  TISSUE=${DIR_PROJECT}/derivatives/${PIPE}/${FLOW}/label/${IDPFX}_label-tissue.nii.gz
fi
if [[ ! -f ${TISSUE} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] TISSUE segmentation not found."
  exit 4
fi

# set directories --------------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}; fi
mkdir -p ${DIR_SCRATCH}

# Copy data to scratch and gunzip as needed ------------------------------------


# Coregister anatomical localizer to NATIVE ------------------------------------
## get brain mask for localizer to focus registration, if not provided
if [[ -z ${MRS_MASK} ]]; then
  MRS_MASK=${DIR_SCRATCH}/mrs-localizer_mask-brain.nii.gz
  mri_synthstrip -i ${MRS_LOC} -m ${MRS_MASK}
fi

## run coregistation
TMOD=($(getField -i ${MRS_LOC} -f modality))
coregistrationChef --recipe-name ${COREG_RECIPE} \
  --fixed ${NATIVE} --fixed-mask ${NATIVE_MASK} \
  --moving ${MRS_LOC} --moving-mask ${MRS_MASK} \
  --space-target "fixed" --interpolation "Linear" \
  --prefix ${IDPFX} --label-from "mrs" --label-to "native" \
  --dir-save ${DIR_SCRATCH} \
  --dir-xfm ${DIR_SCRATCH}/xfm --no-png
XFM_AFF=${DIR_SCRATCH}/xfm/${IDPFX}_mod-${TMOD}_from-mrs_to-native_xfm-affine.mat
XFM_SYN=${DIR_SCRATCH}/xfm/${IDPFX}_mod-${TMOD}_from-mrs_to-native_xfm-syn.nii.gz
XFM_INV=${DIR_SCRATCH}/xfm/${IDPFX}_mod-${TMOD}_from-mrs_to-native_xfm-syn+inverse.nii.gz
XFM_FWD_STR="-t identity"
XFM_REV_STR="-t identity"
if [[ -f ${XFM_SYN} ]]; then XFM_FWD_STR="${XFM_FWD_STR} -t ${XFM_SYN}"; fi
if [[ -f ${XFM_AFF} ]]; then
  XFM_FWD_STR="${XFM_FWD_STR} -t ${XFM_AFF}"
  XFM_REV_STR="${XFM_REV_STR} -t [${XFM_AFF},1]"
fi
if [[ -f ${XFM_INV} ]]; then XFM_REV_STR="${XFM_REV_STR} -t ${XFM_INV}"; fi

# get MRS VOI in native space --------------------------------------------------
Rscript "getMRSvoi" "nii" ${MRS_LOC} "mrs" ${MRS} \
  "file" ${IDPFX}_mask-mrsVOI "dir.save" ${DIR_SCRATCH}
gzip ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  -r ${NATIVE} ${XFM_FWD_STR}
make3Dpng --bg ${NATIVE} --bg-thresh "2.5,97.5" \
  --fg ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  --fg-mask ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz \
  --fg-color "timbow:hue=#00FF00:lum=65,65:cyc=1/6" --fg-cbar "false" \
  --filename ${IDPFX}_mask-mrsVOI --dir-save ${DIR_SCRATCH}

# Calculate partial volumes from tissue segmentation within VOI ----------------
## split tisse segmentation into CSF, GM, and WM components
TVALS=(${TISSUE_VAL//;/ })
CSF=(${TVALS[0]//,/ })
TCSF=${DIR_SCRATCH}/mask-csf.nii.gz
niimath ${TISSUE} -mul 0 ${TCSF}
for (( i=0; i<${#CSF[@]}; i++ )); do
  niimath ${TISSUE} -thr ${CSF[${i}]} -uthr ${CSF[${i}]} -bin -add ${TCSF} ${TCSF} -odt char
done
COUNT_CSF=$(3DBrickStat -sum ${TCSF})

GM=(${TVALS[1]//,/ })
TGM=${DIR_SCRATCH}/mask-gm.nii.gz
niimath ${TISSUE} -mul 0 ${TGM}
for (( i=0; i<${#GM[@]}; i++ )); do
  niimath ${TISSUE} -thr ${GM[${i}]} -uthr ${GM[${i}]} -bin -add ${TGM} ${TGM} -odt char
done
COUNT_GM=$(3DBrickStat -sum ${TGM})

WM=(${TVALS[2]//,/ })
TWM=${DIR_SCRATCH}/mask-wm.nii.gz
niimath ${TISSUE} -mul 0 ${TWM}
for (( i=0; i<${#WM[@]}; i++ )); do
  niimath ${TISSUE} -thr ${WM[${i}]} -uthr ${WM[${i}]} -bin -add ${TWM} ${TWM} -odt char
done
COUNT_WM=$(3DBrickStat -sum ${TWM})

TOTAL_V=$(echo "scale=0; ${COUNT_CSF} + ${COUNT_GM} + ${COUNT_WM}" | bc -l)
CSF_PCT=$(echo "scale=4; ${COUNT_CSF} / ${TOTAL_V} * 100" | bc -l)
GM_PCT=$(echo "scale=4; ${COUNT_GM} / ${TOTAL_V} * 100" | bc -l)
WM_PCT=$(echo "scale=4; ${COUNT_WM} / ${TOTAL_V} * 100" | bc -l)

#  Use SPANT to fit MRS spectrum -----------------------------------------------
#  (a) load MRS data from Siemens TWIX/dat file
#  (b) get VOI, push VOI to space of localizer
#  (c) use VOI in localizer space to get tissue composition
#  (d) output VOI to localizer space NIFF
#  (e) fit MRS data
#      - use HSVD water removal, eddy correction, and dynamic
#        frequency and phase correction.

Rscript fitMRS_spant.R "mrs" ${MRS} \
  "no-hsvd" ${NO_HSVD} "no-eddy" ${NO_EDDY} "no-dfp" ${NO_DFP} \
  "csf" ${CSF_PCT} "gm" ${GM_PCT} "wm" ${WM_PCT} \
  "dir.save" ${DIR_SCRATCH}

#  Save results ----------------------------------------------------------------
mkdir -p ${DIR_SAVE}/mrs
cp ${DIR_SCRATCH}/fit_res_tCr_ratio.csv ${DIR_SAVE}/mrs/${IDPFX}_ratio-tCr_MRSfit.csv
cp ${DIR_SCRATCH}/fit_res_unscaled.csv ${DIR_SAVE}/mrs/${IDPFX}_MRSfit.csv
cp ${DIR_SCRATCH}/report.html ${DIR_SAVE}/mrs/${IDPFX}_MRSfit.html

mkdir -p ${DIR_SAVE}/anat/mask
cp ${DIR_SCRATCH}/${IDPFX}_mask-mrsVOI.nii.gz ${DIR_SAVE}/anat/mask/
