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
OPT_METHOD="Nelder-Mead"
CLAMP_T1="3"
CLAMP_T2="3"

NATIVE=
BRAIN=
CSF=

NO_NORM="false"
ATLAS="/usr/local/tkni/atlas/adult/HCPYAX/HCPYAX_700um_T1w.nii.gz"
ATLAS_XFM=

SYNTH="t2w-fse;t1w-gre;t1w-mp2rage;t2w-flair;dir;tbe"
#SYNTH="t2w-fse,te,0.08,tr,8;tbe,te,0.001,tr,5.02,ti,0.795"

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
QALAS_RAW=${DIR_SCRATCH}/$(modField -i $(basename ${QALAS}) -a -f prep -v raw)
cp ${QALAS} ${QALAS_RAW}
NVOL=$(niiInfo -i ${QALAS_RAW} -f volumes)
QPROC=${QALAS_RAW}

if [[ ${NO_PNG} == "false" ]]; then
  montage_fcn="montage"
  for (( j=1; j<=${NVOL}; j++ )); do
    make3Dpng --bg ${QALAS_RAW} --bg-vol ${j} --bg-threshold "2.5,97.5" --filename t${j}
    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
  done
  montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
  montage_fcn=${montage_fcn}' -background "#FFFFFF"'
  montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_prep-raw_qalas.png"
  eval ${montage_fcn}
  rm ${DIR_SCRATCH}/t*.png
fi

# Denoise Image ----------------------------------------------------------------
## *** MAYBE MOVE TO AFTER QUANTIFICATION OF T1 T2 and PD
if [[ ${NO_DENOISE} == "false" ]]; then
  DENOISE=$(modField -i ${QALAS_RAW} -m -f prep -v denoise)
  NOISE=$(modField -i ${QALAS_RAW} -m -f prep -v noise)
  DenoiseImage -d 4 -n Rician -i ${QALAS_RAW} -o [${DENOISE},${NOISE}]
  if [[ ${NO_PNG} == "false" ]]; then
    montage_fcn="montage"
    for (( j=1; j<=${NVOL}; j++ )); do
      make3Dpng --bg ${DENOISE} --bg-vol ${j} --bg-threshold "2.5,97.5" --filename t${j}
      montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
    done
    montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
    montage_fcn=${montage_fcn}' -background "#FFFFFF"'
    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_prep-denoise_qalas.png"
    eval ${montage_fcn}
    rm ${DIR_SCRATCH}/t*.png

    montage_fcn="montage"
    for (( j=1; j<=${NVOL}; j++ )); do
      make3Dpng --bg ${NOISE} --bg-vol ${j} --bg-color "virid-esque" --filename t${j}
      montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
    done
    montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
    montage_fcn=${montage_fcn}' -background "#FFFFFF"'
    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_prep-noise_qalas.png"
    eval ${montage_fcn}
    rm ${DIR_SCRATCH}/t*.png
  fi
  QPROC=${DENOISE}
fi

# generate FG mask -------------------------------------------------------------
FG=${DIR_SCRATCH}/${IDPFX}_mask-fg+${FLOW}.nii.gz
3dAutomask -prefix ${FG} -clfrac 0.5 -q -dilate 3 -erode 3 ${QPROC}
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${QPROC} --bg-threshold "2.5,97.5" \
    --fg ${FG} --fg-mask ${FG} --fg-alpha 50 \
    --fg-color "timbow:hue=#FF0000:sat=100;lum=35,85;rnd" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_mask-fg+${FLOW}
fi

# Process B1 map ---------------------------------------------------------------
## If not provided, use N4 method.
## If provided, apply smoothing kernel, then scale image by B1 map
DEBIAS=$(modField -i ${QALAS_RAW} -m -f prep -v debias)
BIAS=$(modField -i ${QALAS_RAW} -m -f prep -v bias)
if [[ -z ${B1} ]]; then
  N4BiasFieldCorrection -d 4 -x ${FG} -i ${QPROC} -o [${DEBIAS},${BIAS}]
else
  antsApplyTransforms -d 3 -n Linear -i ${B1} -o ${BIAS} -t identity -r ${FG}
  niimath ${BIAS} -s ${B1K} ${BIAS}
  for (( i=0; i<${NVOL}; i++ )); do
    3dcalc -a ${QPROC}[${i}] -expr a -prefix ${DIR_SCRATCH}/qvol${i}.nii.gz
    OV=($(3dROIstats -mask ${FG} -sigma ${DIR_SCRATCH}/qvol${i}.nii.gz))
    niimath ${DIR_SCRATCH}/qvol${i}.nii.gz -div ${BIAS} ${DIR_SCRATCH}/qvol${i}.nii.gz
    NV=($(3dROIstats -mask ${FG} -sigma ${DIR_SCRATCH}/qvol${i}.nii.gz))
    niimath ${DIR_SCRATCH}/qvol${i}.nii.gz \
      -sub ${NV[-2]} -div ${NV[-1]} \
      -mul ${OV[-1]} -add ${OV[-2]} \
      -thr 0 \
      ${DIR_SCRATCH}/qvol${i}.nii.gz
  done
  TTR=($(niiInfo -i ${QPROC} -f "TR"))
  ImageMath 4 ${DEBIAS} TimeSeriesAssemble ${TTR} 0 ${DIR_SCRATCH}/qvol*.nii.gz
  rm ${DIR_SCRATCH}/qvol*
fi
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${BIAS} --bg-color "plasma"
  montage_fcn="montage"
  for (( j=1; j<=${NVOL}; j++ )); do
    make3Dpng --bg ${DEBIAS} --bg-vol ${j} --bg-threshold "2.5,97.5" --filename t${j}
    montage_fcn="${montage_fcn} ${DIR_SCRATCH}/t${j}.png"
  done
  montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
  montage_fcn=${montage_fcn}' -background "#FFFFFF"'
  montage_fcn="${montage_fcn} ${DIR_SCRATCH}/${IDPFX}_prep-debias_qalas.png"
  eval ${montage_fcn}
  rm ${DIR_SCRATCH}/t*.png
fi
QPROC=${DEBIAS}

# Get brain masks --------------------------------------------------------------
for (( i=0; i<${NVOL}; i++ )); do
  3dcalc -a ${QPROC}[${i}] -expr a -prefix ${DIR_SCRATCH}/qvol${i}.nii.gz
  mri_synthstrip -i ${DIR_SCRATCH}/qvol${i}.nii.gz \
    -m ${DIR_SCRATCH}/mask-brain${i}.nii.gz
done
ImageMath 3 ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
  MajorityVoting ${DIR_SCRATCH}/mask-brain*.nii.gz
rm ${DIR_SCRATCH}/qvol*
rm ${DIR_SCRATCH}/mask-brain*
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${QPROC} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
    --fg-alpha 50 \
    --fg-color "timbow:hue=#FF0000:sat=100;lum=35,85;rnd" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_mask-brain+${FLOW}
fi

mri_synthstrip -i ${NATIVE} -m ${DIR_SCRATCH}/mask-brain+NATIVE.nii.gz
mri_synthstrip -i ${NATIVE} -m ${DIR_SCRATCH}/mask-brain+NATIVE+nocsf.nii.gz --no-csf
niimath ${DIR_SCRATCH}/mask-brain+NATIVE+nocsf.nii.gz \
  -binv -mas ${DIR_SCRATCH}/mask-brain+NATIVE.nii.gz \
  ${DIR_SCRATCH}/mask-csf+NATIVE.nii.gz

# Calculate constants: T1, T2, PDunscaled --------------------------------------
## *** ADD CODE TO COMBINE INTO 4D FILE
cp ${QPROC} ${DIR_SCRATCH}/${IDPFX}_qalas.nii.gz
QPROC=${DIR_SCRATCH}/${IDPFX}_qalas.nii.gz
Rscript ${TKNIPATH}/R/qalasConstants.R \
  "tr" ${OPT_TR} \
  "fa" ${OPT_FA} \
  "turbo" ${OPT_TURBO} \
  "echo_spacing" ${OPT_ECHO_SPACING} \
  "t2prep" ${OPT_T2PREP} \
  "t1_init" ${OPT_T1INIT} \
  "m0_init" ${OPT_M0INIT} \
  "optimizer" ${OPT_METHOD} \
  "qalas" ${QPROC} \
  "mask" ${FG} \
  "prefix" ${IDPFX} \
  "dir_save" ${DIR_SCRATCH} \
  "dir_scratch" ${DIR_SCRATCH}/qalasConstants_tmp
gzip ${DIR_SCRATCH}/*.nii

# Coregister and Push to Native Space -----------------------------------------
3dcalc -a ${QPROC}[2] -expr 'a' -prefix ${DIR_SCRATCH}/MOVING_QALAS.nii.gz
coregistrationChef --recipe-name "intermodalSyn" \
  --fixed ${NATIVE} --fixed-mask ${DIR_SCRATCH}/mask-brain+NATIVE.nii.gz \
  --moving ${DIR_SCRATCH}/MOVING_QALAS.nii.gz \
  --moving-mask ${DIR_SCRATCH}/${IDPFX}_mask-brain+QALAS.nii.gz \
  --space-target "fixed" --interpolation "Linear" \
  --prefix ${IDPFX} --label-from QALAS --label-to native \
  --dir-save ${DIR_SCRATCH} \
  --dir-xfm ${DIR_SCRATCH}/xfm --no-png
rm ${DIR_SCRATCH}/MOVING_QALAS.nii.gz

rename 's/mod-QALAS_//g' ${DIR_SCRATCH}/xfm/*
TXFM1=${DIR_SCRATCH}/xfm/${IDPFX}_from-QALAS_to-native_xfm-affine.mat
TXFM2=${DIR_SCRATCH}/xfm/${IDPFX}_from-QALAS_to-native_xfm-syn.nii.gz
IMG_T1=${DIR_SCRATCH}/${IDPFX}_T1map.nii.gz
IMG_T2=${DIR_SCRATCH}/${IDPFX}_T2map.nii.gz
IMG_PD=${DIR_SCRATCH}/${IDPFX}_PD.nii.gz
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_SCRATCH}/${IDPFX}_qalas_T1map.nii.gz \
  -o ${IMG_T1} \
  -t identity -t ${TXFM2} -t ${TXFM1} \
  -r ${NATIVE}
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_SCRATCH}/${IDPFX}_qalas_T2map.nii.gz \
  -o ${IMG_T2} \
  -t identity -t ${TXFM2} -t ${TXFM1} \
  -r ${NATIVE}
antsApplyTransforms -d 3 -n Linear \
  -i ${DIR_SCRATCH}/${IDPFX}_qalas_PDunscaled.nii.gz \
  -o ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
  -t identity -t ${TXFM2} -t ${TXFM1} \
  -r ${NATIVE}

# Clamp T1 and T2 values to realistic ranges -----------------------------------
if [[ "${CLAMP_T1}" != "false" ]]; then
  niimath ${IMG_T1} -thr ${CLAMP_T1} -bin -mul ${CLAMP_T1} ${DIR_SCRATCH}/tclamp.nii.gz
  niimath ${IMG_T1} -thr 0 -uthr ${CLAMP_T1} -add ${DIR_SCRATCH}/tclamp.nii.gz ${IMG_T1}
fi

if [[ "${CLAMP_T2}" != "false" ]]; then
  niimath ${IMG_T2} -thr ${CLAMP_T2} -bin -mul ${CLAMP_T2} ${DIR_SCRATCH}/tclamp.nii.gz
  niimath ${IMG_T2} -thr 0 -uthr ${CLAMP_T2} -add ${DIR_SCRATCH}/tclamp.nii.gz ${IMG_T2}
fi

# Scale PD map so ventricular CSF is 100% --------------------------------------
TMASK=${DIR_SCRATCH}/mask-brain+NATIVE+nocsf.nii.gz
T2HI=($(3dBrickStat -mask ${TMASK} -perclist 1 97.5 ${IMG_T2}))
niimath ${IMG_T2} -thr ${T2HI[-1]} -bin -mas ${TMASK} -kernel boxv 1 -ero \
  ${DIR_SCRATCH}/${IDPFX}_mask-csf+${FLOW}.nii.gz
PD975=($(3dBrickStat -mask ${DIR_SCRATCH}/${IDPFX}_mask-csf+${FLOW}.nii.gz \
  -perclist 1 97.5 \
  ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz))
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${QPROC} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_mask-csf+${FLOW}.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_mask-csf+${FLOW}.nii.gz \
    --fg-alpha 50 \
    --fg-color "timbow:hue=#FF0000:sat=100;lum=35,85;rnd" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_mask-csf+${FLOW}
fi

niimath ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
  -thr ${PD975[-1]} -bin -mul ${PD975[-1]} \
  ${DIR_SCRATCH}/tclamp.nii.gz
niimath ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
  -thr 0 -uthr ${PD975[-1]} -add ${DIR_SCRATCH}/tclamp.nii.gz \
  -div ${PD975[-1]} \
  ${IMG_PD}

if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${NATIVE} --bg-thresh "2.5,97.5" \
    --bg-color "timbow:hue=#00FF00:lum=0,100:cyc=1/6" \
    --fg ${IMG_T1} --fg-threshold "2.5,97.5" \
      --fg-color "timbow:hue=#FF00FF:lum=0,100:cyc=1/6" \
      --fg-alpha 50 \
      --fg-cbar "false" \
    --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
    --filename ${IDPFX}_coregistration \
    --dir-save ${DIR_SCRATCH}/xfm

  make3Dpng --bg ${IMG_T1} --bg-thresh "2.5,97.5"
  make3Dpng --bg ${IMG_T2} --bg-thresh "2.5,97.5"
  make3Dpng --bg ${IMG_PD} --bg-thresh "2.5,97.5"
fi

# Synthesize desired MRI sequences ---------------------------------------------
SYNTH=(${SYNTH//;/ })
for (( i=0; i<${#SYNTH[@]}; i++ )) do
  if [[ ${SYNTH[${i}],,} == *"t2w-fse"* ]]; then
    PARAMS=(${SYNTH[${i}]//,/ })
    TR=8
    TE=0.08
    for (( j=1; j<${#PARAMS[@]}; j++ )); do
      if [[ ${PARAMS[${j}]^^} == *"TE"* ]]; then TE=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TR"* ]]; then TR=${PARAMS[$((${j}+1))]}; fi
    done
    if [[ ${VERBOSE} == "true" ]]; then
      echo "MSG [${PIPE}:${FLOW}] SYNTHESIZING: ${PARAMS[0]}"
      echo -e "\tTE=${TE}"
      echo -e "\tTR=${TR}"
    fi
    3dcalc -a ${IMG_T1} -b ${IMG_T2} -c ${IMG_PD} \
      -expr 'c*((1-exp(-'${TR}'/a))*exp('${TE}'/b))' \
      -prefix ${DIR_SCRATCH}/${IDPFX}_acq-FSE_synthT2w.nii.gz
  fi

  if [[ ${SYNTH[${i}],,} == *"t1w-gre"* ]]; then
    PARAMS=(${SYNTH[${i}]//,/ })
    TR=0.113
    TE=0
    for (( j=1; j<${#PARAMS[@]}; j++ )); do
      if [[ ${PARAMS[${j}]^^} == *"TE"* ]]; then TE=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TR"* ]]; then TR=${PARAMS[$((${j}+1))]}; fi
    done
    if [[ ${VERBOSE} == "true" ]]; then
      echo "MSG [${PIPE}:${FLOW}] SYNTHESIZING: ${PARAMS[0]}"
      echo -e "\tTE=${TE}"
      echo -e "\tTR=${TR}"
    fi
    3dcalc -a ${IMG_T1} -b ${IMG_T2} -c ${IMG_PD} \
      -expr 'c*((1-exp(-'${TR}'/a))*exp('${TE}'/b))' \
      -prefix ${DIR_SCRATCH}/${IDPFX}_acq-GRE_synthT1w.nii.gz
  fi

  if [[ ${SYNTH[${i}],,} == *"t1w-mp2rage"* ]]; then
    PARAMS=(${SYNTH[${i}]//,/ })
    TI=1.816
    for (( j=1; j<${#PARAMS[@]}; j++ )); do
      if [[ ${PARAMS[${j}]^^} == *"TI"* ]]; then TI=${PARAMS[$((${j}+1))]}; fi
    done
    if [[ ${VERBOSE} == "true" ]]; then
      echo "MSG [${PIPE}:${FLOW}] SYNTHESIZING: ${PARAMS[0]}"
      echo -e "\tTI=${TI}"
    fi
    3dcalc -a ${IMG_T1} \
      -expr '1-2*exp(-'${TI}'/a)' \
      -prefix ${DIR_SCRATCH}/${IDPFX}_acq-MP2RAGE_synthT1w.nii.gz
  fi

  if [[ ${SYNTH[${i}],,} == *"t2w-flair"* ]]; then
    PARAMS=(${SYNTH[${i}]//,/ })
    TI=2.075
    TE=0.08
    TSAT=1.405
    for (( j=1; j<${#PARAMS[@]}; j++ )); do
      if [[ ${PARAMS[${j}]^^} == *"TE"* ]]; then TE=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TI"* ]]; then TI=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TSAT"* ]]; then TSAT=${PARAMS[$((${j}+1))]} fi
    done
    if [[ ${VERBOSE} == "true" ]]; then
      echo "MSG [${PIPE}:${FLOW}] SYNTHESIZING: ${PARAMS[0]}"
      echo -e "\tTE=${TE}"
      echo -e "\tTI=${TI}"
      echo -e "\tTSAT=${TSAT}"
    fi
    3dcalc -a ${IMG_T1} -b ${IMG_T2} -c ${IMG_PD} \
      -expr 'abs(c)*exp(-'${TSAT}'/a)*exp(-'${TE}'/b)*(1-2*exp(-'${TI}'/a))' \
      -prefix ${DIR_SCRATCH}/${IDPFX}_synthFLAIR.nii.gz
  fi

  if [[ ${SYNTH[${i}],,} == *"dir"* ]]; then
    PARAMS=(${SYNTH[${i}]//,/ })
    TI1=2.208
    TI2=0.545
    TE=0.08
    TR=6.67
    for (( j=1; j<${#PARAMS[@]}; j++ )); do
      if [[ ${PARAMS[${j}]^^} == *"TE"* ]]; then TE=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TI1"* ]]; then TI1=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TI2"* ]]; then TI2=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TR"* ]]; then TR=${PARAMS[$((${j}+1))]}; fi
    done
    if [[ ${VERBOSE} == "true" ]]; then
      echo "MSG [${PIPE}:${FLOW}] SYNTHESIZING: ${PARAMS[0]}"
      echo -e "\tTE=${TE}"
      echo -e "\tTI1=${TI1}"
      echo -e "\tTI2=${TI2}"
      echo -e "\tTR=${TR}"
    fi
    3dcalc -a ${IMG_T1} -b ${IMG_T2} -c ${IMG_PD} \
      -expr 'abs((c)*(1-2*exp(-'${TI2}'/a)+2*exp(-('${TI1}'+'${TI2}')/a)-exp(-'${TR}'/a)))*(exp(-'${TE}'/b))' \
      -prefix ${DIR_SCRATCH}/${IDPFX}_synthDIR.nii.gz
  fi

  if [[ ${SYNTH[${i}],,} == *"tbe"* ]]; then
    PARAMS=(${SYNTH[${i}]//,/ })
    TI=0.795
    TE=0.001
    TR=5.02
    for (( j=1; j<${#PARAMS[@]}; j++ )); do
      if [[ ${PARAMS[${j}]^^} == *"TE"* ]]; then TE=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TI"* ]]; then TI=${PARAMS[$((${j}+1))]}; fi
      if [[ ${PARAMS[${j}]^^} == *"TR"* ]]; then TR=${PARAMS[$((${j}+1))]}; fi
    done
    if [[ ${VERBOSE} == "true" ]]; then
      echo "MSG [${PIPE}:${FLOW}] SYNTHESIZING: ${PARAMS[0]}"
      echo -e "\tTE=${TE}"
      echo -e "\tTI=${TI}"
      echo -e "\tTR=${TR}"
    fi
    3dcalc -a ${IMG_T1} -b ${IMG_T2} -c ${IMG_PD} \
      -expr 'abs(c*(1-2*exp(-'${TI}'/a))*(1-exp(-'${TR}'/a))*exp(-'${TE}'/b))' \
      -prefix ${DIR_SCRATCH}/${IDPFX}_synthTBE.nii.gz
  fi
done

if [[ ${NO_PNG} == "false" ]]; then
  FLS=($(ls ${DIR_SCRATCH}/*synth*.nii.gz))
  for (( i=0; i<${#FLS[@]}; i++ )); do
    make3Dpng --bg ${FLS[${i}]} --bg-thresh "2.5,97.5"
  done
fi

# Save outputs -----------------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PIPE}
fi

if [[ ${KEEP_CLEANED} == "true" ]]; then
  mkdir -p ${DIR_SAVE}/anat/cleaned
  mv ${QPROC} ${DIR_SAVE}/anat/cleaned/
fi

mkdir -p ${DIR_SAVE}/anat/native
mv ${DIR_SCRATCH}/${IDPFX}_T1map.nii.gz ${DIR_SAVE}/anat/native/
mv ${DIR_SCRATCH}/${IDPFX}_T1map.png ${DIR_SAVE}/anat/native/
mv ${DIR_SCRATCH}/${IDPFX}_T2map.nii.gz ${DIR_SAVE}/anat/native/
mv ${DIR_SCRATCH}/${IDPFX}_T2map.png ${DIR_SAVE}/anat/native/
mv ${DIR_SCRATCH}/${IDPFX}_PD.nii.gz ${DIR_SAVE}/anat/native/
mv ${DIR_SCRATCH}/${IDPFX}_PD.png ${DIR_SAVE}/anat/native/

mv ${DIR_SCRATCH}/${IDPFX}*synth* ${DIR_SAVE}/anat/native/

mkdir -p ${DIR_SAVE}/anat/mask/${FLOW}
mv ${DIR_SCRATCH}/${IDPFX}_mask* ${DIR_SAVE}/anat/mask/${FLOW}

mkdir -p ${DIR_SAVE}/xfm/${IDDIR}
mv ${DIR_SCRATCH}/xfm/* ${DIR_SAVE}/xfm/${IDDIR}/

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

  echo '## QALAS Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### QALAS Processing Results' >> ${RMD}

  ## T1 ---------------------------------------------------------------------------
  echo '### T1 map' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native/${IDPFX}_T1map.nii.gz
  TPNG=${DIR_ANAT}/native/${IDPFX}_T1map.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  ## T2 ---------------------------------------------------------------------------
  echo '### T2 map' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native/${IDPFX}_T2map.nii.gz
  TPNG=${DIR_ANAT}/native/${IDPFX}_T2map.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  ## PD ---------------------------------------------------------------------------
  echo '### Proton Density (PD)' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native/${IDPFX}_PD.nii.gz
  TPNG=${DIR_ANAT}/native/${IDPFX}_PD.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  ## Synthesized Images
  echo '### Synthesized Images {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  NIILS=($(ls ${DIR_SAVE}/anat/${IDPFX}*synth*.nii.gz))
  for (( i=0; i<${#NIILS[@]}; i++ )); do
    TNII=$(basename ${NIILS[${i}]})
    FNAME=${BNAME//\.nii\.gz}
    TPNG=${DIR_SAVE}/anat/${FNAME}.png
    SFX=${FNAME//${IDPFX}_}
    echo "#### ${SFX}" >> ${RMD}
    if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
    echo '!['${TNII}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
  done

  ## Processing
  echo '### Processing Steps {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### Raw QALAS' >> ${RMD}
  TPNG=${DIR_SCRATCH}/${IDPFX}_prep-raw_qalas.png
  echo '![Raw QALAS]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Denoising' >> ${RMD}
  echo '![Denoised QALAS]('${DIR_SCRATCH}/${IDPFX}_prep-denoise_qalas.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '![Noise]('${DIR_SCRATCH}/${IDPFX}_prep-noise_qalas.png')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### FG Mask' >> ${RMD}
  TPNG=${DIR_SAVE}/anat/mask/${FLOW}/${IDPFX}_mask-fg+${FLOW}.png
  echo '![FG Mask]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Debias' >> ${RMD}
  echo '![Debiased QALAS]('${DIR_SCRATCH}/${IDPFX}_prep-debias_qalas.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '![Bias Field]('${DIR_SCRATCH}/${IDPFX}_prep-bias_qalas.png')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Brain Mask' >> ${RMD}
  TPNG=${DIR_SAVE}/anat/mask/${FLOW}/${IDPFX}_mask-brain+${FLOW}.png
  echo '![Brain Mask]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### CSF Mask' >> ${RMD}
  TPNG=${DIR_SAVE}/anat/mask/${FLOW}/${IDPFX}_mask-csf+${FLOW}.png
  echo '![CSF Mask]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Coregistration' >> ${RMD}
  TPNG=${DIR_SAVE}/xfm/${IDDIR}/${IDPFX}_coregistration.png
  echo '![Coregistration to Native]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  ## knit RMD
  Rscript -e "Sys.setenv(RSTUDIO_PANDOC=\"/usr/bin/pandoc\"); rmarkdown::render('${RMD}')"
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
