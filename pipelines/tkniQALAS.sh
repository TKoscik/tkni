#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      QALAS
# DESCRIPTION:   TKNI processing pipeline for QALAS images
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-02-21
# README:
#     Procedure:
#     (1) Smooth B1 map, use scaled flip angle version, 10mm Gaussian kernel
#     (2) Correct QALAS volumes with B1 map
#         (ALT) If no B1 map, use N4. Estimate field map from each
#             volume, find mean and correct each volume with the mean field map
#     (3) Extract FG Mask
#     (4) Calculate constants: T1, T2, PDunscaled
#     (5) Push to Native Space
#     (6) Push to Normalized Space
#     (7) Scale PD map so ventricular CSF is 100%
#     (8) Synthesize desired MRI sequences
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
id:,dir-id:,qalas:,b1:,native:,brain:,csf:,\
opt-tr:,opt-fa:,opt-turbo:,opt-echo-spacing:,opt-t2prep:,opt-t1init:,opt-m0init:,\
b1k:,\
no-norm,atlas:atlas-xfm:,\
dir-scratch:,requires:,\
help,verbose,force,no-png,no-rmd -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
IDPFX=
IDDIR=

B1=
B1K=10

QALAS=
OPT_TR=4.5
OPT_FA=4
OPT_TURBO=5
OPT_ECHO_SPACING=0.0023
OPT_T2PREP=0.9
OPT_T1INIT=1.3
OPT_M0INIT=875

NATIVE=
BRAIN=
CSF=

NO_NORM="false"
ATLAS="/usr/local/tkni/atlas/adult/HCPYAX/HCPYAX_700um_T1w.nii.gz"
ATLAS_XFM=

SYNTH="T1w,T2w,FLAIR,MP2RAGE,DIR,TBE"

DIR_SAVE=
DIR_SCRATCH=

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES="tkniDICOM,tkniAINIT"
FORCE=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -n | --no-rmd) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --qalas) QALAS="$2" ; shift 2 ;;
    --opt-tr) OPT_TR="$2" ; shift 2 ;;
    --opt-fa) OPT_FA="$2" ; shift 2 ;;
    --opt-turbo) OPT_TURBO="$2" ; shift 2 ;;
    --opt-echo-spacing) OPT_ECHO_SPACING="$2" ; shift 2 ;;
    --opt-t2prep) OPT_T2PREP="$2" ; shift 2 ;;
    --opt-t1init) OPT_T1INIT="$2" ; shift 2 ;;
    --opt-m0init) OPT_M0INIT="$2" ; shift 2 ;;
    --b1) B1="$2" ; shift 2 ;;
    --b1k) B1K="$2" ; shift 2 ;;
    --native) NATIVE="$2" ; shift 2 ;;
    --brain) BRAIN="$2" ; shift 2 ;;
    --csf) CSF="$2" ; shift 2 ;;
    --no-denoise) NO_DENOISE="true" ; shift ;;
    --no-norm) NO_NORM="true" ; shift ;;
    --atlas) ATLAS="$2" ; shift 2 ;;
    --atlas-xfm) ATLAS_XFM="$2" ; shift 2 ;;
    --synth) SYNTH="$2" ; shift 2 ;;
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
  echo '  --id'
  echo '  --dir-id'
  echo '  --qalas'
  echo '  --b1'
  echo '  --native'
  echo '  --csf'
  echo '  --atlas'
  echo '  --atlas-xfm'
  echo '  --synth'
  echo '  --force'
  echo '  --requires'
  echo '  --dir-save'
  echo '  --dir-project'
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

# set directories --------------------------------------------------------------
DIR_RAW=${DIR_PROJECT}/rawdata/${IDDIR}
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
DIR_ANAT=${DIR_PIPE}/anat

mkdir -p ${DIR_SCRATCH}

# parse inputs -----------------------------------------------------------------
if [[ -z ${QALAS} ]]; then
  QALAS=${DIR_RAW}/anat/${IDPFX}_qalas.nii.gz
fi
if [[ ! -f ${QALAS} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] QALAS not found"
  exit 1
fi

if [[ -z ${B1} ]]; then
  B1=${DIR_RAW}/fmap/${IDPFX}_acq-sFlip_TB1TFL.nii.gz
fi
if [[ ! -f ${B1} ]]; then
  echo "WARNING [${PIPE}:${FLOW}] B1 not found, will use N4 method for bias estimation"
  B1="N4"
fi

if [[ -z ${NATIVE} ]]; then
  NATIVE=${DIR_PIPE}/anat/native/${IDPFX}_T1w.nii.gz
fi
if [[ ! -f ${NATIVE} ]]; then
  NATIVE=($(ls ${DIR_PIPE}/anat/native/${IDPFX}_*.nii.gz))
  if [[ ${#NATIVE[@]} -eq 0 ]]; then
    echo "ERROR [${PIPE}:${FLOW}] NATIVE image not found"
    exit 2
  fi
fi

if [[ -n ${CSF} ]]; then
  if [[ ! -f ${CSF} ]]; then
    echo "ERROR [${PIPE}:${FLOW}] CSF mask not found"
    echo "-provide existing binary mask or omit as function input to calculate"
    exit 3
  fi
fi

if [[ ${NO_NORM} == "false" ]]; fi
  if [[ ! -f ${ATLAS} ]]; then
    echo "ERROR [${PIPE}:${FLOW}] ATLAS reference image not found"
    exit 4
  fi
  if [[ -n ${ATLAS_XFM} ]]; then
    ATLAS_XFM=(${ATLAS_XFM//,/ })
    DO_EXIT="false"
    for (( i=0; i<${#ATLAS_XFM[@]}; i++ )); do
      if [[ ! -f ${ATLAS_XFM[${i}]} ]]; then
        echo "ERROR [${PIPE}:${FLOW}] ATLAS XFM ${ATLAS_XFM[${i}]} not found"
        DO_EXIT="true"
      fi
    done
    if [[ ${DO_EXIT} == "true" ]]; then exit 5; fi
  else
    TX=($(ls ${DIR_PIPE}/xfm/${IDDIR}/${IDPFX}_from-native*xfm-affine.mat))
    ATLAS_XFM+=(${TX[0]})
    TX=($(ls ${DIR_PIPE}/xfm/${IDDIR}/${IDPFX}_from-native*xfm-syn.nii.gz))
    ATLAS_XFM+=(${TX[0]})
  fi
fi

# Copy QALAS to scratch --------------------------------------------------------
cp ${QALAS} ${DIR_SCRATCH}
QALAS=${DIR_SCRATCH}/$(basename ${QALAS})
NVOL=$(niiInfo -i ${QALAS} -f volumes)

## IT MIGHT BE EASIER TO SPLIT INTO VOLUMES THEN PROCESS BETTER WITH EASIER 3D not 4D FUNCTIONS
if [[ ${NO_PNG} == "false" ]]; then
  montage_fcn="montage"
  for (( j=1; j<=${NVOL}; j++ )); do
    make3Dpng --bg ${QALAS} --bg-vol ${j} --bg-threshold "2.5,97.5" --filename t${j}
    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
  done
  montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
  montage_fcn=${montage_fcn}' -background "#FFFFFF"'
  montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_qalas_raw.png"
  eval ${montage_fcn}
  rm ${DIR_SCRATCH}/t*.png
fi

# Denoise Image ----------------------------------------------------------------
## *** MAYBE MOVE TO AFTER QUANTIFICATION OF T1 T2 and PD
#if [[ ${NO_DENOISE} == "false" ]]; then
#  DenoiseImage -d 4 -i ${QALAS} -o ${QALAS} -n Rician
#  if [[ ${NO_PNG} == "false" ]]; then
#    montage_fcn="montage"
#    for (( j=1; j<=${NVOL}; j++ )); do
#      make3Dpng --bg ${QALAS} --bg-vol ${j} --bg-threshold "2.5,97.5" --filename t${j}
#      montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
#    done
#    montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
#    montage_fcn=${montage_fcn}' -background "#FFFFFF"'
#    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_qalas_denoise.png"
#    eval ${montage_fcn}
#    rm ${DIR_SCRATCH}/t*.png
#  fi
#fi

# generate FG mask -------------------------------------------------------------
FG=${DIR_SCRATCH}/${IDPFX}_mask-fg+${FLOW}.nii.gz
3dAutomask -prefix ${FG} -clfrac 0.5 -q -dilate 3 -erode 3 ${QALAS}

# Process B1 map ---------------------------------------------------------------
## If not provided, use N4 method.
## If provided, apply smoothing kernel, then scale image by B1 map

if [[ -z ${B1} ]]; then
  N4BiasFieldCorrection -d 4 -x ${FG} -i ${QALAS} \
    -o [${QALAS},${DIR_SCRATCH}/${IDPFX}_biasfield.nii.gz]
else
  antsApplyTransforms -d 3 -n Linear -i ${B1} \
    -o ${DIR_SCRATCH}/${IDPFX}_proc-smooth${B1K}_B1.nii.gz \
    -t identity -r ${FG}
  niimath ${DIR_SCRATCH}/${IDPFX}_proc-smooth${B1K}_B1.nii.gz \
    -s ${B1K} ${DIR_SCRATCH}/${IDPFX}_proc-smooth${B1K}_B1.nii.gz
  RAWVAL=($(3dROIstats -mask ${FG} -sigma ${QALAS}))
  niimath ${QALAS} -div ${DIR_SCRATCH}/${IDPFX}_proc-smooth${B1K}_B1.nii.gz ${QALAS}
  NEWVAL=($(3dROIstats -mask ${FG} -sigma ${QALAS}))
fi
if [[ ${NO_PNG} == "false" ]]; then
  montage_fcn="montage"
  for (( j=1; j<=${NVOL}; j++ )); do
    make3Dpng --bg ${QALAS} --bg-vol ${j} --bg-threshold "2.5,97.5" --filename t${j}
    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
  done
  montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
  montage_fcn=${montage_fcn}' -background "#FFFFFF"'
  montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_qalas_debiased.png"
  eval ${montage_fcn}
  rm ${DIR_SCRATCH}/t*.png
fi

# Calculate constants: T1, T2, PDunscaled --------------------------------------
## *** ADD CODE TO COMBINE INTO 4D FILE
Rscript ${TKNIPATH}/R/qalasConstants.R \
  "tr" ${OPT_TR} \
  "fa" ${OPT_FA} \
  "turbo" ${OPT_TURBO} \
  "echo_spacing" ${OPT_ECHO_SPACING} \
  "t2prep" ${OPT_T2PREP} \
  "t1_init" ${OPT_T1INIT} \
  "m0_init" ${OPT_M0INIT} \
  "qalas" ${QALAS} \
  "mask" ${FG} \
  "prefix" ${IDPFX} \
  "dir_save" ${DIR_SCRATCH} \
  "dir_scratch" ${DIR_SCRATCH}/qalasConstants_tmp
gzip ${DIR_SCRATCH}/*.nii

# Coregister and Push to Native Space -----------------------------------------
coregistrationChef --recipe-name "intermodalSyn" \
  --fixed ${NATIVE} --moving ${DIR_SCRATCH}/${IDPFX}_T1.nii.gz \
  --prefix ${IDPFX} --label-from QALAS --label-to native \
  --dir-save ${DIR_SCRATCH}/tmp \
  --dir-xfm ${DIR_SCRATCH}/xfm --no-png

TXFM1=${DIR_SCRATCH}/xfm/${IDPFX}_from-QALAS_to-native_xfm-affine.mat
TXFM2=${DIR_SCRATCH}/xfm/${IDPFX}_from-QALAS_to-native_xfm-syn.nii.gz
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_SCRATCH}/${IDPFX}_T2.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_reg-native_T2.nii.gz \
  -t identity -t ${TXFM2} -t ${TXFM1} \
  -r ${NATIVE}
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_reg-native_PDunscaled.nii.gz \
  -t identity -t ${TXFM2} -t ${TXFM1} \
  -r ${NATIVE}

# Scale PD map so ventricular CSF is 100% --------------------------------------
if [[ -z ${CSF} ]]; then

fi

#     (8) Synthesize desired MRI sequences
