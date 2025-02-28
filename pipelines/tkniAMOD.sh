#!/bin/bash -e
#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      AINIT
# DESCRIPTION:   TKNI Additional Anatomical Preprocessing Pipelin
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-02-28
# README:
#     Procedure:
#     (1) Reorient to RPI
#     (2) Denoise
#     (3) Extract Foreground Mask
#     (4) Non-uniformity Correction
#     (5) Coregistration to Base Anatomical, (rigid, affine, syn)
#           Default: intermodalSyn
#     (6) Normalization (applying existing transforms)
#     (7) Outcomes by modality
#           Myelin density map: if add-mod is T2w and T1w is base image
#           WM anomalies: if add-mod is FLAIR
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
base-mod:,base-dir:,base-image:,\
add-mod:,add-dir:,add-image:,\
dir-xfm:,\
no-reorient,no-denoise,no-coreg,no-debias,no-norm,no-outcome,\
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
DIR_SCRATCH=
IDPFX=
IDDIR=

BIMG=
BMOD="T1w"
BDIR=
BMASK=

AIMG=
AMOD="T2w,FLAIR,SWI"
#AMOD="T2w,FLAIR,PDT2,PDw,T2starw,SWI,Chimap,M0map,MTRmap,MTVmap,MTsat,MWFmap,PDmap,R1map,R2map,R2starmap,RB1map,S0map,T1map,T1rho,T2map,T2starmap,TB1map")
ADIR=

COREG_RECIPE="intermodalSyn"

DIR_XFM=
NORM_REF=
NORM_XFM_MAT=
NORM_XFM_SYN=

NO_REORIENT="false"
NO_DENOISE="false"
NO_COREG="false"
NO_DEBIAS="false"
NO_NORM="false"
NO_OUTCOME="false"

DIR_SAVE=
DIR_SCRATCH=

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF"
FORCE=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -n | --no-rmd) NO_PNG=true ; shift ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --base-mod) BMOD="$2" ; shift 2 ;;
    --base-dir) BDIR="$2" ; shift 2 ;;
    --base-image) BIMG="$2" ; shift 2 ;;
    --add-mod) AMOD="$2" ; shift 2 ;;
    --add-dir) ADIR="$2" ; shift 2 ;;
    --add-image) AIMG="$2" ; shift 2 ;;
    --no-reorient) NO_REORIENT="true" ; shift ;;
    --no-denoise) NO_DENOISE="true" ; shift ;;
    --no-coreg) NO_COREG="true" ; shift ;;
    --no-debias) NO_DEBIAS="true" ; shift ;;
    --no-norm) NO_NORM="true" ; shift ;;
    --no-outcome) NO_OUTCOME="true" ; shift ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
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
  echo '  --base-mod'
  echo '  --base-dir'
  echo '  --base-image'
  echo '  --add-mod'
  echo '  --add-dir'
  echo '  --add-image'
  echo '  --no-reorient'
  echo '  --no-denoise'
  echo '  --no-coreg'
  echo '  --no-debias'
  echo '  --no-norm'
  echo '  --no-outcome'
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
if [[ -z ${IDDIR} ]]; thenif [[ -z ${BDIR} ]]; then BDIR=${DIR_PROJECT}/derivatives/${PIPE}/anat/native; fi
if [[ -z ${BIMG} ]]; then BIMG=${BDIR}/${IDPFX}_${BMOD}.nii.gz; fi
if [[ ! -f ${BIMG} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] Base image not found."
  exit 1
fi
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
if [[ -z ${BDIR} ]]; then BDIR=${DIR_PROJECT}/derivatives/${PIPE}/anat/native; fi
if [[ -z ${BIMG} ]]; then BIMG=${BDIR}/${IDPFX}_${BMOD}.nii.gz; fi
if [[ -z ${BMASK} ]]; then
  BMASK=${DIR_PROJECT}/derivatives/${PIPE}/anat/${IDPFX}_mask-brain.nii.gz
fi
if [[ ! -f ${BIMG} ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] Base image not found."
  exit 1
fi
if [[ ! -f ${BMASK} ]]; then
  BMASK="DO_SYNTH"
fi


AMOD=(${AMOD//,/ })
if [[ -z ${ADIR} ]]; then ADIR=${DIR_PROJECT}/rawdata/${IDDIR}/anat; fi
if [[ -z ${AIMG} ]]; then
  for (( i=0; i<${#AMOD[@]}; i++ )); do
    AIMG+=($(ls ${ADIR}/${IDPFX}*${AMOD[${i}]}.nii.gz))
  done
else
  AIMG=(${AIMG//,/ })
  for (( i=0; i<${#AIMG[@]}; i++ )); do
    if [[ ! -f ${AIMG[${i}]} ]]; then
      echo -e "\tERROR [${PIPE}:${FLOW}] Image not found: ${AIMG[${i}]}"
      exit 2
    fi
  done
fi
NADD=${#AIMG[@]}
if [[ ${NADD} -eq 0 ]]; then
  echo -e "\tERROR [${PIPE}:${FLOW}] Additional anatomical images not found."
  exit 3
fi

if [[ -z ${DIR_XFM} ]]; then DIR_XFM=${DIR_PROJECT}/derivatives/${PIPE}/xfm/${IDDIR}; fi

if [[ ${NO_NORM,,} == "false" ]]; then
  if [[ -z ${NORM_REF} ]]; then
    TDIR=($(ls -d ${DIR_PROJECT}/derivatives/${PIPE}/anat/reg_*))
    CHKXFM=0
    for (( i=0; i<${#TDIR[@]}; i++ )); do
      NREF=(${TDIR[${i}]//\// })
      NREF=(${NREF[-1]//_/ })
      NREF=${NREF[-1]}
      TREF=${TDIR}/${IDPFX}_reg-${NREF}_${BMOD}.nii.gz
      TMAT=${DIR_XFM}/${IDPFX}_from-native_to-${NREF}_xfm-affine.mat
      TSYN=${DIR_XFM}/${IDPFX}_from-native_to-${NREF}_xfm-syn.nii.gz
      CHKNORM=0
      if [[ ! -f ${TREF} ]]; then CHKNORM=$((${CHKNORM}+1)); fi
      if [[ ! -f ${TAFFINE} ]] && [[ ! -f ${TSYN} ]]; then CHKNORM=$((${CHKNORM}+1)); fi
      if [[ ${CHKNORM} -eq 0 ]]; then
        NORM_REF+=(${TREF})
        NORM_MAT+=(${TMAT})
        NORM_SYN+=(${TSYN})
      fi
    done
  fi
fi

# set directories --------------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}; fi
#DIR_PREP=${DIR_SAVE}/prep/${IDDIR}/${FLOW}
#mkdir -p ${DIR_PREP}
mkdir -p ${DIR_SCRATCH}

# Loop over Additional anatomical images ---------------------------------------
for (( i=0; i<${NADD}; i++ )); do
  # Copy raw image to scratch --------------------------------------------------
  cp ${AIMG[${i}]} ${DIR_SCRATCH}/
  IMG=${DIR_SCRATCH}/$(basename ${AIMG[${i}]})
  MOD=$(getField -i ${IMG} -f modality)

  # Reorient to RPI ------------------------------------------------------------
  reorientRPI --image ${IMG} --dir-save ${DIR_SCRATCH}
  mv ${DIR_SCRATCH}/${IDPFX}_prep-reorient_${MOD}.nii.gz ${IMG}
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Reoriented to RPI"; fi

  # Denoise image --------------------------------------------------------------
  ricianDenoise --image ${IMG} --dir-save ${DIR_SCRATCH}
  mv ${DIR_SCRATCH}/${IDPFX}_prep-denoise_${MOD}.nii.gz ${IMG}
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Rician denoised"; fi

  # Get Foreground mask --------------------------------------------------------
  brainExtraction --image ${IMG} \
    --method "automask" --automask-clip ${FG_CLIP} \
    --label "fg" --dir-save ${DIR_SCRATCH}
  MASK_FG=${DIR_SCRATCH}/${IDPFX}_mod-${MOD}_mask-fg+AUTO.nii.gz
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> FG mask generated"; fi

  # Non-uniformity Correction --------------------------------------------------
  inuCorrection --image ${IMG} --method N4 --mask ${MASK_FG} --dir-save ${DIR_SCRATCH} --keep
  mv ${DIR_SCRATCH}/${IDPFX}_prep-biasN4_${MOD}.nii.gz ${IMG}
  rm ${DIR_SCRATCH}/${IDPFX}_mod-${MOD}_prep-biasN4_biasField.nii.gz
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Non-uniformity corrected"; fi

  # Extract brain mask ---------------------------------------------------------
  brainExtraction --image ${IMG} --method "synth" --dir-save ${DIR_SCRATCH}
  MASK=${DIR_SCRATCH}/${IDPFX}_mod-${MOD}_mask-brain+SYNTH.nii.gz
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> FS Synth brain extraction"; fi

  # Coregistration -------------------------------------------------------------
  if [[ ${BMASK^^} == "DO_SYNTH" ]]; then
    BMASK=${DIR_SCRATCH}/tmp_mask-brain+BASEMOD.nii.gz
    mri_synthstrip -i ${BIMG} -m ${BMASK}
  fi
  coregistrationChef --recipe-name ${COREG_RECIPE} \
    --fixed ${BIMG} --fixed-mask ${BMASK} \
    --moving ${IMG} --moving-mask ${MASK} \
    --space-target "fixed" --interpolation "Linear" \
    --prefix ${IDPFX} --label-from ${MOD} --label-to native \
    --dir-save ${DIR_SCRATCH} \
    --dir-xfm ${DIR_SCRATCH}/xfm${i} --no-png
  ## apply transforms
  TXFM1=${DIR_SCRATCH}/xfm${i}/${IDPFX}_mod-${MOD}_from-${MOD}_to-native_xfm-affine.mat
  TXFM2=${DIR_SCRATCH}/xfm${i}/${IDPFX}_mod-${MOD}_from-${MOD}_to-native_xfm-syn.nii.gz
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${IMG} -o ${IMG} -r ${BIMG} \
    -t identity -t ${TXFM2} -t ${TXFM1}

  # Normalization --------------------------------------------------------------
  for (( j=0; j<${#NORM_REF[@]}; j++ )); do
    TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
    xfm_fcn="antsApplyTransforms -d 3 -n BSpline[3]"
    xfm_fcn="${xfm_fcn} -i ${IMG}"
    xfm_fcn="${xfm_fcn} -o ${DIR_SCRATCH}/${IDPFX}_reg-${TRG}_${MOD}.nii.gz"
    xfm_fcn="${xfm_fcn} -r ${NORM_REF[${j}]}"
    xfm_fcn="${xfm_fcn} -t identity"
    if [[ -n ${NORM_SYN[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_SYN[${j}]}"; fi
    if [[ -n ${NORM_MAT[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_MAT[${j}]}"; fi
    eval ${xfm_fcn}
  done
done

*** check that figures are made
*** save output
*** generate RMD (this should probably be in the loop? or at least will need lopoing components)
