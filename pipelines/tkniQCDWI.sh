#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      QCDWI
# DESCRIPTION:   Generate a quality control report for a participant after
#                processing pipelines are finished for diffusion images.
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
dir-raw:,dir-clean:,dir-scalar:,dir-mask:,dir-label:,dir-xfm:,\
mask-fg:,mask-brain:,mask-wm:,mask-cc:,\
redo-frame,reset-csv,\
dir-scratch:,requires:,\
help,verbose,force -n 'parse-options' -- "$@")
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
DIR_CLEAN=
DIR_SCALAR=
DIR_MASK=
DIR_XFM=
DIR_POST=

MASK_FG=
MASK_BRAIN=
MASK_WM=
MASK_CC=

#METRICS="cjv,cnr,efc,fber,fwhm,snr_frame,snr_fg,snr_brain,snr_dietrich,wm2max"
# disabling option to select metrics, will require rework of output generation to implement
ADD_MEAN="true"
VOLUME="all"
REF_NATIVE=

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
REDO_FRAME="false"

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
    --dir-raw) DIR_RAW="$2" ; shift 2 ;;
    --dir-clean) DIR_CLEAN="$2" ; shift 2 ;;
    --dir-scalar) DIR_SCALAR="$2" ; shift 2 ;;
    --dir-mask) DIR_MASK="$2" ; shift 2 ;;
    --dir-label) DIR_LABEL="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
    --mask-fg) MASK_FG="$2" ; shift 2 ;;
    --mask-brain) MASK_BRAIN="$2" ; shift 2 ;;
    --mask-wm) MASK_WM="$2" ; shift 2 ;;
    --mask-cc) MASK_CC="$2" ; shift 2 ;;
    --redo-frame) REDO_FRAME="true" ; shift ;;
    --reset-csv) RESET_CSV="true" ; shift ;;
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
  DIR_RAW="${DIR_PROJECT}/rawdata/${IDDIR}/dwi"
fi
if [[ -z ${DIR_CLEAN} ]]; then
  DIR_CLEAN="${DIR_PROJECT}/derivatives/${PIPE}/dwi/preproc/dwi"
fi
if [[ -z ${DIR_SCALAR} ]]; then
  DIR_SCALAR="${DIR_PROJECT}/derivatives/${PIPE}/dwi/scalar_native"
fi

if [[ -z ${DIR_MASK} ]]; then
  DIR_MASK=${DIR_PROJECT}/derivatives/${PIPE}/anat/mask
fi
if [[ -z ${DIR_LABEL} ]]; then
  DIR_LABEL=${DIR_PROJECT}/derivatives/${PIPE}/anat/label
fi
if [[ -z ${DIR_XFM} ]]; then
  DIR_XFM=${DIR_PROJECT}/derivatives/${PIPE}/xfm/${IDDIR}
fi
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/dwi/qc
fi
if [[ -z ${DIR_SUMMARY} ]]; then
  DIR_SUMMARY=${DIR_PROJECT}/summary
fi

mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_SAVE}

# set output files and initialize with header as needed ----------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>initialize CSV output files"; fi
HDR="${HDR},dateCalculated,processingStage,imageType,bvalue\
efc,fber,snr_frame,snr_fg,snr_brain,snr_cc,snr_dietrich,fwhm_x,fwhm_y,fwhm_z,piesno"

CSV_SUMMARY=${DIR_SUMMARY}/${PI}_${PROJECT}_qc-dwi_summary.csv
CSV_PX=${DIR_SAVE}/${IDPFX}_qc-dwi.csv
CSV_LOG=${TKNI_LOG}/log_QCDWI.csv
if [[ ${RESET_CSV} == "true" ]]; then
  mv ${CSV_SUMMARY} ${DIR_SUMMARY}/${PI}_${PROJECT}_qc-dwi_summary_dep${TIMESTAMP}.csv
  mv ${CSV_PX} ${DIR_SAVE}/${IDPFX}_qc-dwi_dep${TIMESTAMP}.csv
  mv ${CSV_LOG} ${TKNI_LOG}/log_QCDWI_dep${TIMESTAMP}.csv
fi
if [[ ! -f ${CSV_SUMMARY} ]]; then echo ${HDR} > ${CSV_SUMMARY}; fi
if [[ ! -f ${CSV_PX} ]]; then echo ${HDR} > ${CSV_PX}; fi
if [[ "${NO_LOG}" == "false" ]] && [[ ! -f ${CSV_LOG} ]]; then
  echo "pi,project,id,timestamp,stage,modality,bvalue,metric,value" > ${CSV_LOG}
fi

# Find images -------------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>locate DWI images for QC metrics"; fi
shopt -s nullglob
IMGS_RAW=($(ls ${DIR_RAW}/${IDPFX}*dwi.nii.gz))
IMGS_CLEAN=($(ls ${DIR_CLEAN}/${IDPFX}*dwi.nii.gz))
shopt -u nullglob

if [[ ${#IMGS_RAW[@]} -eq 0 ]] && [[ ${#IMGS_CLEAN[@]} -eq 0 ]]; then
  echo "[${PIPE}${FLOW}] WARNING: No DWI images were found, aborting."
  exit 0
fi

# Copy to scratch (and push raw to native space) ---------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo ">>>push raw images to native space"; fi
if [[ -z ${REF_NATIVE} ]]; then
 REF_NATIVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/native/dwi/${IDPFX}_space-dwi_T1w.nii.gz
fi
unset IMGS TYPES
for (( i=0; i<${#IMGS_RAW[@]}; i++ )); do
  IMG=${IMGS_RAW[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)
  NV=$(niiInfo -i ${IMG} -f volumes)
  TYPES+=("raw")
  IMGS+=("${DIR_SCRATCH}/${PFX}_${MOD}.nii.gz")
  
  XFMFCN="antsApplyTransforms -d 3 -n Linear"
  if [[ ${NV} -gt 1 ]]; then XFMFCN="${XFMFCN} -e 3"; fi
  XFMFCN="${XFMFCN} -i ${IMG} -o ${DIR_SCRATCH}/${PFX}_${MOD}.nii.gz -r ${REF_NATIVE}"
  XFMFCN="${XFMFCN} -t identity"
  XFMFCN="${XFMFCN} -t [${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-affine.mat,1]"
  XFMFCN="${XFMFCN} -t ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-syn+inverse.nii.gz"
  eval ${XFMFCN}
done

for (( i=0; i<${#IMGS_CLEAN[@]}; i++ )); do
  TYPES+=("clean")
  IMGS+=("${IMGS_CLEAN[${i}]}")
done

# find masks and labels ========================================================
if [[ ${VERBOSE} == "true" ]]; then echo ">>>find/create masks"; fi
# find/create frame mask ------
if [[ -z ${MASK_FRAME} ]]; then
  MASK_FRAME=${DIR_MASK}/${IDPFX}_mod-dwi_mask-frame.nii.gz
fi
if [[ ! -f ${MASK_FRAME} ]]; then
  # consider moving frame mask creation to DPREP, create from B0
  3dcalc -a ${IMGS_RAW[0]}[0] -expr a -overwrite -prefix ${MASK_FRAME}
  niimath ${MASK_FRAME} -mul 0 -add 1 ${MASK_FRAME} -odt char
  antsApplyTransforms -d 3 -n Linear \
    -i ${MASK_FRAME} -o ${MASK_FRAME} -r ${REF_NATIVE} \
    -t identity \
    -t [${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-affine.mat,1] \
    -t ${DIR_XFM}/${IDPFX}_from-dwi_to-native_xfm-syn+inverse.nii.gz
fi

## push anatomical masks to dwi space
if [[ ${VERBOSE} == "true" ]]; then echo ">>>push anatomical masks to dwi spacing"; fi
if [[ -z ${MASK_FG} ]]; then MASK_FG=${DIR_MASK}/${IDPFX}_mask-fg.nii.gz; fi
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${MASK_FG} -o ${DIR_SCRATCH}/${IDPFX}_mask-fg.nii.gz -r ${REF_NATIVE}
MASK_FG=${DIR_SCRATCH}/${IDPFX}_mask-fg.nii.gz

if [[ -z ${MASK_BRAIN} ]]; then MASK_BRAIN=${DIR_MASK}/${IDPFX}_mask-brain.nii.gz; fi
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${MASK_BRAIN} -o ${DIR_SCRATCH}/${IDPFX}_mask-brain.nii.gz -r ${REF_NATIVE}
MASK_BRAIN=${DIR_SCRATCH}/${IDPFX}_mask-brain.nii.gz

if [[ -z ${MASK_CC} ]]; then
  MASK_CC=${DIR_MASK}/${IDPFX}_mask-cc.nii.gz
  if [[ ! -f ${MASK_CC} ]]; then
    if [[ -f ${DIR_LABEL}/MALF/${IDPFX}_label-wmparc+MALF.nii.gz ]]; then
      niimath ${DIR_LABEL}/MALF/${IDPFX}_label-wmparc+MALF.nii.gz \
        -thr 251 -uthr 255 -bin ${MASK_CC} -odt char
    else
      echo -e "[${PIPE}${FLOW}] ERROR: cannot automatically create CC mask."
      exit 3
    fi
  fi
fi
antsApplyTransforms -d 3 -n GenericLabel \
  -i ${MASK_CC} -o ${DIR_SCRATCH}/${IDPFX}_mask-cc.nii.gz -r ${REF_NATIVE}
MASK_CC=${DIR_SCRATCH}/${IDPFX}_mask-cc.nii.gz

# CALCULATE METRICS ===============================================================
if [[ ${VERBOSE} == "true" ]]; then echo ">>>calculate metrics"; fi
NIMG=${#IMGS[@]}
for (( i=0; i<${NIMG}; i++ )); do
  if [[ ${VERBOSE} == "true" ]]; then echo ">>>image ${i} of ${NIMG}"; fi
  IMG=${IMGS[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  MOD=$(getField -i ${IMG} -f modality)
  NV=$(niiInfo -i ${IMG} -f volumes)
  FRAME=${DIR_MASK}/${IDPFX}_mod-${MOD}_mask-frame.nii.gz
  if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>processing: ${IMG}"; fi
  # split into shells ------
  if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>>>>splitting by bvalues"; fi
  BNAME=$(getBidsBase -i ${IMG})
  TDIR=$(dirname ${IMG})
  if [[ ${TDIR} == ${DIR_SCRATCH} ]]; then TDIR=${DIR_RAW}; fi
  BVAL=($(cat ${TDIR}/${BNAME}.bval))
  unset BLS
  for (( j=0; j<${#BVAL[@]}; j++ )); do
    TB=$(printf "%.0f" ${BVAL[${j}]})
    if [[ " ${BLS[*]} " != " ${TB} " ]]; then BLS+=(${TB}); fi
    shopt -s nullglob
    TLS=($(ls ${DIR_SCRATCH}/DWI_B${TB}_*.nii.gz))
    shopt -u nullglob
    3dcalc -a ${IMG}[${j}] -expr a -overwrite \
      -prefix ${DIR_SCRATCH}/DWI_B${TB}_${#TLS[@]}.nii.gz
  done

  # loop over shells for metrics
  for (( j=0; j<${#BLS[@]}; j++ )); do
    TB=${BLS[${j}]}
    if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>>>>analyzing bvalue ${TB}"; fi
    3dTcat -overwrite -prefix ${DIR_SCRATCH}/DWI_B${TB}.nii.gz \
      $(ls ${DIR_SCRATCH}/DWI_B${TB}_*.nii.gz)
    TIMG=${DIR_SCRATCH}/DWI_B${TB}.nii.gz

    unset EFC FBER SNR_FRAME SNR_FG SNR_BRAIN SNR_CC SNR_D PIESNO
    EFC=($(qc_efc --image ${TIMG} --add-mean))
    FBER=($(qc_fber --image ${TIMG} --mask ${MASK_FG} --add-mean))
    SNR_FRAME=($(qc_snr --image ${TIMG} --add-mean))
    SNR_FG=($(qc_snr --image ${TIMG} --mask ${MASK_FG} --add-mean))
    SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${MASK_BRAIN} --add-mean))
    SNR_CC=($(qc_snr --image ${TIMG} --mask ${MASK_CC} --add-mean))
    SNR_D=($(qc_snrd --image ${TIMG} --fg ${MASK_FG} --add-mean))
    FWHM=($(qc_fwhm --image ${TIMG} --mask ${MASK_BRAIN}))
    PIESNO=($(qc_piesnoish --image ${TIMG} --mask ${MASK_BRAIN} --add-mean))

    OSTR="${EFC[-1]},${FBER[-1]},${SNR_FRAME[-1]},${SNR_FG[-1]},${SNR_BRAIN[-1]},\
${SNR_CC[-1]},${SNR_D[-1]},${FWHM[0]},${FWHM[1]},${FWHM[2]},${PIESNO[-1]},NA,NA,NA"
    echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${MOD},${TB},${OSTR}" >> ${CSV_SUMMARY}
    echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${MOD},${TB},${OSTR}" >> ${CSV_PX}
    if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>>>>QC metrics written"; fi
  
    if [[ "${NO_LOG}" == "false" ]]; then
      OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},${TYPES[${i}]},${MOD},${TB}"
      for (( j=0; j<${NV}; j++ )); do
        echo "${OPFX},${j},efc,${EFC[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},fber,${FBER[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},snr_frame,${SNR_FRAME[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},snr_fg,${SNR_FG[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},snr_brain,${SNR_BRAIN[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},snr_cc,${SNR_BRAIN[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},snr_dietrich,${SNR_D[${j}]}" >> ${CSV_LOG}
        echo "${OPFX},${j},piesno,${PIESNO[${j}]}" >> ${CSV_LOG}
      done
      echo "${OPFX},NA,fwhm_x,${FWHM[0]}" >> ${CSV_LOG}
      echo "${OPFX},NA,fwhm_y,${FWHM[1]}" >> ${CSV_LOG}
      echo "${OPFX},NA,fwhm_z,${FWHM[2]}" >> ${CSV_LOG}
      echo "${OPFX},mean,efc,${EFC[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,fber,${FBER[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,snr_cc,${SNR_CC[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV_LOG}
      echo "${OPFX},mean,piesno,${PIESNO[-1]}" >> ${CSV_LOG}
      if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>>>>QC logged"; fi
    fi
  rm ${DIR_SCRATCH}/DWI_B*
  done
done

FA=${DIR_SCALAR}/${IDPFX}_space-native_scalar-fa.nii.gz
if [[ -f ${FA} ]]; then
  unset ISNAN ISDEGEN SPIKE
  if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>>processing FA metrics and spikes"; fi
  ISNAN=($(qc_isnan --image ${FA} --mask ${MASK_BRAIN}))
  ISDEGEN=($(qc_outrange --image ${FA} --mask ${MASK_BRAIN}))
  SPIKE=$(cat ${DIR_PROJECT}/derivatives/${PIPE}/dwi/preproc/qc/${IDPFX}_pctOutliers.txt)
  OSTR="NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,${ISNAN[-1]},${ISDEGEN[-1]},${SPIKE}"
  echo "${IDSTR},${TIMESTAMP},NA,fa,NA,${OSTR}" >> ${CSV_SUMMARY}
  echo "${IDSTR},${TIMESTAMP},NA,fa,NA,${OSTR}" >> ${CSV_PX}
  if [[ "${NO_LOG}" == "false" ]]; then
    OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},NA,fa,NA"
    echo "${OPFX},pct,isnan,${ISNAN}" >> ${CSV_LOG}
    echo "${OPFX},pct,isdegen,${ISDEGEN}" >> ${CSV_LOG}
    echo "${OPFX},pct,spike_slice,${SPIKE}" >> ${CSV_LOG}
  fi
else
  if [[ ${VERBOSE} == "true" ]]; then echo ">>>>>> FA NOT FOUND"; fi
fi

# set status file --------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "[${PIPE}${FLOW}] MESSAGE: workflow complete."; fi
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0

