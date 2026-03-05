#!/bin/bash -e
#===============================================================================
# Run NODDI and/or SANDI models using AMICO
# Required: MRtrix3, ANTs, FSL
# Description: Accelerated Microstructure Imaging via Convex Optimization (AMICO)
#              https://github.com/daducci/AMICO/wiki
#              This code is python wrappers for implementation of NODDI and
#              SANDI models. ACTIVEAX is NOT implemented at this time.
# References:
#   Daducci A, Canales-Rodríguez EJ, Zhang H, Dyrby TB, Alexander DC, Thiran JP.
#     Accelerated Microstructure Imaging via Convex Optimization (AMICO) from
#     diffusion MRI data. NeuroImage. 2015;105.
#     doi:10.1016/j.neuroimage.2014.10.026
#   Zhang H, Schneider T, Wheeler-Kingshott CA, Alexander DC. NODDI: practical
#     in vivo neurite orientation dispersion and density imaging of the human
#     brain. Neuroimage. 2012;61: 1000–1016.
#     doi:10.1016/j.neuroimage.2012.03.072
#   Palombo M, Ianus A, Guerreri M, Nunes D, Alexander DC, Shemesh N, et al.
#     SANDI: A compartment-based model for non-invasive apparent soma and
#     neurite imaging by diffusion MRI. Neuroimage. 2020;215: 116835.
#     doi:10.1016/j.neuroimage.2020.116835
# Author: Timothy R. Koscik, PhD
# Date Created: 2026-03/04
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
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,id:,dir-id:,\
dir-dwi:,bval:,bvec:,dwi:,mask:,\
no-noddi,no-sandi,\
noddi-dpar:,noddi-diso:,noddi-isexvivo,noddi-icvfs:,noddi-icods:\
sandi-delta:,sandi-smalldelta:,sandi-te:,sandi-dis:,sandi-rs:,sandi-din:,\
sandi-disos:,sandi-lambda1:,sandi-lambda2:,\
native:,native-mask:,\
dir-scratch:,dir-save:,requires:,force,\
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
DIR_MRTRIX=
IDPFX=
IDDIR=

DIR_DWI=
BVAL=
BVEC=
DWI=
MASK=
NATIVE=
NATIVE_MASK=

NO_NODDI="false"
NODDI_DPAR=0.0017
NODDI_DISO=0.003
NODDI_ISEXVIVO="false"
NODDI_ICVFS=
NODDI_ICODS=

NO_SANDI="false"
SANDI_DELTA=44.2
SANDI_SMALLDELTA=25.8
SANDI_TE=88.0
SANDI_DIS=0.003
SANDI_RS=
SANDI_DIN=
SANDI_DISOS=
SANDI_LAMBDA1=0
SANDI_LAMBDA2=0.005

PIPE=tkni
FLOW=DMICRO
REQUIRES="tkniDICOM,tkniAINIT,tkniDPREP"
FORCE=false

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --force) FORCE=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --dir-dwi) "$2" ; shift 2 ;;
    --bval) "$2" ; shift 2 ;;
    --bvec) "$2" ; shift 2 ;;
    --dwi) "$2" ; shift 2 ;;
    --mask) "$2" ; shift 2 ;;
    --no-noddi) NO_NODDI="true" ; shift ;;
    --no-sandi) NO_SANDI="true" ; shift ;;
    --noddi-dpar) NODDI_DPAR="$2" ; shift 2 ;;
    --noddi-diso) NODDI_DISO="$2" ; shift 2 ;;
    --noddi-isexvivo) NODDI_ISEXVIVO="true" ; shift ;;
    --noddi-icvfs) NODDI_ICVFS="$2" ; shift 2 ;;
    --noddi-icods) NODDI_ICODS="$2" ; shift 2 ;;
    --sandi-delta) SANDI_DELTA="$2" ; shift 2 ;;
    --sandi-smalldelta) SANDI_SMALLDELTA="$2" ; shift 2 ;;
    --sandi-te) SANDI_TE="$2" ; shift 2 ;;
    --sandi-dis) SANDI_DIS="$2" ; shift 2 ;;
    --sandi-rs) SANDI_RS="$2" ; shift 2 ;;
    --sandi-din) SANDI_DIN="$2" ; shift 2 ;;
    --sandi-disos) SANDI_DISOS="$2" ; shift 2 ;;
    --sandi-lambda1) SANDI_LAMBDA1="$2" ; shift 2 ;;
    --sandi-lambda2) SANDI_LAMBDA2="$2" ; shift 2 ;;
    --native) NATIVE="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
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
if [[ ${VERBOSE} == "true" ]]; then echo "TKNI DWI Microstructure"; fi

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

# initialize directories
mkdir -p ${DIR_SCRATCH}

# Setup Inputs and Defaults ----------------------------------------------------
if [[ -z ${DIR_DWI} ]]; then
  DIR_DWI=${DIR_PROJECT}/derivatives/${PIPE}/dwi/preproc
fi
if [[ -z ${BVAL} ]]; then BVAL=${DIR_DWI}/dwi/${IDPFX}_dwi.bval; fi
if [[ -z ${BVEC} ]]; then BVEC=${DIR_DWI}/dwi/${IDPFX}_dwi.bvec; fi
if [[ -z ${DWI} ]]; then DWI=${DIR_DWI}/dwi/${IDPFX}_dwi.nii.gz; fi
if [[ -z ${MASK} ]]; then MASK=${DIR_DWI}/mask/${IDPFX}_mask-brain+b0.nii.gz; fi

if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/dwi/microstructure
fi
mkdir -p ${DIR_SAVE}

if [[ -z ${NATIVE} ]]; then
  NATIVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/${IDPFX}_T1w.nii.gz
fi

if [[ -z ${NATIVE_MASK} ]]; then
  NATIVE_MASK=${DIR_PROJECT}/derivatives/${PIPE}/anat/mask/${IDPFX}_mask-brain.nii.gz
fi

# Check if input files exist ---------------------------------------------------
FCHK="true"
if [[ ! -f ${BVAL} ]]; then
  FCHK="false"
  echo -e "\tWARNING [${PIPE}:${FLOW}] BVAL not found"
fi
if [[ ! -f ${BVEC} ]]; then
  FCHK="false"
  echo -e "\tWARNING [${PIPE}:${FLOW}] BVEC not found"
fi
if [[ ! -f ${DWI} ]]; then
  FCHK="false"
  echo -e "\tWARNING [${PIPE}:${FLOW}] DWI not found"
fi
if [[ ! -f ${MASK} ]]; then
  FCHK="false"
  echo -e "\tWARNING [${PIPE}:${FLOW}] MASK not found"
fi
if [[ ! -f ${NATIVE} ]]; then
  FCHK="false"
  echo -e "\tWARNING [${PIPE}:${FLOW}] NATIVE not found"
fi
if [[ ! -f ${NATIVE_MASK} ]]; then
  FCHK="false"
  echo -e "\tWARNING [${PIPE}:${FLOW}] NATIVE_MASK not found"
fi
if [[ ${FCHK} == "false" ]]; then
  echo "ERROR [${PIPE}:${FLOW}] Required input files not found, aborting"
  exit 2
fi

# Run NODDI ====================================================================
if [[ ${NO_NODDI} == "false" ]]; then
  noddi_fcn="amicoNODDI.py"
  noddi_fcn="${noddi_fcn} --bval ${BVAL}"
  noddi_fcn="${noddi_fcn} --bvec ${BVEC}"
  noddi_fcn="${noddi_fcn} --dwi ${DWI}"
  noddi_fcn="${noddi_fcn} --mask ${MASK}"
  noddi_fcn="${noddi_fcn} --dir-save ${DIR_SCRATCH}/NODDI_results"
  noddi_fcn="${noddi_fcn} --dir-scratch ${DIR_SCRATCH}"
  noddi_fcn="${noddi_fcn} --dPar ${NODDI_DPAR}"
  noddi_fcn="${noddi_fcn} --dIso ${NODDI_DISO}"
  if [[ ${NODDI_ISEXVIVO} == "true" ]]; then noddi_fcn="${noddi_fcn} --isExvivo"; fi
  if [[ -n ${NODDI_ICVFS} ]]; then noddi_fcn="${noddi_fcn} --IC_VFs ${NODDI_ICVFS}"; fi
  if [[ -n ${NODDI_ODS} ]]; then noddi_fcn="${noddi_fcn} --IC_ODs ${NODDI_ODS}"; fi
  echo -e "AMICO NODDI ------\n${noddi_fcn}\n------"
  eval ${noddi_fcn}

  # resample to full native spacing
  antsApplyTransforms -d 3 -e 3 -n Linear -r ${NATIVE} \
    -i ${DIR_SCRATCH}/NODDI_results/${IDPFX}_NODDI-dir.nii.gz \
    -o ${DIR_SCRATCH}/NODDI_results/${IDPFX}_space-native_NODDI-dir.nii.gz
  antsApplyTransforms -d 3 -n Linear -r ${NATIVE} \
    -i ${DIR_SCRATCH}/NODDI_results/${IDPFX}_NODDI-NDI.nii.gz \
    -o ${DIR_SCRATCH}/NODDI_results/${IDPFX}_space-native_NODDI-NDI.nii.gz
  antsApplyTransforms -d 3 -n Linear -r ${NATIVE} \
    -i ${DIR_SCRATCH}/NODDI_results/${IDPFX}_NODDI-ODI.nii.gz \
    -o ${DIR_SCRATCH}/NODDI_results/${IDPFX}_space-native_NODDI-ODI.nii.gz
  antsApplyTransforms -d 3 -n Linear -r ${NATIVE} \
    -i ${DIR_SCRATCH}/NODDI_results/${IDPFX}_NODDI-FWF.nii.gz \
    -o ${DIR_SCRATCH}/NODDI_results/${IDPFX}_space-native_NODDI-FWF.nii.gz

  if [[ ${NO_PNG} == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
    SFXLS=("NDI" "FWF" "ODI")
    for (( i=0; i<${#SFXLS[@]}; i++ )); do
      SFX=${SFXLS[${i}]}
      make3Dpng --bg ${NATIVE} \
        --fg ${DIR_SCRATCH}/NODDI_results/${IDPFX}_space-native_NODDI-${SFX}.nii.gz \
        --fg-mask ${NATIVE_MASK} \
        --fg-color "timbow:hue=#ff00ff:cyc=2.3/6:dir=increasing:lum=35,85" \
        --fg-cbar "true" \
        --layout "5:z;5:z;5:z;5:z;5:z" \
        --filename ${IDPFX}_NODDI-${SFX} \
        --dir-save ${DIR_SCRATCH}
    done
  fi
  # save output
  mv ${DIR_SCRATCH}/NODDI_results/*NODDI* ${DIR_SAVE}/
  mv ${DIR_SCRATCH}/*NODDI*.png ${DIR_SAVE}/
fi

# Run SANDI ====================================================================
if [[ ${NO_SANDI} == "false" ]]; then
  sandi_fcn="amicoSANDI.py"
  sandi_fcn="${sandi_fcn} --bval ${BVAL}"
  sandi_fcn="${sandi_fcn} --bvec ${BVEC}"
  sandi_fcn="${sandi_fcn} --dwi ${DWI}"
  sandi_fcn="${sandi_fcn} --mask ${MASK}"
  sandi_fcn="${sandi_fcn} --dir-save ${DIR_SCRATCH}/SANDI_results"
  sandi_fcn="${sandi_fcn} --dir-scratch ${DIR_SCRATCH}"
  sandi_fcn="${sandi_fcn} --delta ${SANDI_DELTA}"
  sandi_fcn="${sandi_fcn} --small_delta ${SANDI_SMALLDELTA}"
  sandi_fcn="${sandi_fcn} --TE ${SANDI_TE}"
  sandi_fcn="${sandi_fcn} --d_is ${SANDI_DIS}"
  if [[ -n ${SANDI_RS} ]]; then sandi_fcn="${sandi_fcn} --Rs ${SANDI_RS}"; fi
  if [[ -n ${SANDI_DIN} ]]; then sandi_fcn="${sandi_fcn} --d_in ${SANDI_DIN}"; fi
  if [[ -n ${SANDI_DISOS} ]]; then sandi_fcn="${sandi_fcn} --d_isos ${SANDI_DISOS}"; fi
  sandi_fcn="${sandi_fcn} --lambda1 ${SANDI_LAMBDA1}"
  sandi_fcn="${sandi_fcn} --lambda2 ${SANDI_LAMBDA2}"
  echo -e "AMICO SANDI ------\n${sandi_fcn}\n------"
  eval ${sandi_fcn}

  if [[ ${NO_PNG} == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
    SFXLS=("De" "fneurite" "Din" "fsoma" "fextra" "Rsoma")
    for (( i=0; i<${#SFXLS[@]}; i++ )); do
      SFX=${SFXLS[${i}]}
      antsApplyTransforms -d 3 -n Linear  -r ${NATIVE} \
        -i ${DIR_SCRATCH}/SANDI_results/${IDPFX}_SANDI-${SFX}.nii.gz \
        -o ${DIR_SCRATCH}/SANDI_results/${IDPFX}_space-native_SANDI-${SFX}.nii.gz
      make3Dpng --bg ${NATIVE} \
        --fg ${DIR_SCRATCH}/SANDI_results/${IDPFX}_space-native_SANDI-${SFX}.nii.gz \
        --fg-mask ${NATIVE_MASK} \
        --fg-color "timbow:hue=#ff00ff:cyc=2.3/6:dir=decreasing:lum=35,85" \
        --fg-cbar "true" \
        --layout "5:z;5:z;5:z;5:z;5:z" \
        --filename ${IDPFX}_SANDI-${SFX} \
        --dir-save ${DIR_SCRATCH}
    done
  fi
  mv ${DIR_SCRATCH}/SANDI_results/*SANDI* ${DIR_SAVE}/
  mv ${DIR_SCRATCH}/*SANDI*.png ${DIR_SAVE}/
fi

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
  echo 'library(downloadthis)' >> ${RMD}
  echo "create_dt <- function(x){" >> ${RMD}
  echo "  DT::datatable(x, extensions='Buttons'," >> ${RMD}
  echo "    options=list(dom='Blfrtip'," >> ${RMD}
  echo "    buttons=c('copy', 'csv', 'excel', 'pdf', 'print')," >> ${RMD}
  echo '    lengthMenu=list(c(10,25,50,-1), c(10,25,50,"All"))))}' >> ${RMD}
  echo -e '```\n' >> ${RMD}

  echo '## '${PIPE}${FLOW}': DWI Microstructure' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  # Show output file tree ------------------------------------------------------
  echo '' >> ${RMD}
  echo '### DWI Microstructure Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "'${IDPFX}'*" -Rn --prune '${DIR_SAVE} >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  # Microstructure Measures -----------------------------------------------------
  if [[ ${NO_SANDI} == "false" ]]; then
    echo '### Neurite Orientation Dispersion and Density Imaging (NODDI) {.tabset}' >> ${RMD}
    SLS=("NDI" "ODI" "FWF")
    SLAB=("Neurite Density Index" "Orientation Dispersion Index" "Free Water Fraction")
    SDESC=("Description: Also referred to as ICVF (Intra-Cellular Volume Fraction). This represents the fraction of tissue volume occupied by neurites (axons and dendrites).  \nInterpretation: Higher values indicate a higher density of neurites. In white matter, this reflects axonal packing; in gray matter, it reflects dendritic density." \
    "Description: A measure of the angular variation or 'fanning' of neurites.  \nScale: ranges from 0 (perfectly aligned/parallel fibers) to 1 (completely isotropic/randomly oriented).  \nInterpretation: High ODI in white matter might indicate crossing or fanning fibers. Gray matter naturally has much higher ODI due to the complex branching of dendrites." \
    "Description: Also referred to as ISOVF (Isotropic Volume Fraction). This represents the fraction of the volume occupied by 'free' water (e.g., Cerebrospinal Fluid).  \nInterpretation: Elevated FWF is often seen in the ventricles, around the edges of the brain, or in areas of neuroinflammation and edema.")
    for i in {0..2}; do
      echo "#### ${SLAB[${i}]}" >> ${RMD}
      echo -e "${SDESC[${i}]}  " >> ${RMD}
      TPNG=${DIR_SAVE}/${IDPFX}_NODDI-${SLS[${i}]}.png
      TNII=${DIR_SAVE}/${IDPFX}_NODDI-${SLS[${i}]}.nii.gz
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi
  if [[ ${NO_SANDI} == "false" ]]; then
    echo '### Soma and Neurite Density Imaging (SANDI) {.tabset}' >> ${RMD}
    SLS=("fsoma" "fneurite" "fextra" "Rsoma" "Din" "De")
    SLAB=("Soma Volume Fraction" "Neurite Volume Fraction" "Extracellular Volume Fraction" "Soma Radius" "Intraneurite Diffusivity" "Extracellular Diffusivity")
    SDESC=("Description: The estimated fraction of the total tissue volume occupied by cell bodies (somas).  \nInterpretation: Higher values indicate a higher density or larger size of cell bodies. This is particularly relevant in gray matter." \
    "Description: The estimated fraction of the total tissue volume occupied by neurites (axons and dendrites).  \nInterpretation: This is analogous to the NDI (Neurite Density Index) in NODDI. It represents the density of 'sticks' or tubular structures." \
    "Description: The fraction of the volume occupied by the space outside of neurons and glia (extra-cellular space).  \nInterpretation: The remaining fraction after subtracting soma and neurite fractions" \
    "Description: The estimated average radius of the cell bodies (somas).  \nUnits: Meters (m).\nInterpretation: Provides a direct morphological measure of cell size. Note that sensitivity to this parameter depends heavily on having high b-values" \
    "Description: The apparent diffusivity of water molecules trapped inside the neurites.\nUnits: mm/s^2  \nInterpretation: Reflects the restriction of water within the axonal/dendritic tubes." \
    "Description: The apparent isotropic diffusivity of water molecules in the extra-cellular space.  \nUnits: mm/s^2  \nInterpretation: Reflects how easily water moves around the cells and neurites.")
    for i in {0..5}; do
      echo "#### ${SLAB[${i}]}" >> ${RMD}
      echo -e "${SDESC[${i}]}  " >> ${RMD}
      TPNG=${DIR_SAVE}/${IDPFX}_SANDI-${SLS[${i}]}.png
      TNII=${DIR_SAVE}/${IDPFX}_SANDI-${SLS[${i}]}.nii.gz
      echo '!['${TNII}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    done
  fi

  echo "### References" >> ${RMD}
  echo '' >> ${RMD}
  echo "Daducci A, Canales-Rodríguez EJ, Zhang H, Dyrby TB, Alexander DC, Thiran JP. Accelerated Microstructure Imaging via Convex Optimization (AMICO) from diffusion MRI data. NeuroImage. 2015;105. doi:10.1016/j.neuroimage.2014.10.026  " >> ${RMD}
  echo '' >> ${RMD}
  echo "Zhang H, Schneider T, Wheeler-Kingshott CA, Alexander DC. NODDI: practical in vivo neurite orientation dispersion and density imaging of the human brain. Neuroimage. 2012;61: 1000–1016. doi:10.1016/j.neuroimage.2012.03.072  " >> ${RMD}
  echo '' >> ${RMD}
  echo "Palombo M, Ianus A, Guerreri M, Nunes D, Alexander DC, Shemesh N, et al. SANDI: A compartment-based model for non-invasive apparent soma and neurite imaging by diffusion MRI. Neuroimage. 2020;215: 116835. doi:10.1016/j.neuroimage.2020.116835  " >> ${RMD}
  echo '' >> ${RMD}

  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
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
# end of Function
#===============================================================================
exit 0
