#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      FSSYNTH
# DESCRIPTION:   FreeSurfer recon-all-clinical.sh
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2024-02-08
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
OPTS=$(getopt -o hvn --long pi:,project:,dir-project:,\
id:,dir-id:,image:,nthreads:,labels:,\
requires:,force,\
dir-scratch:,dir-fs:,dir-save:,\
help,verbose,no-png -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_FS=
DIR_TKNI=
DIR_SCRATCH=
IDPFX=
IDDIR=

IMAGE=
MOD="T1w"
NTHREADS=4
LABELS=("aparc.a2009s+aseg" "aparc.DKTatlas+aseg" "aparc+aseg" "wmparc")

HELP=false
VERBOSE=false
NO_PNG=false
NO_RMD=false

FSPIPE=fsSynth
PIPE=tkni
FLOW=${FCN_NAME//${PIPE}}
REQUIRES="tkniDICOM,tkniAINIT"
FORCE="false"

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
    --image) IMG="$2" ; shift 2 ;;
    --mod) MOD="$2" ; shift 2 ;;
    --labels) LABELS="$2" ; shift 2 ;;
    --nthreads) NTHREADS="$2" ; shift 2 ;;
    --dir-fs) DIR_FS="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
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
  echo "${PIPE^^}:${FLOW}"
  echo '----------------------------anat--------------------------------------------'
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

# set up directories -----------------------------------------------------------
DIR_PIPE=${DIR_PROJECT}/derivatives/${PIPE}
if [[ -z ${DIR_FS} ]]; then
  DIR_FS=${DIR_PROJECT}/derivatives/${FSPIPE}
fi
mkdir -p ${DIR_FS}
if [[ ! -d ${DIR_FS}/fsaverage ]]; then
  cp -r ${FREESURFER_HOME}/subjects/fsaverage ${DIR_FS}/
fi
#if [[ -z ${DIR_TKNI} ]]; then
#  DIR_TKNI=${DIR_PROJECT}/derivatives/tkni
#fi
DIR_PREP=${DIR_PIPE}/prep/${IDDIR}/${FCN_NAME}
if [[ -z ${DIR_SAVE} ]]; then
  DIR_SAVE=${DIR_PIPE}
fi
mkdir -p ${DIR_PREP}
mkdir -p ${DIR_SCRATCH}

# parse image inputs -----------------------------------------------------------
if [[ -z ${IMAGE} ]]; then
  IMAGE=${DIR_PIPE}/anat/native/${IDPFX}_${MOD}.nii.gz
fi

# Recon-all-clinical -----------------------------------------------------------
recon-all-clinical.sh ${IMAGE} ${IDPFX} ${NTHREADS} ${DIR_FS}

if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> RECON-ALL Clinical COMPLETE"
fi

# convert native_synth ---------------------------------------------------------
mri_convert ${DIR_FS}/${IDPFX}/mri/synthSR.raw.mgz \
  ${DIR_PREP}/${IDPFX}_synthT1w.nii.gz
antsApplyTransforms -d 3 -n BSpline[3] -t identity -r ${IMAGE} \
  -i ${DIR_PREP}/${IDPFX}_synthT1w.nii.gz \
  -o ${DIR_PREP}/${IDPFX}_synthT1w.nii.gz
if [[ "${NO_PNG}" == "false" ]]; then
  make3Dpng --bg ${DIR_PREP}/${IDPFX}_synthT1w.nii.gz --bg-threshold "2.5,97.5"
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> Converted to Native space NIFTI"
fi

# convert stats output to CSV --------------------------------------------------
HEMI=("lh" "rh")
for j in {0..1}; do
  TH=${HEMI[${j}]}
  for (( i=0; i<${#LABELS[@]}; i ++ )); do
    LAB=(${LABELS[${i}]//+/ })
    STATS=${DIR_FS}/${IDPFX}/stats/${TH}.${LAB}.stats
    CSV=${DIR_FS}/${IDPFX}/stats/${TH}.${LAB}.csv
    if [[ -f ${STATS} ]]; then
      cp ${STATS} ${CSV}
      sed -i '1,/^# ColHeaders StructName NumVert SurfArea GrayVol ThickAvg ThickStd MeanCurv GausCurv FoldInd CurvInd$/d' ${CSV}
      sed -i '1s/^/StructName NumVert SurfArea GrayVol ThickAvg ThickStd MeanCurv GausCurv FoldInd CurvInd\n/' ${CSV}
      sed -i 's/ \{1,\}/,/g' ${CSV}
    fi
  done
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> converting output stats to CSV"
fi

# Extract GM Ribbon ------------------------------------------------------------
mri_convert ${DIR_FS}/${IDPFX}/mri/ribbon.mgz ${DIR_PREP}/tmp.nii.gz
niimath ${DIR_PREP}/tmp.nii.gz -thr 3 -uthr 3 -bin \
  ${DIR_PREP}/${IDPFX}_label-ribbon.nii.gz -odt char
niimath ${DIR_PREP}/tmp.nii.gz -thr 42 -uthr 42 -bin -mul 2 \
  -add ${DIR_PREP}/${IDPFX}_label-ribbon.nii.gz \
  ${DIR_PREP}/${IDPFX}_label-ribbon.nii.gz -odt char
rm ${DIR_PREP}/tmp.nii.gz
antsApplyTransforms -d 3 -n MultiLabel -t identity -r ${IMAGE} \
  -i ${DIR_PREP}/${IDPFX}_label-ribbon.nii.gz \
  -o ${DIR_PREP}/${IDPFX}_label-ribbon.nii.gz
if [[ "${NO_PNG}" == "false" ]] || [[ "${NO_RMD}" == "false" ]]; then
  TLAYOUT="3:x;3:x;3:x;3:x;3:x;3:x;3:x;3:x;3:x"
  make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
    --fg ${DIR_PREP}/${IDPFX}_label-ribbon.nii.gz \
    --fg-color "timbow:hue=#FF0000:lum=50,50,cyc=1/6" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_label-ribbon \
    --dir-save ${DIR_PREP}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> GM ribbon extracted to NIFTI"
fi

# convert labels ---------------------------------------------------------------
for (( i=0; i<${#LABELS[@]}; i ++ )); do
  LAB=${LABELS[${i}]}
  if [[ ${LAB} == *"a2009s"* ]]; then FSLAB="aparc.a2009s+aseg"; fi
  if [[ ${LAB} == *"DKT"* ]]; then FSLAB="aparc.DKTatlas+aseg"; fi
  if [[ ${LAB} == *"aparc"* ]]; then FSLAB="aparc+aseg"; fi
  if [[ ${LAB} == *"wmparc"* ]]; then FSLAB="wmparc"; fi
  mri_convert ${DIR_FS}/${IDPFX}/mri/${FSLAB}.mgz \
    ${DIR_PREP}/${IDPFX}_label-${LAB}+${FSPIPE}.nii.gz
  antsApplyTransforms -d 3 -n MultiLabel \
    -i ${DIR_PREP}/${IDPFX}_label-${LAB}+${FSPIPE}.nii.gz \
    -o ${DIR_PREP}/${IDPFX}_label-${LAB}+${FSPIPE}.nii.gz \
    -r ${IMAGE} \
    -t identity
  if [[ "${NO_PNG}" == "false" ]]; then
    make3Dpng --bg ${IMAGE} --bg-threshold "2.5,97.5" \
      --fg ${DIR_PREP}/${IDPFX}_label-${LAB}+${FSPIPE}.nii.gz \
      --fg-color "timbow:random" \
      --fg-cbar "false" --fg-alpha 50 \
      --layout "7:x;7:x;7:y;7:y;7:z;7:z" \
      --filename ${IDPFX}_label-${LAB}+${FSPIPE} --dir-save ${DIR_PREP}
  fi
done
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> labels converted to NIFTI"
fi

# create masks -----------------------------------------------------------------
niimath ${DIR_PREP}/${IDPFX}_label-wmparc+${FSPIPE}.nii.gz \
  -thr 24 -uthr 24 -binv \
  -mul ${DIR_PREP}/${IDPFX}_label-wmparc+${FSPIPE}.nii.gz -bin \
  ${DIR_PREP}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz
if [[ "${NO_PNG}" == "false" ]]; then
  TLAYOUT="3:x;3:x;3:x;3:x;3:x;3:x;3:x;3:x;3:x"
  make3Dpng --bg ${IMAGE} \
    --fg ${DIR_PREP}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz \
    --fg-color "timbow:random" --fg-alpha 50 --fg-cbar "false" \
    --layout ${TLAYOUT} \
    --filename ${IDPFX}_mask-brain+${FSPIPE} \
    --dir-save ${DIR_PREP}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> brain masks generated"
fi

# create surface ---------------------------------------------------------------
mri_tessellate ${DIR_PREP}/${IDPFX}_mask-brain+${FSPIPE}.nii.gz 1 ${DIR_PREP}/${IDPFX}_tmp
mris_convert ${DIR_PREP}/${IDPFX}_tmp ${DIR_PREP}/${IDPFX}_surface-brain+${FSPIPE}.stl
rm ${DIR_PREP}/${IDPFX}_tmp
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> surface tessalation completed for 3D printing"
fi

# create surface renderings ----------------------------------------------------
if [[ "${NO_PNG}" == "false" ]]; then
  makeSURFpng --dir-fs ${DIR_FS} --dir-id ${IDPFX} --surface pial --dir-save ${DIR_PREP}
  makeSURFpng --dir-fs ${DIR_FS} --dir-id ${IDPFX} --surface white --dir-save ${DIR_PREP}
  for (( i=0; i<${#LABELS[@]}; i ++ )); do
    LAB=(${LABELS[${i}]//+/ })
    if [[ -f "${DIR_FS}/${IDPFX}/label/lh.${LAB}.annot" ]]; then
      makeSURFpng --dir-fs ${DIR_FS} --dir-id ${IDPFX} \
        --surface pial --label ${LAB} --dir-save ${DIR_PREP}
    fi
  done
  makeSURFpng --dir-fs ${DIR_FS} --dir-id ${IDPFX} --surface inflated --overlay thickness \
    --dir-save ${DIR_PREP}
  makeSURFpng --dir-fs ${DIR_FS} --dir-id ${IDPFX} --surface inflated --overlay area \
    --dir-save ${DIR_PREP}
  makeSURFpng --dir-fs ${DIR_FS} --dir-id ${IDPFX} \
    --surface inflated --overlay curv --over-color colorwheel \
    --dir-save ${DIR_PREP}
fi
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> surfaces rendered for QC"
fi

# Save output to appropriate locations -----------------------------------------
mkdir -p ${DIR_SAVE}/anat/native/${FSPIPE}
mkdir -p ${DIR_SAVE}/anat/label/${FSPIPE}
mkdir -p ${DIR_SAVE}/anat/mask/${FSPIPE}
mkdir -p ${DIR_SAVE}/anat/surface
mv ${DIR_PREP}/${IDPFX}_synthT1w.nii.gz ${DIR_SAVE}/anat/native/${FSPIPE}/
mv ${DIR_PREP}/${IDPFX}_label*.nii.gz ${DIR_SAVE}/anat/label/${FSPIPE}/
mv ${DIR_PREP}/${IDPFX}_mask*.nii.gz ${DIR_SAVE}/anat/mask/${FSPIPE}/
mv ${DIR_PREP}/${IDPFX}_surface-brain+${FSPIPE}.stl ${DIR_SAVE}/anat/surface/
if [[ ${VERBOSE} == "true" ]]; then
  echo -e ">>>>> output moved to BIDS-esque locations"
fi

# generate HTML QC report ------------------------------------------------------
if [[ "${NO_RMD}" == "false" ]]; then
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}
  RMD=${DIR_PROJECT}/qc/${PIPE}${FLOW}/${IDPFX}_${PIPE}${FLOW}_${DATE_SUFFIX}.Rmd
  HEMI=("lh" "rh")

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

  echo '## Freesurfer Synth Pipeline' >> ${RMD}
  echo 'recon-all-clinical.sh\' >> ${RMD}
  echo -e '\n---\n' >> ${RMD}

  # output Project related information -------------------------------------------
  echo 'PI: **'${PI}'**\' >> ${RMD}
  echo 'PROJECT: **'${PROJECT}'**\' >> ${RMD}
  echo 'IDENTIFIER: **'${IDPFX}'**\' >> ${RMD}
  echo 'DATE: **`r Sys.time()`**\' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Anatomical Images {.tabset}' >> ${RMD}
  echo '#### Input' >> ${RMD}
  TNII=${IMAGE}
  TPNG=${IMAGE//\.nii\.gz}.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII}; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Synthetic' >> ${RMD}
  TNII=${DIR_SAVE}/anat/native/fsSynth/${IDPFX}_synthT1w.nii.gz
  TPNG=${DIR_PREP}/${IDPFX}_synthT1w.png
  if [[ ! -f "${TPNG}" ]]; then make3Dpng --bg ${TNII}; fi
  echo '!['${TNII}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Surface Reconstruction {.tabset}' >> ${RMD}
  echo '#### Pial' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_surface-pial.png
  echo '![Pial Surface]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}
  echo '#### White Matter' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_surface-white.png
  echo '![WM Surface]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '### Surface Outcomes {.tabset}' >> ${RMD}
  OUTLS=("thickness" "area" "curv")
  for k in {0..2}; do
    OUT=${OUTLS[${k}]}
    echo '#### '${OUT^} >> ${RMD}
    TPNG=${DIR_PREP}/${IDPFX}_surface-inflated_overlay-${OUT}.png
    echo '!['${OUT^}']('${TPNG}')' >> ${RMD}
    echo '' >> ${RMD}
    for (( i=0; i<${#LABELS[@]}; i ++ )); do
      LAB=(${LABELS[${i}]//+/ })
      for j in {0..1}; do
        TH=${HEMI[${j}]}
        CSV="${DIR_FS}/${IDPFX}/stats/${TH}.${LAB}.csv"
        if [[ -f ${CSV} ]]; then
          FNAME="${IDPFX}_hemi-${TH}_label-${LAB}_${OUT}"
          echo '```{r}' >> ${RMD}
          echo 'data'${i}${j}${k}' <- read.csv("'${CSV}'")' >> ${RMD}
          echo 'download_this(.data=data'${i}${j}${k}',' >> ${RMD}
          echo '  output_name = "'${FNAME}'",' >> ${RMD}
          echo '  output_extension = ".csv",' >> ${RMD}
          echo '  button_label = "Download '${FNAME}' CSV",' >> ${RMD}
          echo '  button_type = "default", has_icon = TRUE, icon = "fa fa-save", csv2=F)' >> ${RMD}
          echo '```' >> ${RMD}
          echo '' >> ${RMD}
        fi
      done
    done
  done

  echo '### Cortical Labels {.tabset}' >> ${RMD}
  for (( i=0; i<${#LABELS[@]}; i ++ )); do
    LAB=(${LABELS[${i}]//+/ })
    TPNG=${DIR_PREP}/${IDPFX}_surface-pial_label-${LAB}.png
    if [[ -f ${TPNG} ]]; then
      echo "#### ${LAB}" >> ${RMD}
      echo '!['${LAB}']('${TPNG}')' >> ${RMD}
      echo '' >> ${RMD}
    fi
  done

  echo '### Processing Check {.tabset}' >> ${RMD}
  echo '#### Click to View ->' >> ${RMD}
  echo '#### Cortical Segmentation' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_label-ribbon.png
  echo '!['${LAB}']('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  echo '#### Brain Mask' >> ${RMD}
  TPNG=${DIR_PREP}/${IDPFX}_mask-brain+fsSynth.png
  echo '![Brain Mask]('${TPNG}')' >> ${RMD}
  echo '' >> ${RMD}

  ## knit RMD
  Rscript -e "rmarkdown::render('${RMD}')"
  mkdir -p ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd
  mv ${RMD} ${DIR_PROJECT}/qc/${PIPE}${FLOW}/Rmd/
fi

# set status file --------------------------------------------------------------
mkdir -p ${DIR_PROJECT}/status/${PIPE}${FLOW}
touch ${DIR_PROJECT}/status/${PIPE}${FLOW}/CHECK_${PIPE}${FLOW}_${IDPFX}.txt

#===============================================================================
# End of Function
#===============================================================================
exit 0
