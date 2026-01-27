#!/bin/bash -e

#========================================================================================

PI=evanderplas
PROJECT=unitcall
DIR_PROJECT=/data/x/projects/${PI}/${PROJECT}
PIPE=tkni

PIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f participant_id))
SIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f session_id))
AIDLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f assessment_id))
N=${#PIDLS[@]}

IMGLS=("T1w" "qalas" "dwi" "bold")

DSFX=$(date +%Y%m%d)
CSV=${DIR_PROJECT}/summary/${PI}_${PROJECT}_QCSummary_${DSFX}.csv
echo "pid,sid,aid,summaryDate,processingStage,imageType,imageModality,imageVolume,measure,value" > ${CSV}

DIRTMP=/scratch/${PI}_${PROJECT}_QCReport_20260120
mkdir -p ${DIRTMP}

for (( i=1; i<${N}; i++ )); do
  IDPFX="sub-${PIDLS[${i}]}_ses-${SIDLS[${i}]}_aid-${AIDLS[${i}]}"
  IDDIR="sub-${PIDLS[${i}]}/ses-${SIDLS[${i}]}"
  IDSTR="${PIDLS[${i}]},${SIDLS[${i}]},${AIDLS[${i}]}"

  DIRRAW=${DIR_PROJECT}/rawdata/${IDDIR}
  DIRPRO=${DIR_PROJECT}/derivatives/${PIPE}

  # Locate Transforms ----------------------------------------------------------
  XRAW=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_mod-T1w_from-raw_to-ACPC_xfm-rigid.mat
  XAFF=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-native_to-HCPYAX_xfm-affine.mat
  XSYN=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-native_to-HCPYAX_xfm-syn.nii.gz
  XINV=${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-native_to-HCPYAX_xfm-syn+inverse.nii.gz
  REF=${DIRPRO}/anat/native/${IDPFX}_T1w.nii.gz
  if [[ ! -f ${XRAW} ]]; then
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
  MASK_FG=${DIRPRO}/anat/mask/${IDPFX}_mask-fg.nii.gz
  if [[ ! -f ${MASK_FG} ]]; then
    3dAutomask -prefix ${MASK_FG} -clfrac 0.25 ${DIRPRO}/anat/native/${IDPFX}_T1w.nii.gz
  fi
  LAB_TISSUE=${DIRPRO}/anat/label/${IDPFX}_label-tissue.nii.gz
  #LABELS: GM=2, deepGM=3, WM=4, CSF=1
  PST_TISSUE=${DIRPRO}/anat/posterior/${IDPFX}_posterior-tissue.nii.gz
  #POSTERIOR VOLUMES: GM=1, deepGM=2, WM=3, CSF=4
  MASK_WM=${DIRPRO}/anat/mask/${IDPFX}_mask-wm.nii.gz
  if [[ ! -f ${MASK_WM} ]]; then
    niimath ${LAB_TISSUE} -thr 4 -uthr 4 -bin ${MASK_WM} -odt char
  fi

  # RAW ANATOMICALS ------------------------------------------------------------
  RAWLS=($(ls ${DIRRAW}/anat/*.nii.gz))
  for (( j=0; j<${#RAWLS[@]}; j++ )); do
    NV=$(niiInfo -i ${RAWLS[${j}]} -f volumes)
    MOD=$(getField -i ${RAWLS[${j}]} -f modality)
    if [[ ${MOD} == "qalas" ]]; then MOD=${MOD^^}; fi
    TIMG=${DIRTMP}/timg.nii.gz
    FRAME=${DIRTMP}/frame.nii.gz
    for (( k=0; k<${NV}; k++ )); do
      3dcalc -a ${RAWLS[${j}]}[${k}] -expr a -overwrite -prefix ${TIMG}
      niimath ${TIMG} -mul 0 -add 1 -bin ${FRAME} -odt char

      # push to native space
      if [[ ${MOD} == "T1w" ]]; then
        XSTR="-t identity -t ${XRAW}"
      else
        XSTR="-t identity -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-${MOD}_to-native_xfm-syn.nii.gz -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_from-${MOD}_to-native_xfm-affine.mat"
      fi
      antsApplyTransforms -d 3 -n Linear -i ${TIMG} -o ${TIMG} -r ${REF} ${XSTR}
      antsApplyTransforms -d 3 -n GenericLabel -i ${FRAME} -o ${FRAME} -r ${REF} ${XSTR}

      unset CJV CNR EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
      CJV=$(qc_cjv --image ${TIMG} --tissue ${LAB_TISSUE} --label "2,4")
      CNR=$(qc_cnr --image ${TIMG} --fg ${MASK_FG} --tissue ${LAB_TISSUE} --label "2,4")
      EFC=$(qc_efc --image ${TIMG} --frame ${FRAME})
      FBER=$(qc_fber --image ${TIMG} --mask ${MASK_FG})
      RPVE=($(qc_rpve --posterior ${PST_TISSUE}))
      SNR_FRAME=$(qc_snr --image ${TIMG} --mask ${FRAME})
      SNR_FG=$(qc_snr --image ${TIMG} --mask ${MASK_FG})
      SNR_BRAIN=$(qc_snr --image ${TIMG} --mask ${MASK_BRAIN})
      SNR_D=$(qc_snrd --image ${TIMG} --frame ${FRAME} --fg ${MASK_FG})
      WM2MAX=$(qc_wm2max --image ${TIMG} --mask ${MASK_WM})
      FWHM=($(qc_fwhm --image ${TIMG} --mask ${MASK_FG}))

      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),cjv,${CJV}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),cnr,${CNR}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),efc,${EFC}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fber,${FBER}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),rpve_gm,${RPVE[0]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),rpve_deepgm,${RPVE[1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),rpve_wm,${RPVE[2]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),rpve_csf,${RPVE[3]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),snr_frame,${SNR_FRAME}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),snr_fg,${SNR_FG}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),snr_brain,${SNR_BRAIN}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),snr_dietrich,${SNR_D}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),wm2max,${WM2MAX}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fwhm_x,${FWHM[0]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fwhm_y,${FWHM[1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fwhm_z,${FWHM[2]}" >> ${CSV}
    done
  done

  # CLEAN ANATOMICALS ----------------------------------------------------------
  CLNLS=($(ls ${DIRPRO}/anat/native/${IDPFX}*.nii.gz))
  CLNLS+=($(ls  ${DIRPRO}/anat/native_qmri/${IDPFX}*.nii.gz))
  for (( j=0; j<${#CLNLS[@]}; j++ )); do
    NV=$(niiInfo -i ${CLNLS[${j}]} -f volumes)
    MOD=$(getField -i ${CLNLS[${j}]} -f modality)
    TIMG=${DIRTMP}/timg.nii.gz
    for (( k=0; k<${NV}; k++ )); do
      3dcalc -a ${RAWLS[${j}]}[${k}] -expr a -overwrite -prefix ${TIMG}

      unset CJV CNR EFC FBER RPVE SNR_FRAME SNR_FG SNR_BRAIN SNR_D WM2MAX
      CJV=$(qc_cjv --image ${TIMG} --tissue ${LAB_TISSUE} --label "2,4")
      CNR=$(qc_cnr --image ${TIMG} --fg ${MASK_FG} --tissue ${LAB_TISSUE} --label "2,4")
      EFC=$(qc_efc --image ${TIMG})
      FBER=$(qc_fber --image ${TIMG} --mask ${MASK_FG})
      RPVE=($(qc_rpve --posterior ${PST_TISSUE}))
      SNR_FRAME=$(qc_snr --image ${TIMG})
      SNR_FG=$(qc_snr --image ${TIMG} --mask ${MASK_FG})
      SNR_BRAIN=$(qc_snr --image ${TIMG} --mask ${MASK_BRAIN})
      SNR_D=$(qc_snrd --image ${TIMG} --fg ${MASK_FG})
      WM2MAX=$(qc_wm2max --image ${TIMG} --mask ${MASK_WM})
      FWHM=($(qc_fwhm --image ${TIMG} --mask ${MASK_FG}))

      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),cjv,${CJV}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),cnr,${CNR}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),efc,${EFC}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),fber,${FBER}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),rpve_gm,${RPVE[0]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),rpve_deepgm,${RPVE[1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),rpve_wm,${RPVE[2]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),rpve_csf,${RPVE[3]}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),snr_frame,${SNR_FRAME}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),snr_fg,${SNR_FG}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),snr_brain,${SNR_BRAIN}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),snr_dietrich,${SNR_D}" >> ${CSV}
      echo "${IDSTR},${DSFX},clean,anat,${MOD},$((${k}+1)),wm2max,${WM2MAX}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fwhm_x,${FWHM[0]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fwhm_y,${FWHM[1]}" >> ${CSV}
      echo "${IDSTR},${DSFX},raw,anat,${MOD},$((${k}+1)),fwhm_z,${FWHM[2]}" >> ${CSV}
    done
  done

  # RAW FUNCTIONAL -------------------------------------------------------------
  BOLDLS=($(ls ${DIRRAW}/func/${IDPFX}*bold.nii.gz))
  for (( j=0; j<${#CLNLS[@]}; j++ )); do
    TIMG=${BOLDLS[${j}]}
    TASK=$(getBidsBase -i ${TIMG} -s)
    TASK=${TASK//${IDPFX}_}

    XSTR="-t identity -t [${DIRPRO}/xfm/${IDDIR}/${IDPFX}_${TASK}_mod-bold_from-raw_to-native_xfm-affine.mat,1] -t ${DIRPRO}/xfm/${IDDIR}/${IDPFX}_${TASK}_mod-bold_from-raw_to-native_xfm-syn+inverse.nii.gz"
    TMASK_FG=${DIRTMP}/TMASK_FG.nii.gz
    TMASK_BRAIN=${DIRTMP}/TMASK_BRAIN.nii.gz
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_FG} -o ${TMASK_FG} -r ${TIMG} ${XSTR}
    antsApplyTransforms -d 3 -n GenericLabel -i ${MASK_BRAIN} -o ${TMASK_BRAIN} -r ${TIMG} ${XSTR}

    unset EFC FBER FWHM SNR_FRAME SNR_FG SNR_BRAIN SNR_D
    EFC=$(qc_efc --image ${TIMG})
    FBER=$(qc_fber --image ${TIMG} --mask ${TMASK_FG})
    FWHM=($(qc_fwhm --image ${TIMG} --mask ${TMASK_BRAIN}))
    SNR_FRAME=$(qc_snr --image ${TIMG})
    SNR_FG=$(qc_snr --image ${TIMG} --mask ${TMASK_FG})
    SNR_BRAIN=$(qc_snr --image ${TIMG} --mask ${TMASK_BRAIN})
    SNR_D=$(qc_snrd --image ${TIMG} --fg ${TMASK_BRAIN})
  done

  # CLEAN FUNCTIONAL -----------------------------------------------------------

  # RESIDUAL FUNCTIONAL -----------------------------------------------------------

  # RAW DIFFUSION --------------------------------------------------------------

  # CLEAN DIFFUSION ------------------------------------------------------------

done
