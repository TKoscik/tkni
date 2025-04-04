#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkniUHR
# WORKFLOW:      UHRClean
# DESCRIPTION:   TKNI anatomical multi-atlas labelling
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-07
# README:
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
OPTS=$(getopt -o hkvn --long pi:,project:,dir-project:,\
id:,dir-id:,image:,threads:,\
no-debias:,no-denoise:,no-rescale:\
debias-bspline:,debias-shrink:,debias-convergence:,debias-histmatch:\
dir-save:,dir-scratch:,\
keep,help,verbose,no-png -n 'parse-options' -- "$@")
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
IDFIELD="uid,ses"

IMAGE=
THREADS=4

NO_REORIENT="false"
NO_DEBIAS="false"
NO_DENOISE="false"
NO_RESIZE="false"
NO_RESCALE="false"
NO_SMOOTH="false"
NO_ALIGN="false"

REORIENT_CODE="LSA"
REORIENT_DEOBLIQUE="false"

DEBIAS_BSPLINE="[300,3,0.0,0.5]"
DEBIAS_SHRINK=16
DEBIAS_CONVERGENCE="[500x500x500x500,0.001]"
DEBIAS_HISTMATCH="[0.3,0.01,200]"

DENOISE_MODEL="Rician"
DENOISE_SHRINK="1"
DONOISE_PATCH="1x1x1"
DENOISE_SEARCH="3x3x3"

RESCALE_LO=0
RESCALE_HI=1
RESCALE_MAX=32767
RESCALE_TYPE="int16"

MASK_CLFRAC=0.25

RESIZE=
RESIZE_PRECISION=100000

SMOOTH_ITER=10
SMOOTH_SIGMA1=0.5
SMOOTH_SIGMA2=1.0
SMOOTH_DELTAT=0.25
SMOOTH_EDGEFRAC=0.5

ALIGN_FIXED=${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz
ALIGN_MASK=${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_mask-brain.nii.gz

DIR_SAVE=
DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}

KEEP="false"
HELP="false"
VERBOSE="false"
NO_PNG="false"

PIPE=tkni
FLOW=${FCN_NAME//${PIPE}}
REQUIRES="tkniDICOM"
FORCE=false

while true; do
  case "$1" in
    -h | --help) HELP="true" ; shift ;;
    -v | --verbose) VERBOSE="true" ; shift ;;
    -n | --no-png) NO_PNG="true" ; shift ;;
    -r | --no-rmd) NO_PNG="true" ; shift ;;
    -k | --keep) KEEP="true" ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --image) IMAGE="$2" ; shift 2 ;;
    --threads) THREADS="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
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
  echo '  --pid              unique individual identifier'
  echo '  --sid              session identifier'
  echo '  --input-dcm        full path to DICOMs, may be directory or zip-file'
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  echo 'Procedure: '
  echo '(1) denoise image'
  echo '(2) rough tissue segmentation for WM mask using synthseg'
  echo '(3) intensity debias'
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
  TFIELD=(${IDFIELD//,/ })
  TID=$(getField -i ${IDPFX} -f ${TFIELD[0]})
  IDDIR="${TFIELD[0]}-${TID}"
  for (( i=1; i<${#TFIELD[@]}; i++)); do
    unset TID
    TID=$(getField -i ${IDPFX} -f ${TFIELD[${i}]})
    if [[ -n ${TID} ]]; then
      IDDIR="${IDDIR}/${TFIELD[${i}]}-${TID}"
    fi
  done
fi
if [[ ${VERBOSE} == "true" ]]; then
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

# Identify UHR Inputs ----------------------------------------------------------
if [[ -z ${IMAGE} ]]; then
  IMAGE=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/anat/${IDPFX}*swi.nii.gz))
else
  IMGTMP=(${IMAGE//,/ })
  MISSING="false"
  unset IMAGE
  for (( i=0; i<${#IMGTMP[@]}; i++ )); do
    if [[ -d ${IMGTMP[${i}]} ]]; then
      IMAGE+=($(ls ${IMGTMP[${i}]}/*.nii.gz))
    else
      if [[ -f ${IMGTMP[${i}]} ]]; then
        IMAGE+=${IMGTMP[${i}]}
      else
        if [[ ${MISSING} == "false" ]]; then
          echo "ERROR [${PIPE}:${FLOW}] Specified Input file not found"
        fi
        echo "   Could not find: ${IMGTMP[${i}]}"
        MISSING="true"
      fi
    fi
  done
fi
if [[ ${MISSING} == "true" ]]; then
  exit 1
fi
NIMG=${#IMAGE[@]}

if [[ ${VERBOSE} == "true" ]]; then
  echo -e "##### ${PIPE}: ${FLOW} #####"
  echo -e "PI:\t\t${PI}"
  echo -e "PROJECT:\t${PROJECT}"
  echo ">>>>>processing ${NIMG} image"
  for (( i=0; i<${NIMG}; i++ )); do
    echo -e "IMAGE:\t${IMAGE[${i}]}"
  done
fi

DIRTMP=${DIR_SCRATCH}/tmp
mkdir -p ${DIRTMP}

for (( i=0; i<${NIMG}; i++ )); do
  rm ${DIRTMP}/*
  IMG=${IMAGE[${i}]}

  # initialize outputs ---------------------------------------------------------
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)

  # Copy RAW image to scratch --------------------------------------------------
  TIMG=${DIRTMP}/image_raw.nii.gz
  cp ${IMG} ${TIMG}
  if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == false ]]; then
    make3Dpng --bg ${DIRTMP}/image_raw.nii.gz
  fi

  # Fix Orientation ------------------------------------------------------------
  if [[ ${NO_REORIENT} == "false" ]]; then
    3dresample -orient ${REORIENT_CODE} -overwrite \
      -prefix ${DIRTMP}/image_reorient.nii.gz -input ${TIMG}
    CopyImageHeaderInformation ${TIMG} \
      ${DIRTMP}/image_reorient.nii.gz \
      ${DIRTMP}/image_reorient.nii.gz 1 0 0
    3dresample -orient RPI -overwrite \
      -prefix ${DIRTMP}/image_reorient.nii.gz \
      -input ${DIRTMP}/image_reorient.nii.gz
    if [[ ${REORIENT_DEOBLIQUE} == "true" ]]; then
      3dWarp -deoblique -overwrite \
        -prefix ${DIRTMP}/image_reorient.nii.gz \
        -input ${DIRTMP}/image_reorient.nii.gz
    fi
    if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == false ]]; then
      make3Dpng --bg ${DIRTMP}/image_reorient.nii.gz
    fi
    TIMG=${DIRTMP}/image_reorient.nii.gz
  fi

  # get Image Dimensions, and plane of acquisition -------------------------
  DIM=($(niiInfo -i ${TIMG} -f "voxels"))
  if [[ ${DIM[0]} -lt ${DIM[1]} ]] && [[ ${DIM[0]} -lt ${DIM[2]} ]]; then PLANE="x"; fi
  if [[ ${DIM[1]} -lt ${DIM[0]} ]] && [[ ${DIM[1]} -lt ${DIM[2]} ]]; then PLANE="y"; fi
  if [[ ${DIM[2]} -lt ${DIM[0]} ]] && [[ ${DIM[2]} -lt ${DIM[1]} ]]; then PLANE="z"; fi
  if [[ -z ${PLANE} ]]; then PLANE="z"; fi
  #*** be sure to updata filename to reflect this reorientation!

  # Debias ---------------------------------------------------------------------
  if [[ ${NO_DEBIAS} == "false" ]]; then
    MIN=$(3dBrickStat -slow -min ${TIMG})
    niimath ${TIMG} -add ${MIN//-} -add 10 ${DIRTMP}/tmp.nii.gz
    N4BiasFieldCorrection -d 3 \
      -i ${DIRTMP}/tmp.nii.gz  \
      -o [${DIRTMP}/image_debias.nii.gz,${DIRTMP}/image_biasField.nii.gz ] \
      --bspline-fitting ${DEBIAS_BSPLINE} \
      --shrink-factor ${DEBIAS_SHRINK} \
      --convergence ${DEBIAS_CONVERGENCE} \
      --histogram-sharpening ${DEBIAS_HISTMATCH}
    rm ${DIRTMP}/tmp.nii.gz
    if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == false ]]; then
      make3Dpng --bg ${DIRTMP}/image_debias.nii.gz --layout "1:${PLANE}"
      make3Dpng --bg ${DIRTMP}/image_biasField.nii.gz \
        --layout "1:${PLANE}" --bg-color "plasma"
    fi
    TIMG=${DIRTMP}/image_debias.nii.gz
  fi

  # Denoise --------------------------------------------------------------------
  if [[ ${NO_DENOISE} == "false" ]]; then
    if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>Denoising"; fi
    DenoiseImage -d 3 -n ${DENOISE_MODEL} \
      --shrink-factor ${DENOISE_SHRINK} \
      --patch-radius ${DENOISE_PATCH} \
      --search-radius ${DENOISE_SEARCH} \
      -i ${TIMG} \
      -o [${DIRTMP}/image_denoise.nii.gz,${DIRTMP}/image_noise.nii.gz]
    if [[ ${NO_PNG} == "false" ]] || [[ ${NO_RMD} == false ]]; then
      make3Dpng --bg ${DIRTMP}/image_denoise.nii.gz --layout "1:${PLANE}" --max-pixels 1024
      make3Dpng --bg ${DIRTMP}/image_noise.nii.gz \
        --layout "1:${PLANE}" --bg-cbar "true" --bg-color "virid-esque" --max-pixels 1024
    fi
    TIMG=${DIRTMP}/image_denoise.nii.gz
  fi

  # make preliminary FG mask ---------------------------------------------------
  ##3dAutomask -prefix ${DIR_SCRATCH}/mask.nii.gz -overwrite -q -clfrac ${MASK_CLFRAC} ${TIMG}

  # Attempt brain extraction ---------------------------------------------------
  ResampleImage 3 ${TIMG} ${DIRTMP}/image_downsample.nii.gz 1x1x1 0 4
  brainExtraction --image ${TIMG} --method "skullstrip,autmask,ants,bet,synth" \
    --dir-save ${DIRTMP}/mask

  # Coregistration -------------------------------------------------------------
  coregistrationChef --recipe-name intermodalRigid \
    --fixed ${ALIGN_FIXED} --fixed-mask ${FIXED_MASK} --fixed-mask-dilation 3 \
    --moving ${DIRTMP}/image_downsample.nii.gz \
    --moving-mask ${DIRTMP}/mask/image_mask-brain+MALF.nii.gz \
    --moving-mask-dilation 3 \
    --dir-save ${DIRTMP}/xfm

  # Resize ---------------------------------------------------------------------
  if [[ ${NO_RESIZE} == "false" ]]; then
    if [[ -z ${RESIZE} ]]; then
      TSZ=($(niiInfo -i ${IMG} -f "spacing"))
      X=$(printf '%.0f' $(echo "scale=0; ${TSZ[0]} * ${RESIZE_PRECISION}" | bc -l))
      Y=$(printf '%.0f' $(echo "scale=0; ${TSZ[1]} * ${RESIZE_PRECISION}" | bc -l))
      Z=$(printf '%.0f' $(echo "scale=0; ${TSZ[2]} * ${RESIZE_PRECISION}" | bc -l))
      if [[ ${X} -le ${Y} ]] && [[ ${X} -le ${Z} ]]; then SZ=${TSZ[0]}; fi
      if [[ ${Y} -le ${X} ]] && [[ ${Y} -le ${Z} ]]; then SZ=${TSZ[1]}; fi
      if [[ ${Z} -le ${X} ]] && [[ ${Z} -le ${Y} ]]; then SZ=${TSZ[2]}; fi
      RESIZE="${SZ}x${SZ}x${SZ}"
    fi
    SZSTR=(${RESIZE//x/ })
    for i in {0..2}; do
      SZSTR[${i}]=$(echo "scale=0; ${SZSTR[${i}]} * 1000 / 1" | bc -l)
    done
    SZSTR=$(echo ${SZSTR[@]})
    SZSTR="${SZSTR// /x}um"
    ResampleImage 3 ${TIMG} ${DIRTMP}/image_resize.nii.gz ${RESIZE} 0 4

    #antsApplyTransforms -d 3 -n GenericLabel \
    #  -i ${DIR_SCRATCH}/mask.nii.gz -o ${DIR_SCRATCH}/mask.nii.gz \
    #  -r ${DIR_SCRATCH}/image_resize.nii.gz
    if [[ ${NO_PNG} == "false" ]]; then
      make3Dpng --bg ${DIRTMP}/image_resize.nii.gz --layout "1:${PLANE}" \
        --no-reorient --max-pixels 1024
    fi
    TIMG=${DIRTMP}/image_resize.nii.gz
  fi



  # Rescale to Short integer ---------------------------------------------------
  if [[ ${NO_RESCALE} == "false" ]]; then
    rescaleIntensity --lo ${RESCALE_LO} --hi ${RESCALE_HI} \
      --max ${RESCALE_MAX} --datatype ${RESCALE_TYPE} \
      --image ${TIMG} --mask ${DIR_SCRATCH}/mask.nii.gz \
      --filename image_rescale
    mv ${DIR_SCRATCH}/image_rescale.nii.gz ${DIR_SCRATCH}/image.nii.gz
  fi




  # Anisotropic Smoothing ------------------------------------------------------
  if [[ ${NO_SMOOTH} == "false" ]]; then
    SMOOTH_ITER=10
    SMOOTH_SIGMA1=0.5
    SMOOTH_SIGMA2=1.0
    SMOOTH_DELTAT=0.0004
    SMOOTH_EDGEFRAC=0; #0
    3danisosmooth -prefix ${DIR_SCRATCH}/image_anisosmooth.nii.gz \
      -mask ${DIR_SCRATCH}/mask.nii.gz \
      -3D -phiding -matchorig \
      -iters ${SMOOTH_ITER} \
      -sigma1 ${SMOOTH_SIGMA1} \
      -sigma2 ${SMOOTH_SIGMA2} \
      -deltat ${SMOOTH_DELTAT} \
      -edgefraction ${SMOOTH_EDGEFRAC} \
      ${DIR_SCRATCH}/image.nii.gz

    #SIF_CIVET="/data/neuroimage_containers/civet_v2.1.1.sif"
    #gunzip ${DIR_SCRATCH}/image.nii.gz
    #singularity instance start --bind ${DIR_SCRATCH}:/mnt ${SIF_CIVET} civet
    #singularity exec instance://civet nii2mnc /mnt/image.nii /mnt/tmp.mnc
    #singularity exec instance://civet geo_smooth 0.0004 6 /mnt/tmp.mnc /mnt/tmpsmooth.mnc
    #singularity exec instance://civet mnc2nii /mnt/tmpsmooth.mnc /mnt/smooth.nii
    #singularity instance stop civet
    #gzip ${DIR_SCRATCH}/smooth.nii
    #reorientRPI --image ${DIR_SCRATCH}/smooth.nii.gz
    #mv ${DIR_SCRATCH}/smooth.nii.gz ${DIR_SCRATCH}/image.nii.gz
    #rm ${DIR_SCRATCH}/tmp*

    if [[ ${NO_PNG} == "false" ]]; then
      make3Dpng --bg ${DIR_SCRATCH}/image_anisosmooth.nii.gz --layout "1:${PLANE}" --max-pixels 1024
    fi
    mv ${DIR_SCRATCH}/image_anisosmooth.nii.gz ${DIR_SCRATCH}/image.nii.gz
  fi



  # Align to template ----------------------------------------------------------
  if [[ ${NO_ALIGN} == "false" ]]; then
    if [[ -z ${ALIGN_FIXED} ]]; then
      ALIGN_FIXED=${DIR_SCRATCH}/fixed.nii.gz
      niimath ${ALIGN_ATLAS} -mas ${ALIGN_MASK} ${DIR_SCRATCH}/fixed.nii.gz
    fi
    antsAI -d 3 \
      --transform Rigid[0.3] \
      --metric Mattes[${ALIGN_FIXED},${DIR_SCRATCH}/image.nii.gz] \
      --align-blobs 1 \
      --output ${DIR_SCRATCH}/image_aligned.nii.gz
  fi

  # Save Output

  ## add size string
  LSZ=(${RESIZE//x/ })
  LSZ[0]=$(echo "scale=0; ${LSZ[0]} * 1000" | bc -l)
  LSZ[1]=$(echo "scale=0; ${LSZ[1]} * 1000" | bc -l)
  LSZ[2]=$(echo "scale=0; ${LSZ[2]} * 1000" | bc -l)
  RESIZE_LABEL="${LSZ[0]}x${LSZ[1]}x${LSZ[2]}um"

done



#===============================================================================
# End of Function
#===============================================================================
exit 0

