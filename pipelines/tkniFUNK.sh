#!/bin/bash -e
#===============================================================================
# Run TKNI FMRI Preprocessing Pipeline
# Required: MRtrix3, ANTs, FSL
# Description:
#  1) Denoising
#  2) Motion Correction
#  3) Brain extraction
#  4) Coregistration to Native space
#  5) Gather Regressors and calculate displacement
#  6) Nuisance Regression
#  7) Normalization
# Output:
#  1) Residual time-series in native space
#  2) Residual time series in template space
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
do-denoise,bex-mode:,bex-clfrac:,no-cat-runs,keep-runs,no-save-clean,\
anat:,anat-mask:,anat-seg:,val-csf:,val-wm:,seg-erosion:,\
compcorr-n:,bandpass-hi:,bandpass-lo:,space-coreg:,\
spike-thresh:,do-gsr,do-gmr,\
save-clean:,no-norm,no-censor,norm-ref:,norm-xfm:,space-norm:,\
dir-save:,dir-xfm:,dir-scratch:,requires:,\
help,verbose,loquacious,no-png,no-rmd,force -n 'parse-options' -- "$@")
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
DO_DENOISE="false"
BEX_MODE="auto"
BEX_CLFRAC=0.5
NO_CAT_RUNS="false"
KEEP_RUNS="false"

ANAT=
ANAT_MASK=
ANAT_SEG=
VAL_CSF=4
VAL_WM=3
VAL_GM=1,2
SEG_ME=1
COMPCORR_N=5
BP_HI=0.01
BP_LO=0.08
SPACE_COREG="bold"
SPIKE_THRESH=0.25
DO_GSR="false"
DO_GMR="true"

NO_SAVE_CLEAN="false"
NO_NORM="false"
NO_CENSOR="false"
NORM_XFM=
NORM_REF=
SPACE_NORM="2x2x2"

PIPE=tkni
FLOW=FUNK
REQUIRES="tkniDICOM,tkniAINIT,tkniMATS"
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
    -r | --no-rmd) NO_RMD=true ; shift ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --ts) TS="$2" ; shift 2 ;;
    --bex-mode) BEX_MODE="$2" ; shift 2 ;;
    --bex-clfrac) BEX_CLFRAC="$2" ; shift 2 ;;
    --do-denoise) DO_DENOISE="true" ; shift ;;
    --no-cat-runs) NO_CAT_RUNS="true" ; shift ;;
    --keep-runs) KEEP_RUNS="true" ; shift ;;
    --no-save-clean) NO_SAVE_CLEAN="true" ; shift ;;
    --no-norm) NO_NORM="true" ; shift ;;
    --spike-thresh) SPIKE_THRESH="$2" ; shift 2 ;;
    --no-censor) NO_CENSOR="true" ; shift ;;
    --do-gsr) DO_GSR="true" ; shift ;;
    --do-gmr) DO_GMR="true" ; shift ;;
    --anat) ANAT="$2" ; shift 2 ;;
    --anat-mask) ANAT_MASK="$2" ; shift 2 ;;
    --anat-seg) ANAT_SEG="$2" ; shift 2 ;;
    --val-csf) VAL_CSF="$2" ; shift 2 ;;
    --val-wm) VAL_WM="$2" ; shift 2 ;;
    --seg-erosion) SEG_ME="$2" ; shift 2 ;;
    --compcorr-n) COMPCORR_N="$2" ; shift 2 ;;
    --bandpass-hi) BP_HI="$2" ; shift 2 ;;
    --bandpass-lo) BP_LO="$2" ; shift 2 ;;
    --space-coreg) SPACE_COREG="$2" ; shift 2 ;;
    --norm-ref) NORM_REF="$2" ; shift 2 ;;
    --norm-xfm) NORM_XFM="$2" ; shift 2 ;;
    --space-norm) SPACE_NORM="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
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
  echo '  --dir-scratch      directory for temporary workspace'
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
  echo ">>>>>Process BOLD images for the following participant:"
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

# set up directories -----------------------------------------------------------
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PIPE}/func
fi
if [[ -z ${DIR_XFM} ]]; then
  DIR_XFM=${DIR_PIPE}/xfm/${IDDIR}
fi
DIR_RAW=${DIR_PROJECT}/rawdata/${IDDIR}/func

# gather necessary files -------------------------------------------------------
mkdir -p ${DIR_SCRATCH}/bold
## BOLD images to be processed
if [[ -z ${TS} ]]; then
  if ls ${DIR_RAW}/*_bold.nii.gz 1> /dev/null 2>&1; then
    TS=($(ls ${DIR_RAW}/*_bold.nii.gz))
  else
    if [[ ${VERBOSE} == "true" ]]; then
      echo ">>>>>There are 0 BOLD files to process, aborting"
    fi
    exit 0
  fi
else
  TS=(${TS//,/ })
fi
NTS=${#TS[@]}
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>There are ${NTS} BOLD files that will be processed"
fi
for (( i=0; i<${NTS}; i++ )); do
  cp ${TS[${i}]} ${DIR_SCRATCH}/bold/
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e "\tBOLD files copied to scratch"
fi
TS=($(ls ${DIR_SCRATCH}/bold/*_bold.nii.gz))

# Setup NATIVE anatomical space ------------------------------------------------
## NATIVE anatomical - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
mkdir -p ${DIR_SCRATCH}/anat
if [[ -z ${ANAT} ]]; then
  ANAT=${DIR_PIPE}/anat/native/${IDPFX}_T1w.nii.gz
fi
cp ${ANAT} ${DIR_SCRATCH}/anat/anat.nii.gz
ANAT=${DIR_SCRATCH}/anat/anat.nii.gz
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Native anatomical found and copied to scratch"
fi

## Anatomical Brain Mask - - - - - - - - - - - - - - - - - - - - - - - - - - - -
if [[ -z ${ANAT_MASK} ]]; then
  ANAT_MASK=${DIR_PIPE}/anat/mask/${IDPFX}_mask-brain.nii.gz
fi
cp ${ANAT_MASK} ${DIR_SCRATCH}/anat/anat_mask.nii.gz
ANAT_MASK=${DIR_SCRATCH}/anat/anat_mask.nii.gz
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Anatomical brain mask found and copied to scratch"
fi

## Anatomical segmentation with CSF and WM labels for CompCorr - - - - - - - - -
if [[ -z ${ANAT_SEG} ]]; then
  ANAT_SEG=${DIR_PIPE}/anat/label/${IDPFX}_label-tissue.nii.gz
fi
cp ${ANAT_SEG} ${DIR_SCRATCH}/anat/anat_seg.nii.gz
ANAT_SEG=${DIR_SCRATCH}/anat/anat_seg.nii.gz
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Segmentation labels for CompCorr found and copied to scratch"
fi

## RESIZE anatomicals - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
if [[ ${SPACE_COREG,,} == "anat" ]]; then
  echo "using native spacing no tranformation required"
elif [[ ${SPACE_COREG,,} == "bold" ]]; then
  if [[ ${NTS} -gt 1 ]]; then
    if [[ ${VERBOSE} == "true" ]]; then
      echo "Note: the output will use the spacing of the first BOLD image"
    fi
  fi
  TSPACE=$(convSpacing -i $(niiInfo -i ${TS[0]} -f "space"))
  ResampleImage 3 ${ANAT} ${ANAT} ${TSPACE} 0 0
  antsApplyTransforms -f 3 -n GenericLabel -i ${ANAT_MASK} -o ${ANAT_MASK} -r ${ANAT}
  antsApplyTransforms -f 3 -n MultiLabel -i ${ANAT_SEG} -o ${ANAT_SEG} -r ${ANAT}
else
  ResampleImage 3 ${ANAT} ${ANAT} ${SPACE_COREG} 0 0
  antsApplyTransforms -f 3 -n GenericLabel -i ${ANAT_MASK} -o ${ANAT_MASK} -r ${ANAT}
  antsApplyTransforms -f 3 -n MultiLabel -i ${ANAT_SEG} -o ${ANAT_SEG} -r ${ANAT}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Native space anatomical with target spacing constructed"
fi

## BRAIN ROI - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
ANAT_ROI=${DIR_SCRATCH}/anat/anat_roi.nii.gz
niimath ${ANAT} -mas ${ANAT_MASK} ${ANAT_ROI}

## Normalization Transforms ----------------------------------------------------
if [[ ${NO_NORM} == "false" ]]; then
  mkdir -p ${DIR_SCRATCH}/xfm
  if [[ -z ${NORM_REF} ]]; then
    NORM_REF=${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz
  fi
  ## resize normalized reference
  if [[ ${SPACE_NORM} == "ref" ]]; then
    cp ${NORM_REF} ${DIR_SCRATCH}/xfm/norm_ref.nii.gz
  elif [[ ${SPACE_NORM} == "anat" ]]; then
    if [[ ${VERBOSE} == "true" ]]; then
      echo "  >>>resampling normalization reference image to anatomical native spacing"
    fi
    TSPACE=$(convSpacing -i $(niiInfo -i ${DIR_SCRATCH}/anat/anat.nii.gz -f "space"))
    ResampleImage 3 ${NORM_REF} ${DIR_SCRATCH}/xfm/norm_ref.nii.gz ${TSPACE} 0 0
  else
    if [[ ${VERBOSE} == "true" ]]; then
      echo "  >>>resampling normalization reference image"
    fi
    SPACE_NORM=$(convSpacing -i ${SPACE_NORM})
    ResampleImage 3 ${NORM_REF} ${DIR_SCRATCH}/xfm/norm_ref.nii.gz ${SPACE_NORM} 0 0
  fi
  ## get norm reference label
  NORM_LABEL=$(getSpace -i ${NORM_REF})
  NORM_LABEL=(${NORM_LABEL//\+/ })
  NORM_LABEL=${NORM_LABEL[0]}

  if [[ -z ${NORM_XFM} ]]; then
    TDIR=${DIR_PIPE}/xfm/${IDDIR}
    TPFX=${IDPFX}_from-native_to-${NORM_LABEL}
    NORM_XFM="${TDIR}/${TPFX}_xfm-affine.mat,${TDIR}/${TPFX}_xfm-syn.nii.gz"
  fi
  NORM_XFM=(${NORM_XFM//,/ })
  for (( i=0; i<${#NORM_XFM[@]}; i++ )); do
    EXT=${NORM_XFM[${i}]#*.}
    cp ${NORM_XFM[${i}]} ${DIR_SCRATCH}/xfm/norm_xfm${i}.${EXT}
  done
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Normalization transforms found and copied"
fi

# process Time-series individually ---------------------------------------------
for (( i=0; i<${NTS}; i++ )); do
  if [[ ${VERBOSE} == "true" ]]; then
    echo ">>>>>Processing time-series $((${i} + 1))"
  fi
  ## make sure prior loop doesn't interfere
  unset TS_RAW PFX NTR TR
  unset TFX TS_MOCO TS_MEAN RGRS_MOCO
  unset TS_MASK TS_MASK_DIL TS_ROI
  unset XFM_AFFINE XFM_SYN XFM_INVERSE
  unset TS_REG TS_REGMEAN TS_REGMASK
  unset RGRLS PLOTLS
  unset TS_NORM

  TS_RAW=${TS[${i}]}
  PFX=($(getBidsBase -s -i ${TS_RAW}))
  NTR=$(niiInfo -i ${TS_RAW} -f numTR)
  TR=$(niiInfo -i ${TS_RAW} -f TR)
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e ">>>>>PROCESSING: ${PFX}_bold.nii.gz"
    echo -e "\t# TR: ${NTR}\n\tTR: ${TR}"
  fi

  # ADD REMOVAL OF WARMUP TRS ##################################################

  mkdir -p ${DIR_SCRATCH}/tmp
  rm -rf ${DIR_SCRATCH}/tmp/*
  # 4D Rician Denoising --------------------------------------------------------
  if [[ ${DO_DENOISE} == "true" ]]; then
    if [[ ${VERBOSE} == "true" ]]; then  echo -e "  >>>DENOISING"; fi
      fcnstr="DenoiseImage -d 4 -n Rician"
      fcnstr="${fcnstr} -i ${TS_RAW}"
      fcnstr="${fcnstr} -o ${DIR_SCRATCH}/tmp/bold.nii.gz"
      if [[ ${LOQUACIOUS} == "true" ]]; then
        fcnstr="${fcnstr} -v"
        echo ${fcnstr}
      fi
      eval ${fcnstr}
  else
    cp ${TS_RAW} ${DIR_SCRATCH}/tmp/bold.nii.gz
  fi

  # motion correction ------------------------------------------------------------
  ## moco may need to be debugged.
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>MOTION CORRECTION"; fi
  TFX="ts${i}"
  unset fcnstr
  fcnstr="moco --prefix ${TFX}"
  fcnstr="${fcnstr} --ts ${DIR_SCRATCH}/tmp/bold.nii.gz"
  fcnstr="${fcnstr} --dir-save ${DIR_SCRATCH}/tmp"
  fcnstr="${fcnstr} --dir-regressor ${DIR_SCRATCH}/tmp --no-png"
  if [[ ${VERBOSE} == "true" ]]; then
    fcnstr="${fcnstr} --verbose"
    if [[ ${LOQUACIOUS} == "true" ]]; then
      fcnstr="${fcnstr} --ants-verbose"
    fi
    echo ${fcnstr}
  fi
  eval ${fcnstr}

  TS_MOCO=${DIR_SCRATCH}/tmp/${TFX}_bold.nii.gz
  TS_MEAN=${DIR_SCRATCH}/tmp/${TFX}_proc-mean_bold.nii.gz
  RGRS_MOCO=${DIR_SCRATCH}/tmp/${TFX}_moco+6.1D
  ## motion regressor derivatives
  regressorDerivative --regressor ${RGRS_MOCO} --dir-save ${DIR_SCRATCH}/tmp
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>MOTION DERIVATIVES"; fi

  ## calculate displacement
  regressorDisplacement --regressor ${RGRS_MOCO} --thresh ${SPIKE_THRESH} \
    --dir-save ${DIR_SCRATCH}/tmp
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>DISPLACEMENT REGRESSORS"; fi

  # get brain mask -------------------------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>BRAIN EXTRACTION"; fi
  TS_MASK=${DIR_SCRATCH}/tmp/ts_mask-brain.nii.gz
  # TS_MASK_DIL=${DIR_SCRATCH}/tmp/ts_mask-brain+MD.nii.gz
  TS_ROI=${DIR_SCRATCH}/tmp/ts_proc-mean_roi-brain_bold.nii.gz
  if [[ ${BEX_MODE,,} == "synth" ]]; then
    mri_synthstrip -i ${TS_MEAN} -m ${TS_MASK}
  elif [[ ${BEX_MODE,,} == "auto" ]]; then
    3dAutomask -prefix ${TS_MASK} -q -clfrac ${BEX_CLFRAC} ${TS_MEAN}
  elif [[ ${BEX_MODE,,} == "bet" ]]; then
    ## or use BET if you want to and it works better for some reason
    bet ${TS_MEAN} ${TS_MASK} -m -v
    niimath ${TS_MASK} -bin ${TS_MASK} -odt char
  else
    echo "ERROR [TKNI:${FCN_NAME}] Method of BOLD brain extraction must be specified, synth, auto, or bet"
    exit 2
  fi
  niimath ${TS_MEAN} -mas ${TS_MASK} ${TS_ROI}
  # ImageMath 3 ${TS_MASK_DIL} MD ${TS_MASK} 2

  # coregister to native anatomical ----------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>COREGISTER TO NATIVE"; fi
  unset fcnstr
  fcnstr="coregistrationChef --recipe-name intermodalSyn"
  fcnstr="${fcnstr} --fixed ${ANAT_ROI}"
  fcnstr="${fcnstr} --moving ${TS_ROI}"
  fcnstr="${fcnstr} --prefix ${TFX} --label-from raw --label-to native"
  fcnstr="${fcnstr} --dir-save ${DIR_SCRATCH}/tmp"
  fcnstr="${fcnstr} --dir-xfm ${DIR_SCRATCH}/xfm --no-png"
  if [[ ${VERBOSE} == "true" ]]; then
    fcnstr="${fcnstr} --verbose"
    if [[ ${LOQUACIOUS} == "true" ]]; then
      fcnstr="${fcnstr} --ants-verbose"
    fi
    echo ${fcnstr}
  fi
  eval ${fcnstr}

  XFM_AFFINE=${DIR_SCRATCH}/xfm/${TFX}_mod-bold_from-raw_to-native_xfm-affine.mat
  XFM_SYN=${DIR_SCRATCH}/xfm/${TFX}_mod-bold_from-raw_to-native_xfm-syn.nii.gz
  XFM_INVERSE=${DIR_SCRATCH}/xfm/${TFX}_mod-bold_from-raw_to-native_xfm-syn+inverse.nii.gz

  # apply transforms to mean, mask, moco ---------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e "  >>>APPLY COREGISTRATION TO MEAN, MASK, & MOCO"
  fi
  TS_REG=${DIR_SCRATCH}/tmp/${TFX}_coreg_bold.nii.gz
  TS_REGMEAN=${DIR_SCRATCH}/tmp/${TFX}_coreg_proc-mean_bold.nii.gz
  TS_REGMASK=${DIR_SCRATCH}/tmp/${TFX}_coreg_mask-brain.nii.gz
  ## apply COREGISTRATION to TS - - - - - - - - - - - - - - - - - - - - - - - -
  antsApplyTransforms -d 3 -e 3 -n Linear -r ${ANAT} \
    -i ${TS_MOCO} -o ${TS_REG} \
    -t identity -t ${XFM_SYN} -t ${XFM_AFFINE}
  ## apply to mask or use anatomical mask - - - - - - - - - - - - - - - - - - -
  if [[ ${USE_BOLD_MASK} == "true" ]]; then
    antsApplyTransforms -d 3 -n GenericLabel -r ${ANAT} \
      -i ${TS_MASK} -o ${TS_REGMASK} \
      -t identity -t ${XFM_SYN} -t ${XFM_AFFINE}
    niimath ${TS_REGMASK} ${TS_REGMASK} -odt char
  else
    cp ${ANAT_MASK} ${TS_REGMASK}
  fi
  antsApplyTransforms -d 3 -n Linear -r ${ANAT} \
    -i ${TS_MEAN} -o ${TS_REGMEAN} \
    -t identity -t ${XFM_SYN} -t ${XFM_AFFINE}
  make3Dpng --bg ${ANAT} --bg-threshold "2.5,97.5" \
    --fg ${TS_REGMEAN} --fg-color "hot" --fg-alpha 50 \
    --fg-mask ${TS_REGMASK} \
    --layout "6:x;6:x;6:y;6:y;6:z;6:z" \
    --filename ${PFX}_reg-native_proc-mean_bold \
    --dir-save ${DIR_SCRATCH}/tmp

  # COMPCORR -------------------------------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>COMPCORR"; fi
  ## build compcorr mask
  if [[ ${VERBOSE} == "true" ]]; then echo -e "    >COMPCOR SEGMENTATIONS"; fi
  niimath ${ANAT_SEG} \
    -thr ${VAL_CSF} -uthr ${VAL_CSF} -bin \
    ${DIR_SCRATCH}/anat/anat_csf.nii.gz -odt char
  ImageMath 3 ${DIR_SCRATCH}/anat/anat_csf.nii.gz ME \
    ${DIR_SCRATCH}/anat/anat_csf.nii.gz ${SEG_ME}

  niimath ${DIR_SCRATCH}/anat/anat_seg.nii.gz \
    -thr ${VAL_WM} -uthr ${VAL_WM} -bin \
    ${DIR_SCRATCH}/anat/anat_wm.nii.gz -odt char
  ImageMath 3 ${DIR_SCRATCH}/anat/anat_wm.nii.gz ME \
    ${DIR_SCRATCH}/anat/anat_wm.nii.gz ${SEG_ME}

  niimath ${DIR_SCRATCH}/anat/anat_wm.nii.gz -mul 2 \
    -add ${DIR_SCRATCH}/anat/anat_csf.nii.gz \
    ${DIR_SCRATCH}/anat/anat_compcorr.nii.gz -odt char
  antsApplyTransforms -d 3 -n MultiLabel \
    -i ${DIR_SCRATCH}/anat/anat_compcorr.nii.gz \
    -o ${DIR_SCRATCH}/anat/anat_compcorr.nii.gz \
    -r ${ANAT}

  if [[ ${VERBOSE} == "true" ]]; then echo -e "    >COMPCORR REGRESSORS"; fi
  regressorAcompcorr --ts ${TS_REG} \
    --n-components ${COMPCORR_N} \
    --csf 1 --wm 2 --label ${DIR_SCRATCH}/anat/anat_compcorr.nii.gz \
    --dir-save ${DIR_SCRATCH}/tmp

  # Global Signal Regressor ----------------------------------------------------
  if [[ ${DO_GSR} == "true" ]]; then
    3dmaskave -quiet -mask ${TS_REGMASK} ${TS_REG} > ${DIR_SCRATCH}/tmp/${TFX}_globalSignal.1D
  fi

  # Gray Matter Regression -----------------------------------------------------
  # Aquino KM, Fulcher BD, Parkes L, Sabaroedin K, Fornito A.
  # Identifying and removing widespread signal deflections from fMRI data: Rethinking the global signal regression problem.
  # Neuroimage [Internet]. 2020 May 15 [cited 2024 Sep 13];212(116614):116614. Available from: http://dx.doi.org/10.1016/j.neuroimage.2020.116614
  if [[ ${DO_GMR} == "true" ]]; then
    VAL_GM=(${VAL_GM//,/ })
    niimath ${ANAT_SEG} -mul 0 -bin \
      ${DIR_SCRATCH}/anat/anat_gm.nii.gz -odt char
    for (( j=0; j<${#VAL_GM[@]}; j++ )); do
      niimath ${ANAT_SEG} \
        -thr ${VAL_GM[${j}]} -uthr ${VAL_GM[${j}]} -bin \
        -add ${DIR_SCRATCH}/anat/anat_gm.nii.gz \
        ${DIR_SCRATCH}/anat/anat_gm.nii.gz -odt char
    done
    antsApplyTransforms -d 3 -n GenericLabel \
    -i ${DIR_SCRATCH}/anat/anat_gm.nii.gz \
    -o ${DIR_SCRATCH}/anat/anat_gm.nii.gz \
    -r ${ANAT}
    3dmaskave -quiet -mask ${DIR_SCRATCH}/anat/anat_gm.nii.gz \
      ${TS_REG} > ${DIR_SCRATCH}/tmp/${TFX}_GMSignal.1D
  fi

  # Plot Regressors for QC -----------------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>PLOT REGRESSORS"; fi
  PLOTLS="${DIR_SCRATCH}/tmp/${TFX}_moco+6.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_moco+6+deriv.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_coreg_compcorr+csf+${COMPCORR_N}.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_coreg_compcorr+wm+${COMPCORR_N}.1D"
  if [[ ${DO_GSR} == "true" ]]; then
    PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_globalSignal.1D"
  fi
  if [[ ${DO_GMR} == "true" ]]; then
    PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_GMSignal.1D"
  fi
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_displacement+absolute+mm.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_displacement+relative+mm.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_displacement+framewise.1D"
  PLOTLS="${PLOTLS},${DIR_SCRATCH}/tmp/${TFX}_spike.1D"
  regressorPlot --regressor ${PLOTLS}

  # Nuisance Regression --------------------------------------------------------
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>NUISANCE REGRESSION"; fi
  3dmaskave -quiet -mask ${TS_MASK} ${TS_RAW} > ${DIR_SCRATCH}/tmp/${TFX}_coreg_ts-brain+raw.1D
  3dmaskave -quiet -mask ${TS_REGMASK} ${TS_REG} > ${DIR_SCRATCH}/tmp/${TFX}_coreg_ts-brain+mocoReg.1D

  ## censor spikes to replace with local mean first, to preserve to incorrect degrees of freedom for 3dTproject
  if [[ ${NO_CENSOR} == "false" ]]; then
    CENSOR="${DIR_SCRATCH}/tmp/${TFX}_spike.1D"
    3dTproject -input ${TS_REG} \
      -prefix ${DIR_SCRATCH}/${TFX}_coreg_censored.nii.gz \
      -mask ${TS_REGMASK} \
      -censor ${CENSOR} -cenmode NTRP \
      -TR ${TR}
    FOR_NUISANCE=${DIR_SCRATCH}/${TFX}_coreg_censored.nii.gz
    3dmaskave -quiet -mask ${TS_REGMASK} ${FOR_NUISANCE} > ${DIR_SCRATCH}/tmp/${TFX}_coreg_ts-brain+censored.1D
  else
    FOR_NUISANCE=${TS_REG}
  fi

  RGRLS="${DIR_SCRATCH}/tmp/${TFX}_moco+6.1D"
  RGRLS="${RGRLS},${DIR_SCRATCH}/tmp/${TFX}_moco+6+deriv.1D"
  RGRLS="${RGRLS},${DIR_SCRATCH}/tmp/${TFX}_coreg_compcorr+csf+${COMPCORR_N}.1D"
  RGRLS="${RGRLS},${DIR_SCRATCH}/tmp/${TFX}_coreg_compcorr+wm+${COMPCORR_N}.1D"
  if [[ ${DO_GSR} == "true" ]]; then
    RGRLS="${RGRLS},${DIR_SCRATCH}/tmp/${TFX}_globalSignal.1D"
  fi
  if [[ ${DO_GMR} == "true" ]]; then
    RGRLS="${RGRLS},${DIR_SCRATCH}/tmp/${TFX}_GMSignal.1D"
  fi
  nuisanceRegression --ts-bold ${FOR_NUISANCE} --mask ${TS_REGMASK} \
    --regressor ${RGRLS} \
    --pass-lo ${BP_LO} --pass-hi ${BP_HI} \
    --dir-save ${DIR_SCRATCH}/tmp
  TS_RESID=${DIR_SCRATCH}/tmp/${TFX}_coreg_resid.nii.gz

  # normalize time-series (if desired) -----------------------------------------
  if [[ ${NO_NORM} == "false" ]]; then
    if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>NORMALIZATION"; fi
    TS_NORM=${DIR_SCRATCH}/tmp/${TFX}_reg-${NORM_LABEL}_residual.nii.gz
    #mkdir -p ${DIR_SCRATCH}/tnorm
    ### disassemble timeseries (ants hogs memory)
    #ImageMath 4 ${DIR_SCRATCH}/tnorm/tresid.nii.gz TimeSeriesDisassemble ${TS_RESID}
    #TLS=($(ls ${DIR_SCRATCH}/tnorm/*.nii.gz))
    #for (( j=0; j<${#TLS[@]}; j++ )); do
    #  fcn_str="antsApplyTransforms -d 3 -n Linear"
    #  fcn_str="${fcn_str} -i ${TLS[${j}]} -o ${TLS[${j}]}"\
    #  fcn_str="${fcn_str} -r ${DIR_SCRATCH}/xfm/norm_ref.nii.gz"
    #  fcn_str="${fcn_str} -t identity"
    #  for (( k=0; k<${#NORM_XFM[@]}; k++ )); do
    #    fcn_str="${fcn_str} -t ${NORM_XFM[${k}]}"
    #  done
    #  eval ${fcn_str}
    #done
    ### reassemble normalized timeseries
    #ImageMath 4 ${TS_NORM} TimeSeriesAssemble ${TR} 0 ${DIR_SCRATCH}/tnorm/*.nii.gz

    fcn_str="antsApplyTransforms -d 3 -e 3 -n Linear"
    fcn_str="${fcn_str} -i ${TS_RESID} -o ${TS_NORM}"\
    fcn_str="${fcn_str} -r ${DIR_SCRATCH}/xfm/norm_ref.nii.gz"
    fcn_str="${fcn_str} -t identity"
    for (( j=0; j<${#NORM_XFM[@]}; j++ )); do
      fcn_str="${fcn_str} -t ${NORM_XFM[${j}]}"
    done
    eval ${fcn_str}
    niimath ${TS_NORM} ${TS_NORM} -odt flt

    fcn_str="antsApplyTransforms -d 3 -n Linear"
    fcn_str="${fcn_str} -i ${TS_REGMEAN}"
    fcn_str="${fcn_str} -o ${DIR_SCRATCH}/tmp/${TFX}_norm_proc-mean_bold.nii.gz"
    fcn_str="${fcn_str} -r ${DIR_SCRATCH}/xfm/norm_ref.nii.gz"
    fcn_str="${fcn_str} -t identity"
    for (( j=0; j<${#NORM_XFM[@]}; j++ )); do
      fcn_str="${fcn_str} -t ${NORM_XFM[${j}]}"
    done
    eval ${fcn_str}
    fcn_str="antsApplyTransforms -d 3 -n Linear"
    fcn_str="${fcn_str} -i ${TS_REGMASK}"
    fcn_str="${fcn_str} -o ${DIR_SCRATCH}/tmp/${TFX}_norm_mask-brain.nii.gz"
    fcn_str="${fcn_str} -r ${DIR_SCRATCH}/xfm/norm_ref.nii.gz"
    fcn_str="${fcn_str} -t identity"
    for (( j=0; j<${#NORM_XFM[@]}; j++ )); do
      fcn_str="${fcn_str} -t ${NORM_XFM[${j}]}"
    done
    eval ${fcn_str}
    niimath ${DIR_SCRATCH}/tmp/${TFX}_norm_mask-brain.nii.gz \
      ${DIR_SCRATCH}/tmp/${TFX}_norm_mask-brain.nii.gz -odt char

    make3Dpng --bg ${DIR_SCRATCH}/xfm/norm_ref.nii.gz --bg-threshold "2.5,97.5" \
      --fg ${DIR_SCRATCH}/tmp/${TFX}_norm_proc-mean_bold.nii.gz \
      --fg-mask ${DIR_SCRATCH}/tmp/${TFX}_norm_mask-brain.nii.gz \
      --fg-color "hot" --fg-threshold "5,95" --fg-alpha 25 \
      --layout "6:x;6:x;6:y;6:y;6:z;6:z" \
      --filename ${PFX}_reg-${NORM_LABEL}_proc-mean_bold \
      --dir-save ${DIR_SCRATCH}/qc
  fi

  # save output to temporary folder before processing the next timeseries ------
  if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>SAVE RESIDUAL OUTPUT"; fi

  ## stage regressors
  mkdir -p ${DIR_SCRATCH}/regressor
  unset RGRLS
  RGRLS=("moco+6" "moco+6+deriv" "coreg_compcorr+csf+5" "coreg_compcorr+wm+5"\
         "coreg_ts-brain+raw" "coreg_ts-brain+mocoReg" "coreg_ts-brain+resid" \
         "coreg_ts-processing" "displacement+absolute+mm" \
         "displacement+framewise" "displacement+relative+mm"\
         "displacement+RMS" "spike")
  if [[ -n ${CENSOR} ]]; then RGRLS+=("coreg_ts-brain+censored"); fi
  if [[ ${DO_GSR} == "true" ]]; then RGRLS+=("globalSignal"); fi
  if [[ ${DO_GMR} == "true" ]]; then RGRLS+=("GMSignal"); fi
  for (( j=0; j<${#RGRLS[@]}; j++ )); do
    mv ${DIR_SCRATCH}/tmp/${TFX}_${RGRLS[${j}]}.1D \
      ${DIR_SCRATCH}/regressor/${PFX}_${RGRLS[${j}]}.1D
  done

  ## stage residuls
  mkdir -p ${DIR_SCRATCH}/residual_native
  mv ${TS_RESID} ${DIR_SCRATCH}/residual_native/${PFX}_residual.nii.gz

  ## stage normalized residuals
  if [[ ${NO_NORM} == "false" ]]; then
    mkdir -p ${DIR_SCRATCH}/residual_${NORM_LABEL}
    mv ${TS_NORM} ${DIR_SCRATCH}/residual_${NORM_LABEL}/${PFX}_reg-${NORM_LABEL}_residual.nii.gz
  fi

  ## stage qc images
  mkdir -p ${DIR_SCRATCH}/qc
  mv ${DIR_SCRATCH}/tmp/${PFX}_reg-native_proc-mean_bold.png ${DIR_SCRATCH}/qc/
  mv ${DIR_SCRATCH}/tmp/${TFX}_coreg_ts-processing.png \
    ${DIR_SCRATCH}/qc/${PFX}_ts-processing.png
  mv ${DIR_SCRATCH}/tmp/${TFX}_regressors.png \
    ${DIR_SCRATCH}/qc/${PFX}_regressors.png

  ## stage mask
  mkdir -p ${DIR_SCRATCH}/mask
  mv ${DIR_SCRATCH}/tmp/${TFX}_coreg_mask-brain.nii.gz \
    ${DIR_SCRATCH}/mask/${PFX}_mod-bold_mask-brain.nii.gz

  ## stage mean bold
  mkdir -p ${DIR_SCRATCH}/mean
  mv ${DIR_SCRATCH}/tmp/${TFX}_coreg_proc-mean_bold.nii.gz \
    ${DIR_SCRATCH}/mean/${PFX}_proc-mean_bold.nii.gz

  ## stage xfms
  mv ${XFM_AFFINE} ${DIR_SCRATCH}/xfm/${PFX}_mod-bold_from-raw_to-native_xfm-affine.mat
  mv ${XFM_SYN} ${DIR_SCRATCH}/xfm/${PFX}_mod-bold_from-raw_to-native_xfm-syn.nii.gz
  mv ${XFM_INVERSE} ${DIR_SCRATCH}/xfm/${PFX}_mod-bold_from-raw_to-native_xfm-syn+inverse.nii.gz

  ## save clean time series, in case you want to change residuals later
  if [[ ${NO_SAVE_CLEAN} == "false" ]]; then
    mkdir -p ${DIR_SCRATCH}/clean
    mv ${DIR_SCRATCH}/tmp/${TFX}_coreg_bold.nii.gz \
      ${DIR_SCRATCH}/clean/${PFX}_bold.nii.gz
  fi

  ## clear tmp folder for next runs
  rm ${DIR_SCRATCH}/tmp/*
done

# concatenate time series if requested
if [[ ${NO_CAT_RUNS} == "false" ]]; then
  # get task names
  TASKS=""
  for (( i=0; i<${NTS}; i++ )); do
    TTASK=$(getField -i ${TS[${i}]} -f task)
    if [[ ${TASKS} != *"${TTASK}"* ]]; then
      TASKS="${TASKS} ${TTASK}"
    fi
  done
  TASKS=($(echo ${TASKS}))
  NTASKS=${#TASKS[@]}

  ## concatenate residuals
  for (( i=0; i<${NTASKS}; i++ )); do
    TLS=($(ls ${DIR_SCRATCH}/residual_native/*${TASKS[${i}]}*.nii.gz ))
    TR=$(niiInfo -i ${TLS[0]} -f TR)
    TDIR=${DIR_SCRATCH}/residual_native
    TNAME=${TDIR}/${IDPFX}_task-${TASKS[${i}]}_residual.nii.gz
    3dTcat -prefix ${TNAME} -tr ${TR} ${TLS[@]}
    if [[ ${KEEP_RUNS} == "false" ]]; then
      for (( j=0; j<${#TLS[@]}; j++ )); do
        mv ${TLS[${j}]} ${DIR_SCRATCH}/tmp/
      done
    fi
  done

  ##concatenate noramalized residuals
  if [[ ${NO_NORM} == "false" ]]; then
    for (( i=0; i<${NTASKS}; i++ )); do
      TLS=($(ls ${DIR_SCRATCH}/residual_${NORM_LABEL}/*${TASKS[${i}]}*.nii.gz ))
      TR=$(niiInfo -i ${TLS[0]} -f TR)
      TDIR=${DIR_SCRATCH}/residual_${NORM_LABEL}
      TNAME=${TDIR}/${IDPFX}_task-${TASKS[${i}]}_reg-${NORM_LABEL}_residual.nii.gz
      3dTcat -prefix ${TNAME} -tr ${TR} ${TLS[@]}
      if [[ ${KEEP_RUNS} == "false" ]]; then
        for (( j=0; j<${#TLS[@]}; j++ )); do
          mv ${TLS[${j}]} ${DIR_SCRATCH}/tmp/
        done
      fi
    done
  fi

  # combine brain masks
  for (( i=0; i<${NTASKS}; i++ )); do
    TLS=($(ls ${DIR_SCRATCH}/mask/*${TASKS[${i}]}*.nii.gz))
    COMBMASK=${DIR_SCRATCH}/mask/${IDPFX}_task-${TASKS[${i}]}_mask-brain.nii.gz
    AverageImages 3 ${COMBMASK} 0 ${DIR_SCRATCH}/mask/*${TASKS[${i}]}*.nii.gz
    niimath ${COMBMASK} -bin ${COMBMASK} -odt char
    if [[ ${KEEP_RUNS} == "false" ]]; then
      for (( j=0; j${#TLS[@]}; j++ )); do
        mv ${TLS[${j}]} ${DIR_SCRATCH}/tmp/
      done
    fi
  done

  # combine mean bold
  for (( i=0; i<${NTASKS}; i++ )); do
    TLS=($(ls ${DIR_SCRATCH}/mean/*${TASKS[${i}]}*.nii.gz))
    COMBMEAN=${DIR_SCRATCH}/mean/${IDPFX}_task-${TASKS[${i}]}_proc-mean_bold.nii.gz
    AverageImages 3 ${COMBMEAN} 0 ${DIR_SCRATCH}/mean/*${TASKS[${i}]}*.nii.gz
    if [[ ${KEEP_RUNS} == "false" ]]; then
      for (( j=0; j${#TLS[@]}; j++ )); do
        mv ${TLS[${j}]} ${DIR_SCRATCH}/tmp/
      done
    fi
  done
fi

# make PNGs for RMD output -----------------------------------------------------
if [[ ${NO_RMD} == "false" ]] || [[ ${NO_PNG} == "false" ]]; then
  TMEAN=($(ls ${DIR_SCRATCH}/mean/*.nii.gz))
  TMASK=($(ls ${DIR_SCRATCH}/mask/*.nii.gz))
  for (( i=0; i<${#TMEAN[@]}; i++ )); do
    make3Dpng --bg ${TMEAN[${i}]} --bg-threshold "2.5,97.5"
    FNAME=$(basename ${TMASK[${i}]})
    FNAME=${FNAME%%.*}
    make3Dpng --bg ${TMEAN[${i}]} --bg-threshold "2.5,97.5" \
      --fg ${TMASK[${i}]} --fg-color "gradient:hue=#FF0000" --fg-alpha 25 --fg-cbar false \
      --layout "10:z;10:z;10:z" \
      --filename ${FNAME} \
      --dir-save $(dirname ${TMASK[${i}]})
  done
fi

# move final output to save folders --------------------------------------------
mkdir -p ${DIR_SAVE}/mask
cp ${DIR_SCRATCH}/mask/* ${DIR_SAVE}/mask/

mkdir -p ${DIR_SAVE}/mean
cp ${DIR_SCRATCH}/mean/* ${DIR_SAVE}/mean/

mkdir -p ${DIR_SAVE}/qc/${IDDIR}
cp ${DIR_SCRATCH}/qc/* ${DIR_SAVE}/qc/${IDDIR}/

mkdir -p ${DIR_SAVE}/regressor/${IDDIR}
cp ${DIR_SCRATCH}/regressor/* ${DIR_SAVE}/regressor/${IDDIR}/

mkdir -p ${DIR_SAVE}/residual_native
cp ${DIR_SCRATCH}/residual_native/* ${DIR_SAVE}/residual_native/

if [[ ${NO_NORM} == "false" ]]; then
  mkdir -p ${DIR_SAVE}/residual_${NORM_LABEL}
  cp ${DIR_SCRATCH}/residual_${NORM_LABEL}/* ${DIR_SAVE}/residual_${NORM_LABEL}/
fi

if [[ ${NO_SAVE_CLEAN} == "false" ]]; then
  mkdir -p ${DIR_SAVE}/clean
  cp ${DIR_SCRATCH}/clean/* ${DIR_SAVE}/clean/
fi

cp ${DIR_SCRATCH}/xfm/${IDPFX}* ${DIR_XFM}/

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
#  echo 'library(downloadthis)' >> ${RMD}
#  echo "create_dt <- function(x){" >> ${RMD}
#  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
#  echo "    options=list(dom='Blfrtip'," >> ${RMD}
#  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
#  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## '${PIPE}${FLOW}': BOLD fMRI PreProcessing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'PROCESS START: '${PROC_START} >> ${RMD}
  echo 'PROCESS STOP: '$(date +%Y-%m-%dT%H:%M:%S%z) >> ${RMD}
  echo '' >> ${RMD}

  if [[ ${NO_CAT_RUNS} == "false" ]]; then
    echo '**Runs are concatenated by task. Processing and QC is done separately for each run.**  '
  fi

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
  TPNG=($(ls ${DIR_SAVE}/qc/${IDDIR}/${IDPPFX}*ts-processing.png))
  for (( i=0; i<${#TPNG[@]}; i++ )); do
    BNAME=$(getBidsBase -i ${TPNG[$i]} -s)
    BNAME=${BNAME//${IDPFX}_}
    echo "### ${BNAME}" >> ${RMD}
    echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
    echo '' >> ${RMD}
  done

  # coregistration
  echo '## Coregistration {.tabset}' >> ${RMD}
  unset TPNG
  TPNG=($(ls ${DIR_SAVE}/qc/${IDDIR}/${IDPPFX}*reg-native*.png))
  for (( i=0; i<${#TPNG[@]}; i++ )); do
    BNAME=$(getBidsBase -i ${TPNG[$i]})
    BNAME=${BNAME//${IDPFX}_}
    echo "### ${BNAME}" >> ${RMD}
    echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
    echo '' >> ${RMD}
  done

  # normalization
  echo '## Normalization {.tabset}' >> ${RMD}
  unset TPNG
  TPNG=($(ls ${DIR_SAVE}/qc/${IDDIR}/${IDPPFX}*reg-${NORM_LABEL}*.png))
  for (( i=0; i<${#TPNG[@]}; i++ )); do
    BNAME=$(getBidsBase -i ${TPNG[$i]})
    BNAME=${BNAME//${IDPFX}_}
    echo "### ${BNAME}" >> ${RMD}
    echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
    echo '' >> ${RMD}
  done

  # regressor plot
  echo '## Nuisance Regression {.tabset}' >> ${RMD}
  unset TPNG
  TPNG=($(ls ${DIR_SAVE}/qc/${IDDIR}/${IDPPFX}*regressors.png))
  for (( i=0; i<${#TPNG[@]}; i++ )); do
    BNAME=$(getBidsBase -i ${TPNG[$i]})
    BNAME=${BNAME//${IDPFX}_}
    echo "### ${BNAME}" >> ${RMD}
    echo '!['$(basename ${TPNG[${i}]})']('${TPNG[${i}]}')' >> ${RMD}
    echo '' >> ${RMD}
  done

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

