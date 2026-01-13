#!/bin/bash -e
#===============================================================================
# DICOM Conversion
# Author: Timothy R. Koscik, PhD
# Date Created: 2023-08-10
# Date Modified: 2023-08-24
# CHANGE_LOG:	-convert into a function
#===============================================================================
PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
FCN_NAME=($(basename "$0"))
FCN_NAME=${FCN_NAME%.*}
DATE_SUFFIX=$(date +%Y%m%dT%H%M%S%N)
OPERATOR=$(whoami)
KERNEL="$(uname -s)"
HARDWARE="$(uname -m)"
KEEP=false
NO_LOG=false
umask 007

# Parse inputs -----------------------------------------------------------------
OPTS=$(getopt -o hvn --long pi:,project:,dir-project:,\
id:,dir-id:,id-field:,reorient:,flip:,add-resolution,show-mod:,\
input-dcm:,dir-scratch:,\
help,verbose,no-png,force -n 'parse-options' -- "$@")
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
IDFIELD="sub,ses"
REORIENT="false"
FLIP="false"
ADD_RES="false"
SHOW_MOD="anat,dwi,func,fmap,perf"
INPUT_DCM=
HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false
FORCE="false"

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES=null

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    --force) FORCE=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --id-field) IDFIELD="$2" ; shift 2 ;;
    --reorient) REORIENT="$2" ; shift 2 ;;
    --flip) FLIP="$2" ; shift 2 ;;
    --add-resolution) ADD_RES="true" ; shift ;;
    --input-dcm) INPUT_DCM="$2" ; shift 2 ;;
    --show-mod) SHOW_MOD="$2" ; shift 2 ;;
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
  echo '  --pid              participant identifier'
  echo '  --sid              session identifier'
  echo '  --aid              assessment identifier'
  echo '  --input-dcm        full path to DICOMs, may be directory or zip-file'
  echo '  --dir-project      project directory'
  echo '                     default=/data/x/projects/${PI}/${PROJECT}'
  echo '  --dir-scratch      directory for temporary workspace'
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
  DIR_SCRATCH=${TKNI_SCRATCH}/${FCN_NAME}_${PI}_${PROJECT}_${DATE_SUFFIX}
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

# Check if necessary inputs are specified or can be found ----------------------
if [[ -z ${INPUT_DCM} ]]; then
  INPUT_DCM=${DIR_PROJECT}/sourcedata/${IDPFX}_dicom.zip
  if [[ ! -f ${INPUT_DCM} ]]; then
    echo "ERROR [${PIPE}:${FLOW}] Expected input DICOM not found, please specify"
    echo "   Could not find: ${INPUT_DCM}"
    exit 1
  fi
fi

# Begin processing =============================================================
mkdir -p ${DIR_SCRATCH}

# get DICOM extracted or set folder in order to find MRS later on --------------
if [[ -d "${INPUT_DCM}" ]]; then
  if [[ ${VERBOSE} == "true" ]]; then echo "DICOM folder found"; fi
else
  FNAME="${INPUT_DCM##*/}"
  FEXT="${FNAME##*.}"
  if [[ "${FEXT,,}" != "zip" ]]; then
    echo "ERROR [${PIPE}:${FLOW}] Input must be either a directory or zip file"
    exit 1
  fi
  mkdir -p ${DIR_SCRATCH}/dicom
  unzip -qq ${INPUT_DCM} -d ${DIR_SCRATCH}/dicom
  INPUT_DCM=${DIR_SCRATCH}/dicom
fi

# Convert DICOMS ---------------------------------------------------------------
dicomConvert --input ${INPUT_DCM} --depth 10 --dir-save ${DIR_SCRATCH}

# Reorient images if requested -------------------------------------------------
if [[ ${REORIENT} != "false" ]]; then
  FLS=($(ls ${DIR_SCRATCH}/*.nii.gz))
  for (( i=0; i<${#FLS[@]}; i++ )); do
    3dresample -orient ${REORIENT} -overwrite \
      -prefix ${DIR_SCRATCH}/tmp.nii.gz -input ${FLS[${i}]}
    CopyImageHeaderInformation ${FLS[${i}]} \
      ${DIR_SCRATCH}/tmp.nii.gz \
      ${DIR_SCRATCH}/tmp.nii.gz 1 0 0
    3dresample -orient RPI -overwrite \
      -prefix ${DIR_SCRATCH}/tmp.nii.gz \
      -input ${DIR_SCRATCH}/tmp.nii.gz
    mv ${DIR_SCRATCH}/tmp.nii.gz ${FLS[${i}]}
  done
fi

# Autoname NIFTIs --------------------------------------------------------------
if [[ ${ADD_RES} == "false" ]]; then
  dicomAutoname --id ${IDPFX} --id-field ${IDFIELD} \
    --dir-input ${DIR_SCRATCH} --dir-project ${DIR_PROJECT}
else
  dicomAutoname --id ${IDPFX} --id-field ${IDFIELD} --add-resolution \
    --dir-input ${DIR_SCRATCH} --dir-project ${DIR_PROJECT}
fi

# Copy MRS as needed -----------------------------------------------------------
if [[ -d ${DIR_PROJECT}/rawdata/${IDDIR}/mrs ]]; then
  MRS_DAT=($(find ${DIR_SCRATCH}/ -name '*.dat' -type f))
  mkdir -p ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/
  for ((i=0; i<${#MRS_DAT[@]}; i++ )); do
    cp ${MRS_DAT[${i}]} ${DIR_PROJECT}/rawdata/${IDDIR}/mrs/
  done
fi
rm -rf ${DIR_SCRATCH}/dicom

# Flip if requested-------------------------------------------------------------
## useful for ex vivo imaging when brains are put in the sacnner in odd orientation
if [[ ${FLIP} != "false" ]]; then
  FLS=($(ls ${DIR_PROJECT}/rawdata/${IDDIR}/*/*.nii.gz))
  for (( j=0; j<${#FLS[@]}; j++ )); do
    c3d ${FLS[${j}]} -flip ${FLIP} -o ${FLS[${j}]}
  done
fi

# generate PNGs for QC ---------------------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  DIR_RAW=${DIR_PROJECT}/rawdata/${IDDIR}
  DLS=(anat dwi fmap func perf)
  for j in "${DLS[@]}"; do
    if [[ -d ${DIR_RAW}/${j} ]]; then
      unset FLS
      FLS=($(ls ${DIR_RAW}/${j}/*.nii.gz))
      for (( i=0; i<${#FLS[@]}; i++ )); do
        BG=${FLS[${i}]}
        TPNG="${BG%%.*}.png"
        DAT=$(niiInfo -i ${BG} -f datatype)
        echo -e ">>>>>>making png\n\t$BG"
        if [[ ${DAT} -ne 128 ]]; then
          if [[ ! -f ${TPNG} ]]; then
            NVOL=$(niiInfo -i ${BG} -f "volumes")
            if [[ ${NVOL} -eq 1 ]]; then
              make3Dpng --bg ${BG} --bg-threshold "2.5,97.5" --verbose
            elif [[ ${NVOL} -le 10 ]]; then
              for (( j=1; j<=${NVOL}; j++ )); do
                make3Dpng --bg ${BG} --bg-vol ${j} --bg-threshold "2.5,97.5" \
                  --filename vol${j} --dir-save ${DIR_SCRATCH}
                  montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
              done
            elif [[ ${NVOL} -le 100 ]]; then
              make4Dpng_update --fg ${BG}
            elif [[ ${NVOL} -le 250 ]]; then
              make4Dpng_update --fg ${BG} --volumes "0:2:${NVOL}"
            else
              make4Dpng_update --fg ${BG} --volumes "0:5:${NVOL}"
            fi

            #if [[ ${j} == "dwi" ]] || [[ ${j} == "func" ]]; then
            #  if [[ ${NVOL} -eq 1 ]]; then
            #    echo -e "\t3D"
            #    make3Dpng --bg ${BG} --bg-threshold "2.5,97.5" --verbose
            #  elif [[ ${NVOL} -le 100 ]]; then
            #    make4Dpng_update --fg ${BG}
            #  elif [[ ${NVOL} -le 250 ]]; then
            #    make4Dpng_update --fg ${BG} --volumes "0:2:${NVOL}"
            #  else
            #    make4Dpng_update --fg ${BG} --volumes "0:5:${NVOL}"
            #  fi
            #else
            #  if [[ ${NVOL} -eq 1 ]]; then
            #    make3Dpng --bg ${BG} --bg-threshold "2.5,97.5"
            #  elif [[ ${NVOL} -le 5 ]]; then
            #    montage_fcn="montage"
            #    for (( j=1; j<=${NVOL}; j++ )); do
            #      make3Dpng --bg ${BG} --bg-vol ${j} --bg-threshold "2.5,97.5" \
            #        --filename vol${j} --dir-save ${DIR_SCRATCH}
            #      montage_fcn="${montage_fcn} ${DIR_SCRATCH}/vol${j}.png"
            #    done
            #    montage_fcn="${montage_fcn} -tile 1x -geometry +0+0 -gravity center"
            #    montage_fcn=${montage_fcn}' -background "#FFFFFF"'
            #    montage_fcn="${montage_fcn} ${TPNG}"
            #    eval ${montage_fcn}
            #    rm ${DIR_SCRATCH}/vol*.png
            #  else
            #     make4Dpng_update --fg ${BG}
            #  fi
            #fi
          fi
        fi
      done
    fi
  done
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}
  RMD=${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd

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
  echo 'knitr::include_graphics("/usr/local/tkni/dev/TK_BRAINLab_logo.png")' >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  echo '## DICOM Conversion' >> ${RMD}

  # output Project related information -------------------------------------------
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
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo 'DICOM Source: **'${INPUT_DCM}'**\' >> ${RMD}
  echo '' >> ${RMD}
  echo '### NIfTI Output {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### File Tree' >> ${RMD}
  echo '```{bash}' >> ${RMD}
  echo 'tree -P "*" -Rn --prune '${DIR_RAW} >> ${RMD}
  echo '```' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Raw Data {.tabset}' >> ${RMD}

  SHOW_MOD=(${SHOW_MOD//,/ })
  for (( j=0; j<${#SHOW_MOD[@]}; j++ )); do
    TDIR=${DIR_RAW}/${SHOW_MOD[${j}]}
    echo '#### '${SHOW_MOD[${j}]}' {.tabset}' >> ${RMD}
    if [[ -d ${TDIR} ]]; then
      TLS=($(ls ${TDIR}/${IDPFX}*.nii.gz))
      for (( i=0; i<${#TLS[@]}; i++ )); do
        BNAME=$(basename ${TLS[${i}]})
        FNAME=${BNAME//\.nii\.gz}
        TMOD=${FNAME//${IDPFX}_}
        TPNG=${TDIR}/${FNAME}.png
        echo '##### '${TMOD} >> ${RMD}
        if [[ -f ${TPNG} ]]; then
          echo '!['${BNAME}']('${TPNG}')' >> ${RMD}
        else
          echo 'PNG Not Found\' >> ${RMD}
        fi
        echo '' >> ${RMD}
      done
    else
      #echo '##### '${SHOW_MOD[${j}]} >> ${RMD}
      echo 'NIfTI Not Found\' >> ${RMD}
      echo '' >> ${RMD}
    fi
  done

  # Render RMD file as html ------------------------------------------------------
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
fi

# write status file ------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0

