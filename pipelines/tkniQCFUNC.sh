#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      QCFUNC
# DESCRIPTION:   Generate a quality control report for a participant after
#                processing pipelines are finished for functional images.
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
dir-raw:,dir-clean:,dir-residual:,dir-regressor:,dir-mask:,dir-mean:,dir-xfm:,\
mask-brain:,redo-frame,\
dir-save:,dir-scratch:,requires:,\
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
DIR_CLEAN=
DIR_RESIDUAL=
DIR_REGRESSOR=
DIR_MASK=
DIR_MEAN=
DIR_XFM=

MASK_BRAIN=

VOLUME="all"

HELP="false"
VERBOSE="false"
NO_PNG="false"
NO_RMD="false"
NO_SUMMARY="false"
NO_RAW="false"
NO_LOG="false"

PIPE=tkni
FLOW=${FCN_NAME//tkni}
FLOW=${FCN_NAME//\.sh}
REQUIRES=""
FORCE=false

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
    --dir-clean) DIR_CLEAN="$2" ; shift 2 ;;
    --dir-residual) DIR_RESIDUAL="$2" ; shift 2 ;;
    --dir-regressor) DIR_REGRESSOR="$2" ; shift 2 ;;
    --dir-mask) DIR_MASK="$2" ; shift 2 ;;
    --dir-mean) DIR_MEAN="$2" ; shift 2 ;;
    --dir-xfm) DIR_XFM="$2" ; shift 2 ;;
    --mask-brain) MASK_BRAIN="$2" ; shift 2 ;;
    --redo-frame) REDO_FRAME="true" ; shift ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --force) FORCE="true" ; shift ;;
    --requires) REQUIRES="$2" ; shift 2 ;;
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
  DIR_RAW="${DIR_PROJECT}/rawdata/${IDDIR}/func"
fi
if [[ -z ${DIR_CLEAN} ]]; then
  DIR_CLEAN="${DIR_PROJECT}/derivatives/${PIPE}/func/clean"
fi
if [[ -z ${DIR_RESIDUAL} ]]; then
  DIR_RESIDUAL="${DIR_PROJECT}/derivatives/${PIPE}/func/residual_native"
fi
if [[ -z ${DIR_REGRESSOR} ]]; then
  DIR_REGRESSOR="${DIR_PROJECT}/derivatives/${PIPE}/func/regressor/${IDDIR}"
fi
if [[ -z ${DIR_MASK} ]]; then
  DIR_MASK=${DIR_PROJECT}/derivatives/${PIPE}/func/mask
fi
if [[ -z ${DIR_MEAN} ]]; then
  DIR_MEAN=${DIR_PROJECT}/derivatives/${PIPE}/func/mean
fi
if [[ -z ${DIR_XFM} ]]; then
  DIR_XFM=${DIR_PROJECT}/derivatives/${PIPE}/xfm/${IDDIR}
fi
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/func/qc
fi
if [[ -z ${DIR_SUMMARY} ]]; then
  DIR_SUMMARY=${DIR_PROJECT}/summary
fi

mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_SAVE}

# set output files and initialize with header as needed ----------------------
HDR="${HDR},dateCalculated,processingStage,task,\
efc,fber,snr_frame,snr_brain,snr_dietrich,ghostr_x,ghostr_y,ghostr_z,fwhm_x,fwhm_y,fwhm_z,\
dvars_mean,dvars_sigma,fd_mean,fd_sigma,spike_pct"

CSV_SUMMARY=${DIR_SUMMARY}/${PI}_${PROJECT}_qc-func_summary.csv
CSV_PX=${DIR_SAVE}/${IDPFX}_qc-func.csv
CSV_LOG=${TKNI_LOG}/log_QCFUNC.csv
if [[ ${RESET_CSV} == "true" ]]; then
  mv ${CSV_SUMMARY} ${DIR_SUMMARY}/${PI}_${PROJECT}_qc-func_summary_dep${TIMESTAMP}.csv
  mv ${CSV_PX} ${DIR_SAVE}/${IDPFX}_qc-func_dep${TIMESTAMP}.csv
  mv ${CSV_LOG} ${TKNI_LOG}/log_QCFUNC_dep${TIMESTAMP}.csv
fi
if [[ ! -f ${CSV_SUMMARY} ]]; then echo ${HDR} > ${CSV_SUMMARY}; fi
if [[ ! -f ${CSV_PX} ]]; then echo ${HDR} > ${CSV_PX}; fi
if [[ "${NO_LOG}" == "false" ]] && [[ ! -f ${CSV_LOG} ]]; then
  echo "pi,project,id,timestamp,stage,task,volume,metric,value" > ${CSV_LOG}
fi

# Find images and regressors ------------------------------------------------------
IMGS_RAW=($(find ${DIR_RAW} -name "${IDPFX}*bold.nii.gz" 2>/dev/null))
IMGS_CLEAN=($(find ${DIR_CLEAN} -name "${IDPFX}*bold.nii.gz" 2>/dev/null))
IMGS_RESIDUAL=($(find ${DIR_RESIDUAL} -name "${IDPFX}*residual.nii.gz" 2>/dev/null))
#RGRS_RMS=($(find ${DIR_REGRESSOR} -name "${IDPFX}*displacement+RMS.1D" 2>/dev/null))
#RGRS_FD=($(find ${DIR_REGRESSOR} -name "${IDPFX}*displacement+framewise.1D" 2>/dev/null))
#RGRS_SPIKE=($(find ${DIR_REGRESSOR} -name "${IDPFX}*spike.1D" 2>/dev/null))

if [[ ${#IMGS_RAW[@]} -eq 0 ]] && [[ ${#IMGS_CLEAN[@]} -eq 0 ]]; then
  echo "[${PIPE}${FLOW}] WARNING: No BOLD images found, aborting."
  exit 0
fi

# Copy to scratch (and push raw to native space) ---------------------------------
## resample to clean space, and convert to INT16 (short) for faster processing
#if [[ -z ${REF_IMG} ]]; then REF_IMG=${DIR_MEAN}/derivatives/${PIPE}/func/mask/; fi
unset IMGS TYPES
mkdir -p ${DIR_SCRATCH}/raw
mkdir -p ${DIR_SCRATCH}/clean
mkdir -p ${DIR_SCRATCH}/residual
for (( i=0; i<${#IMGS_RAW[@]}; i++ )); do
  ## identify inputs ------
  IMG=${IMGS_RAW[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  REF=${DIR_MEAN}/${PFX}_proc-mean_bold.nii.gz
  BRAIN=${DIR_MASK}/${PFX}_mod-bold_mask-brain.nii.gz
  FRAME=${DIR_MASK}/${PFX}_mask-frame.nii.gz
  XAFFINE=${DIR_XFM}/${PFX}_mod-bold_from-raw_to-native_xfm-affine.mat
  XSYN=${DIR_XFM}/${PFX}_mod-bold_from-raw_to-native_xfm-syn.nii.gz

  TIMG=${DIR_SCRATCH}/raw/${PFX}_bold.nii.gz
  TBRAIN=${DIR_SCRATCH}/raw/${PFX}_mask-brain.nii.gz
  TFRAME=${DIR_SCRATCH}/raw/${PFX}_mask-frame.nii.gz

  # push to native space for metric calculation with native space masks ------
  cp ${IMG} ${TIMG}
  antsApplyTransforms -d 3 -e 3 -n Linear -u short \
    -i ${TIMG} -o ${TIMG} -r ${REF} -t identity -t ${XSYN} -t ${XAFFINE}

  # copy brain mask ------
  if [[ ! -f ${BRAIN} ]]; then mri_synthstrip -i ${REF} -m ${BRAIN}; fi
  cp ${BRAIN} ${TBRAIN}
  niimath ${TBRAIN} -bin ${TBRAIN} -odt char

  # make frame masks ------
  if [[ ! -f ${FRAME} ]]; then
    3dcalc -a ${IMG}[0] -expr a -overwrite -prefix ${FRAME}
    niimath ${FRAME} -mul 0 -add 1 ${FRAME} -odt char
    antsApplyTransforms -d 3 -n GenericLabel -u char \
      -i ${FRAME} -o ${FRAME} -r ${REF} \
      -t identity -t ${XSYN} -t ${XAFFINE}
  fi
  cp ${FRAME} ${TFRAME}
  niimath ${TFRAME} -bin ${TFRAME} -odt char

  TYPES+=("raw")
  IMGS+=("${TIMG}")
done

for (( i=0; i<${#IMGS_CLEAN[@]}; i++ )); do
  IMG=${IMGS_CLEAN[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  REF=${DIR_MEAN}/${PFX}_proc-mean_bold.nii.gz
  BRAIN=${DIR_MASK}/${PFX}_mod-bold_mask-brain.nii.gz
  FRAME=${DIR_MASK}/${PFX}_mask-frame.nii.gz

  TIMG=${DIR_SCRATCH}/clean/${PFX}_bold.nii.gz
  TBRAIN=${DIR_SCRATCH}/clean/${PFX}_mask-brain.nii.gz
  TFRAME=${DIR_SCRATCH}/clean/${PFX}_mask-frame.nii.gz

  # convert to INT16 for speed ------
  cp ${IMG} ${TIMG}
  antsApplyTransforms -d 3 -e 3 -n Linear -u short -i ${TIMG} -o ${TIMG} -r ${REF}

  # copy brain mask ------
  if [[ ! -f ${BRAIN} ]]; then
    TASK=$(getField -i ${IMG} -f task)
    if [[ -f ${DIR_MASK}/${IDPFX}_task-${TASK}_mask-brain.nii.gz ]]; then
      BRAIN=${DIR_MASK}/${IDPFX}_task-${TASK}_mask-brain.nii.gz
    else
      mri_synthstrip -i ${TIMG} -m ${BRAIN}
    fi
  fi
  cp ${BRAIN} ${TBRAIN}
  niimath ${TBRAIN} -bin ${TBRAIN} -odt char

  # make frame masks ------
  if [[ ! -f ${FRAME} ]]; then
    TASK=$(getField -i ${IMG} -f task)
    AverageImages 3 ${FRAME} 0 ${DIR_MASK}/${IDPFX}*task-${TASK}*mask-frame.nii.gz
  fi
  cp ${FRAME} ${TFRAME}
  niimath ${TFRAME} -bin ${TFRAME} -odt char

  IMGS+=("${TIMG}")
  TYPES+=("clean")
done

for (( i=0; i<${#IMGS_RESIDUAL[@]}; i++ )); do
  IMG=${IMGS_RESIDUAL[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  REF=${DIR_MEAN}/${PFX}_proc-mean_bold.nii.gz
  BRAIN=${DIR_MASK}/${PFX}_mod-bold_mask-brain.nii.gz
  FRAME=${DIR_MASK}/${PFX}_mask-frame.nii.gz

  TIMG=${DIR_SCRATCH}/residual/${PFX}_residual.nii.gz
  TBRAIN=${DIR_SCRATCH}/residual/${PFX}_mask-brain.nii.gz
  TFRAME=${DIR_SCRATCH}/residual/${PFX}_mask-frame.nii.gz

  # convert to INT16 for speed ------
  cp ${IMG} ${TIMG}
  antsApplyTransforms -d 3 -e 3 -n Linear -u short -i ${TIMG} -o ${TIMG} -r ${REF}

  # copy brain mask ------
  if [[ ! -f ${BRAIN} ]]; then
    TASK=$(getField -i ${IMG} -f task)
    if [[ -f ${DIR_MASK}/${IDPFX}_task-${TASK}_mask-brain.nii.gz ]]; then
      BRAIN=${DIR_MASK}/${IDPFX}_task-${TASK}_mask-brain.nii.gz
    else
      mri_synthstrip -i ${TIMG} -m ${BRAIN}
    fi
  fi
  cp ${BRAIN} ${TBRAIN}
  niimath ${TBRAIN} -bin ${TBRAIN} -odt char

  # make frame masks ------
  if [[ ! -f ${FRAME} ]]; then
    TASK=$(getField -i ${IMG} -f task)
    AverageImages 3 ${FRAME} 0 ${DIR_MASK}/${IDPFX}*task-${TASK}*mask-frame.nii.gz
  fi
  cp ${FRAME} ${TFRAME}
  niimath ${TFRAME} -bin ${TFRAME} -odt char

  IMGS+=("${TIMG}")
  TYPES+=("residual")
done

# CALCULATE METRICS ===============================================================
NIMG=${#IMGS[@]}
for (( i=0; i<${NIMG}; i++ )); do
  IMG=${IMGS[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  TASK=${PFX//${IDPFX}}
  TYPE=${TYPES[${i}]}

  MASK_FRAME=${DIR_SCRATCH}/${TYPE}/${PFX}_mask-frame.nii.gz
  MASK_BRAIN=${DIR_SCRATCH}/${TYPE}/${PFX}_mask-brain.nii.gz

  # premake ghosting masks *****
  XGHOST=${DIR_SCRATCH}/ghost_x.nii.gz
  YGHOST=${DIR_SCRATCH}/ghost_y.nii.gz
  ZGHOST=${DIR_SCRATCH}/ghost_z.nii.gz
  XNONGHOST=${DIR_SCRATCH}/nonghost_x.nii.gz
  YNONGHOST=${DIR_SCRATCH}/nonghost_y.nii.gz
  ZNONGHOST=${DIR_SCRATCH}/nonghost_z.nii.gz
  circleShift --image ${MASK_BRAIN} --plane "x" --shift "N/2" \
    --filename ghost_x --dir-save ${DIR_SCRATCH}
  circleShift --image ${MASK_BRAIN} --plane "y" --shift "N/2" \
    --filename ghost_y --dir-save ${DIR_SCRATCH}
  circleShift --image ${MASK_BRAIN} --plane "z" --shift "N/2" \
    --filename ghost_z --dir-save ${DIR_SCRATCH}
  niimath ${MASK_BRAIN} -binv -mul ${XGHOST} -bin ${XGHOST} -odt char
  niimath ${MASK_BRAIN} -binv -mul ${YGHOST} -bin ${YGHOST} -odt char
  niimath ${MASK_BRAIN} -binv -mul ${ZGHOST} -bin ${ZGHOST} -odt char
  niimath ${MASK_BRAIN} -add ${XGHOST} -binv ${XNONGHOST} -odt char
  niimath ${MASK_BRAIN} -add ${YGHOST} -binv ${YNONGHOST} -odt char
  niimath ${MASK_BRAIN} -add ${ZGHOST} -binv ${ZNONGHOST} -odt char

  # run as individual volumes to avoid having to resplit file for every volume and qc metric separately
  NV=$(niiInfo -i ${IMG} -f volumes)
  unset EFC FBER SNR_FRAME SNR_FG SNR_BRAIN SNR_D GHOST_X GHOST_Y GHOST_Z FWHM
  MEFC=0
  MFBER=0
  MSNR_FRAME=0
  MSNR_BRAIN=0
  MSNR_D=0
  MGHOST_X=0
  MGHOST_Y=0
  MGHOST_Z=0
  for (( j=0; j<${NV}; j++ )); do
    TIMG=${DIR_SCRATCH}/timg.nii.gz
    3dcalc -a ${IMG}[${j}] -expr a -overwrite -short -prefix ${TIMG}

    EFC+=($(qc_efc --image ${TIMG} --frame ${MASK_FRAME}))
    FBER+=($(qc_fber --image ${TIMG} --mask ${MASK_BRAIN}))
    SNR_FRAME+=($(qc_snr --image ${TIMG} --mask ${MASK_FRAME}))
    SNR_BRAIN+=($(qc_snr --image ${TIMG} --mask ${MASK_BRAIN}))
    SNR_D+=($(qc_snrd --image ${TIMG} --frame ${FRAME} --fg ${MASK_BRAIN} --add-mean))
    GHOST_X+=($(qc_ghostr --image ${TIMG} --mask ${MASK_BRAIN} \
      --ghost ${XGHOST} --nonghost ${XNONGHOST}))
    GHOST_Y+=($(qc_ghostr --image ${TIMG} --mask ${MASK_BRAIN} \
      --ghost ${YGHOST} --nonghost ${YNONGHOST}))
    GHOST_Z+=($(qc_ghostr --image ${TIMG} --mask ${MASK_BRAIN} \
      --ghost ${ZGHOST} --nonghost ${ZNONGHOST}))

    MEFC=$(echo "scale=6; ${MEFC} + (${EFC[-1]} / ${NV})" | bc -l)
    MFBER=$(echo "scale=6; ${MFBER} + (${FBER[-1]} / ${NV})" | bc -l)
    MSNR_FRAME=$(echo "scale=6; ${MSNR_FRAME} + (${SNR_FRAME[-1]} / ${NV})" | bc -l)
    MSNR_BRAIN=$(echo "scale=6; ${MSNR_BRAIN} + (${SNR_BRAIN[-1]} / ${NV})" | bc -l)
    MSNR_D=$(echo "scale=6; ${MSNR_D} + (${SNR_D[-1]} / ${NV})" | bc -l)
    MGHOST_X=$(echo "scale=6; ${MGHOST_X} + (${GHOST_X[-1]} / ${NV})" | bc -l)
    MGHOST_Y=$(echo "scale=6; ${MGHOST_Y} + (${GHOST_Y[-1]} / ${NV})" | bc -l)
    MGHOST_Z=$(echo "scale=6; ${MGHOST_Z} + (${GHOST_Z[-1]} / ${NV})" | bc -l)
  done
  FWHM=($(qc_fwhm --image ${IMG} --mask ${MASK_BRAIN}))

  OSTR="${MEFC},${MFBER},${MSNR_FRAME},${MSNR_BRAIN},${MSNR_D},\
${MGHOST_X},${MGHOST_Y},${MGHOST_Z},${FWHM[0]},${FWHM[1]},${FWHM[2]},NA,NA,NA,NA,NA"
  echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${TASK},${OSTR}" >> ${CSV_SUMMARY}
  echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${TASK},${OSTR}" >> ${CSV_PX}

  if [[ "${NO_LOG}" == "false" ]]; then
    OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},${TYPES[${i}]},${TASK}"
    for (( j=0; j<${NV}; j++ )); do
      echo "${OPFX},${j},efc,${EFC[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},fber,${FBER[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_frame,${SNR_FRAME[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_brain,${SNR_BRAIN[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},snr_dietrich,${SNR_D[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},ghost_x,${GHOST_X[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},ghost_y,${GHOST_Y[${j}]}" >> ${CSV_LOG}
      echo "${OPFX},${j},ghost_z,${GHOST_Z[${j}]}" >> ${CSV_LOG}
    done
    echo "${OPFX},NA,fwhm_x,${FWHM[0]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fwhm_y,${FWHM[1]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fwhm_z,${FWHM[2]}" >> ${CSV_LOG}
    echo "${OPFX},mean,efc,${MEFC}" >> ${CSV_LOG}
    echo "${OPFX},mean,fber,${MFBER}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_frame,${MSNR_FRAME}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_brain,${MSNR_BRAIN}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_dietrich,${MSNR_D}" >> ${CSV_LOG}
    echo "${OPFX},mean,ghost_x,${MGHOST_X}" >> ${CSV_LOG}
    echo "${OPFX},mean,ghost_y,${MGHOST_Y}" >> ${CSV_LOG}
    echo "${OPFX},mean,ghost_z,${MGHOST_Z}" >> ${CSV_LOG}
  fi
  rm ${DIR_SCRATCH}/ghost*.nii.gz
  rm ${DIR_SCRATCH}/nonghost*.nii.gz
done

for (( i=0; i<${#IMGS_RAW[@]}; i++ )); do
  IMG=${IMGS_RAW[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  TASK=${PFX//${IDPFX}}
  RMS=${DIR_REGRESSOR}/${PFX}_displacement+RMS.1D
  RFD=${DIR_REGRESSOR}/${PFX}_displacement+framewise.1D
  RSPIKE=${DIR_REGRESSOR}/${PFX}_spike.1D

  RMS_STATS=($(3dBrickStat -mean -stdev ${RMS}))
  RFD_STATS=($(3dBrickStat -mean -stdev ${RFD}))
  RSPIKE_STATS=($(3dBrickStat -sum -count ${RSPIKE}))
  SPIKE_PCT=$(echo "scale=4; ${RSPIKE_STATS[-2]} / ${RSPIKE_STATS[-1]}" | bc -l)
  OSTR="NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,\
${RMS_STATS[-2]},${RMS_STATS[-1]},${RFD_STATS[-2]},${RFD_STATS[-1]},${SPIKE_PCT}"
  echo "${IDSTR},${TIMESTAMP},NA,${TASK},${OSTR}" >> ${CSV_SUMMARY}
  echo "${IDSTR},${TIMESTAMP},NA,${TASK},${OSTR}" >> ${CSV_PX}

  if [[ "${NO_LOG}" == "false" ]]; then
    OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},NA,${TASK}"
    echo "${OPFX},NA,dvars_mean,${RMS_STATS[-2]}" >> ${CSV_LOG}
    echo "${OPFX},NA,dvars_sigma,${RMS_STATS[-1]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fd_mean,${RFD_STATS[-2]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fd_sigma,${RFD_STATS[-1]}" >> ${CSV_LOG}
    echo "${OPFX},NA,spike_pct,${SPIKE_PCT}" >> ${CSV_LOG}
  fi
done

# clean up workspace (egress functions seems to struggle with subdirectories)
#rm ${DIR_SCRATCH}/raw/*
#rm ${DIR_SCRATCH}/clean/*
#rm ${DIR_SCRATCH}/residual/*
#rmdir ${DIR_SCRATCH}/raw
#rmdir ${DIR_SCRATCH}/clean
#rmdir ${DIR_SCRATCH}/residual
#rmdir ${DIR_SCRATCH}

# set status file --------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "[${PIPE}${FLOW}] MESSAGE: workflow complete."; fi
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
