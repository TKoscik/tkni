#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      QCREPORT
# DESCRIPTION:   Generate a quality control report for a participant after
#                processing pipelines are finished.
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
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,\
id:,dir-id:,base-img:,base-mod:,\
align-manual:,align-to:,\
fg-clip:,ants-template:,\
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

TEMPLATE="HCPYAX"

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
    --id) IDPFX="$2" ; shift 2 ;;
    --dir-id) IDDIR="$2" ; shift 2 ;;
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

DSFX=$(date +%Y%m%d)
DIRTMP=${DIR_SCRATCH}
mkdir ${DIRTMP}

if [[ ${NO_SUMMARY} == "false" ]]; then
  CSV=${DIR_PROJECT}/summary/${PI}_${PROJECT}_QCSummary_${DSFX}.csv
  if [[ ! -f ${CSV} ]]; then
    echo "pid,sid,aid,summaryDate,processingStage,imageType,imageModality,imageVolume,measure,value" > ${CSV}
  fi
fi

DIRRAW=${DIR_PROJECT}/rawdata/${IDDIR}
DIRPRO=${DIR_PROJECT}/derivatives/${PIPE}

if [[ ! -d ${DIRRAW} ]]; then
  echo -e "WARNING [${PIPE}:${FLOW}] Raw directory not found, excluding from output."
  echo -e "\t${DIRRAW}"
  NO_RAW="true"
fi

# Locate Transforms ----------------------------------------------------------
XRAW=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_mod-T1w_from-raw_to-ACPC_xfm-rigid.mat
XAFF=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-native_to-${TEMPLATE}_xfm-affine.mat
XSYN=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-native_to-${TEMPLATE}_xfm-syn.nii.gz
XINV=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-native_to-${TEMPLATE}_xfm-syn+inverse.nii.gz
REF=${DIRPRO}/anat/native/${IDPFX}_T1w.nii.gz

if [[ ${NO_RAW} == "false" ]] && [[ ! -f ${XRAW} ]]; then
  antsRegistration --dimensionality 3 --output ${DIRTMP}/xfm_ \
    --write-composite-transform 0 --collapse-output-transforms 1 \
    --initialize-transforms-per-stage 0 \
    --initial-moving-transform [ ${REF},${DIRRAW}/anat/${IDPFX}_T1w.nii.gz,1 ] \
    --transform Rigid[ 0.1 ] \
      --metric Mattes[ ${REF},${DIRRAW}/anat/${IDPFX}_T1w.nii.gz,1,32,Regular,0.25 ] \
      --convergence [ 2000x2000x2000x2000x2000,1e-6,10 ] \
      --smoothing-sigmas 4x3x2x1x0vox \
      --shrink-factors 8x8x4x2x1 \
    --use-histogram-matching 1 \
    --winsorize-image-intensities [ 0.005,0.995 ] \
    --float 1 --verbose 1 --random-seed 13983981
    mv ${DIRTMP}/xfm_0GenericAffine.mat ${XRAW}
then

# Locate / Create Masks ------------------------------------------------------
MASK_BRAIN=${DIRPRO}/anat/mask/${IDPFX}_mask-brain.nii.gz
if [[ ! -f ${MASK_BRAIN} ]]; then
  echo -e "ERROR [${PIPE}:${FLOW}] A brain mask in native space is required, aborting."
fi
MASK_FG=${DIRPRO}/anat/mask/${IDPFX}_mask-fg.nii.gz
if [[ ! -f ${MASK_FG} ]]; then
  3dAutomask -prefix ${MASK_FG} -clfrac 0.25 ${DIRPRO}/anat/native/${IDPFX}_T1w.nii.gz
fi

  ## CC LABELS: 251-255
LAB_CC=${DIRPRO}/anat/label/MALF/${IDPFX}_label-wmparc+MALF.nii.gz
MASK_CC=${DIRTMP}/MASK_CC.nii.gz
niimath ${LAB_CC} -thr 251 -uthr 255 -bin ${MASK_CC} -odt char

LAB_TISSUE=${DIRPRO}/anat/label/${IDPFX}_label-tissue.nii.gz
  #LABELS: GM=2, deepGM=3, WM=4, CSF=1
PST_TISSUE=${DIRPRO}/anat/posterior/${IDPFX}_posterior-tissue.nii.gz
  #POSTERIOR VOLUMES: GM=1, deepGM=2, WM=3, CSF=4
MASK_WM=${DIRPRO}/anat/mask/${IDPFX}_mask-wm.nii.gz
if [[ ! -f ${MASK_WM} ]]; then
  niimath ${LAB_TISSUE} -thr 4 -uthr 4 -bin ${MASK_WM} -odt char
fi

# RAW ANATOMICALS ------------------------------------------------------------
if [[ ${NO_RAW} == "false" ]]; then
  unset IMGLS
  IMGLS=($(ls ${DIRRAW}/anat/*.nii.gz))
  for (( j=0; j<${#IMGLS[@]}; j++ )); do
    NV=$(niiInfo -i ${RAWLS[${j}]} -f volumes)
    MOD=$(getField -i ${RAWLS[${j}]} -f modality)
    if [[ ${MOD} == "qalas" ]]; then MOD=${MOD^^}; fi
    TIMG=${DIRTMP}/timg.nii.gz
    FRAME=${DIRTMP}/frame.nii.gz
    # get frame mask ------
    3dcalc -a ${IMGLS[${j}]}[0] -expr a -overwrite -prefix ${FRAME}
    niimath ${FRAME} -mul 0 -add 1 -bin ${FRAME} -odt char
    
    # push to native space ------
    if [[ ${MOD} == "T1w" ]]; then
      XSTR="-t identity -t ${XRAW}"
    else
      XSTR="-t identity -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-${MOD}_to-native_xfm-syn.nii.gz -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-${MOD}_to-native_xfm-affine.mat"
    fi
    if [[ ${NV} -eq 1 ]]; then
      antsApplyTransforms -d 3 -n Linear -i ${IMGLS[${j}]} -o ${TIMG} -r ${REF} ${XSTR}
    else
      antsApplyTransforms -d 3 -e 3 -n Linear -i ${IMGLS[${j}]} -o ${TIMG} -r ${REF} ${XSTR}
    fi
    antsApplyTransforms -d 3 -n GenericLabel -i ${FRAME} -o ${FRAME} -r ${REF} ${XSTR}
    
    unset CJV CNR EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
    CJV=($(qc_cjv --image ${TIMG} --tissue ${LAB_TISSUE} --label "2,4"))
    CNR=$(qc_cnr --image ${TIMG} --fg ${MASK_FG} --tissue ${LAB_TISSUE} --label "2,4")
    EFC=$(qc_efc --image ${TIMG} --frame ${FRAME})
    FBER=$(qc_fber --image ${TIMG} --mask ${MASK_FG})
    SNR_FRAME=$(qc_snr --image ${TIMG} --mask ${FRAME})
    SNR_FG=$(qc_snr --image ${TIMG} --mask ${MASK_FG})
    SNR_BRAIN=$(qc_snr --image ${TIMG} --mask ${MASK_BRAIN})
    SNR_D=$(qc_snrd --image ${TIMG} --frame ${FRAME} --fg ${MASK_FG})
    WM2MAX=$(qc_wm2max --image ${TIMG} --mask ${MASK_WM})
    FWHM=($(qc_fwhm --image ${TIMG} --mask ${MASK_FG}))
    for (( k=1; k<=${NV}; k++ )); do
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},cjv,${CJV[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},cnr,${CNR[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},efc,${EFC[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},fber,${FBER[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},${k},wm2max,${WM2MAX[${k}]}" >> ${CSV}
    done
    echo "${IDSTR},${DSFX},raw,anat,${MOD},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,cjv,${CJV[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,cnr,${CNR[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,efc,${EFC[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,fber,${FBER[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},raw,anat,${MOD},mean,wm2max,${WM2MAX[-1]}" >> ${CSV}
  done
fi

# CLEAN ANATOMICALS ------------------------------------------------------------
unset IMGLS
IMGLS=($(ls ${DIRPRO}/anat/native/${IDPFX}*.nii.gz))
IMGLS+=($(ls  ${DIRPRO}/anat/native_qmri/${IDPFX}*.nii.gz))
for (( j=0; j<${#IMGLS[@]}; j++ )); do
  TIMG=${IMGLS[${j}]}
  NV=$(niiInfo -i ${TIMG} -f volumes)
  MOD=$(getField -i ${TIMG} -f modality)
  
  unset CJV CNR EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
  CJV=($(qc_cjv --image ${TIMG} --tissue ${LAB_TISSUE} --label "2,4"))
  CNR=($(qc_cnr --image ${TIMG} --fg ${MASK_FG} --tissue ${LAB_TISSUE} --label "2,4"))
  EFC=($(qc_efc --image ${TIMG}))
  FBER=$(qc_fber --image ${TIMG} --mask ${MASK_FG}))
  RPVE=($(qc_rpve --posterior ${PST_TISSUE})))
  SNR_FRAME=($(qc_snr --image ${TIMG}))
  SNR_FG=($(qc_snr --image ${TIMG} --mask ${MASK_FG}))
  SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${MASK_BRAIN}))
  SNR_D=($(qc_snrd --image ${TIMG} --fg ${MASK_FG}))
  WM2MAX=($(qc_wm2max --image ${TIMG} --mask ${MASK_WM}))
  FWHM=($(qc_fwhm --image ${TIMG} --mask ${MASK_FG}))
  for (( k=1; k<=${NV}; k++ )); do
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},cjv,${CJV[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},cnr,${CNR[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},efc,${EFC[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},fber,${FBER[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,anat,${MOD},${k},wm2max,${WM2MAX[${k}]}" >> ${CSV}
  done
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,rpve_gm,${RPVE[0]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,rpve_deepgm,${RPVE[1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,rpve_wm,${RPVE[2]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},NA,rpve_csf,${RPVE[3]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,cjv,${CJV[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,cnr,${CNR[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,efc,${EFC[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,fber,${FBER[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
  echo "${IDSTR},${DSFX},clean,anat,${MOD},mean,wm2max,${WM2MAX[-1]}" >> ${CSV}
done

# RAW FUNCTIONAL ---------------------------------------------------------------
if [[ ${NO_RAW}=="false" ]]; do
  unset IMGLS
  IMGLS=($(ls ${DIRRAW}/func/${IDPFX}*bold.nii.gz))
  if [[ ${#IMGLS[@]} -gt 0 ]]; then
    for (( j=0; j<${#IMGLS[@]}; j++ )); do
      TIMG=${IMGLS[${j}]}
      TASK=$(getBidsBase -i ${TIMG} -s)
      TASK=${TASK//${IDPFX}_}
      XSTR="-t identity -t [${DIRPRO}/xfm/${IDDIR}/${IDPFX}_${TASK}_mod-bold_from-raw_to-native_xfm-affine.mat,1] -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_${TASK}_mod-bold_from-raw_to-native_xfm-syn+inverse.nii.gz"
      TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
      TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
      antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TIMG} ${XSTR}
      antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TIMG} ${XSTR}
    
      unset EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
      EFC=($(qc_efc --image ${TIMG}))
      FBER=$(qc_fber --image ${TIMG} --mask ${TMASK_FG}))
      SNR_FRAME=($(qc_snr --image ${TIMG}))
      SNR_FG=($(qc_snr --image ${TIMG} --mask ${TMASK_FG}))
      SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${TMASK_BRAIN}))
      SNR_D=($(qc_snrd --image ${TIMG} --fg ${TMASK_FG}))
      FWHM=($(qc_fwhm --image ${TIMG} --mask ${TMASK_BRAIN}))    
      for (( k=1; k<=${NV}; k++ )); do
        echo "${IDSTR},${DSFX},raw,func,${TASK},${k},efc,${EFC[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,func,${TASK},${k},fber,${FBER[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,func,${TASK},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,func,${TASK},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,func,${TASK},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,func,${TASK},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
      done
      echo "${IDSTR},${DSFX},raw,func,${TASK},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},mean,efc,${EFC[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},mean,fber,${FBER[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,func,${TASK},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
    done
  fi
fi

# CLEAN FUNCTIONAL -----------------------------------------------------------
unset IMGLS
IMGLS=($(ls ${DIRPRO}/func/clean/${IDPFX}*bold.nii.gz))
if [[ ${#IMGLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#IMGLS[@]}; j++ )); do
    TIMG=${IMGLS[${j}]}
    TASK=$(getBidsBase -i ${TIMG} -s)
    TASK=${TASK//${IDPFX}_}
    TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
    TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TIMG}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TIMG}
    
    unset EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
    EFC=($(qc_efc --image ${TIMG}))
    FBER=$(qc_fber --image ${TIMG} --mask ${TMASK_FG}))
    SNR_FRAME=($(qc_snr --image ${TIMG}))
    SNR_FG=($(qc_snr --image ${TIMG} --mask ${TMASK_FG}))
    SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${TMASK_BRAIN}))
    SNR_D=($(qc_snrd --image ${TIMG} --fg ${TMASK_FG}))
    FWHM=($(qc_fwhm --image ${TIMG} --mask ${TMASK_BRAIN}))  
    for (( k=1; k<=${NV}; k++ )); do
      echo "${IDSTR},${DSFX},clean,func,${TASK},${k},efc,${EFC[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,func,${TASK},${k},fber,${FBER[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,func,${TASK},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,func,${TASK},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,func,${TASK},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,func,${TASK},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
    done
    echo "${IDSTR},${DSFX},clean,func,${TASK},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},mean,efc,${EFC[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},mean,fber,${FBER[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,func,${TASK},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
  done
fi

# RESIDUAL FUNCTIONAL -----------------------------------------------------------
unset IMGLS
IMGLS=($(ls ${DIRPRO}/func/residual_native/${IDPFX}*bold.nii.gz))
if [[ ${#IMGLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#IMGLS[@]}; j++ )); do
    TIMG=${IMGLS[${j}]}
    TASK=$(getBidsBase -i ${TIMG} -s)
    TASK=${TASK//${IDPFX}_}
    TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
    TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TIMG}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TIMG}
    
    unset EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D FWHM
    EFC=($(qc_efc --image ${TIMG}))
    FBER=$(qc_fber --image ${TIMG} --mask ${TMASK_FG}))
    SNR_FRAME=($(qc_snr --image ${TIMG}))
    SNR_FG=($(qc_snr --image ${TIMG} --mask ${TMASK_FG}))
    SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${TMASK_BRAIN}))
    SNR_D=($(qc_snrd --image ${TIMG} --fg ${TMASK_FG}))
    FWHM=($(qc_fwhm --image ${TIMG} --mask ${TMASK_BRAIN}))  
    for (( k=1; k<=${NV}; k++ )); do
      echo "${IDSTR},${DSFX},resid,func,${TASK},${k},efc,${EFC[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},resid,func,${TASK},${k},fber,${FBER[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},resid,func,${TASK},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},resid,func,${TASK},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},resid,func,${TASK},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
      echo "${IDSTR},${DSFX},resid,func,${TASK},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
    done
    echo "${IDSTR},${DSFX},resid,func,${TASK},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},mean,efc,${EFC[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},mean,fber,${FBER[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
    echo "${IDSTR},${DSFX},resid,func,${TASK},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
  done
fi

# FUNCTIONAL REGRESSORS ------------------------------------------------------
FLS=($(ls ${DIRPRO}/func/regressors/${IDDIR}/*displacement+RMS.1D))
FLS+=($(ls ${DIRPRO}/func/regressors/${IDDIR}/*displacement+framewise.1D))
if [[ ${#FLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#FLS[@]}; j++ )); do
    TASK=$(getBidsBase -i ${FLS[${i}]} -s)
    TASK=${TASK//${IDPFX}_}
    MOD=$(getField -i ${FLS[${i}]} -f modality)
    STATS=($(3dBrickStat -mean -stdev ${FLS[${i}]}))
    echo "${IDSTR},${DSFX},regressor,func,${TASK},mean,${MOD},${STATS[-2]}" >> ${CSV}
    echo "${IDSTR},${DSFX},regressor,func,${TASK},sigma,${MOD},${STATS[-1]}" >> ${CSV}
  done
fi

unset FLS
FLS=($(ls ${DIRPRO}/func/regressors/${IDDIR}/*spike.1D))
if [[ ${#FLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#FLS[@]}; j++ )); do
    TASK=$(getBidsBase -i ${FLS[${i}]} -s)
    TASK=${TASK//${IDPFX}_}
    MOD=$(getField -i ${FLS[${i}]} -f modality)
    STATS=($(3dBrickStat -sum -count ${FLS[${i}]}))
    TVAL=$(echo "scale=${PRECISION}; ${STATS[-2]} / ${STATS[-1]}" | bc -l)
    echo "${IDSTR},${DSFX},regressor,func,${TASK},percent,${MOD},${TVAL}" >> ${CSV}
  done
fi

# RAW DIFFUSION --------------------------------------------------------------
EFC FBER FWHM SNR SNR_FRAME SNR_FG SNR_BRAIN SNR_D
SNR_CC (NEEDS LABELS)

# NEIGHBOR_CORRELATION not implemented yet
CALCULATE BY_SHELL and BY_VOLUME?

if [[ ${NO_RAW}=="false" ]]; do
  unset IMGLS
  IMGLS=($(ls ${DIRRAW}/dwi/${IDPFX}*dwi.nii.gz))
  if [[ ${#IMGLS[@]} -gt 0 ]]; then
    for (( j=0; j<${#IMGLS[@]}; j++ )); do
      #gather XFMs and masks
      XSTR="-t identity -t [${DIRPRO}/xfm/${IDDIR}/${IDPFX}_mod-dwi_from-raw_to-native_xfm-affine.mat,1] -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_mod-dwi_from-raw_to-native_xfm-syn+inverse.nii.gz"
      TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
      TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
      TMASK_CC==${DIRTMP}/TMASK_CC.nii.gz
      TREF=${DIRTMP}/DWI_TREF.nii.gz
      3dcalc -a ${IMGLS[${j}]}[0] -expr a -prefix ${TREF}
      antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TREF} ${XSTR}
      antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TREF} ${XSTR}
      antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_CC} -o ${TMASK_BRAIN} -r ${TREF} ${XSTR}
    
      # split into shells
      BNAME=$(getBidsBase -i ${IMGLS[${j}]})
      BVAL=(cat ${DIRRAW}/dwi/${BNAME}.bval)
      unset BLS
      for (( k=0; k<{#BVAL[@]}; k++ )); do
        TB=$(printf "%.0f" ${BVAL[${k}]})
        if [[ " ${BLS[*]} " != " ${TB} " ]]; then BLS+=(${TB}); fi
        TLS=($(ls ${DIRTMP}/DWI_B${TB}_*.nii.gz))
        3dcalc -a ${IMGLS[${j}]} -expr a -prefix ${DIRTMP}/DWI_B${TB}_${#TLS[@]}.nii.gz
      done
      for (( k=0; k<${#BLS[@]}; k++ )); do
        TB=${BLS[${k}]}
        3dTcat -prefix ${DIRTMP}/DWI_B${TB}.nii.gz $(ls ${DIRTMP}/DWI_B${TB}_*.nii.gz)
        TIMG=${DIRTMP}/DWI_B${TB}.nii.gz
        
        unset EFC FBER SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
        EFC=($(qc_efc --image ${TIMG}))
        FBER=$(qc_fber --image ${TIMG} --mask ${TMASK_FG}))
        SNR_FRAME=($(qc_snr --image ${TIMG}))
        SNR_FG=($(qc_snr --image ${TIMG} --mask ${TMASK_FG}))
        SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${TMASK_BRAIN}))
        SNR_CC=($(qc_snr --image ${TIMG} --mask ${TMASK_CC}))
        SNR_D=($(qc_snrd --image ${TIMG} --fg ${TMASK_FG}))
        FWHM=($(qc_fwhm --image ${TIMG} --mask ${TMASK_BRAIN}))
      PIESNO=$(qc_piesnoish --image ${TIMG} --mask ${TMASK_BRAIN})
        for (( k=1; k<=${NV}; k++ )); do
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},efc,${EFC[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},fber,${FBER[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},snr_cc,${SNR_CC[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
          echo "${IDSTR},${DSFX},raw,dwi,${TB},${k},pieshoish,${PIESNO[${k}]}" >> ${CSV}
        done
        echo "${IDSTR},${DSFX},raw,dwi,${TB},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,efc,${EFC[-1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,fber,${FBER[-1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
        echo "${IDSTR},${DSFX},raw,dwi,${TB},mean,piesnoish,${PIESNO[-1]}" >> ${CSV}
      done
    done
  fi
fi

# CLEAN DIFFUSION ------------------------------------------------------------
unset IMGLS
IMGLS=($(ls ${DIRPRO}/dwi/preproc/dwi/${IDPFX}*dwi.nii.gz))
if [[ ${#IMGLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#IMGLS[@]}; j++ )); do
    #gather XFMs and masks
    XSTR="-t identity -t [${DIRPRO}/xfm/${IDDIR}/${IDPFX}_mod-dwi_from-raw_to-native_xfm-affine.mat,1] -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_mod-dwi_from-raw_to-native_xfm-syn+inverse.nii.gz"
    TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
    TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
    TREF=${DIRTMP}/DWI_TREF.nii.gz
    3dcalc -a ${IMGLS[${j}]}[0] -expr a -prefix ${TREF}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TREF} ${XSTR}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TREF} ${XSTR}
  
    # split into shells
    BNAME=$(getBidsBase -i ${IMGLS[${j}]})
    BVAL=(cat ${DIRRAW}/dwi/${BNAME}.bval)
    unset BLS
    for (( k=0; k<{#BVAL[@]}; k++ )); do
      TB=$(printf "%.0f" ${BVAL[${k}]})
      if [[ " ${BLS[*]} " != " ${TB} " ]]; then BLS+=(${TB}); fi
      TLS=($(ls ${DIRTMP}/DWI_B${TB}_*.nii.gz))
      3dcalc -a ${IMGLS[${j}]} -expr a -prefix ${DIRTMP}/DWI_B${TB}_${#TLS[@]}.nii.gz
    done
    for (( k=0; k<${#BLS[@]}; k++ )); do
      TB=${BLS[${k}]}
      3dTcat -prefix ${DIRTMP}/DWI_B${TB}.nii.gz $(ls ${DIRTMP}/DWI_B${TB}_*.nii.gz)
      TIMG=${DIRTMP}/DWI_B${TB}.nii.gz
      
      unset EFC FBER SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
      EFC=($(qc_efc --image ${TIMG}))
      FBER=$(qc_fber --image ${TIMG} --mask ${TMASK_FG}))
      SNR_FRAME=($(qc_snr --image ${TIMG}))
      SNR_FG=($(qc_snr --image ${TIMG} --mask ${TMASK_FG}))
      SNR_BRAIN=($(qc_snr --image ${TIMG} --mask ${TMASK_BRAIN}))
      SNR_D=($(qc_snrd --image ${TIMG} --fg ${TMASK_FG}))
      FWHM=($(qc_fwhm --image ${TIMG} --mask ${TMASK_BRAIN}))
      PIESNO=$(qc_piesnoish --image ${TIMG} --mask ${TMASK_BRAIN})
      for (( k=1; k<=${NV}; k++ )); do
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},efc,${EFC[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},fber,${FBER[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},snr_frame,${SNR_FRAME[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},snr_fg,${SNR_FG[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},snr_brain,${SNR_BRAIN[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},snr_dietrich,${SNR_D[${k}]}" >> ${CSV}
        echo "${IDSTR},${DSFX},clean,dwi,${TB},${k},pieshoish,${PIESNO[${k}]}" >> ${CSV}
      done
      echo "${IDSTR},${DSFX},clean,dwi,${TB},NA,fwhm_x,${FWHM[0]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},NA,fwhm_y,${FWHM[1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},NA,fwhm_z,${FWHM[2]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,efc,${EFC[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,fber,${FBER[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,snr_frame,${SNR_FRAME[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,snr_fg,${SNR_FG[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,snr_brain,${SNR_BRAIN[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,snr_dietrich,${SNR_D[-1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,dwi,${TB},mean,piesnoish,${PIESNO[-1]}" >> ${CSV}
    done
  done
fi


# DWI FA -----------------------------------------------------------------------
unset IMGLS
IMGLS=($(ls ${DIRPRO}/dwi/scalar_native/${IDPFX}*scalar-fa.nii.gz))
if [[ ${#IMGLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#IMGLS[@]}; j++ )); do
    #gather XFMs and masks
    TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
    TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
    TREF=${DIRTMP}/DWI_TREF.nii.gz
    3dcalc -a ${IMGLS[${j}]}[0] -expr a -prefix ${TREF}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TREF}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TREF}
    
    unset ISNAN ISDEGEN
    ISNAN=$(qc_isnan --image ${IMGLS[${j}]})
    ISDEGEN=$(qc_isoutrange --image ${IMGLS[${j}]})
    echo "${IDSTR},${DSFX},clean,dwi,${TB},pct,fa_isnan,${ISNAN}" >> ${CSV}
    echo "${IDSTR},${DSFX},clean,dwi,${TB},pct,fa_isdegen,${ISDEGEN}" >> ${CSV}
  done
fi

TLS=($(ls ${DIRPRO}/dwi/preproc/qc/${IDPFX}*pctOutliers.txt))
if [[ ${#TLS[@]} -gt 0 ]]; then
  for (( j=0; j<${#TLS[@]}; j++ )); do
    unset SPIKE
    SPIKE=$(cat ${TLS[${i}]})
    echo "${IDSTR},${DSFX},clean,dwi,${TB},pct,spike,${SPIKE}" >> ${CSV}
  done
fi