#!/bin/bash -e
#===============================================================================
# Summarize Results of TKNI Pipelines
# Required: MRtrix3, ANTs, FSL
# Description:
# Author: Timothy R. Koscik, PhD
# Date Created: 2024-03-05
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
png-redo,\
dir-save:,dir-scratch:,\
help,verbose -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
PI=
PROJECT=
PIPELINE=tkni
DIR_PROJECT=
DIR_SCRATCH=
IDPFX=
IDDIR=
DIR_SAVE=
HELP=false
VERBOSE=false
PNG_REDO=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --png-redo) PNG_REDO="true" ; shift ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
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
if [[ ${VERBOSE} == "true" ]]; then echo "TKNI Pipeline SUMMARIZER"; fi

# set project defaults ---------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [TKNI:${FCN_NAME}] PROJECT must be provided"
  exit 1
fi
if [[ -z ${DIR_PROJECT} ]]; then
  DIR_PROJECT=/data/x/projects/${PI}/${PROJECT}
fi
if [[ -z ${DIR_SCRATCH} ]]; then
  DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi
mkdir -p ${DIR_SCRATCH}
if [[ ${VERBOSE} == "true" ]]; then
  echo ">>>>>Project information set"
  echo -e "\tPI:\t${PI}"
  echo -e "\tPROJECT:\t${PROJECT}"
  echo -e "\tDIR_PROJECT:\t${DIR_PROJECT}"
  echo -e "\tPIPELINE:\t${PIPELINE} - ${FCN_NAME}"
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
  echo -e "\tID:\t${IDPFX}"
  echo -e "\tDIR_SUBJECT:\t${IDDIR}"
fi

# set up directories -----------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Locate up directories"; fi
DIR_SRC=${DIR_PROJECT}/sourcedata
DIR_RAW=${DIR_PROJECT}/rawdata/${IDDIR}
DIR_ANAT=${DIR_PROJECT}/derivatives/${PIPELINE}/anat
DIR_FSSYNTH=${DIR_PROJECT}/derivatives/fsSynth/${IDPFX}
DIR_DWI=${DIR_PROJECT}/derivatives/${PIPELINE}/dwi
DIR_MRTRIX=${DIR_PROJECT}/derivatives/mrtrix/${IDDIR}
DIR_FUNC=${DIR_PROJECT}/derivatives/${PIPELINE}/func
DIR_XFM=${DIR_PROJECT}/derivatives/${PIPELINE}/xfm/${IDDIR}
DIR_SUMMARY=${DIR_PROJECT}/derivatives/${PIPELINE}/summary

## Identify all files to output ================================================
# check for images if the don't exist make them
# Raw Acquisitions -------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Locate Raw Data"; fi
IMG_RAW=($(find ${DIR_RAW} -name "${IDPFX}*.nii.gz"))

# Anatomicals ------------------------------------------------------------------
## Base anatomical, other native modalities, normalized, masks, labels,
## posteriors, and outcomes
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Locate Anatomical Processes"; fi
if [[ -f "${DIR_ANAT}/native/${IDPFX}_T1w.nii.gz" ]]; then
  ANAT_BASE=${DIR_ANAT}/native/${IDPFX}_T1w.nii.gz
elif [[ -f "${DIR_ANAT}/native/${IDPFX}_T2w.nii.gz" ]]; then
  ANAT_BASE=${DIR_ANAT}/native/${IDPFX}_T2w.nii.gz
else
  TIMG=($(ls ${DIR_ANAT}/native/${IDPFX}*.nii.gz 2>/dev/null))
  ANAT_BASE=${TIMG[0]}
fi
ANAT_BASE_MOD=$(getField -i ${ANAT_BASE} -f modality)
ANAT_OTHER=($(find ${DIR_ANAT}/native -name "${IDPFX}*.nii.gz"))
ANAT_OTHER=(${ANAT_OTHER[@]/${ANAT_BASE}})
ANAT_COREG=($(find ${DIR_ANAT}/reg* -name "${IDPFX}*overlay.png"))
ANAT_BASE_NORM=($(find ${DIR_ANAT}/reg* -name "${IDPFX}*${ANAT_BASE_MOD}.nii.gz"))
ANAT_OTHER_NORM=($(find ${DIR_ANAT}/reg* -name "${IDPFX}*.nii.gz"))
for (( i=0; i<${#ANAT_BASE_NORM[@]}; i++ )); do
  ANAT_OTHER_NORM=(${ANAT_OTHER_NORM[@]/${ANAT_BASE_NORM[${i}]}})
done
ANAT_MASK=($(ls ${DIR_ANAT}/mask/${IDPFX}*mask*.nii.gz 2>/dev/null))
ANAT_LABEL=($(ls ${DIR_ANAT}/label/${IDPFX}*label*.nii.gz 2>/dev/null))
ANAT_POST=($(ls ${DIR_ANAT}/posterior/${IDPFX}*posterior*.nii.gz 2>/dev/null))
ANAT_OUT=($(find ${DIR_ANAT}/outcomes -name ${IDPFX}*.nii.gz))

# Diffusion Processing ---------------------------------------------------------
## B0, mask, coreg result, % outliers, scalars, mrtrix, tracts, connectomes
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Locate Diffusion Processes"; fi
DWI_B0=($(ls ${DIR_DWI}/preproc/b0/${IDPFX}_b0.nii.gz 2>/dev/null))
DWI_MASK=($(ls ${DIR_DWI}/preproc/mask/${IDPFX}_mask-brain+b0.nii.gz 2>/dev/null))
DWI_OUTLIERS=($(cat ${DIR_DWI}/preproc/qc/${IDPFX}_pctOutliers.txt))
DWI_COREG=($(ls ${DIR_DWI}/preproc/qc/${IDPFX}*overlay.png 2>/dev/null))
DWI_CLEAN=($(ls ${DIR_DWI}/preproc/dwi/${IDPFX}*dwi.nii.gz 2>/dev/null))
DWI_TENSOR=($(ls ${DIR_DWI}/tensor/${IDPFX}*.nii.gz 2>/dev/null))
DWI_SCALAR=($(ls ${DIR_DWI}/scalar/${IDPFX}*.nii.gz 2>/dev/null))
if [[ -d ${DIR_MRTRIX} ]]; then
  DWI_TRACT=${DIR_MRTRIX}/TCK/smallerSift_200k.png
else
  DWI_TRACT=
fi
DWI_CONNECTOME=($(ls ${DIR_DWI}/connectome/${IDPFX}*.csv 2>/dev/null))

# Functional Processing -------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Locate Functional Processes"; fi
FUNC_MEAN=($(ls ${DIR_FUNC}/mean/${IDPFX}*proc-mean_bold.nii.gz 2>/dev/null))
FUNC_MASK=($(ls ${DIR_FUNC}/mask/${IDPFX}*mask-brain.nii.gz 2>/dev/null))
FUNC_QC=($(ls ${DIR_FUNC}/qc/${IDDIR}/${IDPFX}*.png 2>/dev/null))
FUNC_RESID=($(ls ${DIR_FUNC}/residual_native/${IDPFX}*residual.nii.gz 2>/dev/null))
FUNC_TS=($(ls ${DIR_FUNC}/ts_*/${IDPFX}*.csv 2>/dev/null))
FUNC_TZ=($(ls ${DIR_FUNC}/tensorZ/${IDPFX}*tensor-z.nii.gz 2>/dev/null))
FUNC_LFF=($(ls ${DIR_FUNC}/rsfc_parameters/${IDPFX}*_LFF.nii.gz 2>/dev/null))
FUNC_RSFC=($(ls ${DIR_FUNC}/rsfc_parameters/${IDPFX}*.nii.gz 2>/dev/null))
for (( i=0; i<${#FUNC_LFF[@]}; i++ )); do
  FUNC_RSFC=(${FUNC_RSFC[@]/${FUNC_LFF[${i}]}})
done
FUNC_CON_R=($(ls ${DIR_FUNC}/connectivity/${IDPFX}*pearsonR.csv 2>/dev/null))
FUNC_CON_TE=($(ls ${DIR_FUNC}/connectivity/${IDPFX}*transferEntropy.csv 2>/dev/null))
FUNC_CON=($(ls ${DIR_FUNC}/connectivity/${IDPFX}*.csv 2>/dev/null))
for (( i=0; i<${#FUNC_CON_R[@]}; i++ )); do
  FUNC_CON=(${FUNC_CON[@]/${FUNC_CON_R[${i}]}})
done
for (( i=0; i<${#FUNC_CON_TE[@]}; i++ )); do
  FUNC_CON=(${FUNC_CON[@]/${FUNC_CON_TE[${i}]}})
done
FUNC_CON=(${FUNC_CON_R[@]} ${FUNC_CON_TE[@]} ${FUNC_CON[@]})

# Transformations --------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Locate Transforms"; fi
XFM_NORM_AFFINE=${DIR_XFM}/${IDPFX}_from-native*xfm-affine.mat
XFM_NORM_SYN=${DIR_XFM}/${IDPFX}_from-native*xfm-syn.nii.gz

# Make PNGS ====================================================================
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Check/Generate PNGs"; fi
# multiple slice orienations for Base image
if [[ ${VERBOSE} == "true" ]]; then echo "  >>>Base Anatomical Image"; fi
DNAME=$(dirname ${ANAT_BASE})
BNAME=$(basename ${ANAT_BASE%%.*})
TAXI=$(modField -i ${BNAME} -a -f slice -v axial)
TCOR=$(modField -i ${BNAME} -a -f slice -v coronal)
TSAG=$(modField -i ${BNAME} -a -f slice -v sagittal)
if [[ ! -f ${DNAME}/${BNAME}.png ]] || [[ ${PNG_REDO} == "true" ]]; then
  make3Dpng --bg ${ANAT_BASE} --bg-thresh "2.5,97.5"
fi
if [[ ! -f "${DNAME}/${TAXI}.png" ]] || [[ ${PNG_REDO} == "true" ]]; then
  make3Dpng --bg ${ANAT_BASE} --bg-thresh "2.5,97.5" \
    --layout "9:z;9:z;9:z" --offset "0,0,0" \
    --filename ${TAXI}
fi
if [[ ! -f "${DNAME}/${TCOR}.png" ]] || [[ ${PNG_REDO} == "true" ]]; then
  make3Dpng --bg ${ANAT_BASE} --bg-thresh "2.5,97.5" \
    --layout "9:y;9:y;9:y" --offset "0,0,0" \
    --filename ${TCOR}
fi
if [[ ! -f "${DNAME}/${TSAG}.png" ]] || [[ ${PNG_REDO} == "true" ]]; then
  make3Dpng --bg ${ANAT_BASE} --bg-thresh "2.5,97.5" \
    --layout "9:x;9:x;9:x" --offset "0,0,0" \
    --filename ${TSAG}
fi

## Basic 3D --------------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "  >>>Basic 3D images"; fi
unset BGLS
BGLS=("${IMG_RAW[@]}" "${ANAT_OTHER[@]}" "${ANAT_BASE_NORM[@]}" \
      "${ANAT_OTHER_NORM[@]}" "${DWI_B0[@]}" "${FUNC_MEAN[@]}")
for (( i=0; i<${#BGLS[@]}; i++ )); do
  BG=${BGLS[${i}]}
  TPNG="${BG%%.*}.png"
  DAT=$(niiInfo -i ${BG} -f datatype)
  if [[ ${DAT} -ne 128 ]]; then
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    NVOL=$(niiInfo -i ${BG} -f "volumes")
    if [[ ${NVOL} -eq 1 ]]; then
      make3Dpng --bg ${BG} --bg-threshold "2.5,97.5"
    elif [[ ${NVOL} -le 5 ]]; then
      montage_fcn="montage"
      for (( j=1; j<=${NVOL}; j++ )); do
        make3Dpng --bg ${BG} --bg-vol ${j} --bg-threshold "2.5,97.5" \
          --filename vol${j} --dir-save ${DIR_SCRATCH}
        montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
      done
      montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
      montage_fcn=${montage_fcn}' -background "#FFFFFF"'
      montage_fcn="${montage_fcn} ${TPNG}"
      eval ${montage_fcn}
      rm ${DIR_SCRATCH}/vol*.png
    else
      make3Dpng --bg ${BG} --bg-threshold "2.5,97.5"
    fi
  fi
  fi
done


## Basic 4D --------------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "  >>>Basic 4D images"; fi
unset BG FGLS MASK
BG=${ANAT_BASE}
FGLS=("${DWI_CLEAN[@]}")
MASK=${DWI_MASK}
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    make4Dpng --bg ${BG} --bg-threshold "2.5,97.5" \
      --fg ${FG} --fg-color "hot" --fg-threshold "2.5,97.5" \
      --fg-cbar "false" --fg-alpha 50 --fg-mask ${MASK} \
      --plane z --layout "9;9;9;9;9" \
      --filename $(basename ${FG%%.*})
  fi
done

FGLS=("${FUNC_RESID[@]}" "${FUNC_TZ[@]}" "${FUNC_LFF[@]}")
MASK=${FUNC_MASK}
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TMOD=$(getField -i ${FG} -f modality)
  if [[ ${TMOD} == "tensor-z" ]]; then fslmaths ${FG} -nan ${FG}; fi
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    make4Dpng --bg ${BG} --bg-threshold "2.5,97.5" \
      --fg ${FG} --fg-color "hot" --fg-threshold "2.5,97.5" \
      --fg-cbar "false" --fg-alpha 50 --fg-mask ${MASK} \
      --plane z --layout "9;9;9;9;9" \
      --filename $(basename ${FG%%.*})
  fi
done

## With Masked Regions ---------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "  >>>Masked Regions"; fi
unset BG FGLS
BG=${ANAT_BASE}
FGLS=("${ANAT_MASK[@]}")
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    make3Dpng --bg ${BG} --bg-thresh "2.5,97.5" \
      --fg ${FG} --fg-color "#FF0000" --fg-cbar "false" --fg-alpha 50 \
      --layout "11:z;11:y;11:x" --offset "0,0,0" \
      --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
  fi
done

unset BG FGLS
BG=${DWI_B0}
FGLS=("${DWI_MASK[@]}")
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    make3Dpng --bg ${BG} --bg-thresh "2.5,97.5" \
      --fg ${FG} --fg-color "#FF0000" --fg-cbar "false" --fg-alpha 50 \
      --layout "11:z;11:y;11:x" --offset "0,0,0" \
      --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
  fi
done

unset BG FGLS
BG=${FUNC_MEAN}
FGLS=("${FUNC_MASK[@]}")
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    make3Dpng --bg ${BG} --bg-thresh "2.5,97.5" \
      --fg ${FG} --fg-color "#FF0000" --fg-cbar "false" --fg-alpha 50 \
      --layout "11:z;11:y;11:x" --offset "0,0,0" \
      --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
  fi
done

## With Discrete Overlays ------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "  >>>Discrete Overlays"; fi
unset BG FGLS
BG=${ANAT_BASE}
FGLS=("${ANAT_LABEL[@]}")
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TNAME=${FG%.*}
  TPNG="${TNAME%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    make3Dpng --bg ${BG} --bg-threshold "2.5,97.5" \
      --fg ${FG} --fg-color "timbow" --fg-order random --fg-discrete \
      --fg-cbar "false" --fg-alpha 50 \
      --layout "7:x;7:x;7:y;7:y;7:z;7:z" --offset "0,0,0" \
      --filename $(basename ${TPNG%.*}) --dir-save $(dirname ${FG})
  fi
done

## With Continuous Overlays ----------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "  >>>Continous Overlays"; fi
unset BG FGLS
BG=${ANAT_BASE}
FGLS=("${ANAT_POST[@]}")
TLO="0.2"
THI="1"
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    NVOL=$(niiInfo -i ${FG} -f volumes)
    if [[ ${NVOL} -eq 1 ]]; then
      fslmaths ${FG} -thr ${TLO} -uthr ${THI} \
        -bin ${DIR_SCRATCH}/TMASK.nii.gz -odt char
      make3Dpng --bg ${BG} --bg-threshold "2.5,97.5" \
        --fg ${FG} --fg-mask ${DIR_SCRATCH}/TMASK.nii.gz \
        --fg-color "hot" --fg-cbar "true" --fg-threshold "2.5,97.5" --fg-alpha 50 \
        --layout "9:z;9:z;9:z" --offset "0,0,0" \
        --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
    else
      fslsplit ${FG} ${DIR_SCRATCH}/t -t
      montage_fcn="montage"
      for (( j=1; j<=${NVOL}; j++ )); do
        VNUM=$(printf "%04d" $((${j} - 1)))
        fslmaths ${DIR_SCRATCH}/t${VNUM}.nii.gz -thr ${TLO} -uthr ${THI} \
          -bin ${DIR_SCRATCH}/TMASK.nii.gz -odt char
        make3Dpng --bg ${BG} --bg-threshold "2.5,97.5" \
          --fg ${DIR_SCRATCH}/t${VNUM}.nii.gz \
          --fg-mask ${DIR_SCRATCH}/TMASK.nii.gz \
          --fg-color "hot" --fg-cbar "true" --fg-threshold "2.5,97.5" --fg-alpha 50 \
          --layout "9:z;9:z;9:z" --offset "0,0,0" \
          --filename vol${j} --dir-save ${DIR_SCRATCH}
        montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
      done
      montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
      montage_fcn=${montage_fcn}' -background "#FFFFFF"'
      montage_fcn="${montage_fcn} ${TPNG}"
      eval ${montage_fcn}
      rm ${DIR_SCRATCH}/vol*.png
    fi
  fi
done

unset BG FGLS
FGLS=("${ANAT_OUT[@]}")
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    NVOL=$(niiInfo -i ${FG} -f volumes)
    if [[ ${NVOL} -eq 1 ]]; then
      make3Dpng --bg ${FG} \
        --bg-color "timbow" --bg-cbar "true" \
        --layout "9:z;9:z;9:z" --offset "0,0,0" \
        --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
    else
      montage_fcn="montage"
      for (( j=1; j<=${NVOL}; j++ )); do
        make3Dpng --bg ${FG} --bg-vol ${j} \
          --bg-color "hot" --bg-cbar "true" \
          --layout "9:z;9:z;9:z" --offset "0,0,0" \
          --filename vol${j} --dir-save ${DIR_SCRATCH}
        montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
      done
      montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
      montage_fcn=${montage_fcn}' -background "#FFFFFF"'
      montage_fcn="${montage_fcn} ${TPNG}"
      eval ${montage_fcn}
      rm ${DIR_SCRATCH}/vol*.png
    fi
  fi
done

unset BG FGLS
FGLS=("${DWI_TENSOR[@]}" "${DWI_SCALAR[@]}")
MASK=${DWI_MASK}
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TPNG="${FG%%.*}.png"
  echo ${TPNG}
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    NVOL=$(niiInfo -i ${FG} -f volumes)
    fslmaths ${MASK} -thr 0 -bin ${DIR_SCRATCH}/TMASK.nii.gz
    if [[ ${NVOL} -eq 1 ]]; then
      make3Dpng --bg ${FG} --bg-mask ${DIR_SCRATCH}/TMASK.nii.gz \
        --bg-color "timbow" --bg-cbar "true" \
        --layout "9:z;9:z;9:z" --offset "0,0,0" \
        --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
    else
      montage_fcn="montage"
      for (( j=1; j<=${NVOL}; j++ )); do
        echo "${j}: ${NVOL}"
        make3Dpng --bg ${FG} --bg-vol ${j} \
          --bg-mask ${DIR_SCRATCH}/TMASK.nii.gz --bg-threshold "2.5,97.5"\
          --bg-color "timbow" --bg-cbar "true" \
          --layout "11:z" --offset "0,0,0" \
          --filename vol${j} --dir-save ${DIR_SCRATCH}
        montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
      done
      montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
      montage_fcn=${montage_fcn}' -background "#FFFFFF"'
      montage_fcn="${montage_fcn} ${TPNG}"
      eval ${montage_fcn}
      rm ${DIR_SCRATCH}/vol*.png
    fi
  fi
done

unset BG FGLS
FGLS=("${FUNC_RSFC[@]}")
MASK=${FUNC_MASK}
for (( i=0; i<${#FGLS[@]}; i++ )); do
  FG=${FGLS[${i}]}
  TMOD=$(getField -i ${FG} -f modality)
  TPNG="${FG%%.*}.png"
  if [[ ! -f ${TPNG} ]] || [[ ${PNG_REDO} == "true" ]]; then
    NVOL=$(niiInfo -i ${FG} -f volumes)
    fslmaths ${MASK} -thr 0 -bin ${DIR_SCRATCH}/TMASK.nii.gz
    if [[ ${NVOL} -eq 1 ]]; then
      make3Dpng --bg ${FG} --bg-mask ${DIR_SCRATCH}/TMASK.nii.gz \
        --bg-color "hot" --bg-cbar "true" \
        --layout "9:z;9:z;9:z" --offset "0,0,0" \
        --filename $(basename ${FG%%.*}) --dir-save $(dirname ${FG})
    else
      montage_fcn="montage"
      for (( j=1; j<=${NVOL}; j++ )); do
        make3Dpng --bg ${FG} --bg-vol ${j} \
          --bg-mask ${DIR_SCRATCH}/TMASK.nii.gz\
          --bg-color "hot" --bg-cbar "true" \
          --layout "9:z;9:z;9:z" --offset "0,0,0" \
          --filename vol${j} --dir-save ${DIR_SCRATCH}
        montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
      done
      montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
      montage_fcn=${montage_fcn}' -background "#FFFFFF"'
      montage_fcn="${montage_fcn} ${TPNG}"
      eval ${montage_fcn}
      rm ${DIR_SCRATCH}/vol*.png
    fi
  fi
done

## MAKE SUMMARY FILES FOR LABELS AND OUTCOMES ==================================
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Generate Summaries"; fi
for (( i=0; i<${#ANAT_LABEL[@]}; i++ )); do
  TIMG=${ANAT_LABEL[${i}]}
  TDIR=$(dirname ${TIMG})
  TBASE=$(basename ${TIMG})
  TFILE=${TBASE//\.nii\.gz}
  TSFX=${TFILE//${IDPFX}_}
  TPNG=${TDIR}/${TFILE}.png
  TLABEL=$(getField -i ${TFILE} -f modality)
  TTSV=${TDIR}/${IDPFX}_volume_${TSFX}.tsv

  ## volumes
  LABEL=$(getField -i ${TIMG} -f label)
  if [[ -f ${TKNIPATH}/lut/lut-${LABEL}.tsv ]]; then
    summarize3D --label ${TIMG} \
      --prefix ${IDPFX} \
      --stats volume \
      --lut ${TKNIPATH}/lut/lut-${LABEL}.tsv
  fi

  # Summarize Outcomes by labels
  ALLOUT=(${ANAT_OUT[@]} ${DWI_SCALAR[@]})
  for (( j=0; j<${#ALLOUT[@]}; j++ )); do
    TOUT=$(getField -i ${ALLOUT[${j}]} -f modality)
    if [[ ${TOUT} == "jac" ]]; then
      TSPACE=$(getField -i ${ANAT_OUT[${j}]} -f to)
      if [[ ${TSPACE} == *"HCPYAX"* ]]; then
        TREF=${TKNI_TEMPLATE}/HCPYAX/HCPYAX_700um_T1w.nii.gz
      else
        TMP=(${TSPACE//\+/ })
        TREF=${TKNI_TEMPLATE}/${TMP[0]}/${TMP[1]}/${TMP[0]}_${TMP[1]}_T1w.nii.gz
      fi
      XFM1=$(ls ${DIR_XFM}/*from-native_to-${TSPACE}_xfm-syn.nii.gz)
      XFM2=$(ls ${DIR_XFM}/*from-native_to-${TSPACE}_xfm-affine.mat)
      if [[ -f ${XFM1} ]] && [[ -f ${XFM2} ]]; then
        antsApplyTransforms -d 3 -n MultiLabel \
          -i ${TIMG} -o ${DIR_SCRATCH}/NORM_label-${LABEL}.nii.gz \
          -r ${TREF} -t identity -t ${XFM1} -t ${XFM2}
      fi
      TLAB=${DIR_SCRATCH}/NORM_label-${LABEL}.nii.gz
    else
      TLAB=${TIMG}
    fi
    if [[ -f ${TKNIPATH}/lut/lut-${LABEL}.tsv ]] && [[ -f ${TLAB} ]]; then
      antsApplyTransforms -d 3 -n MultiLabel \
        -i ${TLAB} -o ${DIR_SCRATCH}/temp_label-${LABEL}.nii.gz \
        -r ${ALLOUT[${j}]} -t identity
      summarize3D --label ${DIR_SCRATCH}/temp_label-${LABEL}.nii.gz \
        --prefix ${IDPFX} \
        --value ${ALLOUT[${j}]} \
        --stats "mean,sigma,median" \
        --dir-save $(dirname ${ALLOUT[${j}]}) \
        --lut ${TKNIPATH}/lut/lut-${LABEL}.tsv
    fi
  done
done

# Initialize summary output Rmd ------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>Generate RMD/HTML Report"; fi

mkdir -p ${DIR_SUMMARY}
RMD=${DIR_SUMMARY}/${IDPFX}_${FCN_NAME}_${DATE_SUFFIX}.Rmd

echo '---' > ${RMD}
echo 'title: "&nbsp;"' >> ${RMD}
echo 'output: html_document' >> ${RMD}
echo -e '---\n' >> ${RMD}
echo '' >> ${RMD}
echo '```{r setup, include=FALSE}' >> ${RMD}
echo 'knitr::opts_chunk$set(echo=FALSE, message=FALSE, warning=FALSE, comment=NA)' >> ${RMD}
echo '```' >> ${RMD}
echo '' >> ${RMD}
echo '```{r, out.width = "400px", fig.align="right"}' >> ${RMD}
echo 'knitr::include_graphics("/usr/local/tkbrainlab/neuroimage_code/TK_BRAINLab_logo.png")' >> ${RMD}
echo '```' >> ${RMD}
echo '' >> ${RMD}

# output Project related information -------------------------------------------
echo 'PI: **'${PI}'**\' >> ${RMD}
echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
echo '---'
echo '' >> ${RMD}
echo '```{r, echo=FALSE}' >> ${RMD}
echo 'library(DT)' >> ${RMD}
echo "create_dt <- function(x){" >> ${RMD}
echo "  DT::datatable(x," >> ${RMD}
echo "    extensions = 'Buttons'," >> ${RMD}
echo "    options = list(dom = 'Blfrtip'," >> ${RMD}
echo "    buttons = c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
echo "    lengthMenu = list(c(10,25,50,-1)," >> ${RMD}
echo '      c(10,25,50,"All"))))' >> ${RMD}
echo "}" >> ${RMD}
echo '```' >> ${RMD}
echo '' >> ${RMD}
echo '---' >> ${RMD}
echo '' >> ${RMD}

# output Raw data --------------------------------------------------------------
echo '## Raw Data {.tabset}' >> ${RMD}
echo '### Click Tabs to View ->' >> ${RMD}
MOD_RAW=("anat" "dwi" "func" "fmap")
for (( j=0; j<${#MOD_RAW[@]}; j++ )); do
  TDIR=${DIR_RAW}/${MOD_RAW[${j}]}
  if [[ -d ${TDIR} ]]; then
    echo '### '${MOD_RAW[${j}]}' {.tabset}' >> ${RMD}
    TLS=($(ls ${TDIR}/${IDPFX}*.nii.gz))
    for (( i=0; i<${#TLS[@]}; i++ )); do
      BNAME=$(basename ${TLS[${i}]})
      FNAME=${BNAME//\.nii\.gz}
      TMOD=${FNAME//${IDPFX}_}
      TPNG=${TDIR}/${FNAME}.png
      echo '#### '${TMOD} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${BNAME}']('${TPNG}')' >> ${RMD}
      else
        echo 'PNG Not Found\' >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  else
    echo '##### '${MOD_RAW[${j}]} >> ${RMD}
    echo 'NIfTI Not Found\' >> ${RMD}
    echo '' >> ${RMD}
  fi
done
echo '##### File Tree' >> ${RMD}
echo '```{bash}' >> ${RMD}
echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_RAW} >> ${RMD}
echo '```' >> ${RMD}
echo '' >> ${RMD}

# Derivatives File tree --------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>"; fi
echo '## Derivatives {.tabset}' >> ${RMD}
echo '### Click to View ->' >> ${RMD}
echo '### File Tree' >> ${RMD}
echo '```{bash}' >> ${RMD}
echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_PROJECT}'/derivatives/'${PIPELINE} >> ${RMD}
echo '```' >> ${RMD}
echo '' >> ${RMD}


# Neuroanatomical Results ======================================================
unset TLS
TLS=($(ls -r ${DIR_ANAT}/*/${IDPFX}*.nii.gz 2>/dev/null))
if [[ ${#TLS[@]} -eq 0 ]]; then
  echo "## Neuroanatomy - RESULTS NOT FOUND"
else
  echo '## Neuroanatomy' >> ${RMD}

  # Native Anatomicals -----------------------------------------------------------
  echo '### Native Space Anatomicals {.tabset}' >> ${RMD}
  ## Base Image
  echo '#### '${ANAT_BASE_MOD}' {.tabset}' >> ${RMD}
  TDIR=$(dirname ${ANAT_BASE})
  TBASE=$(basename ${ANAT_BASE})
  TPFX=$(getBidsBase -i ${TBASE} -s)
  echo '##### Base Native Anatomical' >> ${RMD}
  if [[ -f "${ANAT_BASE//\.nii\.gz}.png" ]]; then
    echo '!['${TBASE}']('${ANAT_BASE//\.nii\.gz}.png')' >> ${RMD}
  else
    echo 'PNG Not Found\' >> ${RMD}
  fi
  echo '' >> ${RMD}

  PNGSLICE=($(ls ${TDIR}/${TPFX}*slice*${ANAT_BASE_MOD}.png))
  for (( i=0; i<${#PNGSLICE[@]}; i++ )); do
    if [[ -f ${PNGSLICE[${i}]} ]]; then
      TPLANE=$(getField -i ${PNGSLICE[${i}]} -f slice)
      if [[ -z ${TPLANE} ]]; then TPLANE="Base Native"; fi
      echo '##### '${TPLANE} >> ${RMD}
      echo '!['${TBASE}' - '${TPLANE}']('${PNGSLICE[${i}]}')' >> ${RMD}
      echo '' >> ${RMD}
    fi
  done

  # Other Native Space Anatomicals ---------------------------------------------
  unset NIMG
  NIMG=${#ANAT_OTHER[@]}
  for (( i=0; i<${NIMG}; i++ )); do
    TIMG=${ANAT_OTHER[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  # Normalization -------------------------------------------------------------
  echo '### Normalization to Common Space {.tabset}' >> ${RMD}
  echo '#### Click Tabs to View ->' >> ${RMD}
  unset NIMG
  NIMG=${#ANAT_BASE_NORM[@]}
  for (( i=0; i<${NIMG}; i++ )); do
    TIMG=${ANAT_BASE_NORM[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  if [[ -n ${ANAT_COREG} ]]; then
    unset NIMG
    NIMG=${#ANAT_COREG[@]}
    for (( i=0; i<${NIMG}; i++ )); do
      TFROM=$(getField -i ${ANAT_COREG[${i}]} -f from)
      TTO=$(getField -i ${ANAT_COREG[${i}]} -f to)
      echo '#### Normalization - from:'${TFROM}' to:'${TTO} >> ${RMD}
      echo '![]('${ANAT_COREG[${i}]}')' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  unset NIMG
  NIMG=${#ANAT_OTHER_NORM[@]}
  for (( i=0; i<${NIMG}; i++ )); do
    TIMG=${ANAT_OTHER_NORM[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  # Anatomical Results ---------------------------------------------------------
  echo '### Neuroanatomical Results {.tabset}' >> ${RMD}
  # Anatomical Masks
  echo '#### Masks {.tabset}' >> ${RMD}
  unset NIMG
  NIMG=${#ANAT_MASK[@]}
  for (( i=0; i<${NIMG}; i++ )); do
    TIMG=${ANAT_MASK[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '##### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "Data Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  # Labels
  echo '#### Labels {.tabset}' >> ${RMD}
  unset NIMG
  NIMG=${#ANAT_LABEL[@]}
  for (( i=0; i<${NIMG}; i++ )); do
    TIMG=${ANAT_LABEL[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    TLABEL=$(getField -i ${TFILE} -f label)
    echo '##### '${TLABEL}' {.tabset}' >> ${RMD}
    echo '###### Image' >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}

    TCSV=${TDIR}/${IDPFX}_volume_${TSFX}.tsv
    echo '###### Volumes' >> ${RMD}
    if [[ -f ${TCSV} ]]; then
      echo '```{r, echo=FALSE}' >> ${RMD}
      echo 'tf <- read.csv("'${TCSV}'", sep="\t")' >> ${RMD}
      echo 'tf <- t(tf)' >> ${RMD}
      echo 'create_dt(tf)' >> ${RMD}
      echo '```' >> ${RMD}
    else
      echo "Data Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}

    for (( j=0; j<${#ANAT_OUT[@]}; j++ )); do
      ODIR=$(dirname ${ANAT_OUT[${j}]})
      OMOD=$(getField -i ${ANAT_OUT[${j}]} -f modality)
      OCSV=${ODIR}/${IDPFX}_${OMOD}_${TSFX}.tsv
      if [[ -f ${OCSV} ]]; then
        echo '###### '${OMOD} >> ${RMD}
        echo '```{r, echo=FALSE}' >> ${RMD}
        echo 'tf <- read.csv("'${OCSV}'", sep="\t")' >> ${RMD}
        echo 'tf <- t(tf)' >> ${RMD}
        echo 'create_dt(tf)' >> ${RMD}
        echo '```' >> ${RMD}
        echo '' >> ${RMD}
      fi
    done
  done

  # Posteriors
  echo '#### Posteriors {.tabset}' >> ${RMD}
  unset NIMG
  NIMG=${#ANAT_POST[@]}
  for (( i=0; i<${NIMG}; i++ )); do
    TIMG=${ANAT_POST[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '##### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  if [[ -n ${DIR_FSSYNTH} ]]; then
    echo '#### FS Synth' >> ${RMD}
    echo '```{bash}' >> ${RMD}
    echo 'tree -Rn --prune '${DIR_FSSYNTH} >> ${RMD}
    echo '```' >> ${RMD}
    echo '' >> ${RMD}
  fi
fi

# Diffusion Processing ---------------------------------------------------------
## B0, mask, coreg result, % outliers, scalars, mrtrix, tracts, connectomes
unset TLS
TLS=($(ls -r ${DIR_DWI}/*/${IDPFX}*.nii.gz 2>/dev/null))
if [[ ${#TLS[@]} -eq 0 ]]; then
  echo "## Diffusion Imaging - RESULTS NOT FOUND"
else
  echo '## Diffusion Imaging' >> ${RMD}

  echo '### Diffusion Preprocessing {.tabset}' >> ${RMD}
  echo '#### Click Tabs to View ->' >> ${RMD}

  TLS=("${DWI_B0[@]}")
  if [[ -n ${TLS[@]} ]]; then
    echo '#### B0 {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TIMG=${TLS[${i}]}
      TDIR=$(dirname ${TIMG})
      TBASE=$(basename ${TIMG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi

  TLS=("${DWI_MASK[@]}")
  if [[ -n ${TLS[@]} ]]; then
    echo '#### Masks {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TIMG=${TLS[${i}]}
      TDIR=$(dirname ${TIMG})
      TBASE=$(basename ${TIMG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi

  if [[ -n ${DWI_OUTLIERS} ]]; then
    echo "#### Outlier %"  >> ${RMD}
    echo "##### Observed Outliers: ${DWI_OUTLIERS} %"  >> ${RMD}
    echo "If >10, may have too much motion or corrupted slices\\"  >> ${RMD}
    echo '' >> ${RMD}
  fi

  for (( i=0; i<${#DWI_COREG[@]}; i++ )); do
    TPNG=${DWI_COREG[${i}]}
    TBASE=$(basename ${TPNG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  TLS=("${DWI_CLEAN[@]}")
  for (( i=0; i<${#TLS[@]}; i++ )); do
    TIMG=${TLS[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  echo '### Diffusion Tensor Results {.tabset}' >> ${RMD}
  #echo '#### Click Tabs to View ->' >> ${RMD}

  echo '#### DTI Scalars {.tabset}' >> ${RMD}
  for (( i=0; i<${#DWI_SCALAR[@]}; i++ )); do
    TIMG=${DWI_SCALAR[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSCALAR=$(getField -i ${TIMG} -f scalar)
    TPNG=${TDIR}/${TFILE}.png
    echo '##### '${TSCALAR}' {.tabset}' >> ${RMD}
    echo '###### Image' >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}

    TSVLS=($(ls ${TDIR}/${TFILE}_*.tsv))
    for (( j=0; j<${#TSVLS[@]}; j++ )); do
      TLABEL=$(getField -i ${TSVLS[${j}]} -f label)
      echo '###### '${TLABEL} >> ${RMD}
      echo '```{r, echo=FALSE}' >> ${RMD}
      echo 'tf <- read.csv("'${TSVLS[${j}]}'", sep="\t")' >> ${RMD}
      echo 'tf <- t(tf)' >> ${RMD}
      echo 'create_dt(tf)' >> ${RMD}
      echo '```' >> ${RMD}
      echo '' >> ${RMD}
    done
  done

  TLS=("${DWI_TENSOR[@]}")
  for (( i=0; i<${#TLS[@]}; i++ )); do
    TIMG=${TLS[${i}]}
    TDIR=$(dirname ${TIMG})
    TBASE=$(basename ${TIMG})
    TFILE=${TBASE//\.nii\.gz}
    TSFX=${TFILE//${IDPFX}_}
    TPNG=${TDIR}/${TFILE}.png
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  echo '### Tractography Results {.tabset}' >> ${RMD}
  #echo '#### Click Tabs to View ->' >> ${RMD}
  for (( i=0; i<${#DWI_TRACT[@]}; i++ )); do
    TPNG=${DWI_TRACT[${i}]}
    TBASE=$(basename ${TPNG})
    TFILE=${TBASE//\.png}
    TSFX=${TFILE//${IDPFX}_}
    echo '#### '${TSFX} >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}
  done

  TLS=("${DWI_CONNECTOME[@]}")
  for (( i=0; i<${#TLS[@]}; i++ )); do
    TCSV=${TLS[${i}]}
    TDIR=$(dirname ${TCSV})
    TBASE=$(basename ${TCSV})
    TFILE=${TBASE//\.csv}
    TLABEL=$(getField -i ${TCSV} -f connectome)
    TPNG=${TDIR}/${TFILE}.png
    echo '#### '${TLABEL}' {.tabset}' >> ${RMD}
    echo '##### Image' >> ${RMD}
    if [[ -f ${TPNG} ]]; then
      echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
    else
      echo "PNG Not Found\\" >> ${RMD}
    fi
    echo '' >> ${RMD}

    echo '##### Matrix' >> ${RMD}
    echo '```{r, echo=FALSE}' >> ${RMD}
    echo 'tf <- read.csv("'${TCSV}'", sep=",", header=F)' >> ${RMD}
    echo 'tf <- t(tf)' >> ${RMD}
    echo 'create_dt(tf)' >> ${RMD}
    echo '```' >> ${RMD}
    echo '' >> ${RMD}
  done

  if [[ -n ${DIR_MRTRIX} ]]; then
    echo '#### MRTrix' >> ${RMD}
    echo '```{bash}' >> ${RMD}
    echo 'tree -Rn --prune '${DIR_MRTRIX} >> ${RMD}
    echo '```' >> ${RMD}
    echo '' >> ${RMD}
  fi
fi

# Functional Processing -------------------------------------------------------
unset TLS
TLS=($(ls -r ${DIR_FUNC}/*/${IDPFX}*.nii.gz 2>/dev/null))
if [[ ${#TLS[@]} -eq 0 ]]; then
  echo "## Functional Imaging - RESULTS NOT FOUND"
else
  echo '## Functional Imaging' >> ${RMD}
  echo '### Functional Preprocessing {.tabset}' >> ${RMD}
  #echo '#### Click Tabs to View ->' >> ${RMD}
  TLS=("${FUNC_MEAN[@]}")
  if [[ -n ${TLS} ]]; then
    echo '#### Mean BOLD {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TIMG=${TLS[${i}]}
      TDIR=$(dirname ${TIMG})
      TBASE=$(basename ${TIMG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi

  TLS=("${FUNC_MASK[@]}")
  if [[ -n ${TLS} ]]; then
    echo '#### Masks {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TIMG=${TLS[${i}]}
      TDIR=$(dirname ${TIMG})
      TBASE=$(basename ${TIMG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi

  if [[ -n ${FUNC_QC[@]} ]]; then
    echo "#### QC {.tabset}" >> ${RMD}
    for (( i=0; i<${#FUNC_QC[@]}; i++ )); do
      TPNG=${FUNC_QC[${i}]}
      TBASE=$(basename ${TPNG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi

  TLS=("${FUNC_RESID[@]}")
  if [[ -n ${TLS} ]]; then
    echo '#### Residuals' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TIMG=${TLS[${i}]}
      TDIR=$(dirname ${TIMG})
      TBASE=$(basename ${TIMG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi

  echo '### Functional Results {.tabset}' >> ${RMD}
#  echo '#### Click Tabs to View ->' >> ${RMD}

    TLS=("${FUNC_CON[@]}")
  if [[ -n ${TLS[@]} ]]; then
    echo '#### Connectivity {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TCSV=${TLS[${i}]}
      TDIR=$(dirname ${TCSV})
      TBASE=$(basename ${TCSV})
      TFILE=${TBASE//\.csv}
      TLABEL=$(getField -i ${TCSV} -f modality)
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TLABEL}' {.tabset}' >> ${RMD}
      echo '###### Image' >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
      echo '###### Matrix' >> ${RMD}
      echo '```{r, echo=FALSE}' >> ${RMD}
      echo 'tf <- read.csv("'${TCSV}'", sep=",", header=F)' >> ${RMD}
      echo 'tf <- t(tf)' >> ${RMD}
      echo 'create_dt(tf)' >> ${RMD}
      echo '```' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  TLS=("${FUNC_TS[@]}")
  if [[ -n ${TLS[@]} ]]; then
    echo '#### Time-series {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TCSV=${TLS[${i}]}
      TDIR=$(dirname ${TCSV})
      TBASE=$(basename ${TCSV})
      TFILE=${TBASE//\.csv}
      TLABEL=$(getField -i ${TCSV} -f ts)
      echo '##### '${TLABEL}' {.tabset}' >> ${RMD}
      echo '```{r, echo=FALSE}' >> ${RMD}
      echo 'tf <- read.csv("'${TCSV}'", sep=",", header=F)' >> ${RMD}
      echo 'tf <- t(tf)' >> ${RMD}
      echo 'create_dt(tf)' >> ${RMD}
      echo '```' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  TLS=("${FUNC_TZ[@]}" "${FUNC_LFF[@]}" "${FUNC_RSFC[@]}")
  if [[ -n ${TLS[@]} ]]; then
    echo '#### RS Metrics {.tabset}' >> ${RMD}
    for (( i=0; i<${#TLS[@]}; i++ )); do
      TIMG=${TLS[${i}]}
      TDIR=$(dirname ${TIMG})
      TBASE=$(basename ${TIMG})
      TFILE=${TBASE//\.nii\.gz}
      TSFX=${TFILE//${IDPFX}_}
      TPNG=${TDIR}/${TFILE}.png
      echo '##### '${TSFX} >> ${RMD}
      if [[ -f ${TPNG} ]]; then
        echo '!['${TBASE}']('${TPNG}')' >> ${RMD}
      else
        echo "PNG Not Found\\" >> ${RMD}
      fi
      echo '' >> ${RMD}
    done
  fi
fi

# Render HTML ==================================================================
echo 2
Rscript -e "rmarkdown::render('${RMD}')"

#===============================================================================
# End of function
#===============================================================================
exit 0

