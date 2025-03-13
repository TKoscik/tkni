#!/bin/bash -e
#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      PCASL
# DESCRIPTION:   TKNI Arterial Spin Labelling Pipeline
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-03-13
# README:
#     Procedure:
#     (1) Copy to scratch
#     (2) Reorient
#     (3) Motion Correction
#     (4) Split 4D file into 3D, organize into pairs
#     (5) Denoise
#     (6) FG Mask
#     (7) Bias Correction
#     (8) Calculate M0, mean control image
#     (9) Brain mask
#    (10) Coregister to Native Space
#    (11) Calculate change in control/label pairs, dM
#    (12) Calculate CBF
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
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,id:,dir-id:,\
asl:,asl-type:,asl-json:,asl-ctl:,asl-lab:,asl-m0:,pwi:,pwi-label:,\
native:,native-mask:,native-mod:,\
opt-brainblood:,opt-t1blood:,opt-duration:,opt-efficiency:,opt-delay:,\
no-pwi:,no-reorient:,no-denoise,no-debias,no-norm,\
coreg-recipe:,dir-xfm:,norm-ref:,norm-xfm-mat:,norm-xfm-syn:,\
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

ASL=
ASL_TYPE="pcasl"
ASL_JSON=
ASL_CTL="even"
ASL_M0="false"
PWI=
PWI_LABEL="proc-scanner_relCBF"
NATIVE=
NATIVE_MASK=
NATIVE_MOD="T1w"
LABEL=

OPT_BRAINBLOOD=0.9
OPT_T1BLOOD=1650
OPT_EFFICIENCY=0.85
OPT_DURATION=
OPT_DELAY=
#FORMULA="(6000*lambda*deltaM*exp(-((gamma)/(t1blood))))/(2*alpha*M0*t1blood*(1-exp(-(tau)/(t1blood))))"

NO_PWI="false"
NO_REORIENT="false"
NO_DENOISE="false"
NO_DEBIAS="false"
NO_NORM="false"
NO_SUMMARY="false"

COREG_RECIPE="intermodalAffine"
DIR_XFM=
NORM_REF=
NORM_XFM_MAT=
NORM_XFM_SYN=

DIR_SAVE=
DIR_SCRATCH=

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false
KEEP_CLEANED=true

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
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --asl) ASL="$2" ; shift 2 ;;
    --asl-type) ASL_TYPE="$2" ; shift 2 ;;
    --asl-json) ASL_JSON="$2" ; shift 2 ;;
    --asl-ctl) ASL_CTL="$2" ; shift 2 ;;
    --asl-m0) ASL_M0="$2" ; shift 2 ;;
    --pwi) PWI="$2" ; shift 2 ;;
    --pwi-label) PWI_LABEL="$2" ; shift 2 ;;
    --native) NATIVE="$2" ; shift 2 ;;
    --native-mask) NATIVE_MASK="$2" ; shift 2 ;;
    --native-mod) NATIVE_MOD="$2" ; shift 2 ;;
    --label) LABEL="$2" ; shift 2 ;;
    --opt-brainblood) OPT_BRAINBLOOD="$2" ; shift 2 ;;
    --opt-t1blood) OPT_T1BLOOD="$2" ; shift 2 ;;
    --opt-efficiency) OPT_EFFICIENCY="$2" ; shift 2 ;;
    --opt-duration) OPT_DURATION="$2" ; shift 2 ;;
    --opt-delay) OPT_DELAY="$2" ; shift 2 ;;
    --coreg-recipe) COREG_RECIPE="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
    --norm-ref) NORM_REF="$2" ; shift 2 ;;
    --norm-xfm-mat) NORM_XFM_MAT="$2" ; shift 2 ;;
    --norm-xfm-syn) NORM_XFM_SYN="$2" ; shift 2 ;;
    --no-pwi) NO_PWI="true" ; shift ;;
    --no-reorient) NO_REORIENT="true" ; shift ;;
    --no-denoise) NO_DENOISE="true" ; shift ;;
    --no-debias) NO_DEBIAS="true" ; shift ;;
    --no-norm) NO_NORM="true" ; shift ;;
    --no-summary) NO_SUMMARY="true" ; shift ;;
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
  echo '  -r | --no-rmd      disable RMD/HTML output'
  echo '  --force            force rerun'
  echo '  --requires         prerequisites for running, use force to override'
  echo '  --pi               folder name for PI, no underscores'
  echo '                       e.g., tkoscik'
  echo '  --project          project name, preferrable camel case'
  echo '                       e.g., projectName'
  echo '  --dir-project      project directory, used to check for status files'
  echo '                     of prior runs and sets default file paths'
  echo '                       default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-save         save file path'
  echo '  --dir-scratch      location for processing preliminaries'
  echo '  --id'
  echo '  --dir-id'
  echo '  --asl'
  echo '  --asl-type'
  echo '  --pwi'
  echo '  --pwi-label'
  echo '  --native'
  echo '  --native-mask'
  echo '  --label'
  echo '  --opt-brainblood'
  echo '  --opt-t1blood'
  echo '  --opt-efficiency'
  echo '  --opt-duration'
  echo '  --opt-delay'
  echo '  --coreg-recipe'
  echo '  --dir-xfm'
  echo '  --norm-ref'
  echo '  --norm-xfm-mat'
  echo '  --norm-xfm-syn'
  echo '  --no-pwi'
  echo '  --no-reorient'
  echo '  --no-denoise'
  echo '  --no-debias'
  echo '  --no-norm'
  echo '  --no-summary'
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

# locate files to process ------------------------------------------------------
if [[ -z ${ASL} ]]; then
  ASL=${DIR_PROJECT}/rawdata/${IDDIR}/perf/${IDPFX}_asl.nii.gz
fi
if [[ ! -f ${ASL} ]]; then
  echo "ERROR [${PIPE}${FLOW}]: ASL file not found, aborting."
  exit 1
fi

if [[ -z ${ASL_JSON} ]]; then
  ASL_JSON=${DIR_PROJECT}/rawdata/${IDDIR}/perf/${IDPFX}_asl.json
fi
if [[ ! -f ${ASL_JSON} ]]; then
  if [[ -z ${OPT_DURATION} ]] || [[ -z ${OPT_DELAY} ]]; then
    echo "ERROR [${PIPE}${FLOW}]: JSON sidecar or label duration and label delay must be given, aborting."
    exit 1
  fi
fi

if [[ ${NO_PWI} == "false" ]]; then
  if [[ -z ${PWI} ]]; then
    PWI=${DIR_PROJECT}/rawdata/${IDDIR}/perf/${IDPFX}_pwi.nii.gz
  fi
  if [[ ! -f ${ASL} ]]; then
    echo "ERROR [${PIPE}${FLOW}]: PWI file not found, aborting."
    exit 2
  fi
fi

if [[ -z ${NATIVE} ]]; then
  NATIVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/${IDPFX}_${NATIVE_MOD}.nii.gz
fi
if [[ ! -f ${ASL} ]]; then
  echo "ERROR [${PIPE}${FLOW}]: ASL file not found, aborting."
  exit 3
fi

if [[ -z ${NATIVE_MASK} ]]; then
  NATIVE_MASK=${DIR_PROJECT}/derivatives/${PIPE}/anat/mask/${IDPFX}_mask-brain.nii.gz
fi
if [[ ! -f ${NATIVE_MASK} ]]; then
  echo "ERROR [${PIPE}${FLOW}]: NATIVE MASK file not found, aborting."
  exit 4
fi

if [[ -z ${LABEL} ]]; then
  LABEL=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/MALF
fi
if [[ -d ${LABEL} ]]; then
  LABEL=($(ls ${LABEL}/${IDPFX}_label-*.nii.gz))
else
  LABEL=(${LABEL//,/ })
fi
for (( i=0; i<${#LABEL[@]}; i++ )); do
  if [[ ! -f ${LABEL[${i}]} ]]; then
    echo "ERROR [${PIPE}${FLOW}]: LABEL file, ${LABEL[${i}]}, not found, aborting."
    exit 5
  fi
done

if [[ -z ${DIR_XFM} ]]; then DIR_XFM=${DIR_PROJECT}/derivatives/${PIPE}/xfm/${IDDIR}; fi

if [[ ${NO_NORM,,} == "false" ]]; then
  if [[ -z ${NORM_REF} ]]; then
    TDIR=($(ls -d ${DIR_PROJECT}/derivatives/${PIPE}/anat/reg_*))
    CHKXFM=0
    for (( i=0; i<${#TDIR[@]}; i++ )); do
      NREF=(${TDIR[${i}]//\// })
      NREF=(${NREF[-1]//_/ })
      NREF=${NREF[-1]}
      TREF=${TDIR}/${IDPFX}_reg-${NREF}_${NATIVE_MOD}.nii.gz
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

# gather missing OPTS from JSON -------------------------------------------
if [[ -z ${OPT_DURATION} ]]; then
  TR=($(jq ".RepetitionTime" < ${ASL_JSON} | tr -d '[],\n'))
  TD=($(jq ".PostLabelDelay" < ${ASL_JSON} | tr -d '[],\n'))
  OPT_DURATION=$(echo "scale=4; ${TR} - ${TD}" | bc -l)
fi

if [[ -z ${OPT_DELAY} ]]; then
  OPT_DELAY=($(jq ".PostLabelDelay" < ${ASL_JSON} | tr -d '[],\n'))
fi

# set directories --------------------------------------------------------------
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/outcomes/perfusion
fi
if [[ -z ${DIR_SCRATCH} ]]; then
  DIR_SCRATCH=${TKNI_SCRATCH}/${FLOW}_${PI}_${PROJECT}_${DATE_SUFFIX}
fi
mkdir -p ${DIR_SCRATCH}

# START PROCESSING PIPELINE ====================================================
# Copy raw image to scratch ----------------------------------------------------
ASL_TMP=${DIR_SCRATCH}/$(basename ${ASL})
cp ${ASL} ${ASL_TMP}
NVOL=$(niiInfo -i ${ASL_TMP} -f volumes)

if [[ $((${NVOL} % 2)) -ne 0 ]] && [[ ${ASL_M0} == "false" ]]; then
  echo "ERROR [${PIPE}${FLOW}]: ASL has an odd number of volumes, but M0 is not specified"
  echo "                        unable to auto-parse control/labeled pairs"
  exit 6
fi
if [[ $((${NVOL} % 2)) -eq 0 ]] && [[ ${ASL_M0} != "false" ]]; then
  echo "ERROR [${PIPE}${FLOW}]: ASL has an even number of volumes, and M0 is specified"
  echo "                        unable to auto-parse control/labeled pairs"
  exit 7
fi

for (( i=1; i<=${NVOL}; i++ )); do
  make3Dpng --bg ${ASL_TMP} --bg-vol ${i} --bg-threshold "2.5,97.5" --filename t${i}
done
montage ${DIR_SCRATCH}/t*.png \
  -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
  ${DIR_SCRATCH}/${IDPFX}_prep-raw_asl.png
rm ${DIR_SCRATCH}/t*.png

# Reorient ---------------------------------------------------------------------
if [[ ${NO_REORIENT} == "false" ]]; then
  reorientRPI --image ${ASL_TMP} --dir-save ${DIR_SCRATCH} --no-png
  mv ${DIR_SCRATCH}/${IDPFX}_prep-reorient_asl.nii.gz ${ASL_TMP}
  for (( i=1; i<=${NVOL}; i++ )); do
    make3Dpng --bg ${ASL_TMP} --bg-vol ${i} --bg-threshold "2.5,97.5" --filename t${i}
  done
  montage ${DIR_SCRATCH}/t*.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-reorient_asl.png
  rm ${DIR_SCRATCH}/t*.png
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>>Reoriented to RPI"; fi
fi

# Motion Correction ------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo -e "  >>>>>MOTION CORRECTION"; fi
moco --prefix ${IDPFX} --ts ${ASL_TMP} \
  --dir-save ${DIR_SCRATCH}/moco \
  --dir-regressor ${DIR_SCRATCH}/moco --no-png -v
ASL_MOCO=${DIR_SCRATCH}/${IDPFX}_moco+6.1D
ASL_MEAN=${DIR_SCRATCH}/${IDPFX}_proc-mean_asl.nii.gz
mv ${DIR_SCRATCH}/moco/${IDPFX}_asl.nii.gz ${ASL_TMP}
mv ${DIR_SCRATCH}/moco/${IDPFX}_proc-mean_asl.nii.gz ${ASL_MEAN}
mv ${DIR_SCRATCH}/moco/${IDPFX}_moco+6.1D ${ASL_MOCO}

for (( i=1; i<=${NVOL}; i++ )); do
  make3Dpng --bg ${ASL_TMP} --bg-vol ${i} --bg-threshold "2.5,97.5" --filename t${i}
done
montage ${DIR_SCRATCH}/t*.png \
  -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
  ${DIR_SCRATCH}/${IDPFX}_prep-moco_asl.png
rm ${DIR_SCRATCH}/t*.png

## calculate displacement
regressorDisplacement --regressor ${ASL_MOCO}
PLOTLS="${DIR_SCRATCH}/${IDPFX}_moco+6.1D"
PLOTLS="${PLOTLS},${DIR_SCRATCH}/${IDPFX}_displacement+absolute+mm.1D"
PLOTLS="${PLOTLS},${DIR_SCRATCH}/${IDPFX}_displacement+relative+mm.1D"
PLOTLS="${PLOTLS},${DIR_SCRATCH}/${IDPFX}_displacement+framewise.1D"
PLOTLS="${PLOTLS},${DIR_SCRATCH}/${IDPFX}_displacement+RMS.1D"
regressorPlot --regressor ${PLOTLS}

# Split 4D file into 3D, organize into pairs -----------------------------------
for (( i=0; i<${NVOL}; i++ )); do
  3dcalc -a ${ASL_TMP}[${i}] -expr 'a' -prefix ${DIR_SCRATCH}/vol${i}.nii.gz
done

if [[ ${ASL_M0} != "false" ]]; then
  mv ${DIR_SCRATCH}/vol${ASL_M0}.nii.gz ${DIR_SCRATCH}/M0.nii.gz
fi

TLS=($(ls ${DIR_SCRATCH}/vol*.nii.gz))
if [[ ${ASL_CTL} == "even" ]]; then
  TC=0
  TL=0
  for (( i=0; i<${#TLS[@]}; i++ )); do
    if [[ $((${i} % 2)) -eq 0 ]]; then
      TC=$((${TC} + 1))
      mv ${DIR_SCRATCH}/vol${i}.nii.gz ${DIR_SCRATCH}/C${TC}.nii.gz
    else
      TL=$((${TL} + 1))
      mv ${DIR_SCRATCH}/vol${i}.nii.gz ${DIR_SCRATCH}/L${TL}.nii.gz
    fi
  done
elif [[ ${ASL_CTL} == "odd" ]]; then
  TC=0
  TL=0
  for (( i=0; i<${#TLS[@]}; i++ )); do
    if [[ $((${i} % 2)) -ne 0 ]]; then
      TC=$((${TC} + 1))
      mv ${DIR_SCRATCH}/vol${i}.nii.gz ${DIR_SCRATCH}/C${TC}.nii.gz
    else
      TL=$((${TL} + 1))
      mv ${DIR_SCRATCH}/vol${i}.nii.gz ${DIR_SCRATCH}/L${TL}.nii.gz
    fi
  done
else
  ASL_CTL=(${ASL_CTL//,/ })
  TC=0
  TL=0
  for (( i=0; i<${#TLS[@]}; i++ )); do
    CTL="false"
    for j in "${ASL_CTL[@]}"; do
      if [[ ${i} -eq ${j} ]]; then
        CTL="true"
      fi
    done
    if [[ ${CTL} == "true" ]]; then
      TC=$((${TC} + 1))
      mv ${DIR_SCRATCH}/vol${i}.nii.gz ${DIR_SCRATCH}/C${TC}.nii.gz
    else
      TL=$((${TL} + 1))
      mv ${DIR_SCRATCH}/vol${i}.nii.gz ${DIR_SCRATCH}/L${TL}.nii.gz
    fi
  done
fi
CTL_LS=($(ls ${DIR_SCRATCH}/C*.nii.gz))
LAB_LS=($(ls ${DIR_SCRATCH}/L*.nii.gz))
NPAIR=${#CTL_LS[@]}

# Denoise ----------------------------------------------------------------------
if [[ ${NO_DENOISE} == "false" ]]; then
  for (( i=1; i<=${NPAIR}; i++ )); do
    DenoiseImage -d 3 -n Rician -i ${DIR_SCRATCH}/C${i}.nii.gz \
      -o [${DIR_SCRATCH}/C${i}_denoise.nii.gz,${DIR_SCRATCH}/C${i}_noise.nii.gz]
    DenoiseImage -d 3 -n Rician -i ${DIR_SCRATCH}/L${i}.nii.gz \
      -o [${DIR_SCRATCH}/L${i}_denoise.nii.gz,${DIR_SCRATCH}/L${i}_noise.nii.gz]
    ## Correct output spacing that gets messed up by ANTs
    antsApplyTransforms -d 3 -n Linear \
      -i ${DIR_SCRATCH}/C${i}_denoise.nii.gz \
      -o ${DIR_SCRATCH}/C${i}_denoise.nii.gz \
      -r ${DIR_SCRATCH}/C${i}.nii.gz
    antsApplyTransforms -d 3 -n Linear \
      -i ${DIR_SCRATCH}/L${i}_noise.nii.gz \
      -o ${DIR_SCRATCH}/L${i}_noise.nii.gz \
      -r ${DIR_SCRATCH}/L${i}.nii.gz
    if [[ ${NO_PNG} == "false" ]]; then
      make3Dpng --bg ${DIR_SCRATCH}/C${i}_denoise.nii.gz --bg-threshold "2.5,97.5"
      make3Dpng --bg ${DIR_SCRATCH}/L${i}_denoise.nii.gz --bg-threshold "2.5,97.5"
      make3Dpng --bg ${DIR_SCRATCH}/C${i}_noise.nii.gz --bg-color "virid-esque"
      make3Dpng --bg ${DIR_SCRATCH}/L${i}_noise.nii.gz --bg-color "virid-esque"
    fi
    mv ${DIR_SCRATCH}/C${i}_denoise.nii.gz ${DIR_SCRATCH}/C${i}.nii.gz
    mv ${DIR_SCRATCH}/L${i}_denoise.nii.gz ${DIR_SCRATCH}/L${i}.nii.gz
  done
  montage ${DIR_SCRATCH}/C*_denoise.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-control+denoise_asl.png
  montage ${DIR_SCRATCH}/L*_denoise.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-label+denoise_asl.png
  montage ${DIR_SCRATCH}/C*_noise.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-control+noise_asl.png
  montage ${DIR_SCRATCH}/L*_noise.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-label+noise_asl.png
  rm ${DIR_SCRATCH}/C*.png
  rm ${DIR_SCRATCH}/L*.png
fi

# Bias Correction --------------------------------------------------------------
if [[ ${NO_DEBIAS} == "false" ]]; then
  for (( i=1; i<=${NPAIR}; i++ )); do
    inuCorrection --image ${DIR_SCRATCH}/C${i}.nii.gz --method N4 \
      --prefix C${i} --dir-save ${DIR_SCRATCH} --keep
    rename "s/prep-biasN4_C${i}_C${i}/C${i}_debias/g" ${DIR_SCRATCH}/*
    rename "s/mod-C${i}_prep-biasN4_//g" ${DIR_SCRATCH}/*
    inuCorrection --image ${DIR_SCRATCH}/L${i}.nii.gz --method N4 \
      --prefix L${i} --dir-save ${DIR_SCRATCH} --keep
    rename "s/prep-biasN4_L${i}_L${i}/L${i}_debias/g" ${DIR_SCRATCH}/*
    rename "s/mod-L${i}_prep-biasN4_//g" ${DIR_SCRATCH}/*
    mv ${DIR_SCRATCH}/C${i}_debias.nii.gz ${DIR_SCRATCH}/C${i}.nii.gz
    mv ${DIR_SCRATCH}/L${i}_debias.nii.gz ${DIR_SCRATCH}/L${i}.nii.gz
  done
  montage ${DIR_SCRATCH}/C*_debias.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-control+debias_asl.png
  montage ${DIR_SCRATCH}/L*_debias.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-label+debias_asl.png
  montage ${DIR_SCRATCH}/C*_biasField.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-control+biasField_asl.png
  montage ${DIR_SCRATCH}/L*_biasField.png \
    -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
    ${DIR_SCRATCH}/${IDPFX}_prep-label+biasField_asl.png
  rm ${DIR_SCRATCH}/C*.png
  rm ${DIR_SCRATCH}/L*.png
  if [[ ${VERBOSE} == "true" ]]; then echo -e ">>>>> Non-uniformity corrected"; fi
fi

# Calculate M0, mean control image ---------------------------------------------
if [[ ${ASL_M0} == "false" ]]; then
  AVGFCN="AverageImages 3 ${DIR_SCRATCH}/M0.nii.gz 0"
  for (( i=1; i<=${NPAIR}; i++ )); do
    AVGFCN="${AVGFCN} ${DIR_SCRATCH}/C${i}.nii.gz"
  done
  eval ${AVGFCN}
fi

# Brain mask -------------------------------------------------------------------
mri_synthstrip -i ${DIR_SCRATCH}/M0.nii.gz -m ${DIR_SCRATCH}/mask-brain.nii.gz

# Coregister to Native Space ---------------------------------------------------
coregistrationChef --recipe-name ${COREG_RECIPE} \
  --fixed ${NATIVE} --fixed-mask ${NATIVE_MASK} \
  --moving ${DIR_SCRATCH}/M0.nii.gz \
  --moving-mask ${DIR_SCRATCH}/mask-brain.nii.gz \
  --space-target "fixed" --interpolation "Linear" \
  --prefix ${IDPFX} --label-from asl --label-to native \
  --dir-save ${DIR_SCRATCH} \
  --dir-xfm ${DIR_SCRATCH}/xfm

rm ${DIR_SCRATCH}/*${COREG_RECIPE}*
mv ${DIR_SCRATCH}/xfm/*.png ${DIR_SCRATCH}/

TXFM1=${DIR_SCRATCH}/xfm/${IDPFX}_mod-M0_from-asl_to-native_xfm-affine.mat
TXFM2=${DIR_SCRATCH}/xfm${i}/${IDPFX}_mod-M0_from-asl_to-native_xfm-syn.nii.gz
XFMSTR="-t identity"
if [[ -f ${TXFM2} ]]; then XFMSTR="${XFMSTR} -t ${TXFM2}"; fi
if [[ -f ${TXFM1} ]]; then XFMSTR="${XFMSTR} -t ${TXFM1}"; fi

antsApplyTransforms -d 3 -n BSpline[3] \
  -i ${DIR_SCRATCH}/M0.nii.gz -o ${DIR_SCRATCH}/M0.nii.gz \
  -r ${NATIVE} ${XFMSTR}
for (( i=1; i<=${NPAIR}; i++ )); do
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${DIR_SCRATCH}/C${i}.nii.gz -o ${DIR_SCRATCH}/C${i}.nii.gz \
    -r ${NATIVE} ${XFMSTR}
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${DIR_SCRATCH}/L${i}.nii.gz -o ${DIR_SCRATCH}/L${i}.nii.gz \
    -r ${NATIVE} ${XFMSTR}
  make3Dpng --bg ${DIR_SCRATCH}/C${i}.nii.gz --bg-thresh "2.5,97.5"
  make3Dpng --bg ${DIR_SCRATCH}/L${i}.nii.gz --bg-thresh "2.5,97.5"
done
montage ${DIR_SCRATCH}/C*.png \
  -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
  ${DIR_SCRATCH}/${IDPFX}_prep-control+coreg_asl.png
montage ${DIR_SCRATCH}/L*.png \
  -tile 1x -geometry +0+0 -gravity center -background "#FFFFFF" \
  ${DIR_SCRATCH}/${IDPFX}_prep-label+coreg_asl.png
rm ${DIR_SCRATCH}/C*.png
rm ${DIR_SCRATCH}/L*.png

## remake brain mask from M0 with 2mm border
mri_synthstrip -i ${DIR_SCRATCH}/M0.nii.gz -m ${DIR_SCRATCH}/mask-brain.nii.gz -b 2

# Calculate change in control/label pairs, dM ----------------------------------
for (( i=1; i<=${NPAIR}; i++ )); do
  niimath ${DIR_SCRATCH}/C${i}.nii.gz -sub ${DIR_SCRATCH}/L${i}.nii.gz \
    ${DIR_SCRATCH}/M${i}.nii.gz
done

# Calculate CBF ----------------------------------------------------------------
FORMULA="(6000*${OPT_BRAINBLOOD}*b*exp(${OPT_DELAY}/${OPT_T1BLOOD}))/(2*${OPT_EFFICIENCY}*a*${OPT_T1BLOOD}*(1-exp(-(${OPT_DURATION}/${OPT_T1BLOOD}))))"
for (( i=1; i<=${NPAIR}; i++ )); do
  3dcalc -a ${DIR_SCRATCH}/M0.nii.gz \
    -b ${DIR_SCRATCH}/M${i}.nii.gz \
    -expr ${FORMULA} \
    -prefix ${DIR_SCRATCH}/CBF${i}.nii.gz
done
AverageImages 3 ${DIR_SCRATCH}/${IDPFX}_CBF.nii.gz 0 ${DIR_SCRATCH}/CBF*.nii.gz
## exclude noise regions outside of brain, and clip at 0
niimath ${DIR_SCRATCH}/${IDPFX}_CBF.nii.gz \
  -thr 0 -mas ${DIR_SCRATCH}/mask-brain.nii.gz \
  ${DIR_SCRATCH}/${IDPFX}_CBF.nii.gz
make3Dpng --bg ${DIR_SCRATCH}/${IDPFX}_CBF.nii.gz --bg-cbar "true" \
  --bg-mask ${DIR_SCRATCH}/mask-brain.nii.gz \
  --bg-color "timbow:hue=#ff00ff:lum=50,95:dir=decreasing:cyc=2/3" \
  --layout "6:z;6:z;6:z;6:z;6:z"

# apply transforms to PWI ------------------------------------------------------
if [[ ${NO_PWI} == "false" ]]; then
  antsApplyTransforms -d 3 -n BSpline[3] \
    -i ${PWI} -o ${DIR_SCRATCH}/${IDPFX}_${PWI_LABEL}.nii.gz \
    -r ${NATIVE} ${XFMSTR}
  make3Dpng --bg ${DIR_SCRATCH}/${IDPFX}_${PWI_LABEL}.nii.gz --bg-cbar "true" \
  --bg-mask ${DIR_SCRATCH}/mask-brain.nii.gz \
  --bg-color "timbow:hue=#ff00ff:lum=50,95:dir=decreasing:cyc=2/3" \
  --layout "6:z;6:z;6:z;6:z;6:z"
fi

## Normalized output -----------------------------------------------------------
if [[ ${NO_NORM,,} == "false" ]]; then
  for (( j=0; j<${#NORM_REF[@]}; j++ )); do
    TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
    xfm_fcn="antsApplyTransforms -d 3 -n BSpline[3]"
    xfm_fcn="${xfm_fcn} -i ${DIR_SCRATCH}/${IDPFX}_CBF.nii.gz"
    xfm_fcn="${xfm_fcn} -o ${DIR_SCRATCH}/${IDPFX}_reg-${TRG}_CBF.nii.gz"
    xfm_fcn="${xfm_fcn} -r ${NORM_REF[${j}]}"
    xfm_fcn="${xfm_fcn} -t identity"
    if [[ -n ${NORM_SYN[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_SYN[${j}]}"; fi
    if [[ -n ${NORM_MAT[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_MAT[${j}]}"; fi
    eval ${xfm_fcn}
    if [[ ${NO_PWI} == "false" ]]; then
      xfm_fcn="antsApplyTransforms -d 3 -n BSpline[3]"
      xfm_fcn="${xfm_fcn} -i ${DIR_SCRATCH}/${IDPFX}_${PWI_LABEL}.nii.gz"
      xfm_fcn="${xfm_fcn} -o ${DIR_SCRATCH}/${IDPFX}_reg-${TRG}_${PWI_LABEL}.nii.gz"
      xfm_fcn="${xfm_fcn} -r ${NORM_REF[${j}]}"
      xfm_fcn="${xfm_fcn} -t identity"
      if [[ -n ${NORM_SYN[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_SYN[${j}]}"; fi
      if [[ -n ${NORM_MAT[${j}]} ]]; then xfm_fcn="${xfm_fcn} -t ${NORM_MAT[${j}]}"; fi
      eval ${xfm_fcn}
    fi
  done
fi

## get summaries by label sets --------------------------------------------------
for (( i=0; i<${#LABEL[@]}; i++ )); do
  LNAME=$(getField -i ${LABEL[${i}]} -f label)
  LNAME=(${LNAME//\+/ })
  LUT=${TKNIPATH}/lut/lut-${LNAME}.tsv
  summarize3D --label ${LABEL[${i}]} \
    --value ${DIR_SCRATCH}/${IDPFX}_CBF.nii.gz \
    --stats "mean,sigma" --lut ${LUT} --prefix ${IDPFX}
  if [[ ${NO_PWI} == "false" ]]; then
    summarize3D --label ${LABEL[${i}]} \
      --value ${DIR_SCRATCH}/${IDPFX}_${PWI_LABEL}.nii.gz \
      --stats "mean,sigma" --lut ${LUT} --prefix ${IDPFX} --suffix ${PWI_LABEL}
  fi
done

# Save output ------------------------------------------------------------------
mkdir -p ${DIR_SAVE}
mv ${DIR_SCRATCH}/${IDPFX}_CBF.* ${DIR_SAVE}/
if [[ ${NO_PWI} == "false" ]]; then
  mv ${DIR_SCRATCH}/${IDPFX}_${PWI_LABEL}.* ${DIR_SAVE}/
fi

mkdir -p ${DIR_SAVE}/moco/${IDDIR}
mv ${DIR_SCRATCH}/*.1D ${DIR_SAVE}/moco/${IDDIR}/

#save normalized output
if [[ ${NO_NORM,,} == "false" ]]; then
  for (( j=0; j<${#NORM_REF[@]}; j++ )); do
    TRG=$(getField -i ${NORM_REF[${j}]} -f reg)
    mkdir -p ${DIR_SAVE}_${TRG}
    mv ${DIR_SCRATCH}/${IDPFX}_reg-${TRG}_CBF.nii.gz ${DIR_SAVE}_${TRG}/
    if [[ ${NO_PWI} == "false" ]]; then
      mv ${DIR_SCRATCH}/${IDPFX}_reg-${TRG}_${PWI_LABEL}.nii.gz ${DIR_SAVE}_${TRG}/
    fi
  done
fi
mv ${DIR_SCRATCH}/xfm/* ${DIR_XFM}/

# initialize RMD output --------------------------------------------------------
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
  echo 'library(downloadthis)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## PCASL Perfusion Processing' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  # show outcome
  echo '### Cerebral Blood Flow (ml/100g/min)' >> ${RMD}
  echo -e '!['${IDPFX}_CBF.nii.gz']('${DIR_SAVE}/${IDPFX}_CBF.png')\n' >> ${RMD}
  for (( i=0; i<${#LABEL[@]}; i++ )); do
    LNAME=$(getField -i ${LABEL[${i}]} -f label)
    TCSV="${DIR_SAVE}/${IDPFX}_label-${LNAME}_CBF.tsv"
    FNAME="${IDPFX}_label-${LNAME}_CBF"
    echo '```{r}' >> ${RMD}
    echo 'data <- read.csv("'${TCSV}'", sep="\t")' >> ${RMD}
    echo 'download_this(.data=data,' >> ${RMD}
    echo '  output_name = "'${FNAME}'",' >> ${RMD}
    echo '  output_extension = ".csv",' >> ${RMD}
    echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
    echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
    echo '```' >> ${RMD}
    echo '' >> ${RMD}
  done

  # show PWI
  if [[ ${NO_PWI} == "false" ]]; then
    echo '### Relative Cerebral Blood Flow (processed on scanner)' >> ${RMD}
    echo -e '!['${IDPFX}_${PWI_LABEL}.nii.gz']('${DIR_SAVE}/${IDPFX}_${PWI_LABEL}.png')\n' >> ${RMD}
    for (( i=0; i<${#LABEL[@]}; i++ )); do
      LNAME=$(getField -i ${LABEL[${i}]} -f label)
      TCSV="${DIR_SAVE}/${IDPFX}_label-${LNAME}_${PWI_LABEL}.tsv"
      FNAME="${IDPFX}_label-${LNAME}_${PWI_LABEL}"
      echo '```{r}' >> ${RMD}
      echo 'data <- read.csv("'${TCSV}'", sep="\t")' >> ${RMD}
      echo 'download_this(.data=data,' >> ${RMD}
      echo '  output_name = "'${FNAME}'",' >> ${RMD}
      echo '  output_extension = ".csv",' >> ${RMD}
      echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
      echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
      echo '```' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  #Processing Steps tabs
  echo '### Processing Steps {.tabset}' >> ${RMD}
  echo '#### Click to View -->' >> ${RMD}
  echo '#### Raw' >> ${RMD}
  echo -e '![Raw]('${DIR_SCRATCH}'/'${IDPFX}'_prep-raw_asl.png)\n' >> ${RMD}

  if [[ ${NO_REORIENT} == "false" ]]; then
    echo '#### Reorient' >> ${RMD}
    echo -e '![Reorient]('${DIR_SCRATCH}'/'${IDPFX}'_prep-reorient_asl.png)\n' >> ${RMD}
  fi

  echo '#### Motion Correction'
  echo -e '![MOCO]('${DIR_SCRATCH}'/'${IDPFX}'_prep-moco_asl.png)\n' >> ${RMD}
  echo -e '![Regressors]('${DIR_SCRATCH}'/'${IDPFX}'_regressors.png)\n' >> ${RMD}

  if [[ ${NO_DENOISE} == "false" ]]; then
    echo '#### Denoise {.tabset}' >> ${RMD}
    echo '##### Control' >> ${RMD}
    echo -e '![Denoise]('${DIR_SCRATCH}'/'${IDPFX}'_prep-control+denoise_asl.png)\n' >> ${RMD}
    echo -e '![Noise]('${DIR_SCRATCH}'/'${IDPFX}'_prep-control+noise_asl.png)\n' >> ${RMD}
    echo '##### Labeled' >> ${RMD}
    echo -e '![Denoise]('${DIR_SCRATCH}'/'${IDPFX}'_prep-label+denoise_asl.png)\n' >> ${RMD}
    echo -e '![Noise]('${DIR_SCRATCH}'/'${IDPFX}'_prep-label+noise_asl.png)\n' >> ${RMD}
  fi

  if [[ ${NO_Debias} == "false" ]]; then
    echo '#### Debias {.tabset}' >> ${RMD}
    echo '##### Control' >> ${RMD}
    echo -e '![Debias]('${DIR_SCRATCH}'/'${IDPFX}'_prep-control+debias_asl.png)\n' >> ${RMD}
    echo -e '![Bias Field]('${DIR_SCRATCH}'/'${IDPFX}'_prep-control+biasField_asl.png)\n' >> ${RMD}
    echo '##### Labeled' >> ${RMD}
    echo -e '![Debias]('${DIR_SCRATCH}'/'${IDPFX}'_prep-label+debias_asl.png)\n' >> ${RMD}
    echo -e '![Bias Field]('${DIR_SCRATCH}'/'${IDPFX}'_prep-label+biasField_asl.png)\n' >> ${RMD}
  fi

  echo '#### Coregistration' >> ${RMD}
    echo -e '![Coregistration]('${DIR_SCRATCH}'/'${IDPFX}'_reg-${COREG_RECIPE}+native.png)\n' >> ${RMD}
    echo -e '![Control]('${DIR_SCRATCH}'/'${IDPFX}'_prep-control+coreg_asl.png)\n' >> ${RMD}
    echo -e '![Labeled]('${DIR_SCRATCH}'/'${IDPFX}'_prep-label+coreg_asl.png)\n' >> ${RMD}
  fi

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


