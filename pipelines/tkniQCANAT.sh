#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      QCANAT
# DESCRIPTION:   Generate a quality control report for a participant after
#                processing pipelines are finished for anatomical images.
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2026-01-27
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
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,id:,dir-id:,\
dir-raw:,dir-native:,dir-add:,dir-xfm:,dir-mask:,dir-label:,dir-posterior:,\
mask-fg:,mask-brain:,mask-wm:,\
label-tissue:,value-gm:,value-wm:,value-deep:,value-csf:,\
posterior-tissue:,vol-gm:,vol-wm:,vol-deep:,vol-csf:,\
ref-native:,redo-frame,\
dir-save:,dir-summary:,dir-scratch:,requires:,\
help,verbose,force,reset-csv -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_SCRATCH=
IDPFX=
IDDIR=

DIR_RAW=
DIR_NATIVE=
DIR_ADD=
DIR_MASK=
DIR_LABEL=
DIR_XFM=
DIR_POST=

MASK_FG=
MASK_BRAIN=
MASK_WM=
LABEL_TISSUE=
POSTERIOR_TISSUE=

#METRICS="cjv,cnr,efc,fber,fwhm,snr_frame,snr_fg,snr_brain,snr_dietrich,wm2max"
# disabling option to select metrics, will require rework of output generation to implement
#ADD_MEAN="true"
#VOLUME="all"
REF_NATIVE=
LAB_GM=2
LAB_WM=4
LAB_DEEP=3
LAB_CSF=1
VOL_GM=1
VOL_WM=3
VOL_DEEP=2
VOL_CSF=4

REDO_FRAME="false"

HELP="false"
VERBOSE="false"
NO_PNG="false"
NO_RMD="false"
NO_SUMMARY="false"
NO_RAW="false"

PIPE=tkni
FLOW=${FCN_NAME//tkni}
REQUIRES=""
FORCE="false"
RESET_CSV="false"

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
    --reset-csv) RESET_CSV=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --dir-raw) DIR_RAW="$2" ; shift 2 ;;
    --dir-native) DIR_NATIVE="$2" ; shift 2 ;;
    --dir-add) DIR_ADD="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
    --dir-mask) DIR_MASK="$2" ; shift 2 ;;
    --dir-label) DIR_LABEL="$2" ; shift 2 ;;
    --dir-posterior) DIR_POSTERIOR="$2" ; shift 2 ;;
    --mask-fg) MASK_FG="$2" ; shift 2 ;;
    --mask-brain) MASK_BRAIN="$2" ; shift 2 ;;
    --mask-wm) MASK_WM="$2" ; shift 2 ;;
    --label-tissue) LABEL_TISSUE="$2" ; shift 2 ;;
    --value-gm) LAB_GM="$2" ; shift 2 ;;
    --value-wm) LAB_WM="$2" ; shift 2 ;;
    --value-deep) LAB_DEEP="$2" ; shift 2 ;;
    --value-csf) CSF="$2" ; shift 2 ;;
    --posterior-tissue) POSTERIOR_TISSUE="$2" ; shift 2 ;;
    --vol-gm) VOL_GM="$2" ; shift 2 ;;
    --vol-wm) VOL_WM="$2" ; shift 2 ;;
    --vol-deep) VOL_DEEP="$2" ; shift 2 ;;
    --vol-csf) VOL_CSF="$2" ; shift 2 ;;
    --ref-native) REF_NATIVE="$2" ; shift 2 ;;
    --redo-frame) REDO_FRAME="true" ; shift ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --dir-summary) DIR_SUMMARY="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --force) FORCE="true" ; shift ;;
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
  echo '  --dir-scratch      directory for temporary workspace'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
if [[ ${RESET_CSV} == "true" ]]; then
  echo -e "\n\n[${PIPE}${FLOW}] WARNING: --reset-csv create a new CSV data file."
  echo -e "\tthe existing file will have _dep${TIMESTAMP} appended to the filename."
  read -p "Continue with this action? (y/n)" RESPONSE
  if [[ "${RESPONSE,,}" != "y" ]]; then
    echo "[${PIPE}${FLOW}] ABORTING."
    exit 1
  fi
fi

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
# make ID String for output ------
unset HDR IDSTR TV
TV=(${IDPFX//_/ })
for (( i=0; i<${#TV[@]}; i++ )); do
  TTV=(${TV[${i}]//-/ })
  HDR="${HDR},${TTV[0]}"
  IDSTR="${IDSTR},${TTV[1]}"
done
HDR=${HDR:1}
HDR=${HDR//sub,/participant_id,}
HDR=${HDR//ses,/session_id,}
IDSTR=${IDSTR:1}

### PIPELINE
# Set default directories ------------------------------------------------------
if [[ -z ${DIR_RAW} ]]; then
  DIR_RAW="${DIR_PROJECT}/rawdata/${IDDIR}/anat"
fi
if [[ -z ${DIR_NATIVE} ]]; then
  DIR_NATIVE="${DIR_PROJECT}/derivatives/${PIPE}/anat/native"
fi
if [[ -z ${DIR_ADD} ]]; then
  ## update with additional directories as the come online with various workflows
  if [[ -d ${DIR_PROJECT}/derivatives/${PIPE}/anat/native_qmri ]]; then
    DIR_ADD="${DIR_PROJECT}/derivatives/${PIPE}/anat/native_qmri"
  fi
fi
DIR_ADD=(${DIR_ADD//,/ })
if [[ -z ${DIR_MASK} ]]; then
  DIR_MASK=${DIR_PROJECT}/derivatives/${PIPE}/anat/mask
fi
if [[ -z ${DIR_LABEL} ]]; then
  DIR_LABEL=${DIR_PROJECT}/derivatives/${PIPE}/anat/label
fi
if [[ -z ${DIR_POSTERIOR} ]]; then
  DIR_POSTERIOR=${DIR_PROJECT}/derivatives/${PIPE}/anat/posterior
fi
if [[ -z ${DIR_XFM} ]]; then
  DIR_XFM=${DIR_PROJECT}/derivatives/${PIPE}/xfm/${IDDIR}
fi
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/qc
fi
if [[ -z ${DIR_SUMMARY} ]]; then
  DIR_SUMMARY=${DIR_PROJECT}/summary
fi

mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_SAVE}

# set output files and initialize with header as needed ----------------------
HDR="${HDR},dateCalculated,processingStage,imageType,\
cjv,cnr,efc,fber,snr_frame,snr_fg,snr_brain,snr_dietrich,wm2max,fwhm_x,fwhm_y,fwhm_z,\
rpve_gm,rpve_deepgm,rpve_wm,rpve_csf"

CSV_SUMMARY=${DIR_SUMMARY}/${PI}_${PROJECT}_qc-anat_summary.csv
CSV_PX=${DIR_SAVE}/${IDPFX}_qc-anat.csv
CSV_LOG=${TKNI_LOG}/log_QCANAT.csv
if [[ ${RESET_CSV} == "true" ]]; then
  mv ${CSV_SUMMARY} ${DIR_SUMMARY}/${PI}_${PROJECT}_QC-anat_summary_dep${TIMESTAMP}.csv
  mv ${CSV_PX} ${DIR_SAVE}/${IDPFX}_qc-anat_dep${TIMESTAMP}.csv
  mv ${CSV_LOG} ${TKNI_LOG}/log_QCANAT_dep${TIMESTAMP}.csv
fi
if [[ ! -f ${CSV_SUMMARY} ]]; then echo ${HDR} > ${CSV_SUMMARY}; fi
if [[ ! -f ${CSV_PX} ]]; then echo ${HDR} > ${CSV_PX}; fi
if [[ "${NO_LOG}" == "false" ]] && [[ ! -f ${CSV_LOG} ]]; then
  echo "pi,project,id,timestamp,stage,modality,volume,metric,value" > ${CSV_LOG}
fi

# Find images -------------------------------------------------------------------
shopt -s nullglob
IMGS_RAW=($(ls ${DIR_RAW}/${IDPFX}*.nii.gz))
IMGS_NATIVE=($(ls ${DIR_NATIVE}/${IDPFX}*.nii.gz))
for (( i=0; i<${#DIR_ADD[@]}; i++ )); do
  IMGS_NATIVE+=($(ls ${DIR_ADD[${i}]}/${IDPFX}*.nii.gz))
done
shopt -u nullglob

# Copy to scratch (and push raw to native space) ---------------------------------
if [[ -z ${REF_NATIVE} ]]; then REF_NATIVE=${DIR_NATIVE}/${IDPFX}_T1w.nii.gz; fi
unset IMGS TYPES
for (( i=0; i<${#IMGS_RAW[@]}; i++ )); do
  IMG=${IMGS_RAW[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)
  if [[ ${MOD,,} == "qalas" ]]; then MOD=${MOD^^}; fi
  NV=$(niiInfo -i ${IMG} -f volumes)
  TYPES+=("raw")
  IMGS+=("${DIR_SCRATCH}/$(basename ${IMG})")
  if [[ -f ${DIR_XFM}/${IDPFX}_mod-${MOD}_from-raw_to-ACPC_xfm-rigid.mat ]]; then
    XFMSTR="-t ${DIR_XFM}/${IDPFX}_mod-${MOD}_from-raw_to-ACPC_xfm-rigid.mat"
  else
    XFMSTR="-t ${DIR_XFM}/${IDPFX}_from-${MOD}_to-native_xfm-syn.nii.gz"
    XFMSTR="${XFMSTR} -t ${DIR_XFM}/${IDPFX}_from-${MOD}_to-native_xfm-affine.mat"
  fi
  XFMFCN="antsApplyTransforms -d 3 -n Linear"
  if [[ ${NV} -gt 1 ]]; then XFMFCN="${XFMFCN} -e 3"; fi
  XFMFCN="${XFMFCN} -i ${IMG} -o ${DIR_SCRATCH}/$(basename ${IMG}) -r ${REF_NATIVE}"
  XFMFCN="${XFMFCN} -t identity ${XFMSTR}"
#  echo -e "\n\n${XFMFCN}\n\n"
  eval ${XFMFCN}
done

for (( i=0; i<${#IMGS_NATIVE[@]}; i++ )); do
  TYPES+=("clean")
  IMGS+=("${IMGS_NATIVE[${i}]}")
done

# find masks and labels ========================================================
# find/create frame masks ------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>Create frame masks as needed"; fi
for (( i=0; i<${#IMGS_RAW[@]}; i++ )); do
  IMG=${IMGS_RAW[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)
  if [[ ${MOD,,} == "qalas" ]]; then MOD=${MOD^^}; fi
  TFRAME=${DIR_MASK}/${IDPFX}_mod-${MOD}_mask-frame.nii.gz
  if [[ ! -f ${TFRAME} ]] || [[ ${REDO_FRAME} == "true" ]]; then
    unset XFMSTR
    # consider moving frame mask creation to AINIT and AMOD
    if [[ -f ${DIR_XFM}/${IDPFX}_mod-${MOD}_from-raw_to-ACPC_xfm-rigid.mat ]]; then
      XFMSTR="-t ${DIR_XFM}/${IDPFX}_mod-${MOD}_from-raw_to-ACPC_xfm-rigid.mat"
    else
      XFMSTR="-t ${DIR_XFM}/${IDPFX}_from-${MOD}_to-native_xfm-syn.nii.gz"
      XFMSTR="${XFMSTR} -t ${DIR_XFM}/${IDPFX}_from-${MOD}_to-native_xfm-affine.mat"
    fi
    3dcalc -a ${IMG}[0] -expr a -overwrite -prefix ${TFRAME}
    niimath ${TFRAME} -mul 0 -add 1 ${TFRAME} -odt char
    XFMFCN="antsApplyTransforms -d 3 -n Linear"
    XFMFCN="${XFMFCN} -i ${TFRAME} -o ${TFRAME}.nii.gz -r ${REF_NATIVE}"
    XFMFCN="${XFMFCN} -t identity ${XFMSTR}"
#    echo -e "\n\n${XFMFCN}\n\n"
    eval ${XFMFCN}
  fi
done

if [[ -z ${MASK_FG} ]]; then MASK_FG=${DIR_MASK}/${IDPFX}_mask-fg.nii.gz; fi
if [[ ! -f ${MASK_FG} ]]; then
  3dAutomask -prefix ${MASK_FG} -clfrac 0.25 ${REF_NATIVE}
fi
if [[ -z ${MASK_BRAIN} ]]; then MASK_BRAIN=${DIR_MASK}/${IDPFX}_mask-brain.nii.gz; fi
if [[ -z ${LABEL_TISSUE} ]]; then LABEL_TISSUE=${DIR_LABEL}/${IDPFX}_label-tissue.nii.gz; fi
if [[ -z ${MASK_WM} ]]; then MASK_WM=${DIR_MASK}/${IDPFX}_mask-wm.nii.gz; fi
if [[ ! -f ${MASK_WM} ]]; then
  niimath ${LABEL_TISSUE} -thr ${LAB_WM} -uthr ${LAB_WM} -bin ${MASK_WM} -odt char
fi
if [[ -z ${POSTERIOR_TISSUE} ]]; then
  POSTERIOR_TISSUE=${DIR_POSTERIOR}/${IDPFX}_posterior-tissue.nii.gz
fi

# CALCULATE METRICS ===============================================================
NIMG=${#IMGS[@]}
for (( i=0; i<${NIMG}; i++ )); do
  IMG=${IMGS[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)
  if [[ ${MOD,,} == "qalas" ]]; then MOD=${MOD^^}; fi
  NV=$(niiInfo -i ${IMG} -f volumes)
  
  FMOD=${MOD}
  if [[ ${MOD} == "PD" ]] \
  || [[ ${MOD} == "T1map" ]] \
  || [[ ${MOD} == "T2map" ]]; then
    FMOD="QALAS"
  fi
  FRAME=${DIR_MASK}/${IDPFX}_mod-${FMOD}_mask-frame.nii.gz
  if [[ ! -f ${FRAME} ]]; then
    echo -e "\n\n\npseudo frame for ${IMG}\n\n\n"
    FRAME=${DIR_SCRATCH}/FRAME.nii.gz
    3dcalc -a ${IMG}[0] -expr a -overwrite -prefix ${FRAME}
    niimath ${FRAME} -mul 0 -add 1 -bin ${FRAME} -odt char
  fi
 
  if [[ ${VERBOSE} == "true" ]]; then
    echo -e "\n>>>Calculating QC Metrics: ------"
    echo -e "\tIMAGE: ${IMG}"
    echo -e "\tFRAME: ${DIR_MASK}/${IDPFX}_mod-${MOD}_mask-frame.nii.gz\n"
  fi
  
  unset CJV CNR EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX FWHM
  CJV=($(qc_cjv --image ${IMG} --tissue ${LABEL_TISSUE} \
	        --label "${LAB_GM},${LAB_WM}" --add-mean))
  CNR=($(qc_cnr --image ${IMG} --fg ${MASK_FG} --tissue ${LABEL_TISSUE} \
	        --label "${LAB_GM},${LAB_WM}" --add-mean))
  EFC=($(qc_efc --image ${IMG} --frame ${FRAME} --add-mean))
  FBER=($(qc_fber --image ${IMG} --mask ${MASK_FG} --add-mean))
  SNR_FRAME=($(qc_snr --image ${IMG} --mask ${FRAME} --add-mean))
  SNR_FG=($(qc_snr --image ${IMG} --mask ${MASK_FG} --add-mean))
  SNR_BRAIN=($(qc_snr --image ${IMG} --mask ${MASK_BRAIN} --add-mean))
  SNR_D=($(qc_snrd --image ${IMG} --frame ${FRAME} --fg ${MASK_FG} --add-mean))
  WM2MAX=($(qc_wm2max --image ${IMG} --mask ${MASK_WM} --add-mean))
  FWHM=($(qc_fwhm --image ${IMG} --mask ${MASK_FG}))
  PIESNO=($(qc_piesnoish --image ${IMG} --mask ${MASK_BRAIN} --add-mean))

  unset M SD MED MAD SKEW KURT P05 P95
  M_M=0; M_SD=0; M_MED=0; M_MAD=0; M_SKEW=0; M_KURT=0; M_P05=0; M_P95=0;
  for (( j=0; j<${NV}; j++ )); do
    TV=($(Rscript ${TKNIPATH}/R/qc_descriptives.R \
            "image" ${IMG} "mask" ${MASK_BRAIN} "volume" $((${j}+1))))
    M+=(${TV[0]})
    SD+=(${TV[1]})
    MED+=(${TV[2]})
    MAD+=(${TV[3]})
    SKEW+=(${TV[4]})
    KURT+=(${TV[5]})
    P05+=(${TV[6]})
    P95+=(${TV[7]})
    M_M=$(echo "scale=6; ${M_M} + ${M[-1]} / ${NV}" | bc -l)
    M_SD=$(echo "scale=6; ${M_SD} + ${SD[-1]} / ${NV}" | bc -l)
    M_MED=$(echo "scale=6; ${M_MED} + ${MED[-1]} / ${NV}" | bc -l)
    M_MAD=$(echo "scale=6; ${M_MAD} + ${MAD[-1]} / ${NV}" | bc -l)
    M_SKEW=$(echo "scale=6; ${M_SKEW} + ${SKEW[-1]} / ${NV}" | bc -l)
    M_KURT=$(echo "scale=6; ${M_KURT} + ${KURT[-1]} / ${NV}" | bc -l)
    M_P05=$(echo "scale=6; ${M_P05} + ${P05[-1]} / ${NV}" | bc -l)
    M_P95=$(echo "scale=6; ${M_P95} + ${P95[-1]} / ${NV}" | bc -l)
  done

  OSTR="${CJV[-1]},${CNR[-1]},${EFC[-1]},${FBER[-1]},\
${SNR_FRAME[-1]},${SNR_FG[-1]},${SNR_BRAIN[-1]},${SNR_D[-1]},\
${WM2MAX[-1]},${FWHM[0]},${FWHM[1]},${FWHM[2]},${PIESNO[-1]},\
${M_M},${M_SD},${M_MED},${M_MAD},${M_SKEW},${M_KURT},${M_P05},${M_P95},\
NA,NA,NA,NA"
  echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${MOD},${OSTR}" >> ${CSV_SUMMARY}
  echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${MOD},${OSTR}" >> ${CSV_PX}
  
  if [[ "${NO_LOG}" == "false" ]]; then
    OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},${TYPES[${i}]},${MOD}"
    for (( j=0; j<${NV}; j++ )); do
      echo "${OPFX},${j},cjv,${CJV[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},cnr,${CNR[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},efc,${EFC[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},fber,${FBER[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_frame,${SNR_FRAME[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_fg,${SNR_FG[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_brain,${SNR_BRAIN[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_dietrich,${SNR_D[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},wm2max,${WM2MAX[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},piesno,${PIESNO[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},mean,${M[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},sigma,${SD[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},median,${MED[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},mad,${MAD[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},skew,${SKEW[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},kurtosis,${KURT[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},p05,${P05[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},p95,${P95[${j}]}" >> ${CSV_LOG}
    done
    echo "${OPFX},NA,fwhm_x,${FWHM[0]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fwhm_y,${FWHM[1]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fwhm_z,${FWHM[2]}" >> ${CSV_LOG}
    echo "${OPFX},mean,cjv,${CJV[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,cnr,${CNR[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,efc,${EFC[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,fber,${FBER[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,wm2max,${WM2MAX[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,piesno,${PIESNO[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,mean,${M_M}" >> ${CSV_LOG}
    echo "${OPFX},mean,sigma,${M_SD}" >> ${CSV_LOG}
    echo "${OPFX},mean,median,${M_MED}" >> ${CSV_LOG}
    echo "${OPFX},mean,mad,${M_MAD}" >> ${CSV_LOG}
    echo "${OPFX},mean,skew,${M_SKEW}" >> ${CSV_LOG}
    echo "${OPFX},mean,kurtosis,${M_KURT}" >> ${CSV_LOG}
    echo "${OPFX},mean,p05,${M_P05}" >> ${CSV_LOG}
    echo "${OPFX},mean,p95,${M_P95}" >> ${CSV_LOG}
  fi
done

if [[ ${VERBOSE} == "true" ]]; then echo ">>>calculating RPVE"; fi
RPVE=($(qc_rpve --posterior ${POSTERIOR_TISSUE}))
OSTR="NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,\
${RPVE[0]},${RPVE[1]},${RPVE[2]},${RPVE[3]}"
echo "${IDSTR},${TIMESTAMP},NA,NA,${OSTR}" >> ${CSV_SUMMARY}
echo "${IDSTR},${TIMESTAMP},NA,NA,${OSTR}" >> ${CSV_PX}
if [[ "${NO_LOG}" == "false" ]]; then
  OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},NA,NA"
  echo "${OPFX},NA,rpve_gm,${RPVE[0]}" >> ${CSV_LOG}
  echo "${OPFX},NA,rpve_deepgm,${RPVE[1]}" >> ${CSV_LOG}
  echo "${OPFX},NA,rpve_wm,${RPVE[2]}" >> ${CSV_LOG}
  echo "${OPFX},NA,rpve_csf,${RPVE[3]}" >> ${CSV_LOG}
fi

if [[ ${VERBOSE} == "true" ]]; then echo "[${PIPE}${FLOW}] MESSAGE: workflow complete."; fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
