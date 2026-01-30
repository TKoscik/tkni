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
mask-brain:,ref-native:,redo-frame,\
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
FORCE=false

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    -n | --no-png) NO_PNG=true ; shift ;;
    -r | --no-rmd) NO_RMD=true ; shift ;;
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
    --ref-native) REF_NATIVE="$2" ; shift 2 ;;
    --redo-frame) REDO_FRAME="true" ; shift ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
    --reset-csv) RESET_CSV="true" ; shift ;;
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
HDR=${IDVARS}
IDVARS=(${IDVARS//,/ })
IDSTR=""
for i in "${IDVARS[@]}"; do IDSTR="${IDSTR},$(getField -i ${IDPFX} -f ${i})"; done
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
  DIR_SAVE=${DIR_PROJECT}/derivatives/${PIPE}/anat/qc
fi
if [[ -z ${DIR_SUMMARY} ]]; then
  DIR_SUMMARY=${DIR_PROJECT}/summary
fi

mkdir -p ${DIR_SCRATCH}
mkdir -p ${DIR_SAVE}

# set output files and initialize with header as needed ----------------------
HDR="${HDR},dateCalculated,processingStage,imageType,task,\
efc,fber,snr_frame,snr_brain,snr_dietrich,ghostr_x,ghostr_y,ghostr_z,fwhm_x,fwhm_y,fwhm_z,\
dvars_mean,dvars_sigma,fd_mean,fd_sigma,spike_pct"

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
  echo "pi,project,id,timestamp,stage,task,volume,metric,value" > ${TKNI_LOG}/log_QCANAT.csv
fi

# Find images and regressors ------------------------------------------------------
shopt -s nullglob
IMGS_RAW=($(ls ${DIR_RAW}/${IDPFX}*bold.nii.gz))
IMGS_CLEAN=($(ls ${DIR_CLEAN}/${IDPFX}*bold.nii.gz))
IMGS_RESIDUAL=($(ls ${DIR_RESIDUAL}/${IDPFX}*residual.nii.gz))
RGRS_RMS=($(ls ${DIR_REGRESSOR}/${IDPFX}*displacement+RMS.1D))
RGRS_FD=($(ls ${DIR_REGRESSOR}/${IDPFX}*displacement+framewise.1D))
RGRS_SPIKE=($(ls ${DIR_REGRESSOR}/${IDPFX}*spike.1D))
shopt -u nullglob

# Copy to scratch (and push raw to native space) ---------------------------------
#if [[ -z ${REF_IMG} ]]; then REF_IMG=${DIR_MEAN}/derivatives/${PIPE}/func/mask/; fi
unset IMGS TYPES
for (( i=0; i<${#IMGS_RAW[@]}; i++ )); do
  IMG=${IMGS_RAW[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  #TASK=${PFX//${IDPFX}}

  TYPES+=("raw")
  IMGS+=("${DIR_SCRATCH}/${PFX}_bold.nii.gz")
  
  REF=${DIR_MEAN}/${PFX}_proc-mean_bold.nii.gz
  XAFFINE=${DIR_XFM}/${PFX}_mod-bold_from-raw_to-native_xfm-affine.mat
  XSYN=${DIR_XFM}/${PFX}_mod-bold_from-raw_to-native_xfm-syn.nii.gz
  antsApplyTransforms -d 3 -e 3-n Linear \
    -i ${IMG} -o ${DIR_SCRATCH}/${PFX}_bold.nii.gz -r ${REF} \
    -t identity -t ${XSYN} -t ${XAFFINE}
  
  # make frame masks
  FRAME=${DIR_MASK}/${PFX}_mask-frame.nii.gz
  if [[ ! -f ${FRAME} ]]; then
    3dcalc -a ${IMG}[0] -expr a -overwrite -prefix ${FRAME}
    niimath ${FRAME} -mul 0 -add 1 ${FRAME} -odt char
    antsApplyTransforms -d 3 -n GenericLabel \
      -i ${FRAME} -o ${FRAME} -r ${REF} \
      -t identity -t ${XSYN} -t ${XAFFINE}
  fi
done

for (( i=0; i<${#IMGS_CLEAN[@]}; i++ )); do
  TYPES+=("clean")
  IMGS+=("${IMGS_CLEAN[${i}]}")
done
for (( i=0; i<${#IMGS_RESIDUAL[@]}; i++ )); do
  TYPES+=("residual")
  IMGS+=("${IMGS_RESIDUAL[${i}]}")
done

# CALCULATE METRICS ===============================================================
NIMG=${#IMGS[@]}
for (( i=0; i<${NIMG}; i++ )); do
  IMG=${IMGS[${i}]}
  PFX=$(getBidsBase -i ${IMG} -s)
  TASK=${PFX//${IDPFX}}
  
  MASK_FRAME=${DIR_MASK}/${PFX}_mask-frame.nii.gz
  shopt -s nullglob
  MASK_BRAIN=($(ls ${DIR_MASK}/${PFX}*mask-brain.nii.gz))
  shopt -u nullglob
  if [[ ${#MASK_BRAIN[@]} -eq 0 ]]; then
    echo "mask: not found ${DIR_MASK}/${PFX}_mask-brain.nii.gz"
    exit 4
  fi
 
  unset EFC FBER SNR_FRAME SNR_FG SNR_BRAIN SNR_D FWHM
  EFC=($(qc_efc --image ${IMG} --frame ${FRAME} --add-mean))
  FBER=($(qc_fber --image ${IMG} --mask ${MASK_FG} --add-mean))
  SNR_FRAME=($(qc_snr --image ${IMG} --mask ${FRAME} --add-mean))
  SNR_BRAIN=($(qc_snr --image ${IMG} --mask ${MASK_BRAIN} --add-mean))
  SNR_D=($(qc_snrd --image ${IMG} --frame ${FRAME} --fg ${MASK_BRAIN} --add-mean))
  GHOST_X=($(qc_ghostr --image ${IMG} --mask ${MASK_BRAIN} --plane x --add-mean))
  GHOST_Y=($(qc_ghostr --image ${IMG} --mask ${MASK_BRAIN} --plane y --add-mean))
  GHOST_Z=($(qc_ghostr --image ${IMG} --mask ${MASK_BRAIN} --plane z --add-mean))
  FWHM=($(qc_fwhm --image ${IMG} --mask ${MASK_BRAIN}))
  
  OSTR="${EFC[-1]},${FBER[-1]},${SNR_FRAME[-1]},${SNR_BRAIN[-1]},${SNR_D[-1]},\
${GHOST_X[-1]},${GHOST_Y[-1]},${GHOST_Z[-1]},${FWHM[0]},${FWHM[1]},${FWHM[2]},NA,NA,NA,NA,NA"
  echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${TASK},${OSTR}" | tee -a ${CSV_PROJECT} ${CSV_PX}
  
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
    echo "${OPFX},mean,efc,${EFC[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,fber,${FBER[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,ghost_x,${GHOST_X[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,ghost_y,${GHOST_Y[-1]}" >> ${CSV_LOG}
    echo "${OPFX},mean,ghost_z,${GHOST_Z[-1]}" >> ${CSV_LOG}
  fi
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
  SPIKE_PCT=$(echo "scale=${PRECISION}; ${RSPIKE_STATS[-2]} / ${RSPIKE_STATS[-1]}" | bc -l)
  OSTR="NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,NA,\
${RMS_STATS[-2]},${RMS_STATS[-1]},${RFD_STATS[-2]},${RFD_STATS[-1]},${SPIKE_PCT}"
  echo "${IDSTR},${TIMESTAMP},${TYPES[${i}]},${TASK},${OSTR}" | tee -a ${CSV_PROJECT} ${CSV_PX}

  if [[ "${NO_LOG}" == "false" ]]; then
    OPFX="${PI},${PROJECT},${IDPFX},${TIMESTAMP},${TYPES[${i}]},${TASK}"
    echo "${OPFX},NA,dvars_mean,${RMS_STATS[-2]}" >> ${CSV_LOG}
    echo "${OPFX},NA,dvars_sigma,${RMS_STATS[-1]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fd_mean,${RFD_STATS[-2]}" >> ${CSV_LOG}
    echo "${OPFX},NA,fd_sigma,${RFD_STATS[-1]}" >> ${CSV_LOG}
    echo "${OPFX},NA,spike_pct,${SPIKE_PCT}" >> ${CSV_LOG}
  fi
done

# set status file --------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "[${PIPE}${FLOW}] MESSAGE: workflow complete."; fi
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
