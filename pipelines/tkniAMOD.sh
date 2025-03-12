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
base-mod:,base-dir:,base-image:,base-mask:,\
add-mod:,add-dir:,add-image:,\
coreg-recipe:,dir-xfm:,norm-ref:,norm-mat:,norm-syn:,\
no-myelin,tissue:,tissue-value:,\
no-anomaly,wm-thresh:,\
no-reorient,no-denoise,no-coreg,no-debias,no-rescale,no-norm,no-outcome,\
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

NO_MYELIN="false"
TISSUE=
TISSUE_VAL=1x2x4
NO_ANOMALY="false"
WM_THRESH=2.5

NO_REORIENT="false"
NO_DENOISE="false"
NO_COREG="false"
NO_DEBIAS="false"
NO_RESCALE="false"
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
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF,tkniMATS"
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
    --base-mod) BMOD="$2" ; shift 2 ;;
    --base-dir) BDIR="$2" ; shift 2 ;;
    --base-image) BIMG="$2" ; shift 2 ;;
    --base-mask) BMASK="$2" ; shift 2 ;;
    --add-mod) AMOD="$2" ; shift 2 ;;
    --add-dir) ADIR="$2" ; shift 2 ;;
    --add-image) AIMG="$2" ; shift 2 ;;
    --coreg-recipe) COREG_RECIPE="$2" ; shift 2 ;;
    --norm-ref) NORM_REF="$2" ; shift 2 ;;
    --norm-mat) NORM_XFM_MAT="$2" ; shift 2 ;;
    --norm-syn) NORM_XFM_SYN="$2" ; shift 2 ;;
    --no-myelin) NO_MYELIN="true" ; shift ;;
    --tissue) TISSUE="$2" ; shift 2 ;;
    --tissue-val) TISSUE_VAL="$2" ; shift 2 ;;
    --no-anomaly) NO_ANOMALY="true" ; shift ;;
    --wm-thresh) WM_THRESH="$2" ; shift 2 ;;
    --no-reorient) NO_REORIENT="true" ; shift ;;
    --no-denoise) NO_DENOISE="true" ; shift ;;
    --no-coreg) NO_COREG="true" ; shift ;;
    --no-debias) NO_DEBIAS="true" ; shift ;;
    --no-rescale) NO_REORIENT="true" ; shift ;;
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
    if ls ${ADIR}/${IDPFX}*${AMOD[${i}]}.nii.gz 1> /dev/null 2>&1; then
      TLS=($(ls ${ADIR}/${IDPFX}*${AMOD[${i}]}.nii.gz))
      AIMG+=${TLS[@]}
    fi
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
        NORM_REF+=${TREF}
        NORM_MAT+=${TMAT}
        NORM_SYN+=${TSYN}
      fi
    done
  fi
fi

# set directories --------------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}; fi
mkdir -p ${DIR_SCRATCH}

# initialize RMD output --------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  #mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}
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
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## Additional Anatomical Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}
fi

# Loop over Additional anatomical images ---------------------------------------
for (( i=0; i<${NADD}; i++ )); do
  # Copy raw image to scratch --------------------------------------------------
  cp ${AIMG[${i}]} ${DIR_SCRATCH}/
  IMG=${DIR_SCRATCH}/$(basename ${AIMG[${i}]})
  MOD=$(getField -i ${IMG} -f modality)
  TPFX=$(getBidsBase -i ${IMG} -s)
  make3Dpng --bg ${AIMG[${i}]} --bg-thresh "2.5,97.5" \
    --filename "${TPFX}_prep-raw_${MOD}" --dir-save ${DIR_SCRATCH}

  # Reorient to RPI ------------------------------------------------------------
  if [[ ${NO_REORIENT} == "false" ]]; then
    reorientRPI --image ${IMG} --dir-save ${DIR_SCRATCH}
    mv ${DIR_SCRATCH}/${TPFX}_prep-reorient_${MOD}.nii.gz ${IMG}
    if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Reoriented to RPI"; fi
  fi

  # Denoise image --------------------------------------------------------------
  if [[ ${NO_DENOISE} == "false" ]]; then
    ricianDenoise --image ${IMG} --dir-save ${DIR_SCRATCH}
    mv ${DIR_SCRATCH}/${TPFX}_prep-denoise_${MOD}.nii.gz ${IMG}
    if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Rician denoised"; fi
  fi

  # Get Foreground mask --------------------------------------------------------
  FG_CLIP=0.4
  brainExtraction --image ${IMG} \
    --method "automask" --automask-clip ${FG_CLIP} \
    --label "fg" --dir-save ${DIR_SCRATCH}
  MASK_FG=${DIR_SCRATCH}/${TPFX}_mod-${MOD}_mask-fg+AUTO.nii.gz
  rename "s/mask-fg/mod-${MOD}_mask-fg/g" ${DIR_SCRATCH}/*
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> FG mask generated"; fi

  # Non-uniformity Correction --------------------------------------------------
  if [[ ${NO_DEBIAS} == "false" ]]; then
    inuCorrection --image ${IMG} --method N4 --mask ${MASK_FG} --dir-save ${DIR_SCRATCH} --keep
    mv ${DIR_SCRATCH}/${TPFX}_prep-biasN4_${MOD}.nii.gz ${IMG}
    rm ${DIR_SCRATCH}/${TPFX}_mod-${MOD}_prep-biasN4_biasField.nii.gz
    if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Non-uniformity corrected"; fi
  fi

  # Rescale intensity ------------------------------------------------------------
  if [[ ${NO_RESCALE} == "false" ]]; then
    rescaleIntensity --image ${IMG} --mask ${MASK_FG} --dir-save ${DIR_SCRATCH}
    mv ${DIR_SCRATCH}/${TPFX}_prep-rescale_${MOD}.nii.gz ${IMG}
    if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Rescale Intensity"; fi
  fi

  # Extract brain mask ---------------------------------------------------------
  brainExtraction --image ${IMG} --method "synth" --dir-save ${DIR_SCRATCH}
  MASK=${DIR_SCRATCH}/${TPFX}_mod-${MOD}_mask-brain+SYNTH.nii.gz
  rename "s/mask-brain/mod-${MOD}_mask-brain/g" ${DIR_SCRATCH}/*
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> FS Synth brain extraction"; fi

  # Coregistration -------------------------------------------------------------
  if [[ ${NO_COREG} == "false" ]]; then
    if [[ ${BMASK^^} == "DO_SYNTH" ]]; then
      BMASK=${DIR_SCRATCH}/tmp_mask-brain+${BMOD}.nii.gz
      mri_synthstrip -i ${BIMG} -m ${BMASK}
    fi
    coregistrationChef --recipe-name ${COREG_RECIPE} \
      --fixed ${BIMG} --fixed-mask ${BMASK} \
      --moving ${IMG} --moving-mask ${MASK} \
      --space-target "fixed" --interpolation "Linear" \
      --prefix ${TPFX} --label-from ${MOD} --label-to native \
      --dir-save ${DIR_SCRATCH} \
      --dir-xfm ${DIR_SCRATCH}/xfm${i}
    rm ${DIR_SCRATCH}/*${COREG_RECIPE}*
    mv ${DIR_SCRATCH}/xfm${i}/*.png ${DIR_SCRATCH}/
    TXFM1=${DIR_SCRATCH}/xfm${i}/${TPFX}_mod-${MOD}_from-${MOD}_to-native_xfm-affine.mat
    TXFM2=${DIR_SCRATCH}/xfm${i}/${TPFX}_mod-${MOD}_from-${MOD}_to-native_xfm-syn.nii.gz
    XFMSTR="-t identity"
    if [[ -f ${TXFM2} ]]; then XFMSTR="${XFMSTR} -t ${TXFM2}"; fi
    if [[ -f ${TXFM1} ]]; then XFMSTR="${XFMSTR} -t ${TXFM1}"; fi
    antsApplyTransforms -d 3 -n BSpline[3] -i ${IMG} -o ${IMG} -r ${BIMG} ${XFMSTR}
    antsApplyTransforms -d 3 -r GenericLabel -i ${MASK_FG} -o ${MASK_FG} -r ${BIMG} ${XFMSTR}
    antsApplyTransforms -d 3 -r GenericLabel -i ${MASK} -o ${MASK} -r ${BIMG} ${XFMSTR}
    make3Dpng --bg ${IMG} --bg-thresh "2.5,97.5"
    make3Dpng --bg ${BIMG} --bg-thresh "2.5,97.5" \
        --bg-color "timbow:hue=#00FF00:lum=0,100:cyc=1/6" \
      --fg ${IMG} --fg-threshold "2.5,97.5" \
        --fg-color "timbow:hue=#FF00FF:lum=0,100:cyc=1/6" \
        --fg-alpha 50 \
        --fg-cbar "false"\
      --layout "9:x;9:x;9:x;9:y;9:y;9:y;9:z;9:z;9:z" \
      --filename ${TPFX}_coregistration \
      --dir-save ${DIR_SCRATCH}
    if [[ -f ${DIR_SCRATCH}/tmp_mask-brain+${BMOD}.nii.gz ]]; then
      rm ${DIR_SCRATCH}/tmp_mask-brain+${BMOD}.nii.gz
    fi
  fi

  # append results to RMD output -----------------------------------------------
  if [[ "${NO_RMD}" == "false" ]]; then
    echo '### Anatomical Processing Results' >> ${RMD}
    echo '### '${TPFX}'_'${MOD}' {.tabset}' >> ${RMD}
    echo '#### Cleaned' >> ${RMD}
    TNII=$(getBidsBase -i ${IMG})
    TPNG=${IMG//.nii.gz}.png
    echo -e '!['${TNII}']('${TPNG}')\n' >> ${RMD}
    echo '#### Raw' >> ${RMD}
    TNII=${AIMG[${i}]}
    TPNG="${DIR_SCRATCH}/${TPFX}_prep-raw_${MOD}.png"
    echo -e '!['${TNII}']('${TPNG}')\n' >> ${RMD}
  fi

  # Normalization --------------------------------------------------------------
  if [[ ${NO_NORM,,} == "false" ]] || [[ ${NO_COREG} == "false" ]]; then
    for (( j=0; j<${#NORM_REF[@]}; j++ )); do
      TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
      xfm_fcn="antsApplyTransforms -d 3 -n BSpline[3]"
      xfm_fcn="${xfm_fcn} -i ${IMG}"
      xfm_fcn="${xfm_fcn} -o ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_${MOD}.nii.gz"
      xfm_fcn="${xfm_fcn} -r ${NORM_REF[${j}]}"
      xfm_fcn="${xfm_fcn} -t identity"
      if [[ -n ${NORM_SYN[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_SYN[${j}]}"; fi
      if [[ -n ${NORM_MAT[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_MAT[${j}]}"; fi
      eval ${xfm_fcn}
      make3Dpng --bg ${NORM_REF[${j}]} --bg-thresh "2.5,97.5" \
        --filename tmp_ref --dir-save ${DIR_SCRATCH}
      make3Dpng --bg ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_${MOD}.nii.gz \
        --bg-thresh "2.5,97.5" --filename tmp_norm
      montage ${DIR_SCRATCH}/tmp_ref.png ${DIR_SCRATCH}/tmp_norm.png \
      -tile 1x -geometry +0+0 -gravity center -background "#000000" \
      ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_${MOD}.png
      rm ${DIR_SCRATCH}/tmp_ref.png
      rm ${DIR_SCRATCH}/tmp_norm.png
    done
  fi

  # generate outcomes based on input modality ----------------------------------
  if [[ ${NO_OUTCOME,,} == "false" ]]; then
    ## make myelin map if T2w
    if [[ ${MOD} == "T2w" ]] && [[ ${BMOD} == "T1w" ]] && [[ ${NO_MYELIN} == "false" ]]; then
      if [[ -z ${TISSUE} ]]; then
        TISSUE=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/${IDPFX}_label-tissue.nii.gz
        TISSUE_VAL=1x2x4
      fi
      mapMyelin --t1 ${BIMG} --t2 ${IMG} \
        --label ${TISSUE} --label-vals ${TISSUE_VAL} \
        --dir-save ${DIR_SCRATCH}
      if [[ ${NO_NORM,,} == "false" ]] || [[ ${NO_COREG} == "false" ]]; then
        for (( j=0; j<${#NORM_REF[@]}; j++ )); do
          TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
          xfm_fcn="antsApplyTransforms -d 3 -n BSpline[3]"
          xfm_fcn="${xfm_fcn} -i ${DIR_SCRATCH}/${TPFX}_myelin.nii.gz"
          xfm_fcn="${xfm_fcn} -o ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_myelin.nii.gz"
          xfm_fcn="${xfm_fcn} -r ${NORM_REF[${j}]}"
          xfm_fcn="${xfm_fcn} -t identity"
          if [[ -n ${NORM_SYN[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_SYN[${j}]}"; fi
          if [[ -n ${NORM_MAT[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_MAT[${j}]}"; fi
          eval ${xfm_fcn}
        done
      fi
    fi

    ## get WM anomalies if FLAIR provided
    if [[ ${MOD} == ${FLAIR} ]] && [[ ${NO_ANOMALY} == "false" ]]; then
      mkdir -p ${DIR_SCRATCH}/tmp_synthseg
      TSEG=${DIR_SCRATCH}/tmp_synthseg/tseg.nii.gz
      TCX=${DIR_SCRATCH}/tmp_synthseg/cx.nii.gz
      TWM=${DIR_SCRATCH}/tmp_synthseg/wm.nii.gz
      mri_synthseg --i ${IMG} --robust --o ${TSEG}
      ## Resize back to anatomical, not 1mm
      antsApplyTransforms -d 3 -n MultiLabel -i ${TSEG} -o ${TSEG} -r ${IMG}
      ## extract CX and WM masks
      niimath ${TSEG} -thr 3 -uthr 3 -bin ${TCX} -odt char
      niimath ${TSEG} -thr 42 -uthr 42 -bin -add ${TCX} ${TCX} -odt char
      niimath ${TSEG} -thr 2 -uthr 2 -bin ${TWM} -odt char
      niimath ${TSEG} -thr 41 -uthr 41 -bin -add ${TWM} ${TWM} -odt char
      ## exclude voxels near cortical ribbon
      niimath ${TCX} -kernel boxv 3 -dilM -binv ${TCX} -odt char
      niimath ${TWM} -mas ${TCX} ${TWM} -odt char
      ## get thresholds
      TV=($(3dBrickStat -mask ${TWM} -mean -stdev ${IMG}))
      LO=($(echo "scale=4; ${TV[0]} - (${WM_THRESH} * ${TV[1]})" | bc -l))
      HI=($(echo "scale=4; ${TV[0]} + (${WM_THRESH} * ${TV[1]})" | bc -l))
      ##generate WM anomaly mask
      HYPO=${DIR_SCRATCH}/tmp_synthseg/hypo.nii.gz
      HYPER=${DIR_SCRATCH}/tmp_synthseg/hyper.nii.gz
      niimath ${IMG} -uthr ${LO} -mas ${TWM} -bin ${HYPO} -odt char
      niimath ${IMG} -thr ${HI} -mas ${TWM} -bin -mul 2 ${HYPER} -odt char
      niimath ${HYPO} -add ${HYPER} ${DIR_SCRATCH}/${TPFX}_mask-anomalyWM.nii.gz -odt char
      make3Dpng --bg ${IMG} --bg-threshold "2.5,97.5" \
        --fg ${DIR_SCRATCH}/${TPFX}_mask-anomalyWM.nii.gz \
        --fg-mask ${DIR_SCRATCH}/${TPFX}_mask-anomalyWM.nii.gz \
        --fg-color "timbow:hue=#FF0000:sat=100:lum=65,65:cyc=5/6:n=2" \
        --fg-alpha 50 --fg-cbar "false" --layout "5:z;5:z;5:z" \
        --filename ${TPFX}_mask-anomalyWM --dir-save ${DIR_SCRATCH}
      rm -rf ./tmp_synthseg
    fi
  fi

  # Save results ---------------------------------------------------------------
  mkdir -p ${DIR_SAVE}/anat/native
  mv ${IMG} ${DIR_SAVE}/anat/native/

  mkdir -p ${DIR_SAVE}/anat/mask/${FLOW}
  mv ${MASK_FG} ${DIR_SAVE}/anat/mask/${FLOW}/
  mv ${MASK} ${DIR_SAVE}/anat/mask/${FLOW}/

  if [[ ${NO_COREG} == "false" ]]; then
    mv ${DIR_SCRATCH}/xfm${i}/* ${DIR_XFM}/
  fi

  if [[ -f ${DIR_SCRATCH}/${TPFX}_myelin.nii.gz ]]; then
    mkdir -p ${DIR_SAVE}/anat/outcomes/myelin_native
    mv ${DIR_SCRATCH}/${TPFX}_myelin.* ${DIR_SAVE}/anat/outcomes/myelin_native/
  fi
  if [[ -f ${DIR_SCRATCH}/${TPFX}_mask-anomalyWM.nii.gz ]]; then
    mkdir -p ${DIR_SAVE}/anat/label
    mv ${DIR_SCRATCH}/${TPFX}_mask-anomalyWM.* ${DIR_SAVE}/anat/label/
  fi

  if [[ ${NO_NORM,,} == "false" ]] || [[ ${NO_COREG} == "false" ]]; then
    for (( j=0; j<${#NORM_REF[@]}; j++ )); do
      TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
      mkdir -p ${DIR_SAVE}/anat/reg_${TRG}
      mv ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_${MOD}.nii.gz ${DIR_SAVE}/anat/reg_${TRG}/
      if [[ -f ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_myelin.nii.gz ]]; then
        mkdir -p ${DIR_SAVE}/anat/outcomes/myelin_${TRG}
        mv ${DIR_SCRATCH}/${TPFX}_reg-${TRG}_myelin.* ${DIR_SAVE}/anat/outcomes/myelin_${TRG}/
      fi
    done
  fi

  # append to RMD output -------------------------------------------------------
  if [[ "${NO_RMD}" == "false" ]]; then
    echo '### Processing Steps {.tabset}' >> ${RMD}
    echo '#### Click to View -->' >> ${RMD}
    if [[ ${NO_REORIENT} == "false" ]]; then
      echo '#### Reorient' >> ${RMD}
      echo -e '![Reorient]('${DIR_SCRATCH}'/'${TPFX}'_prep-reorient_'${MOD}'.png)\n' >> ${RMD}
    fi
    if [[ ${NO_DENOISE} == "false" ]]; then
      echo '#### Denoise' >> ${RMD}
      echo -e '![Denoise]('${DIR_SCRATCH}'/'${TPFX}'_prep-denoise_'${MOD}'.png)\n' >> ${RMD}
      echo -e '![Noise]('${DIR_SCRATCH}'/'${TPFX}'_prep-noise_'${MOD}'.png)\n' >> ${RMD}
    fi
    echo '#### FG Mask' >> ${RMD}
    echo -e '![FG Mask]('${DIR_SCRATCH}'/'${TPFX}'_mod-'${MOD}'_mask-fg+AUTO.png)\n' >> ${RMD}
    if [[ ${NO_DEBIAS} == "false" ]]; then
      echo '#### Debias' >> ${RMD}
      echo -e '![Debias]('${DIR_SCRATCH}'/'${TPFX}'_prep-biasN4_'${MOD}'.png)\n' >> ${RMD}
      echo -e '![Bias]('${DIR_SCRATCH}'/'${TPFX}'_mod-'${MOD}'_prep-biasN4_biasField.png)\n' >> ${RMD}
    fi
    if [[ ${NO_RESCALE} == "false" ]]; then
      echo '#### Rescale' >> ${RMD}
      echo -e '![Rescale]('${DIR_SCRATCH}'/'${TPFX}'_prep-rescale_'${MOD}'.png)\n' >> ${RMD}
    fi
    echo '#### Brain Mask' >> ${RMD}
    echo -e '![Brain Mask]('${DIR_SCRATCH}'/'${TPFX}'_mod-'${MOD}'_mask-brain+SYNTH.png)\n' >> ${RMD}
    if [[ ${NO_COREG} == "false" ]]; then
      echo '#### Coregistration' >> ${RMD}
      echo -e '![Coregistration]('${DIR_SCRATCH}'/'${TPFX}'_coregistration.png)\n' >> ${RMD}
    fi
    if [[ ${NO_NORM,,} == "false" ]] || [[ ${NO_COREG} == "false" ]]; then
      echo '#### Normalization' >> ${RMD}
      for (( j=0; j<${#NORM_REF[@]}; j++ )); do
        TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
        echo -e '!['${TRG}']('${DIR_SCRATCH}'/'${TPFX}'_reg-'${TRG}'_'${MOD}'.png)\n' >> ${RMD}
      done
    fi
    if [[ ${NO_OUTCOME,,} == "false" ]]; then
      if [[ ${MOD} == "T2w" ]] && [[ ${BMOD} == "T1w" ]] && [[ ${NO_MYELIN} == "false" ]]; then
        echo '#### Myelin' >> ${RMD}
        echo -e '![Myelin]('${DIR_SAVE}'/anat/outcomes/myelin_native/'${TPFX}'_myelin.png)\n' >> ${RMD}
      fi
      if [[ ${MOD} == "FLAIR" ]] && [[ ${NO_ANOMALY} == "false" ]]; then
        echo '#### WM Anomaly' >> ${RMD}
        echo -e '![WM Anomaly]('${DIR_SAVE}'/anat/label/'${TPFX}'_mask-anomalyWM.png)\n' >> ${RMD}
      fi
    fi
  fi
done

if [[ "${NO_RMD}" == "false" ]]; then
  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
  mv ${DIR_SCRATCH}/*.html ${DIR_PROJECT}/qc/${PIPE}${FLOW}/
fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
