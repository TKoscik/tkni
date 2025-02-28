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
no-b1:,b1k:,do-n4:,\
no-denoise,no-norm,atlas:atlas-xfm:,\
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

NO_B1="false"
DO_N4="false"
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

NO_DENOISE="false"
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
KEEP_CLEANED=true

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
    --no-b1) NO_B1="true" ; shift ;;
    --do-n4) DO_N4="true" ; shift ;;
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

if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Directories Setup"; fi

# parse inputs -----------------------------------------------------------------
if [[ -z ${QALAS} ]]; then
  QALAS=${DIR_RAW}/anat/${IDPFX}_qalas.nii.gz
fi
if [[ ! -f ${QALAS} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] QALAS not found"
  exit 1
fi
if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Processing QALAS: ${QALAS}"; fi

if [[ ${NO_B1,,} == "false" ]]; then
  if [[ -z ${B1} ]]; then
    B1=${DIR_RAW}/fmap/${IDPFX}_acq-sFlip_TB1TFL.nii.gz
  fi
  if [[ ! -f ${B1} ]]; then
    echo "WARNING [${PIPE}:${FLOW}] B1 not found"
  fi
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Using B1: ${B1}"; fi
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

if [[ ${NO_NORM} == "false" ]]; then
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
TR=$(niiInfo -i ${QALAS_RAW} -f tr)
unset QPROC

# Split QALAS into volumes -----------------------------------------------------
for (( i=0; i<${NVOL}; i++ )); do
  QPROC+=(${DIR_SCRATCH}/q${i}_raw.nii.gz)
  3dcalc -a ${QALAS_RAW}[${i}] -expr 'a' -prefix ${QPROC[${i}]}
  if [[ ${NO_PNG} == "false" ]]; then
    make3Dpng --bg ${QPROC[${i}]} --bg-threshold "2.5,97.5"
  fi
done
if [[ ${NO_PNG} == "false" ]]; then
  montage ${DIR_SCRATCH}/q*_raw.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-raw_qalas.png
  rm ${DIR_SCRATCH}/q*_raw.png
fi

# Denoise Image ----------------------------------------------------------------
if [[ ${NO_DENOISE} == "false" ]]; then
  for (( i=0; i<${NVOL}; i++ )); do
    DenoiseImage -d 3 -n Rician -i ${QPROC[${i}]} \
      -o [${DIR_SCRATCH}/q${i}_denoise.nii.gz,${DIR_SCRATCH}/q${i}_noise.nii.gz]
    ## Correct output spacing that gets messed up by ANTs
    antsApplyTransforms -d 3 -n Linear \
      -i ${DIR_SCRATCH}/q${i}_denoise.nii.gz \
      -o ${DIR_SCRATCH}/q${i}_denoise.nii.gz \
      -r ${QPROC[${i}]}
    antsApplyTransforms -d 3 -n Linear \
      -i ${DIR_SCRATCH}/q${i}_noise.nii.gz \
      -o ${DIR_SCRATCH}/q${i}_noise.nii.gz \
      -r ${QPROC[${i}]}
    if [[ ${NO_PNG} == "false" ]]; then
      make3Dpng --bg ${DIR_SCRATCH}/q${i}_denoise.nii.gz --bg-threshold "2.5,97.5"
      make3Dpng --bg ${DIR_SCRATCH}/q${i}_noise.nii.gz --bg-color "virid-esque"
    fi
    QPROC[${i}]="${DIR_SCRATCH}/q${i}_denoise.nii.gz"
  done
  if [[ ${NO_PNG} == "false" ]]; then
    montage ${DIR_SCRATCH}/q*_denoise.png \
      -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
      ${DIR_SCRATCH}/${IDPFX}_prep-denoise_qalas.png
    rm ${DIR_SCRATCH}/q*_denoise.png
    montage ${DIR_SCRATCH}/q*_noise.png \
      -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
      ${DIR_SCRATCH}/${IDPFX}_prep-noise_qalas.png
    rm ${DIR_SCRATCH}/q*_noise.png
  fi
fi

# generate FG mask -------------------------------------------------------------
FG=${DIR_SCRATCH}/${IDPFX}_mask-fg+${FLOW}.nii.gz
for (( i=0; i<${NVOL}; i++ )); do
  3dAutomask -prefix ${DIR_SCRATCH}/fg${i}.nii.gz -clfrac 0.5 -q ${QPROC[${i}]}
done
ImageMath 3 ${FG} MajorityVoting ${DIR_SCRATCH}/fg*.nii.gz
rm ${DIR_SCRATCH}/fg*.nii.gz
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${QPROC[0]} --bg-threshold "2.5,97.5" \
    --fg ${FG} --fg-mask ${FG} --fg-alpha 50 --fg-cbar "false" \
    --fg-color "timbow:hue=#FF0000:sat=100:lum=65,65:cyc=1/6" \
    --layout "9:x;9:x;9:x;9:x;9:x" \
    --filename ${IDPFX}_mask-fg+${FLOW}
fi

# Debias Image ---------------------------------------------------------------
## If not provided, use N4 method.
## If provided, apply smoothing kernel, then scale image by B1 map
if [[ -n ${B1} ]]; then NO_B1="false"; fi
if [[ ${NO_B1,,} == "false" ]]; then
  BIAS=${DIR_SCRATCH}/${IDPFX}_prep-biasB1_qalas.nii.gz
  antsApplyTransforms -d 3 -n Linear -i ${B1} -o ${BIAS} -t identity -r ${FG}
  niimath ${BIAS} -s ${B1K} ${BIAS}
  for (( i=0; i<${NVOL}; i++ )); do
    OV=($(3dROIstats -mask ${FG} -sigma ${QPROC[${i}]}))
    niimath ${QPROC[${i}]} -div ${BIAS} ${DIR_SCRATCH}/q${i}_debiasB1.nii.gz
    NV=($(3dROIstats -mask ${FG} -sigma ${DIR_SCRATCH}/q${i}_debiasB1.nii.gz))
    niimath ${DIR_SCRATCH}/q${i}_debiasB1.nii.gz \
      -sub ${NV[-2]} -div ${NV[-1]} -mul ${OV[-1]} -add ${OV[-2]} -thr 0 \
      ${DIR_SCRATCH}/q${i}_debiasB1.nii.gz
    if [[ ${NO_PNG} == "false" ]]; then
      make3Dpng --bg ${DIR_SCRATCH}/q${i}_debiasB1.nii.gz --bg-threshold "2.5,97.5"
    fi
    QPROC[${i}]="${DIR_SCRATCH}/q${i}_debiasB1.nii.gz"
  done
  if [[ ${NO_PNG} == "false" ]]; then
    make3Dpng --bg ${BIAS} --bg-color "plasma"
    montage ${DIR_SCRATCH}/q*_debiasB1.png \
      -tile 1x -geometry +0+0 -gravity center -background "#000000" \
      ${DIR_SCRATCH}/${IDPFX}_prep-debiasB1_qalas.png
    rm ${DIR_SCRATCH}/q*_debiasB1.png
  fi
fi

if [[ ${DO_N4,,} == "true" ]]; then
  for (( i=0; i<${NVOL}; i++ )); do
    N4BiasFieldCorrection -d 3 -x ${FG} -i ${QPROC[${i}]} \
      -o [${DIR_SCRATCH}/q${i}_debiasN4.nii.gz,${DIR_SCRATCH}/q${i}_biasN4.nii.gz]
    if [[ ${NO_PNG} == "false" ]]; then
      make3Dpng --bg ${DIR_SCRATCH}/q${i}_biasN4.nii.gz --bg-color "plasma"
      make3Dpng --bg ${DIR_SCRATCH}/q${i}_debiasN4.nii.gz --bg-threshold "2.5,97.5"
    fi
    QPROC[${i}]="${DIR_SCRATCH}/q${i}_debiasN4.nii.gz"
  done
  if [[ ${NO_PNG} == "false" ]]; then
    montage ${DIR_SCRATCH}/q*_debiasN4.png \
      -tile 1x -geometry +0+0 -gravity center -background "#000000" \
      ${DIR_SCRATCH}/${IDPFX}_prep-debiasN4_qalas.png
    montage ${DIR_SCRATCH}/q*_biasN4.png \
      -tile 1x -geometry +0+0 -gravity center -background "#000000" \
      ${DIR_SCRATCH}/${IDPFX}_prep-biasN4_qalas.png
    rm ${DIR_SCRATCH}/q*_debiasN4.png
    rm ${DIR_SCRATCH}/q*_biasN4.png
  fi
fi

# Get brain masks --------------------------------------------------------------
for (( i=0; i<${NVOL}; i++ )); do
  mri_synthstrip -i ${QPROC[${i}]} -m ${DIR_SCRATCH}/mask-brain${i}.nii.gz
done
ImageMath 3 ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
  MajorityVoting ${DIR_SCRATCH}/mask-brain*.nii.gz
rm ${DIR_SCRATCH}/mask-brain*
if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${QPROC} --bg-threshold "2.5,97.5" \
    --fg ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
    --fg-mask ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
    --fg-alpha 50 \
    --fg-color "timbow:hue=#FF0000:sat=100;lum=65,65" \
    --layout "9:x;9:x;9:x;9:x;9:x" \
    --filename ${IDPFX}_mask-brain+${FLOW}
fi

mri_synthstrip -i ${NATIVE} -m ${DIR_SCRATCH}/mask-brain+NATIVE.nii.gz
mri_synthstrip -i ${NATIVE} -m ${DIR_SCRATCH}/mask-brain+NATIVE+nocsf.nii.gz --no-csf
niimath ${DIR_SCRATCH}/mask-brain+NATIVE+nocsf.nii.gz \
  -binv -mas ${DIR_SCRATCH}/mask-brain+NATIVE.nii.gz \
  ${DIR_SCRATCH}/mask-csf+NATIVE.nii.gz

# Recombine volumes into time-series -------------------------------------------
ImageMath 4 ${DIR_SCRATCH}/${IDPFX}_qalas.nii.gz TimeSeriesAssemble ${TR} 0 ${QPROC[@]}

# Calculate constants: T1, T2, PDunscaled --------------------------------------
Rscript ${TKNIPATH}/R/qalasConstants.R \
  "tr" ${OPT_TR} \
  "fa" ${OPT_FA} \
  "turbo" ${OPT_TURBO} \
  "echo_spacing" ${OPT_ECHO_SPACING} \
  "t2prep" ${OPT_T2PREP} \
  "t1_init" ${OPT_T1INIT} \
  "m0_init" ${OPT_M0INIT} \
  "optimizer" ${OPT_METHOD} \
  "qalas" ${DIR_SCRATCH}/${IDPFX}_qalas.nii.gz \
  "mask" ${DIR_SCRATCH}/${IDPFX}_mask-brain+${FLOW}.nii.gz \
  "prefix" ${IDPFX} \
  "dir_save" ${DIR_SCRATCH} \
  "dir_scratch" ${DIR_SCRATCH}/qalasConstants_tmp
gzip ${DIR_SCRATCH}/*.nii

# Coregister and Push to Native Space -----------------------------------------
MIDVOL=$(printf %.0f $(echo "(${NVOL} / 2)" | bc -l))
cp ${QPROC[${MIDVOL}]} ${DIR_SCRATCH}/MOVING_QALAS.nii.gz
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
fi

## Tissue segmentation  (and improved rescaling PD to actual CSF) --------------
#Rscript ${TKNIPATH}/R/qmriMClust.R \
#  "n" 3 \
#  "t1" ${IMG_T1} \
#  "t2" ${IMG_T2} \
#  "pd" ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
#  "mask" ${DIR_SCRATCH}/mask-brain+NATIVE+nocsf.nii.gz \
#  "prefix" ${IDPFX} \
#  "dir_save" ${DIR_SCRATCH} \
#  "dir_scratch" ${DIR_SCRATCH}/qmriMClust_tmp
#gzip ${DIR_SCRATCH}/*.nii

# Scale PD map so ventricular CSF is 100% --------------------------------------
#TMASK=${DIR_SCRATCH}/${IDPFX}_mask-CSF+QMRI.nii.gz
#niimath ${DIR_SCRATCH}/${IDPFX}_label-tissue+QMRI.nii.gz -thr 3 -uthr 3 -bin ${TMASK}
#PD975=($(3dBrickStat -mask ${TMASK} -perclist 1 97.5 ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz))
#niimath ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
#  -thr ${PD975[-1]} -bin -mul ${PD975[-1]} \
#  ${DIR_SCRATCH}/tclamp.nii.gz
#niimath ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
#  -thr 0 -uthr ${PD975[-1]} -add ${DIR_SCRATCH}/tclamp.nii.gz \
#  -div ${PD975[-1]} -mul 1000 \
#  ${IMG_PD}

## clamp PD values to 99% of in brain values then rescale so this is 1000 -----
PD99=($(3dBrickStat -mask ${DIR_SCRATCH}/mask-brain+NATIVE.nii.gz \
  -perclist 1 99 ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz))
niimath ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
  -thr ${PD99[-1]} -bin -mul ${PD99[-1]} ${DIR_SCRATCH}/tclamp.nii.gz
niimath ${DIR_SCRATCH}/${IDPFX}_PDunscaled.nii.gz \
  -thr 0 -uthr ${PD99[-1]} -add ${DIR_SCRATCH}/tclamp.nii.gz \
  -div ${PD99[-1]} -mul 1000 \
  ${IMG_PD}

if [[ ${NO_PNG} == "false" ]]; then
  make3Dpng --bg ${IMG_T1}
  make3Dpng --bg ${IMG_T1} --layout "9:x;9:x;9:x;9:x;9:x" --filename ${IDPFX}_plane-sagittal_T1map
  make3Dpng --bg ${IMG_T1} --layout "9:y;9:y;9:y;9:y;9:y" --filename ${IDPFX}_plane-coronal_T1map
  make3Dpng --bg ${IMG_T1} --layout "9:z;9:z;9:z;9:z;9:z" --filename ${IDPFX}_plane-axial_T1map

  make3Dpng --bg ${IMG_T2}
  make3Dpng --bg ${IMG_T2} --layout "9:x;9:x;9:x;9:x;9:x" --filename ${IDPFX}_plane-sagittal_T2map
  make3Dpng --bg ${IMG_T2} --layout "9:y;9:y;9:y;9:y;9:y" --filename ${IDPFX}_plane-coronal_T2map
  make3Dpng --bg ${IMG_T2} --layout "9:z;9:z;9:z;9:z;9:z" --filename ${IDPFX}_plane-axial_T2map

  make3Dpng --bg ${IMG_PD}
  make3Dpng --bg ${IMG_PD} --layout "9:x;9:x;9:x;9:x;9:x" --filename ${IDPFX}_plane-sagittal_PD
  make3Dpng --bg ${IMG_PD} --layout "9:y;9:y;9:y;9:y;9:y" --filename ${IDPFX}_plane-coronal_PD
  make3Dpng --bg ${IMG_PD} --layout "9:z;9:z;9:z;9:z;9:z" --filename ${IDPFX}_plane-axial_PD
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
      if [[ ${PARAMS[${j}]^^} == *"TSAT"* ]]; then TSAT=${PARAMS[$((${j}+1))]}; fi
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
  mv ${DIR_SCRATCH}/${IDPFX}_qalas.nii.gz ${DIR_SAVE}/anat/cleaned/
fi

mkdir -p ${DIR_SAVE}/anat/native_qmri
mv ${DIR_SCRATCH}/${IDPFX}_T1map.nii.gz ${DIR_SAVE}/anat/native_qmri/
mv ${DIR_SCRATCH}/${IDPFX}_T1map.png ${DIR_SAVE}/anat/native_qmri/
mv ${DIR_SCRATCH}/${IDPFX}_T2map.nii.gz ${DIR_SAVE}/anat/native_qmri/
mv ${DIR_SCRATCH}/${IDPFX}_T2map.png ${DIR_SAVE}/anat/native_qmri/
mv ${DIR_SCRATCH}/${IDPFX}_PD.nii.gz ${DIR_SAVE}/anat/native_qmri/
mv ${DIR_SCRATCH}/${IDPFX}_PD.png ${DIR_SAVE}/anat/native_qmri/

mkdir -p ${DIR_SAVE}/anat/native_synth
mv ${DIR_SCRATCH}/${IDPFX}*synth* ${DIR_SAVE}/anat/native_synth/

mkdir -p ${DIR_SAVE}/anat/mask/${FLOW}
mv ${DIR_SCRATCH}/${IDPFX}_mask* ${DIR_SAVE}/anat/mask/${FLOW}

mkdir -p ${DIR_SAVE}/xfm/${IDDIR}
mv ${DIR_SCRATCH}/xfm/* ${DIR_SAVE}/xfm/${IDDIR}/

DIR_PREP="${DIR_SAVE}/prep/${IDDIR}/${PIPE}${FLOW}"
mkdir -p ${DIR_PREP}
mv ${DIR_SCRATCH}/*.png ${DIR_PREP}/

#mkdir -p ${DIR_SAVE}/anat/posterior/${FLOW}
#mv ${DIR_SCRATCH}/*posterior* ${DIR_SAVE}/anat/posterior/${FLOW}/

#mkdir -p ${DIR_SAVE}/label/${FLOW}
#mv ${DIR_SCRATCH}/*label-tissue.nii.gz ${DIR_SAVE}/label/${FLOW}/

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

  echo '## QALAS Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -----------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### QALAS Processing Results' >> ${RMD}

  ## T1 ------------------------------------------------------------------------
  echo '### T1 map' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native_qmri/${IDPFX}_T1map.nii.gz
  TPNG=${DIR_SAVE}/anat/native_qmri/${IDPFX}_T1map.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### T1map Slice Mosaics {.tabset}' >> ${RMD}
  echo '##### Click to View -->' >> ${RMD}
  echo '##### Axial' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-axial_T1map.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '##### Coronal' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-coronal_T1map.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '##### Sagittal' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-sagittal_T1map.png')' >> ${RMD}
  echo '' >> ${RMD}

  ## T2 ------------------------------------------------------------------------
  echo '### T2 map' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native_qmri/${IDPFX}_T2map.nii.gz
  TPNG=${DIR_SAVE}/anat/native_qmri/${IDPFX}_T2map.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### T2map Slice Mosaics {.tabset}' >> ${RMD}
  echo '##### Click to View -->' >> ${RMD}
  echo '##### Axial' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-axial_T2map.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '##### Coronal' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-coronal_T2map.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '##### Sagittal' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-sagittal_T2map.png')' >> ${RMD}
  echo '' >> ${RMD}

  ## PD ------------------------------------------------------------------------
  echo '### Proton Density (PD)' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native_qmri/${IDPFX}_PD.nii.gz
  TPNG=${DIR_SAVE}/anat/native_qmri/${IDPFX}_PD.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII} --bg-thresh "2.5,97.5"; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### PD Slice Mosaics {.tabset}' >> ${RMD}
  echo '##### Click to View -->' >> ${RMD}
  echo '##### Axial' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-axial_PD.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '##### Coronal' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-coronal_PD.png')' >> ${RMD}
  echo '' >> ${RMD}
  echo '##### Sagittal' >> ${RMD}
  echo '![Axial]('${DIR_PREP}/${IDPFX}_plane-sagittal_PD.png')' >> ${RMD}
  echo '' >> ${RMD}

  ## Synthesized Images --------------------------------------------------------
  echo '### Synthesized Images {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  NIILS=($(ls ${DIR_SAVE}/anat/native_synth/${IDPFX}*synth*.nii.gz))
  for (( i=0; i<${#NIILS[@]}; i++ )); do
    TNII=$(basename ${NIILS[${i}]})
    FNAME=${TNII//\.nii\.gz}
    TPNG=${DIR_SAVE}/anat/native_synth/${FNAME}.png
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
  TPNG=${DIR_PREP}/${IDPFX}_prep-raw_qalas.png
  echo '![Raw QALAS]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  if [[ ${NO_DENOISE} == "false" ]]; then
    echo '#### Denoising' >> ${RMD}
    echo '![Denoised QALAS]('${DIR_PREP}/${IDPFX}_prep-denoise_qalas.png')' >> ${RMD}
    echo '' >> ${RMD}
    echo '![Noise]('${DIR_PREP}/${IDPFX}_prep-noise_qalas.png')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  echo '#### FG Mask' >> ${RMD}
  TPNG=${DIR_SAVE}/anat/mask/${FLOW}/${IDPFX}_mask-fg+${FLOW}.png
  echo '![FG Mask]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  if [[ ${NO_B1,,} == "false" ]]; then
    echo '#### Debias' >> ${RMD}
    echo '![Debiased QALAS]('${DIR_PREP}/${IDPFX}_prep-debiasB1_qalas.png')' >> ${RMD}
    echo '' >> ${RMD}
    echo '![Bias Field]('${DIR_PREP}/${IDPFX}_prep-biasB1_qalas.png')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  if [[ ${DO_N4,,} == "true" ]]; then
    echo '#### Debias' >> ${RMD}
    echo '![Debiased QALAS]('${DIR_PREP}/${IDPFX}_prep-debiasN4_qalas.png')' >> ${RMD}
    echo '' >> ${RMD}
    echo '![Bias Field]('${DIR_PREP}/${IDPFX}_prep-biasN4_qalas.png')' >> ${RMD}
    echo '' >> ${RMD}
  fi

  echo '#### Brain Mask' >> ${RMD}
  TPNG=${DIR_SAVE}/anat/mask/${FLOW}/${IDPFX}_mask-brain+${FLOW}.png
  echo '![Brain Mask]('${TPNG}')' >> ${RMD}
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

#===============================================================================
# End of Function
#===============================================================================
exit 0
