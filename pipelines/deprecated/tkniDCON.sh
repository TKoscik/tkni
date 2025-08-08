#!/bin/bash -e
#===============================================================================
# Get Connectivity Matrix
# Required: MRtrix3, ANTs, FSL
# Description:
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
label:,lut-orig:,lut-sort:,tck:,image-t1-dwi:,\
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
DIR_PROJECT=
DIR_SCRATCH=
IDPFX=
IDDIR=

LABEL=hcpmmp1+MALF
LUT_ORIG=${TKNIPATH}/lut/hcpmmp1_original.txt
LUT_SORT=${TKNIPATH}/lut/hcpmmp1_ordered_tkni.txt
TCK=
IMAGE_T1_DWI=
DIR_SAVE=

PIPE=tkni
FLOW=DPREP
REQUIRES="tkniDICOM,tkniAINIT,tkniMALF"
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
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --label) LABEL="$2" ; shift 2 ;;
    --lut-orig) LUT_ORIG="$2" ; shift 2 ;;
    --lut-sort) LUT_SORT="$2" ; shift 2 ;;
    --tck) TCK="$2" ; shift 2 ;;
    --image-t1-dwi) IMAGE_T1_DWI="$2" ; shift 2 ;;
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
# set project defaults ---------------------------------------------------------
if [[ -z ${MRTRIXPATH} ]]; then
  MRTRIXPATH=/usr/lib/mrtrix3/bin
fi
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
  echo ">>>>>Process DWI images for the following participant:"
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
      echo "ERROR [${PIPE}:${FLOW}] Prerequisite WORKFLOW: ${REQ} not run."
      ERROR_STATE=1
    fi
  done
  if [[ ${ERROR_STATE} -eq 1 ]]; then
    echo "Aborting."
    exit 1
  fi
fi

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> Prerequisites COMPLETE: ${REQUIRES[@]}"
fi

# Check if has already been run, and force if requested ------------------------
FCHK=${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt
FDONE=${DIR_PROJECT}/status/${PIPE}${FLOW}/DONE_${PIPE}${FLOW}_${IDPFX}.txt
if [[ -f ${FCHK} ]] || [[ -f ${FDONE} ]]; then
  echo "WARNING [${PIPE}:${FLOW}] This pipeline has been run."
  if [[ "${FORCE}" == "true" ]]; then
    echo "Re-running ${PIPE}${FLOW}"
  else
    echo "ABORTING. Use the '--force' option to re-run"
    exit 1
  fi
fi

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> Previous Runs CHECKED"
fi

# Additional default values ----------------------------------------------------
if [[ -z ${DIR_MRTRIX} ]]; then
  DIR_MRTRIX=${DIR_PROJECT}/derivatives/mrtrix/${IDDIR}
fi
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/dwi/connectome
fi

if [[ ! -f ${LABEL} ]]; then
  TLAB=(${LABEL//\+/ })
  LAB_PIPE=${TLAB[-1]}
  LAB_DIR=${DIR_PROJECT}/derivatives/${PIPE}/anat/label/${LAB_PIPE}
  LABEL=${LAB_DIR}/${IDPFX}_label-${LABEL}.nii.gz
fi
if [[ ! -f ${LABEL} ]]; then
  echo "ERROR [TKNI: ${FCN_NAME}] LABEL file not found."
  exit 2
fi

if [[ -z ${TCK} ]]; then
  TCK=${DIR_MRTRIX}/TCK/sift_1mio.tck
fi
if [[ -z ${IMAGE_T1_DWI} ]]; then
  IMAGE_T1_DWI=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/dwi/${IDPFX}_space-dwi_T1w.nii.gz
fi

# Connectome construction ======================================================
# Preparing an atlas for structural connectivity analysis ----------------------
## Purpose: Obtain a volumetric atlas-based parcellation image, co-registered to
## diffusion space for downstream structural connectivity (SC) matrix generation
## Main reference: Glasser et al., 2016a (for the atlas used here for SC generation)

# convert labels to DWI space
antsApplyTransforms -d 3 -n MultiLabel \
  -i ${LABEL} \
  -o ${DIR_SCRATCH}/labels.nii.gz \
  -r ${IMAGE_T1_DWI}

## Replace the random integers of the hcpmmp1.mif file with integers that start
## at 1 and increase by 1.
#HCPMMP_ORIG=${TKNIPATH}/lut/hcpmmp1_original.txt
#HCPMMP_SORT=${TKNIPATH}/lut/hcpmmp1_ordered.txt
labelconvert ${DIR_SCRATCH}/labels.nii.gz \
  ${LUT_ORIG} ${LUT_SORT} ${DIR_SCRATCH}/labels.mif

# Matrix Generation ------------------------------------------------------------
## Purpose: Gain quantitative information on how strongly each atlas region is
## connected to all others; represent it in matrix format
tck2connectome -symmetric -zero_diagonal \
  -scale_invnodevol ${TCK} \
  ${DIR_SCRATCH}/labels.mif \
  ${DIR_SCRATCH}/connectome.csv \
  -out_assignment ${DIR_SCRATCH}/assignments.csv

connectome2tck ${TCK} \
  ${DIR_SCRATCH}/assignments.csv ${DIR_SCRATCH}/exemplar \
  -files single \
  -exemplars ${DIR_SCRATCH}/labels.mif

# Create Mesh Node Geometry ----------------------------------------------------
label2mesh ${DIR_SCRATCH}/labels.mif ${DIR_SCRATCH}/labels_mesh.obj

# Save Results output ---------------------------------------------------------
LABNAME=$(getField -i ${LABEL} -f label)
LABNAME=(${LABNAME//+/ })

mkdir -p ${DIR_SAVE}
cp ${DIR_SCRATCH}/connectome.csv ${DIR_SAVE}/${IDPFX}_connectome-${LABNAME[0]}.csv
mkdir -p ${DIR_MRTRIX}/CON
cp ${DIR_SCRATCH}/* ${DIR_MRTRIX}/CON

Rscript ${TKNIPATH}/R/connectivityPlot.R \
  ${DIR_SAVE}/${IDPFX}_connectome-${LABNAME[0]}.csv

#===============================================================================
# end of Function
#===============================================================================
exit 0

