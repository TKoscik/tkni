#!/bin/bash
#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      HPC Workflow
# DESCRIPTION:   Main file to interface with TKNI Pipelines on the ACRI HPC
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2026-04-26
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

# Parse Input Variables --------------------------------------------------------
# 1. Remove leading hyphens
# 2. Convert to uppercase and replace hyphens with underscores
##   Note: This requires Bash 4.0+ for ^^ operator
# 3. Assign the next argument to the dynamic variable name
##   We use 'printf -v' or 'eval' for dynamic assignment
# 4. Require '--' flags, throw an error if '-'
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --*)
      flag_name="${1#--}"
      var_name="${flag_name^^}"
      var_name="${var_name//-/_}"
      printf -v "$var_name" "%s" "$2"
      shift 2 ;;
    -*)
      echo "ERROR [${PIPE}:${FLOW}]: '-' flags ($1) are not supported, use '--'"
      exit 1 ;;
    *)
      echo "Unknown argument: $1"
      shift ;;
  esac
done

# Usage Help -------------------------------------------------------------------
if [[ -z "${HELP}" ]]; then
  echo ''
  echo '------------------------------------------------------------------------'
  echo "TKNI: ${FCN_NAME}"
  echo '------------------------------------------------------------------------'
  echo '  --help                    display command help'
  echo '  --pi          <REQUIRED>  PI name, e.g., evanderplas'
  echo '  --project     <REQUIRED>  project name, preferrable camel case'
  echo '  --dir-project <REQUIRED>  project directory'
  echo '                              e.g., /data/x/projects/${PI}/${PROJECT}'
  echo '  --id          <REQUIRED>  file prefix, usually participant identifier'
  echo '                            string, e.g., sub-123_ses-20230111'
  echo '                            "all" will run all available participants'
  echo '  --idvars                  names of variables in standard participant.tsv'
  echo '  --idflag                  flags for BIDS-like filename'
  echo '  --workflows   <REQUIRED>  names of workflows to run'
  echo '  --<var-name>              converted to VAR_NAME for use in setting up'
  echo '                            and deploy tkni workflows on the ACRI-HPC'
  echo '  Note: "-" flags are not supported only "--"'
  echo ''
  NO_LOG=true
  exit 0
fi

# Check Required Inputs --------------------------------------------------------
if [[ -z ${WORKFLOWS} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] WORKFLOWS must be provided"
  echo -e "\te.g., --workflows \"AINIT,MALF,DPREP,DSCALE,FUNK\""
  exit 2
fi
if [[ -z ${PI} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] PI must be provided"
  exit 2
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] PROJECT must be provided"
  exit 2
fi
if [[ -z ${DIR_PROJECT} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] DIR_PROJECT must be provided"
  exit 2
fi
if [[ -z ${IDVARS} ]]; then IDVARS="participant_id,session_id"; fi
if [[ -z ${IDFLAG} ]]; then IDFLAG="sub,ses"; fi
if [[ -z ${ID} ]]; then ID="all"; fi

# establish job directory ------------------------------------------------------
if [[ -z ${DIR_JOB} ]]; then DIR_JOB=/home/${USER}/job/${PI}_${PROJECT}_tkniWORKFLOWS; fi
if [[ -z ${DIR_LOG} ]]; then DIR_LOG=/home/${USER}/log/${PI}_${PROJECT}_tkniWORKFLOWS; fi
mkdir -p ${DIR_JOB}
mkdir -p ${DIR_LOG}

# Loop over participants -------------------------------------------------------
N=2 # should be 1 but this works with the tsv output to make the code easier
if [[ ${ID,,} == "all" ]]; then N=$(wc -l ${DIR_PROJECT}/participants.tsv); fi
IDVARS=(${IDVARS//,/ })
IDFLAG=(${IDFLAG//,/ })

for (( i=1; i<${N}; i++ )); do
  if [[ ${ID,,} == "all" ]]; then
    unset IDPFX
    TVARS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f ${IDVARS[0]}))
    IDPFX="${IDFLAG[0]}-${TVARS[${i}]}"
    for (( j=0; j<${#IDVARS[@]}; j++ )); do
      TVARS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f ${IDVARS[${j}]}))
      IDPFX="${IDFLAG[${j}]}-${TVARS[${i}]}"
    done
  else
    IDPFX=${ID}
  fi

  # Write Job Scripts for Workflows ----------------------------------------------
  SLURM_SFX=${IDPFX}_${DATE_SUFFIX}

  ###############################################################################
  ## tkniAINIT - Initial Anatomical Processing
  ###############################################################################
  if [[ "${WORKFLOWS^^}" == *"AINIT"* ]]; then
    SLURM_AINIT=${DIR_JOB}/AINIT_${SLURM_SUFFIX}.slurm
    if [[ -z ${AINIT_NTHREADS} ]]; then AINIT_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_AINIT}
    echo "#SBATCH --output=${DIR_LOG}/AINIT_${SLURM_SUFFIX}.txt" >> ${SLURM_AINIT}
    echo "#SBATCH -p normal" >> ${SLURM_AINIT}
    echo "#SBATCH -q normal" >> ${SLURM_AINIT}
    echo "#SBATCH --nodes=1" >> ${SLURM_AINIT}
    echo "#SBATCH --ntasks=1" >> ${SLURM_AINIT}
    echo "#SBATCH --cpus-per-task=${AINIT_NTHREADS}" >> ${SLURM_AINIT}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_AINIT}
    echo "" >> ${SLURM_AINIT}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_AINIT}
    echo "" >> ${SLURM_AINIT}
    echo "# Load Neurocontainers ------" >> ${SLURM_AINIT}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_AINIT}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_AINIT}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_AINIT}
    echo "               \"synthstrip_7.4.1_20240913\" \\" >> ${SLURM_AINIT}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_AINIT}
    echo "" >> ${SLURM_AINIT}
    FSTR="${TKNIPIPES}/tkniAINIT.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${AINIT_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${AINIT_DIR_ID}"; fi
    if [[ -n ${AINIT_DIR_PROJECT} ]]; then  FSTR="${FSTR} --dir-project ${AINIT_DIR_PROJECT}"; fi
    if [[ -n ${AINIT_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${AINIT_DIR_SAVE}"; fi
    if [[ -n ${AINIT_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${AINIT_DIR_SCRATCH}"; fi
    if [[ -n ${AINIT_BASE_IMG} ]]; then     FSTR="${FSTR} --base-img ${AINIT_BASE_IMG}"; fi
    if [[ -n ${AINIT_BASE_MOD} ]]; then     FSTR="${FSTR} --base-mod ${AINIT_BASE_MOD}"; fi
    if [[ -n ${AINIT_ALIGN_MANUAL} ]]; then FSTR="${FSTR} --align-manual ${AINIT_ALIGN_MANUAL}"; fi
    if [[ -n ${AINIT_ALIGN_TO} ]]; then     FSTR="${FSTR} --align-to ${AINIT_ALIGN_TO}"; fi
    if [[ -n ${AINIT_FG_CLIP} ]]; then      FSTR="${FSTR} --fg-clip ${AINIT_FG_CLIP}"; fi
    if [[ -n ${AINIT_FORCE} ]]; then        FSTR="${FSTR} --force \\" >> ${SLURM_AINIT}; fi
    echo ${FSTR} >> ${SLURM_AINIT}
    echo "" >> ${SLURM_AINIT}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_AINIT}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_AINIT}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_AINIT}
    echo "" >> ${SLURM_AINIT}
  fi

  ###############################################################################
  ## tkniFSSYNTH - Freesurfer's recon-all-clinical
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"FSSYNTH"* ]]; then
    SLURM_FSSYNTH=${DIR_JOB}/FSSYNTH_${SLURM_SUFFIX}.slurm
    if [[ -z ${FSSYNTH_NTHREADS} ]]; then FSSYNTH_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_FSSYNTH}
    echo "#SBATCH --output=${DIR_LOG}/FSSYNTH_${SLURM_SUFFIX}.txt" >> ${SLURM_FSSYNTH}
    echo "#SBATCH -p normal" >> ${SLURM_FSSYNTH}
    echo "#SBATCH -q normal" >> ${SLURM_FSSYNTH}
    echo "#SBATCH --nodes=1" >> ${SLURM_FSSYNTH}
    echo "#SBATCH --ntasks=1" >> ${SLURM_FSSYNTH}
    echo "#SBATCH --cpus-per-task=${FSSYNTH_NTHREADS}" >> ${SLURM_FSSYNTH}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_FSSYNTH}
    echo "" >> ${SLURM_FSSYNTH}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_FSSYNTH}
    echo "" >> ${SLURM_FSSYNTH}
    echo "# Load Neurocontainers ------" >> ${SLURM_FSSYNTH}
    echo "ND_CONTAINERS=(\"ants_2.6.5_20260225\" \\" >> ${SLURM_FSSYNTH}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_FSSYNTH}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_FSSYNTH}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_FSSYNTH}
    echo "" >> ${SLURM_FSSYNTH}
    FSTR="${TKNIPIPES}/tkniFSSYNTH.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${FSSYNTH_DIR_ID} ]]; then      FSTR="${FSTR} --dir-id ${FSSYNTH_DIR_ID}"; fi
    if [[ -z ${FSSYNTH_IMAGE} ]]; then       FSTR="${FSTR} --image ${FSSYNTH_IMAGE}"; fi
    if [[ -z ${FSSYNTH_MOD} ]]; then         FSTR="${FSTR} --mod ${FSSYNTH_MOD}"; fi
    if [[ -z ${FSSYNTH_LABELS} ]]; then      FSTR="${FSTR} --labels ${FSSYNTH_LABELS}"; fi
    if [[ -z ${FSSYNTH_NTHREADS} ]]; then    FSTR="${FSTR} --nthreads ${FSSYNTH_NTHREADS}"; fi
    if [[ -z ${FSSYNTH_DIR_FS} ]]; then      FSTR="${FSTR} --dir-fs ${FSSYNTH_DIR_FS}"; fi
    if [[ -z ${FSSYNTH_DIR_SAVE} ]]; then    FSTR="${FSTR} --dir-save ${FSSYNTH_DIR_SAVE}"; fi
    if [[ -z ${FSSYNTH_DIR_SCRATCH} ]]; then FSTR="${FSTR} --dir-scratch ${FSSYNTH_DIR_SCRATCH}"; fi
    if [[ -z ${FSSYNTH_FORCE} ]]; then       FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_FSSYNTH}
    echo "" >> ${SLURM_FSSYNTH}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_FSSYNTH}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_FSSYNTH}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_FSSYNTH}
    echo "" >> ${SLURM_FSSYNTH}
  fi

  ###############################################################################
  ## tkniMALF - Multi-label Atlas Fusion
  ###############################################################################
   if [[ ${WORKFLOWS^^} == *"MALF"* ]]; then
    SLURM_MALF=${DIR_JOB}/MALF_${SLURM_SUFFIX}.slurm
    if [[ -z ${MALF_NTHREADS} ]]; then MALF_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_MALF}
    echo "#SBATCH --output=${DIR_LOG}/MALF_${SLURM_SUFFIX}.txt" >> ${SLURM_MALF}
    echo "#SBATCH -p normal" >> ${SLURM_MALF}
    echo "#SBATCH -q normal" >> ${SLURM_MALF}
    echo "#SBATCH --nodes=1" >> ${SLURM_MALF}
    echo "#SBATCH --ntasks=1" >> ${SLURM_MALF}
    echo "#SBATCH --cpus-per-task=${MALF_NTHREADS}" >> ${SLURM_MALF}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
    echo "# Load Neurocontainers ------" >> ${SLURM_MALF}
    echo "ND_CONTAINERS=(\"ants_2.6.5_20260225\" \\" >> ${SLURM_MALF}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_MALF}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_MALF}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
    FSTR="${TKNIPIPES}/tkniMALF.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${MALF_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${MALF_DIR_ID}"; fi
    if [[ -z ${MALF_IMAGE} ]]; then         FSTR="${FSTR} --image ${MALF_IMAGE}"; fi
    if [[ -z ${MALF_MOD} ]]; then           FSTR="${FSTR} --mod ${MALF_MOD}"; fi
    if [[ -z ${MALF_MASK} ]]; then          FSTR="${FSTR} --mask ${MALF_MASK}"; fi
    if [[ -z ${MALF_MASK_DIL} ]]; then      FSTR="${FSTR} --mask-dil ${MALF_MASK_DIL}"; fi
    if [[ -z ${MALF_ATLAS_NAME} ]]; then    FSTR="${FSTR} --atlas-name ${MALF_ATLAS_NAME}"; fi
    if [[ -z ${MALF_ATLAS_REF} ]]; then     FSTR="${FSTR} --atlas-ref ${MALF_ATLAS_REF}"; fi
    if [[ -z ${MALF_ATLAS_MASK} ]]; then    FSTR="${FSTR} --atlas-mask ${MALF_ATLAS_MASK}"; fi
    if [[ -z ${MALF_ATLAS_EX} ]]; then      FSTR="${FSTR} --atlas-ex ${MALF_ATLAS_EX}"; fi
    if [[ -z ${MALF_ATLAS_LABEL} ]]; then   FSTR="${FSTR} --atlas-label ${MALF_ATLAS_LABEL}"; fi
    if [[ -z ${MALF_ATLAS_DIL} ]]; then     FSTR="${FSTR} --atlas-dil ${MALF_ATLAS_DIL}"; fi
    if [[ -z ${MALF_NO_PREMASK} ]]; then    FSTR="${FSTR} --no-premask"; fi
    if [[ -z ${MALF_MASK_RESTRICT} ]]; then FSTR="${FSTR} --mask-restrict ${MALF_MASK_RESTRICT}"; fi
    if [[ -z ${MALF_NO_JAC} ]]; then        FSTR="${FSTR} --no-jac"; fi
    if [[ -z ${MALF_DIR_SAVE} ]]; then      FSTR="${FSTR} --dir-save ${MALF_DIR_SAVE}"; fi
    if [[ -z ${MALF_DIR_SCRATCH} ]]; then   FSTR="${FSTR} --dir-scratch ${MALF_SCRATCH}"; fi
    if [[ -z ${MALF_FORCE} ]]; then         FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_MALF}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_MALF}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
  fi

  ###############################################################################
  ## tkniMATS - Multi-Approach Tissue Segmentation
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"MATS"* ]]; then
    SLURM_MATS=${DIR_JOB}/MATS_${SLURM_SUFFIX}.slurm
    if [[ -z ${MATS_NTHREADS} ]]; then MATS_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_MATS}
    echo "#SBATCH --output=${DIR_LOG}/MATS_${SLURM_SUFFIX}.txt" >> ${SLURM_MATS}
    echo "#SBATCH -p normal" >> ${SLURM_MATS}
    echo "#SBATCH -q normal" >> ${SLURM_MATS}
    echo "#SBATCH --nodes=1" >> ${SLURM_MATS}
    echo "#SBATCH --ntasks=1" >> ${SLURM_MATS}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_MATS}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_MATS}
    echo "" >> ${SLURM_MATS}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_MATS}
    echo "" >> ${SLURM_MATS}
    echo "# Load Neurocontainers ------" >> ${SLURM_MATS}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_MATS}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_MATS}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_MATS}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_MATS}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_MATS}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_MATS}
    echo "" >> ${SLURM_MATS}
    FSTR="${TKNIPIPES}/tkniMATS.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${MATS_DIR_ID} ]]; then       FSTR="${FSTR} --dir-id ${MATS_DIR_ID}"; fi
    if [[ -z ${MATS_SRC_ANAT} ]]; then     FSTR="${FSTR} --src-anat ${MATS_SRC_ANAT}"; fi
    if [[ -z ${MATS_IMAGE} ]]; then        FSTR="${FSTR} --image ${MATS_IMAGE}"; fi
    if [[ -z ${MATS_MOD} ]]; then          FSTR="${FSTR} --mod ${MATS_MOD}"; fi
    if [[ -z ${MATS_MASK} ]]; then         FSTR="${FSTR} --mask ${MATS_MASK}"; fi
    if [[ -z ${MATS_MASK_DIL} ]]; then     FSTR="${FSTR} --mask-dil ${MATS_MASK_DIL}"; fi
    if [[ -z ${MATS_METHOD} ]]; then       FSTR="${FSTR} --method ${MATS_METHOD}"; fi
    if [[ -z ${MATS_ATLAS} ]]; then        FSTR="${FSTR} --atlas"; fi
    if [[ -z ${MATS_ROI} ]]; then          FSTR="${FSTR} --roi ${MATS_ROI}"; fi
    if [[ -z ${MATS_PROB} ]]; then         FSTR="${FSTR} --prob ${MATS_PROB}"; fi
    if [[ -z ${MATS_PRIOR} ]]; then        FSTR="${FSTR} --prior ${MATS_PRIOR}"; fi
    if [[ -z ${MATS_K_CLASS} ]]; then      FSTR="${FSTR} --k-class ${MATS_K_CLASS}"; fi
    if [[ -z ${MATS_WEIGHT_ANTS} ]]; then  FSTR="${FSTR} --weight-ants ${MATS_WEIGHT_ANTS}"; fi
    if [[ -z ${MATS_WEIGHT_5TT} ]]; then   FSTR="${FSTR} --weight-5tt ${MATS_WEIGHT_5TT}"; fi
    if [[ -z ${MATS_WEIGHT_SYNTH} ]]; then FSTR="${FSTR} --weight-synth ${MATS_WEIGHT_SYNTH}"; fi
    if [[ -z ${MATS_NO_KEEP} ]]; then      FSTR="${FSTR} --no-keep"; fi
    if [[ -z ${MATS_NO_THICKNESS} ]]; then FSTR="${FSTR} --no-thickness"; fi
    if [[ -z ${MATS_REFINE} ]]; then       FSTR="${FSTR} --refine ${MATS_REFINE}"; fi
    if [[ -z ${MATS_KEEP_PARTS} ]]; then   FSTR="${FSTR} --keep-parts"; fi
    if [[ -z ${MATS_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${MATS_DIR_SAVE}"; fi
    if [[ -z ${MATS_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${MATS_SCRATCH}"; fi
    if [[ -z ${MATS_FORCE} ]]; then        FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_MATS}
    echo "" >> ${SLURM_MATS}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_MATS}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_MATS}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_MATS}
    echo "" >> ${SLURM_MATS}
  fi

  ###############################################################################
  ## tkniAMOD - Additional Anatomical Modality Processing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"AMOD"* ]]; then
    SLURM_AMOD=${DIR_JOB}/AMOD_${SLURM_SUFFIX}.slurm
    if [[ -z ${AMOD_NTHREADS} ]]; then AMOD_NTHREADS=1; fi
    echo "#/bin/bash" > ${SLURM_AMOD}
    echo "#SBATCH --output=${DIR_LOG}/AMOD_${SLURM_SUFFIX}.txt" >> ${SLURM_AMOD}
    echo "#SBATCH -p normal" >> ${SLURM_AMOD}
    echo "#SBATCH -q normal" >> ${SLURM_AMOD}
    echo "#SBATCH --nodes=1" >> ${SLURM_AMOD}
    echo "#SBATCH --ntasks=1" >> ${SLURM_AMOD}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_AMOD}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_AMOD}
    echo "" >> ${SLURM_AMOD}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_AMOD}
    echo "" >> ${SLURM_AMOD}
    echo "# Load Neurocontainers ------" >> ${SLURM_AMOD}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_AMOD}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_AMOD}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_AMOD}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_AMOD}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_AMOD}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_AMOD}
    echo "" >> ${SLURM_AMOD}
    FSTR="${TKNIPIPES}/tkniAMOD.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${AMOD_DIR_ID} ]]; then       FSTR="${FSTR} --dir-id ${AMOD_DIR_ID}"; fi
    if [[ -z ${AMOD_BASE_MOD} ]]; then     FSTR="${FSTR} --base-mod ${AMOD_BMOD}"; fi
    if [[ -z ${AMOD_BASE_DIR} ]]; then     FSTR="${FSTR} --base-dir ${AMOD_BDIR}"; fi
    if [[ -z ${AMOD_BASE_IMAGE} ]]; then   FSTR="${FSTR} --base-image ${AMOD_BIMG}"; fi
    if [[ -z ${AMOD_BASE_MASK} ]]; then    FSTR="${FSTR} --base-mask ${AMOD_BMASK}"; fi
    if [[ -z ${AMOD_ADD_MOD} ]]; then      FSTR="${FSTR} --add-mod ${AMOD_AMOD}"; fi
    if [[ -z ${AMOD_ADD_DIR} ]]; then      FSTR="${FSTR} --add-dir ${AMOD_ADIR}"; fi
    if [[ -z ${AMOD_ADD_IMAGE} ]]; then    FSTR="${FSTR} --add-image ${AMOD_AIMG}"; fi
    if [[ -z ${AMOD_COREG_RECIPE} ]]; then FSTR="${FSTR} --coreg-recipe ${AMOD_COREG_RECIPE}"; fi
    if [[ -z ${AMOD_NORM_REF} ]]; then     FSTR="${FSTR} --norm-ref ${AMOD_NORM_REF}"; fi
    if [[ -z ${AMOD_NORM_XFM_MAT} ]]; then FSTR="${FSTR} --norm-mat ${AMOD_NORM_XFM_MAT}"; fi
    if [[ -z ${AMOD_NORM_XFM_SYN} ]]; then FSTR="${FSTR} --norm-syn ${AMOD_NORM_XFM_SYN}"; fi
    if [[ -z ${AMOD_TISSUE} ]]; then       FSTR="${FSTR} --tissue ${AMOD_TISSUE}"; fi
    if [[ -z ${AMOD_TISSUE_VAL} ]]; then   FSTR="${FSTR} --tissue-val ${AMOD_TISSUE_VAL}"; fi
    if [[ -z ${AMOD_WM_THRESH} ]]; then    FSTR="${FSTR} --wm-thresh ${AMOD_WM_THRESH}"; fi
    if [[ -z ${AMOD_DIR_XFM} ]]; then      FSTR="${FSTR} --dir-xfm ${AMOD_DIR_XFM}"; fi
    if [[ -z ${AMOD_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${AMOD_DIR_SAVE}"; fi
    if [[ -z ${AMOD_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${AMOD_SCRATCH}"; fi
    if [[ -z ${AMOD_NO_MYELIN} ]]; then    FSTR="${FSTR} --no-myelin"; fi
    if [[ -z ${AMOD_NO_ANOMALY} ]]; then   FSTR="${FSTR} --no-anomaly"; fi
    if [[ -z ${AMOD_NO_REORIENT} ]]; then  FSTR="${FSTR} --no-reorient"; fi
    if [[ -z ${AMOD_NO_DENOISE} ]]; then   FSTR="${FSTR} --no-denoise"; fi
    if [[ -z ${AMOD_NO_COREG} ]]; then     FSTR="${FSTR} --no-coreg"; fi
    if [[ -z ${AMOD_NO_DEBIAS} ]]; then    FSTR="${FSTR} --no-debias"; fi
    if [[ -z ${AMOD_NO_RESCALE} ]]; then   FSTR="${FSTR} --no-rescale"; fi
    if [[ -z ${AMOD_NO_NORM} ]]; then      FSTR="${FSTR} --no-norm"; fi
    if [[ -z ${AMOD_NO_OUTCOME} ]]; then   FSTR="${FSTR} --no-outcome"; fi
    if [[ -z ${AMOD_FORCE} ]]; then        FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_AMOD}
    echo "" >> ${SLURM_AMOD}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_AMOD}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_AMOD}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_AMOD}
    echo "" >> ${SLURM_AMOD}
  fi

  ###############################################################################
  ## tkniQALAS - QALAS Processing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"QALAS"* ]]; then
    SLURM_QALAS=${DIR_JOB}/QALAS_${SLURM_SUFFIX}.slurm
    if [[ -z ${QALAS_NTHREADS} ]]; then QALAS_NTHREADS=1; fi
    echo "#/bin/bash" > ${SLURM_QALAS}
    echo "#SBATCH --output=${DIR_LOG}/QALAS_${SLURM_SUFFIX}.txt" >> ${SLURM_QALAS}
    echo "#SBATCH -p normal" >> ${SLURM_QALAS}
    echo "#SBATCH -q normal" >> ${SLURM_QALAS}
    echo "#SBATCH --nodes=1" >> ${SLURM_QALAS}
    echo "#SBATCH --ntasks=1" >> ${SLURM_QALAS}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_QALAS}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_QALAS}
    echo "" >> ${SLURM_QALAS}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_QALAS}
    echo "" >> ${SLURM_QALAS}
    echo "# Load Neurocontainers ------" >> ${SLURM_QALAS}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_QALAS}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_QALAS}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_QALAS}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_QALAS}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_QALAS}
    echo "" >> ${SLURM_QALAS}
    FSTR="${TKNIPIPES}/tkniQALAS.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${QALAS_DIR_ID} ]]; then            FSTR="${FSTR} --dir-id ${QALAS_DIR_ID}"; fi
    if [[ -z ${QALAS_QALAS} ]]; then             FSTR="${FSTR} --qalas ${QALAS_QALAS}"; fi
    if [[ -z ${QALAS_OPT_TR} ]]; then            FSTR="${FSTR} --opt-tr ${QALAS_OPT_TR}"; fi
    if [[ -z ${QALAS_OPT_FA} ]]; then            FSTR="${FSTR} --opt-fa ${QALAS_OPT_FA}"; fi
    if [[ -z ${QALAS_OPT_TURBO} ]]; then         FSTR="${FSTR} --opt-turbo ${QALAS_OPT_TURBO}"; fi
    if [[ -z ${QALAS_OPT_ECHO_SPACING} ]]; then  FSTR="${FSTR} --opt-echo-spacing ${QALAS_OPT_ECHO_SPACING}"; fi
    if [[ -z ${QALAS_OPT_T2PREP} ]]; then        FSTR="${FSTR} --opt-t2prep ${QALAS_OPT_T2PREP}"; fi
    if [[ -z ${QALAS_OPT_T1INIT} ]]; then        FSTR="${FSTR} --opt-t1init ${QALAS_OPT_T1INIT}"; fi
    if [[ -z ${QALAS_OPT_M0INIT} ]]; then        FSTR="${FSTR} --opt-m0init ${QALAS_OPT_M0INIT}"; fi
    if [[ -z ${QALAS_B1} ]]; then                FSTR="${FSTR} --b1 ${QALAS_B1}"; fi
    if [[ -z ${QALAS_B1K} ]]; then               FSTR="${FSTR} --b1k ${QALAS_B1K}"; fi
    if [[ -z ${QALAS_NATIVE} ]]; then            FSTR="${FSTR} --native ${QALAS_NATIVE}"; fi
    if [[ -z ${QALAS_BRAIN} ]]; then             FSTR="${FSTR} --brain ${QALAS_BRAIN}"; fi
    if [[ -z ${QALAS_CSF} ]]; then               FSTR="${FSTR} --csf ${QALAS_CSF}"; fi
    if [[ -z ${QALAS_NO_DENOISE} ]]; then        FSTR="${FSTR} --no-denoise"; fi
    if [[ -z ${QALAS_NO_B1} ]]; then             FSTR="${FSTR} --no-b1"; fi
    if [[ -z ${QALAS_NO_N4} ]]; then             FSTR="${FSTR} --do-n4"; fi
    if [[ -z ${QALAS_NO_NORM} ]]; then           FSTR="${FSTR} --no-norm"; fi
    if [[ -z ${QALAS_ATLAS} ]]; then             FSTR="${FSTR} --atlas ${QALAS_ATLAS}"; fi
    if [[ -z ${QALAS_ATLAS_XFM} ]]; then         FSTR="${FSTR} --atlas-xfm ${QALAS_ATLAS_XFM}"; fi
    if [[ -z ${QALAS_SYNTH} ]]; then             FSTR="${FSTR} --synth ${QALAS_SYNTH}"; fi
    if [[ -z ${QALAS_DIR_PROJECT} ]]; then       FSTR="${FSTR} --dir-project ${QALAS_DIR_PROJECT}"; fi
    if [[ -z ${QALAS_DIR_SAVE} ]]; then          FSTR="${FSTR} --dir-save ${QALAS_DIR_SAVE}"; fi
    if [[ -z ${QALAS_DIR_SCRATCH} ]]; then       FSTR="${FSTR} --dir-scratch ${QALAS_DIR_SCRATCH}"; fi
    if [[ -z ${QALAS_FORCE} ]]; then             FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_QALAS}
    echo "" >> ${SLURM_QALAS}
    if [[ -z ${QALAS_NO_MYELIN} ]]; then
      TDIR=${DIR_PROJECT}
      if [[ -z ${QALAS_DIR_PROJECT} ]]; then TDIR=${QALAS_DIR_PROJECT}; fi
      if [[ -z ${QALAS_DIR_SAVE} ]]; then TDIR=${QALAS_DIR_SAVE}; fi
      echo "mapMyelin --t1 ${TDIR}/anat/native_synth/${IDPFX}_acq-GRE_synthT1w.nii.gz \\" >> ${SLURM_QALAS}
      echo "  --t2 ${TDIR}/anat/native_synth/${IDPFX}_acq-FSE_synthT2w.nii.gz \\" >> ${SLURM_QALAS}
      echo "  --label ${TDIR}/anat/label/${IDPFX}_label-tissue.nii.gz --label-vals \"1x2x4\" \\" >> ${SLURM_QALAS}
      echo "  --dir-save ${TDIR}/anat/outcomes/myelin --prefix ${IDPFX}" >> ${SLURM_QALAS}
      echo "mkdir -p ${TDIR}/anat/outcomes/myelin_reg-HCPYAX" >> ${SLURM_QALAS}
      if [[ -z ${QALAS_DIR_ID} ]]; then
        TSUB=$(getField -i ${IDPFX} -f sub)
        TSES=$(getField -i ${IDPFX} -f ses)
        IDDIR=sub-${TSUB}
        if [[ -n ${TSES} ]]; then
          IDDIR="${IDDIR}/ses-${TSES}"
        fi
      else
        IDDIR=${QALAS_DIR_ID}
      fi
      echo "antsApplyTransforms -d 3 -n BSpline[3] \\" >> ${SLURM_QALAS}
      echo "  -i ${TDIR}/anat/outcomes/myelin/${IDPFX}_myelin.nii.gz \\" >> ${SLURM_QALAS}
      echo "  -o ${TDIR}/anat/outcomes/myelin_reg-HCPYAX/${IDPFX}_reg-HCPYAX_myelin.nii.gz \\" >> ${SLURM_QALAS}
      echo "  -r ${TDIR}/anat/reg_HCPYAX/${IDPFX}_reg-HCPYAX_T1w.nii.gz \\" >> ${SLURM_QALAS}
      echo "  -t identity -t ${TDIR}/xfm/${IDDIR}/${IDPFX}_from-native_to-HCPYAX_xfm-syn.nii.gz \\" >> ${SLURM_QALAS}
      echo "  -t ${TDIR}/xfm/${IDDIR}/${IDPFX}_from-native_to-HCPYAX_xfm-affine.mat" >> ${SLURM_QALAS}
      echo "" >> ${SLURM_QALAS}
    fi


    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_QALAS}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_QALAS}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_QALAS}
    echo "" >> ${SLURM_QALAS}
  fi

  ###############################################################################
  ## tkniDPREP - Diffusion Image Preprocessing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"DPREP"* ]]; then
    SLURM_DPREP=${DIR_JOB}/DPREP_${SLURM_SUFFIX}.slurm
    if [[ -z ${DPREP_NTHREADS} ]]; then DPREP_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_DPREP}
    echo "#SBATCH --output=${DIR_LOG}/DPREP_${SLURM_SUFFIX}.txt" >> ${SLURM_DPREP}
    echo "#SBATCH -p normal" >> ${SLURM_DPREP}
    echo "#SBATCH -q normal" >> ${SLURM_DPREP}
    echo "#SBATCH --nodes=1" >> ${SLURM_DPREP}
    echo "#SBATCH --ntasks=1" >> ${SLURM_DPREP}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_DPREP}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_DPREP}
    echo "" >> ${SLURM_DPREP}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_DPREP}
    echo "" >> ${SLURM_DPREP}
    echo "# Load Neurocontainers ------" >> ${SLURM_DPREP}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_DPREP}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_DPREP}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_DPREP}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_DPREP}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_DPREP}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_DPREP}
    echo "" >> ${SLURM_DPREP}
    FSTR="${TKNIPIPES}/tkniDPREP.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${DPREP_DIR_ID} ]]; then         FSTR="${FSTR} --dir-id ${DPREP_DIR_ID}"; fi
    if [[ -z ${DPREP_IMAGE_DWI} ]]; then      FSTR="--image-dwi ${DPREP_IMAGE_DWI}"; fi
    if [[ -z ${DPREP_IMAGE_AP} ]]; then       FSTR="--image-ap ${DPREP_IMAGE_AP}"; fi
    if [[ -z ${DPREP_IMAGE_PA} ]]; then       FSTR="--image-pa ${DPREP_IMAGE_PA}"; fi
    if [[ -z ${DPREP_IMAGE_ANAT} ]]; then     FSTR="--image-anat ${DPREP_IMAGE_ANAT}"; fi
    if [[ -z ${DPREP_MASK_BRAIN} ]]; then     FSTR="--mask-brain ${DPREP_MASK_BRAIN}"; fi
    if [[ -z ${DPREP_MASK_DIL} ]]; then       FSTR="--mask-dil ${DPREP_MASK_DIL}"; fi
    if [[ -z ${DPREP_MASK_B0_METHOD} ]]; then FSTR="--mask-b0-method ${DPREP_MASK_B0_METHOD}"; fi
    if [[ -z ${DPREP_RPENONE} ]]; then        FSTR="--rpenone"; fi
    if [[ -z ${DPREP_DIR_ANAT} ]]; then       FSTR="--dir-anat ${DPREP_DIR_ANAT}"; fi
    if [[ -z ${DPREP_DIR_DWI} ]]; then        FSTR="--dir-dwi ${DPREP_DIR_DWI}"; fi
    if [[ -z ${DPREP_DIR_XFM} ]]; then        FSTR="--dir-xfm ${DPREP_DIR_XFM}"; fi
    if [[ -z ${DPREP_DIR_MRTRIX} ]]; then     FSTR="--dir-mrtrix ${DPREP_DIR_MRTRIX}"; fi
    if [[ -z ${DPREP_DIR_PROJECT} ]]; then    FSTR="${FSTR} --dir-scratch ${DPREP_DIR_PROJECT}"; fi
    if [[ -z ${DPREP_DIR_SAVE} ]]; then       FSTR="${FSTR} --dir-save ${DPREP_DIR_SAVE}"; fi
    if [[ -z ${DPREP_DIR_SCRATCH} ]]; then    FSTR="${FSTR} --dir-scratch ${DPREP_DIR_SCRATCH}"; fi
    if [[ -z ${DPREP_FORCE} ]]; then          FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_DPREP}
    echo "" >> ${SLURM_DPREP}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_DPREP}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_DPREP}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_DPREP}
    echo "" >> ${SLURM_DPREP}
  fi

  ###############################################################################
  ## tkniDSCALE - Diffusion Scalars
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"DSCALE"* ]]; then
    SLURM_DSCALE=${DIR_JOB}/DSCALE_${SLURM_SUFFIX}.slurm
    if [[ -z ${DSCALE_NTHREADS} ]]; then DSCALE_NTHREADS=1; fi
    echo "#/bin/bash" > ${SLURM_DSCALE}
    echo "#SBATCH --output=${DIR_LOG}/DSCALE_${SLURM_SUFFIX}.txt" >> ${SLURM_DSCALE}
    echo "#SBATCH -p normal" >> ${SLURM_DSCALE}
    echo "#SBATCH -q normal" >> ${SLURM_DSCALE}
    echo "#SBATCH --nodes=1" >> ${SLURM_DSCALE}
    echo "#SBATCH --ntasks=1" >> ${SLURM_DSCALE}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_DSCALE}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_DSCALE}
    echo "" >> ${SLURM_DSCALE}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_DSCALE}
    echo "" >> ${SLURM_DSCALE}
    echo "# Load Neurocontainers ------" >> ${SLURM_DSCALE}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_DSCALE}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_DSCALE}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_DSCALE}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_DSCALE}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_DSCALE}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_DSCALE}
    echo "" >> ${SLURM_DSCALE}
    FSTR="${TKNIPIPES}/tkniDSCALE.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${DSCALE_DIR_ID} ]]; then      FSTR="${FSTR} --dir-id ${DSCALE_DIR_ID}"; fi
    if [[ -z ${DSCALE_IMAGE_DWI} ]]; then   FSTR="${FSTR} --image-dwi ${DSCALE_IMAGE_DWI}"; fi
    if [[ -z ${DSCALE_MASK_ROI} ]]; then    FSTR="${FSTR} --mask-roi ${DSCALE_MASK_ROI}"; fi
    if [[ -z ${DSCALE_NO_SCALAR} ]]; then   FSTR="${FSTR} --no-scalar"; fi
    if [[ -z ${DSCALE_NO_TENSOR} ]]; then   FSTR="${FSTR} --no-tensor"; fi
    if [[ -z ${DSCALE_NO_KURTOSIS} ]]; then FSTR="${FSTR} --no-kurtosis"; fi
    if [[ -z ${DSCALE_DO_B0} ]]; then       FSTR="${FSTR} --do-b0"; fi
    if [[ -z ${DSCALE_DIR_MRTRIX} ]]; then  FSTR="${FSTR} --dir-mrtrix ${DSCALE_DIR_MRTRIX}"; fi
    if [[ -z ${DSCALE_DIR_SAVE} ]]; then    FSTR="${FSTR} --dir-save ${DSCALE_DIR_SAVE}"; fi
    if [[ -z ${DSCALE_DIR_SCRATCH} ]]; then FSTR="${FSTR} --dir-scratch ${DSCALE_SCRATCH}"; fi
    if [[ -z ${DSCALE_FORCE} ]]; then       FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_DSCALE}
    echo "" >> ${SLURM_DSCALE}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_DSCALE}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_DSCALE}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_DSCALE}
    echo "" >> ${SLURM_DSCALE}
  fi

  ###############################################################################
  ## tkniMICRO - Diffusion Microstructure, NODDI and SANDI
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"DMICRO"* ]]; then
    SLURM_DMICRO=${DIR_JOB}/DMICRO_${SLURM_SUFFIX}.slurm
    if [[ -z ${DMICRO_NTHREADS} ]]; then DMICRO_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_DMICRO}
    echo "#SBATCH --output=${DIR_LOG}/DMICRO_${SLURM_SUFFIX}.txt" >> ${SLURM_DMICRO}
    echo "#SBATCH -p normal" >> ${SLURM_DMICRO}
    echo "#SBATCH -q normal" >> ${SLURM_DMICRO}
    echo "#SBATCH --nodes=1" >> ${SLURM_DMICRO}
    echo "#SBATCH --ntasks=1" >> ${SLURM_DMICRO}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_DMICRO}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_DMICRO}
    echo "" >> ${SLURM_DMICRO}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_DMICRO}
    echo "" >> ${SLURM_DMICRO}
    echo "# Load Neurocontainers ------" >> ${SLURM_DMICRO}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_DMICRO}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_DMICRO}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_DMICRO}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_DMICRO}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_DMICRO}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_DMICRO}
    echo "" >> ${SLURM_DMICRO}
    FSTR="${TKNIPIPES}/tkniDMICRO.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${DMICRO_DIR_ID} ]]; then           FSTR="${FSTR} --dir-id ${DMICRO_DIR_ID}"; fi
    if [[ -z ${DMICRO_DIR_DWI} ]]; then          FSTR="${FSTR} --dir-dwi ${DMICRO_DIR_DWI}"; fi
    if [[ -z ${DMICRO_BVAL} ]]; then             FSTR="${FSTR} --bval ${DMICRO_BVAL}"; fi
    if [[ -z ${DMICRO_BVEC} ]]; then             FSTR="${FSTR} --bvec ${DMICRO_BVEC}"; fi
    if [[ -z ${DMICRO_DWI} ]]; then              FSTR="${FSTR} --dwi ${DMICRO_DWI}"; fi
    if [[ -z ${DMICRO_MASK} ]]; then             FSTR="${FSTR} --mask ${DMICRO_MASK}"; fi
    if [[ -z ${DMICRO_NO_NODDI} ]]; then         FSTR="${FSTR} --no-noddi"; fi
    if [[ -z ${DMICRO_NO_SANDI} ]]; then         FSTR="${FSTR} --no-sandi"; fi
    if [[ -z ${DMICRO_NODDI_DPAR} ]]; then       FSTR="${FSTR} --noddi-dpar ${DMICRO_NODDI_DPAR}"; fi
    if [[ -z ${DMICRO_NODDI_DISO} ]]; then       FSTR="${FSTR} --noddi-diso ${DMICRO_NODDI_DISO}"; fi
    if [[ -z ${DMICRO_NODDI_ISEXVIVO} ]]; then   FSTR="${FSTR} --noddi-isexvivo"; fi
    if [[ -z ${DMICRO_NODDI_ICVFS} ]]; then      FSTR="${FSTR} --noddi-icvfs ${DMICRO_NODDI_ICVFS}"; fi
    if [[ -z ${DMICRO_NODDI_ICODS} ]]; then      FSTR="${FSTR} --noddi-icods ${DMICRO_NODDI_ICODS}"; fi
    if [[ -z ${DMICRO_SANDI_DELTA} ]]; then      FSTR="${FSTR} --sandi-delta ${DMICRO_SANDI_DELTA}"; fi
    if [[ -z ${DMICRO_SANDI_SMALLDELTA} ]]; then FSTR="${FSTR} --sandi-smalldelta ${DMICRO_SANDI_SMALLDELTA}"; fi
    if [[ -z ${DMICRO_SANDI_TE} ]]; then         FSTR="${FSTR} --sandi-te ${DMICRO_SANDI_TE}"; fi
    if [[ -z ${DMICRO_SANDI_DIS} ]]; then        FSTR="${FSTR} --sandi-dis ${DMICRO_SANDI_DIS}"; fi;
    if [[ -z ${DMICRO_SANDI_RS} ]]; then         FSTR="${FSTR} --sandi-rs ${DMICRO_SANDI_RS}"; fi
    if [[ -z ${DMICRO_SANDI_DIN} ]]; then        FSTR="${FSTR} --sandi-din ${DMICRO_SANDI_DIN}"; fi
    if [[ -z ${DMICRO_SANDI_DISOS} ]]; then      FSTR="${FSTR} --sandi-disos ${DMICRO_SANDI_DISOS}"; fi
    if [[ -z ${DMICRO_SANDI_LAMBDA1} ]]; then    FSTR="${FSTR} --sandi-lambda1 ${DMICRO_SANDI_LAMBDA1}"; fi
    if [[ -z ${DMICRO_SANDI_LAMBDA2} ]]; then    FSTR="${FSTR} --sandi-lambda2 ${DMICRO_SANDI_LAMBDA2}"; fi
    if [[ -z ${DMICRO_NATIVE} ]]; then           FSTR="${FSTR} --native ${DMICRO_NATIVE}"; fi
    if [[ -z ${DMICRO_DIR_SAVE} ]]; then         FSTR="${FSTR} --dir-save ${DMICRO_DIR_SAVE}"; fi
    if [[ -z ${DMICRO_DIR_SCRATCH} ]]; then      FSTR="${FSTR} --dir-scratch ${DMICRO_SCRATCH}"; fi
    if [[ -z ${DMICRO_FORCE} ]]; then            FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_DMICRO}
    echo "" >> ${SLURM_DMICRO}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_DMICRO}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_DMICRO}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_DMICRO}
    echo "" >> ${SLURM_DMICRO}
  fi

  ###############################################################################
  ## tkniDTRACT - Diffusion Tractography
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"DTRACT"* ]]; then
    SLURM_DTRACT=${DIR_JOB}/DTRACT_${SLURM_SUFFIX}.slurm
    if [[ -z ${DTRACT_NTHREADS} ]]; then DTRACT_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_DTRACT}
    echo "#SBATCH --output=${DIR_LOG}/DTRACT_${SLURM_SUFFIX}.txt" >> ${SLURM_DTRACT}
    echo "#SBATCH -p normal" >> ${SLURM_DTRACT}
    echo "#SBATCH -q normal" >> ${SLURM_DTRACT}
    echo "#SBATCH --nodes=1" >> ${SLURM_DTRACT}
    echo "#SBATCH --ntasks=1" >> ${SLURM_DTRACT}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_DTRACT}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_DTRACT}
    echo "" >> ${SLURM_DTRACT}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_DTRACT}
    echo "" >> ${SLURM_DTRACT}
    echo "# Load Neurocontainers ------" >> ${SLURM_DTRACT}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_DTRACT}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_DTRACT}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_DTRACT}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_DTRACT}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_DTRACT}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_DTRACT}
    echo "" >> ${SLURM_DTRACT}
    FSTR="${TKNIPIPES}/tkniDTRACT.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${DTRACT_DIR_ID} ]]; then            FSTR="${FSTR} --dir-id ${DTRACT_DIR_ID}"; fi
    if [[ -z ${DTRACT_IMAGE_DWI} ]]; then         FSTR="${FSTR} --image-dwi ${DTRACT_IMAGE_DWI}"; fi
    if [[ -z ${DTRACT_POST_5TT} ]]; then          FSTR="${FSTR} --posterior-5tt ${DTRACT_POST_5TT}"; fi
    if [[ -z ${DTRACT_IMAGE_T1_DWI} ]]; then      FSTR="${FSTR} --image-t1-dwi ${DTRACT_IMAGE_T1_DWI}"; fi
    if [[ -z ${DTRACT_IMAGE_T1_NATIVE} ]]; then   FSTR="${FSTR} --image-t1-native ${DTRACT_IMAGE_T1_NATIVE}"; fi
    if [[ -z ${DTRACT_MASK_BRAIN_NATIVE} ]]; then FSTR="${FSTR} --mask-brain-native ${DTRACT_MASK_BRAIN_NATIVE}"; fi
    if [[ -z ${DTRACT_LABEL} ]]; then             FSTR="${FSTR} --label ${DTRACT_LABEL}"; fi
    if [[ -z ${DTRACT_LUT_ORIG} ]]; then          FSTR="${FSTR} --lut-orig ${DTRACT_LUT_ORIG}"; fi
    if [[ -z ${DTRACT_LUT_SORT} ]]; then          FSTR="${FSTR} --lut-sort ${DTRACT_LUT_SORT}"; fi
    if [[ -z ${DTRACT_KEEP_10MIL} ]]; then        FSTR="${FSTR} --keep-10mil"; fi
    if [[ -z ${DTRACT_NO_AFD} ]]; then            FSTR="${FSTR} --no-afd"; fi
    if [[ -z ${DTRACT_NO_TRACT} ]]; then          FSTR="${FSTR} --no-tract"; fi
    if [[ -z ${DTRACT_DIR_SAVE} ]]; then          FSTR="${FSTR} --dir-save ${DTRACT_DIR_SAVE}"; fi
    if [[ -z ${DTRACT_DIR_SCRATCH} ]]; then       FSTR="${FSTR} --dir-scratch ${DTRACT_SCRATCH}"; fi
    if [[ -z ${DTRACT_FORCE} ]]; then             FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_DTRACT}
    echo "" >> ${SLURM_DTRACT}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_DTRACT}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_DTRACT}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_DTRACT}
    echo "" >> ${SLURM_DTRACT}
  fi

  ###############################################################################
  ## tkniPCASL - Cerebral Blood Flow from PCASL
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"PCASL"* ]]; then
    SLURM_PCASL=${DIR_JOB}/PCASL_${SLURM_SUFFIX}.slurm
    if [[ -z ${PCASL_NTHREADS} ]]; then PCASL_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_PCASL}
    echo "#SBATCH --output=${DIR_LOG}/PCASL_${SLURM_SUFFIX}.txt" >> ${SLURM_PCASL}
    echo "#SBATCH -p normal" >> ${SLURM_PCASL}
    echo "#SBATCH -q normal" >> ${SLURM_PCASL}
    echo "#SBATCH --nodes=1" >> ${SLURM_PCASL}
    echo "#SBATCH --ntasks=1" >> ${SLURM_PCASL}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_PCASL}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_PCASL}
    echo "" >> ${SLURM_PCASL}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_PCASL}
    echo "" >> ${SLURM_PCASL}
    echo "# Load Neurocontainers ------" >> ${SLURM_PCASL}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_PCASL}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_PCASL}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_PCASL}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_PCASL}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_PCASL}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_PCASL}
    echo "" >> ${SLURM_PCASL}
    FSTR="${TKNIPIPES}/tkniPCASL.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${PCASL_DIR_ID} ]]; then         FSTR="${FSTR} --dir-id ${PCASL_DIR_ID}"; fi
    if [[ -z ${PCASL_ASL} ]]; then            FSTR="${FSTR} --asl ${PCASL_ASL}"; fi
    if [[ -z ${PCASL_ASL_TYPE} ]]; then       FSTR="${FSTR} --asl-type ${PCASL_ASL_TYPE}"; fi
    if [[ -z ${PCASL_ASL_JSON} ]]; then       FSTR="${FSTR} --asl-json ${PCASL_ASL_JSON}"; fi
    if [[ -z ${PCASL_ASL_CTL} ]]; then        FSTR="${FSTR} --asl-ctl ${PCASL_ASL_CTL}"; fi
    if [[ -z ${PCASL_ASL_M0} ]]; then         FSTR="${FSTR} --asl-m0 ${PCASL_ASL_M0}"; fi
    if [[ -z ${PCASL_PWI} ]]; then            FSTR="${FSTR} --pwi ${PCASL_PWI}"; fi
    if [[ -z ${PCASL_PWI_LABEL} ]]; then      FSTR="${FSTR} --pwi-label ${PCASL_PWI_LABEL}"; fi
    if [[ -z ${PCASL_NATIVE} ]]; then         FSTR="${FSTR} --native ${PCASL_NATIVE}"; fi
    if [[ -z ${PCASL_NATIVE_MASK} ]]; then    FSTR="${FSTR} --native-mask ${PCASL_NATIVE_MASK}"; fi
    if [[ -z ${PCASL_NATIVE_MOD} ]]; then     FSTR="${FSTR} --native-mod ${PCASL_NATIVE_MOD}"; fi
    if [[ -z ${PCASL_LABEL} ]]; then          FSTR="${FSTR} --label ${PCASL_LABEL}"; fi
    if [[ -z ${PCASL_OPT_BRAINBLOOD} ]]; then FSTR="${FSTR} --opt-brainblood ${PCASL_OPT_BRAINBLOOD}"; fi
    if [[ -z ${PCASL_OPT_T1BLOOD} ]]; then    FSTR="${FSTR} --opt-t1blood ${PCASL_OPT_T1BLOOD}"; fi
    if [[ -z ${PCASL_OPT_EFFICIENCY} ]]; then FSTR="${FSTR} --opt-efficiency ${PCASL_OPT_EFFICIENCY}"; fi
    if [[ -z ${PCASL_OPT_DURATION} ]]; then   FSTR="${FSTR} --opt-duration ${PCASL_OPT_DURATION}"; fi
    if [[ -z ${PCASL_OPT_DELAY} ]]; then      FSTR="${FSTR} --opt-delay ${PCASL_OPT_DELAY}"; fi
    if [[ -z ${PCASL_COREG_RECIPE} ]]; then   FSTR="${FSTR} --coreg-recipe ${PCASL_COREG_RECIPE}"; fi
    if [[ -z ${PCASL_DIR_XFM} ]]; then        FSTR="${FSTR} --dir-xfm ${PCASL_DIR_XFM}"; fi
    if [[ -z ${PCASL_NORM_REF} ]]; then       FSTR="${FSTR} --norm-ref ${PCASL_NORM_REF}"; fi
    if [[ -z ${PCASL_NORM_XFM_MAT} ]]; then   FSTR="${FSTR} --norm-xfm-mat ${PCASL_NORM_XFM_MAT}"; fi
    if [[ -z ${PCASL_NORM_XFM_SYN} ]]; then   FSTR="${FSTR} --norm-xfm-syn ${PCASL_NORM_XFM_SYN}"; fi
    if [[ -z ${PCASL_NO_PWI} ]]; then         FSTR="${FSTR} --no-pwi"; fi
    if [[ -z ${PCASL_NO_REORIENT} ]]; then    FSTR="${FSTR} --no-reorient"; fi
    if [[ -z ${PCASL_NO_DENOISE} ]]; then     FSTR="${FSTR} --no-denoise"; fi
    if [[ -z ${PCASL_NO_DEBIAS} ]]; then      FSTR="${FSTR} --no-debias"; fi
    if [[ -z ${PCASL_NO_NORM} ]]; then        FSTR="${FSTR} --no-norm"; fi
    if [[ -z ${PCASL_NO_SUMMARY} ]]; then     FSTR="${FSTR} --no-summary"; fi
    if [[ -z ${PCASL_DIR_SAVE} ]]; then       FSTR="${FSTR} --dir-save ${PCASL_DIR_SAVE}"; fi
    if [[ -z ${PCASL_DIR_SCRATCH} ]]; then    FSTR="${FSTR} --dir-scratch ${PCASL_SCRATCH}"; fi
    if [[ -z ${PCASL_FORCE} ]]; then          FSTR="${FSTR} --force ${PCASL_}"; fi
    echo ${FSTR} >> ${SLURM_PCASL}
    echo "" >> ${SLURM_PCASL}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_PCASL}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_PCASL}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_PCASL}
    echo "" >> ${SLURM_PCASL}
  fi

  ###############################################################################
  ## tkniFUNK - BOLD Functional Preprocessing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"FUNK"* ]]; then
    SLURM_FUNK=${DIR_JOB}/FUNK_${SLURM_SUFFIX}.slurm
    if [[ -z ${FUNK_NTHREADS} ]]; then FUNK_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_FUNK}
    echo "#SBATCH --output=${DIR_LOG}/FUNK_${SLURM_SUFFIX}.txt" >> ${SLURM_FUNK}
    echo "#SBATCH -p normal" >> ${SLURM_FUNK}
    echo "#SBATCH -q normal" >> ${SLURM_FUNK}
    echo "#SBATCH --nodes=1" >> ${SLURM_FUNK}
    echo "#SBATCH --ntasks=1" >> ${SLURM_FUNK}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_FUNK}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_FUNK}
    echo "" >> ${SLURM_FUNK}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_FUNK}
    echo "" >> ${SLURM_FUNK}
    echo "# Load Neurocontainers ------" >> ${SLURM_FUNK}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_FUNK}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_FUNK}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_FUNK}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_FUNK}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_FUNK}
    echo "" >> ${SLURM_FUNK}
    FSTR="${TKNIPIPES}/tkniFUNK.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${FUNK_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${FUNK_DIR_ID}"; fi
    if [[ -z ${FUNK_TS} ]]; then            FSTR="${FSTR} --ts ${FUNK_TS}"; fi;
    if [[ -z ${FUNK_BEX_MODE} ]]; then      FSTR="${FSTR} --bex-mode ${FUNK_BEX_MODE}"; fi
    if [[ -z ${FUNK_BEX_CLFRAC} ]]; then    FSTR="${FSTR} --bex-clfrac ${FUNK_BEX_CLFRAC}"; fi;
    if [[ -z ${FUNK_DO_DENOISE} ]]; then    FSTR="${FSTR} --do-denoise"; fi
    if [[ -z ${FUNK_NO_CAT_RUNS} ]]; then   FSTR="${FSTR} --no-cat-runs"; fi
    if [[ -z ${FUNK_KEEP_RUNS} ]]; then     FSTR="${FSTR} --keep-runs"; fi
    if [[ -z ${FUNK_NO_SAVE_CLEAN} ]]; then FSTR="${FSTR} --no-save-clean"; fi
    if [[ -z ${FUNK_NO_NORM} ]]; then       FSTR="${FSTR} --no-norm"; fi
    if [[ -z ${FUNK_SPIKE_THRESH} ]]; then  FSTR="${FSTR} --spike-thresh ${FUNK_SPIKE_THRESH}"; fi;
    if [[ -z ${FUNK_NO_CENSOR} ]]; then     FSTR="${FSTR} --no-censor"; fi
    if [[ -z ${FUNK_DO_GSR} ]]; then        FSTR="${FSTR} --do-gsr"; fi
    if [[ -z ${FUNK_DO_GMR} ]]; then        FSTR="${FSTR} --do-gmr"; fi
    if [[ -z ${FUNK_ANAT} ]]; then          FSTR="${FSTR} --anat ${FUNK_ANAT}"; fi
    if [[ -z ${FUNK_ANAT_MASK} ]]; then     FSTR="${FSTR} --anat-mask ${FUNK_ANAT_MASK}"; fi
    if [[ -z ${FUNK_ANAT_SEG} ]]; then      FSTR="${FSTR} --anat-seg ${FUNK_ANAT_SEG}"; fi
    if [[ -z ${FUNK_VAL_CSF} ]]; then       FSTR="${FSTR} --val-csf ${FUNK_VAL_CSF}"; fi
    if [[ -z ${FUNK_VAL_WM} ]]; then        FSTR="${FSTR} --val-wm ${FUNK_VAL_WM}"; fi
    if [[ -z ${FUNK_SEG_EROSION} ]]; then   FSTR="${FSTR} --seg-erosion ${FUNK_SEG_ME}"; fi;
    if [[ -z ${FUNK_COMPCORR_N} ]]; then    FSTR="${FSTR} --compcorr-n ${FUNK_COMPCORR_N}"; fi
    if [[ -z ${FUNK_BANDPASS_HI} ]]; then   FSTR="${FSTR} --bandpass-hi ${FUNK_BP_HI}"; fi
    if [[ -z ${FUNK_BANDPASS_LO} ]]; then   FSTR="${FSTR} --bandpass-lo ${FUNK_BP_LO}"; fi
    if [[ -z ${FUNK_SPACE_COREG} ]]; then   FSTR="${FSTR} --space-coreg ${FUNK_SPACE_COREG}"; fi
    if [[ -z ${FUNK_NORM_REF} ]]; then      FSTR="${FSTR} --norm-ref ${FUNK_NORM_REF}"; fi
    if [[ -z ${FUNK_NORM_XFM} ]]; then      FSTR="${FSTR} --norm-xfm ${FUNK_NORM_XFM}"; fi
    if [[ -z ${FUNK_SPACE_NORM} ]]; then    FSTR="${FSTR} --space-norm ${FUNK_SPACE_NORM}"; fi
    if [[ -z ${FUNK_DIR_XFM} ]]; then       FSTR="${FSTR} --dir-xfm ${FUNK_DIR_XFM}"; fi
    if [[ -z ${FUNK_DIR_SAVE} ]]; then      FSTR="${FSTR} --dir-save ${FUNK_DIR_SAVE}"; fi
    if [[ -z ${FUNK_DIR_SCRATCH} ]]; then   FSTR="${FSTR} --dir-scratch ${FUNK_SCRATCH}"; fi
    if [[ -z ${FUNK_FORCE} ]]; then         FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_FUNK}
    echo "" >> ${SLURM_FUNK}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_FUNK}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_FUNK}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_FUNK}
    echo "" >> ${SLURM_FUNK}
  fi

  ###############################################################################
  ## tkniFCON - Functional Connectivity
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"FCON"* ]]; then
    SLURM_FCON=${DIR_JOB}/FCON_${SLURM_SUFFIX}.slurm
    if [[ -z ${FCON_NTHREADS} ]]; then FCON_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_FCON}
    echo "#SBATCH --output=${DIR_LOG}/FCON_${SLURM_SUFFIX}.txt" >> ${SLURM_FCON}
    echo "#SBATCH -p normal" >> ${SLURM_FCON}
    echo "#SBATCH -q normal" >> ${SLURM_FCON}
    echo "#SBATCH --nodes=1" >> ${SLURM_FCON}
    echo "#SBATCH --ntasks=1" >> ${SLURM_FCON}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_FCON}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_FCON}
    echo "" >> ${SLURM_FCON}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_FCON}
    echo "" >> ${SLURM_FCON}
    echo "# Load Neurocontainers ------" >> ${SLURM_FCON}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_FCON}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_FCON}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_FCON}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_FCON}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_FCON}
    echo "" >> ${SLURM_FCON}
    FSTR="${TKNIPIPES}/tkniFCON.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${FCON_DIR_ID} ]]; then      FSTR="${FSTR} --dir-id ${FCON_DIR_ID}"; fi
    if [[ -z ${FCON_TS} ]]; then          FSTR="${FSTR} --ts ${FCON_TS}"; fi
    if [[ -z ${FCON_LABEL} ]]; then       FSTR="${FSTR} --label ${FCON_LABEL}"; fi
    if [[ -z ${FCON_LABEL_NAME} ]]; then  FSTR="${FSTR} --label-name ${FCON_LABEL_NAME}"; fi
    if [[ -z ${FCON_LUT_ORIG} ]]; then    FSTR="${FSTR} --lut-orig ${FCON_LUT_ORIG}"; fi
    if [[ -z ${FCON_LUT_SORT} ]]; then    FSTR="${FSTR} --lut-sort ${FCON_LUT_SORT}"; fi
    if [[ -z ${FCON_CON_METRIC} ]]; then  FSTR="${FSTR} --con-metric ${FCON_CON_METRIC}"; fi
    if [[ -z ${FCON_DO_RSFC} ]]; then     FSTR="${FSTR} --do-rsfc"; fi
    if [[ -z ${FCON_NO_Z} ]]; then        FSTR="${FSTR} --no-z"; fi
    if [[ -z ${FCON_Z_LO} ]]; then        FSTR="${FSTR} --z-lo ${FCON_Z_LO}"; fi
    if [[ -z ${FCON_Z_HI} ]]; then        FSTR="${FSTR} --x-hi ${FCON_Z_HI}"; fi
    if [[ -z ${FCON_DIR_SAVE} ]]; then    FSTR="${FSTR} --dir-save ${FCON_DIR_SAVE}"; fi
    if [[ -z ${FCON_DIR_SCRATCH} ]]; then FSTR="${FSTR} --dir-scratch ${FCON_SCRATCH}"; fi
    if [[ -z ${FCON_FORCE} ]]; then       FSTR="${FSTR} --force ${FCON_}"; fi
    echo ${FSTR} >> ${SLURM_FCON}
    echo "" >> ${SLURM_FCON}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_FCON}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_FCON}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_FCON}
    echo "" >> ${SLURM_FCON}
  fi

  ###############################################################################
  ## tkniMRS - Magnetic Resonance Spectroscopy
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"MRS"* ]]; then
    SLURM_MRS=${DIR_JOB}/MRS_${SLURM_SUFFIX}.slurm
    if [[ -z ${MRS_NTHREADS} ]]; then MRS_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_MRS}
    echo "#SBATCH --output=${DIR_LOG}/MRS_${SLURM_SUFFIX}.txt" >> ${SLURM_MRS}
    echo "#SBATCH -p normal" >> ${SLURM_MRS}
    echo "#SBATCH -q normal" >> ${SLURM_MRS}
    echo "#SBATCH --nodes=1" >> ${SLURM_MRS}
    echo "#SBATCH --ntasks=1" >> ${SLURM_MRS}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_MRS}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_MRS}
    echo "" >> ${SLURM_MRS}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_MRS}
    echo "" >> ${SLURM_MRS}
    echo "# Load Neurocontainers ------" >> ${SLURM_MRS}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_MRS}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_MRS}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_MRS}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_MRS}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_MRS}
    echo "" >> ${SLURM_MRS}
    FSTR="${TKNIPIPES}/tkniMRS.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${MRS_DIR_ID} ]]; then           FSTR="${FSTR} --dir-id ${MRS_DIR_ID}"; fi
    if [[ -z ${MRS_MRS} ]]; then              FSTR="${FSTR} --mrs ${MRS_MRS}"; fi
    if [[ -z ${MRS_MRS_LOC} ]]; then          FSTR="${FSTR} --mrs-loc ${MRS_MRS_LOC}"; fi
    if [[ -z ${MRS_MRS_MASK} ]]; then         FSTR="${FSTR} --mrs-mask ${MRS_MRS_MASK}"; fi
    if [[ -z ${MRS_MRS_UNSUPPRESSED} ]]; then FSTR="${FSTR} --mrs-unsuppressed"; fi
    if [[ -z ${MRS_NATIVE} ]]; then           FSTR="${FSTR} --native ${MRS_NATIVE}"; fi
    if [[ -z ${MRS_NATIVE_MASK} ]]; then      FSTR="${FSTR} --native-mask ${MRS_NATIVE_MASK}"; fi
    if [[ -z ${MRS_TISSUE} ]]; then           FSTR="${FSTR} --tissue ${MRS_TISSUE}"; fi
    if [[ -z ${MRS_TISSUE_VAL} ]]; then       FSTR="${FSTR} --tissue-val ${MRS_TISSUE_VAL}"; fi
    if [[ -z ${MRS_COREG_RECIPE} ]]; then     FSTR="${FSTR} --coreg-recipe ${MRS_COREG_RECIPE}"; fi
    if [[ -z ${MRS_NO_HSVD} ]]; then          FSTR="${FSTR} --no-hsvd"; fi
    if [[ -z ${MRS_NO_EDDY} ]]; then          FSTR="${FSTR} --no-eddy"; fi
    if [[ -z ${MRS_NO_DFP} ]]; then           FSTR="${FSTR} --no-dfp"; fi
    if [[ -z ${MRS_DIR_SAVE} ]]; then         FSTR="${FSTR} --dir-save ${MRS_DIR_SAVE}"; fi
    if [[ -z ${MRS_DIR_SCRATCH} ]]; then      FSTR="${FSTR} --dir-scratch ${MRS_SCRATCH}"; fi
    if [[ -z ${MRS_FORCE} ]]; then            FSTR="${FSTR} --force ${MRS_}"; fi
    echo ${FSTR} >> ${SLURM_MRS}
    echo "" >> ${SLURM_MRS}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_MRS}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_MRS}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_MRS}
    echo "" >> ${SLURM_MRS}
  fi

  ###############################################################################
  ## tkniQCANAT - Anatomical Quality Control
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"QCANAT"* ]]; then
    SLURM_QCANAT=${DIR_JOB}/QCANAT_${SLURM_SUFFIX}.slurm
    if [[ -z ${QCANAT_NTHREADS} ]]; then QCANAT_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_QCANAT}
    echo "#SBATCH --output=${DIR_LOG}/QCANAT_${SLURM_SUFFIX}.txt" >> ${SLURM_QCANAT}
    echo "#SBATCH -p normal" >> ${SLURM_QCANAT}
    echo "#SBATCH -q normal" >> ${SLURM_QCANAT}
    echo "#SBATCH --nodes=1" >> ${SLURM_QCANAT}
    echo "#SBATCH --ntasks=1" >> ${SLURM_QCANAT}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_QCANAT}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_QCANAT}
    echo "" >> ${SLURM_QCANAT}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_QCANAT}
    echo "" >> ${SLURM_QCANAT}
    echo "# Load Neurocontainers ------" >> ${SLURM_QCANAT}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_QCANAT}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_QCANAT}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_QCANAT}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_QCANAT}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_QCANAT}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_QCANAT}
    echo "" >> ${SLURM_QCANAT}
    FSTR="${TKNIPIPES}/tkniQCANAT.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${QCANAT_DIR_ID} ]]; then           FSTR="${FSTR} --dir-id ${QCANAT_DIR_ID}"; fi
    if [[ -z ${QCANAT_RESET_CSV} ]]; then        FSTR="${FSTR} --reset-csv"; fi
    if [[ -z ${QCANAT_DIR_RAW} ]]; then          FSTR="${FSTR} --dir-raw ${QCANAT_DIR_RAW}"; fi
    if [[ -z ${QCANAT_DIR_NATIVE} ]]; then       FSTR="${FSTR} --dir-native ${QCANAT_DIR_NATIVE}"; fi
    if [[ -z ${QCANAT_DIR_ADD} ]]; then          FSTR="${FSTR} --dir-add ${QCANAT_DIR_ADD}"; fi
    if [[ -z ${QCANAT_DIR_XFM} ]]; then          FSTR="${FSTR} --dir-xfm ${QCANAT_DIR_XFM}"; fi
    if [[ -z ${QCANAT_DIR_MASK} ]]; then         FSTR="${FSTR} --dir-mask ${QCANAT_DIR_MASK}"; fi
    if [[ -z ${QCANAT_DIR_LABEL} ]]; then        FSTR="${FSTR} --dir-label ${QCANAT_DIR_LABEL}"; fi
    if [[ -z ${QCANAT_DIR_POSTERIOR} ]]; then    FSTR="${FSTR} --dir-posterior ${QCANAT_DIR_POSTERIOR}"; fi
    if [[ -z ${QCANAT_MASK_FG} ]]; then          FSTR="${FSTR} --mask-fg ${QCANAT_MASK_FG}"; fi
    if [[ -z ${QCANAT_MASK_BRAIN} ]]; then       FSTR="${FSTR} --mask-brain ${QCANAT_MASK_BRAIN}"; fi
    if [[ -z ${QCANAT_MASK_WM} ]]; then          FSTR="${FSTR} --mask-wm ${QCANAT_MASK_WM}"; fi
    if [[ -z ${QCANAT_LABEL_TISSUE} ]]; then     FSTR="${FSTR} --label-tissue ${QCANAT_LABEL_TISSUE}"; fi
    if [[ -z ${QCANAT_VALUE_GM} ]]; then         FSTR="${FSTR} --value-gm ${QCANAT_LAB_GM}"; fi
    if [[ -z ${QCANAT_VALUE_WM} ]]; then         FSTR="${FSTR} --value-wm ${QCANAT_LAB_WM}"; fi
    if [[ -z ${QCANAT_VALUE_DEEP} ]]; then       FSTR="${FSTR} --value-deep ${QCANAT_LAB_DEEP}"; fi
    if [[ -z ${QCANAT_VALUE_CSF} ]]; then        FSTR="${FSTR} --value-csf ${QCANAT_CSF}"; fi
    if [[ -z ${QCANAT_POSTERIOR_TISSUE} ]]; then FSTR="${FSTR} --posterior-tissue ${QCANAT_POSTERIOR_TISSUE}"; fi
    if [[ -z ${QCANAT_VOL_GM} ]]; then           FSTR="${FSTR} --vol-gm ${QCANAT_VOL_GM}"; fi
    if [[ -z ${QCANAT_VOL_WM} ]]; then           FSTR="${FSTR} --vol-wm ${QCANAT_VOL_WM}"; fi
    if [[ -z ${QCANAT_VOL_DEEP} ]]; then         FSTR="${FSTR} --vol-deep ${QCANAT_VOL_DEEP}"; fi
    if [[ -z ${QCANAT_VOL_CSF} ]]; then          FSTR="${FSTR} --vol-csf ${QCANAT_VOL_CSF}"; fi
    if [[ -z ${QCANAT_REF_NATIVE} ]]; then       FSTR="${FSTR} --ref-native ${QCANAT_REF_NATIVE}"; fi
    if [[ -z ${QCANAT_REDO_FRAME} ]]; then       FSTR="${FSTR} --redo-frame"; fi
    if [[ -z ${QCANAT_DIR_SUMMARY} ]]; then      FSTR="${FSTR} --dir-summary ${QCANAT_DIR_SUMMARY}"; fi
    if [[ -z ${QCANAT_DIR_SAVE} ]]; then         FSTR="${FSTR} --dir-save ${QCANAT_DIR_SAVE}"; fi
    if [[ -z ${QCANAT_DIR_SCRATCH} ]]; then      FSTR="${FSTR} --dir-scratch ${QCANAT_SCRATCH}"; fi
    if [[ -z ${QCANAT_FORCE} ]]; then            FSTR="${FSTR} --force ${QCANAT_}"; fi
    echo ${FSTR} >> ${SLURM_QCANAT}
    echo "" >> ${SLURM_QCANAT}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_QCANAT}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_QCANAT}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_QCANAT}
    echo "" >> ${SLURM_QCANAT}
  fi

  ###############################################################################
  ## tkniQCDWI - Diffusion Quality Control
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"QCDWI"* ]]; then
    SLURM_QCDWI=${DIR_JOB}/QCDWI_${SLURM_SUFFIX}.slurm
    if [[ -z ${QCDWI_NTHREADS} ]]; then QCDWI_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_QCDWI}
    echo "#SBATCH --output=${DIR_LOG}/QCDWI_${SLURM_SUFFIX}.txt" >> ${SLURM_QCDWI}
    echo "#SBATCH -p normal" >> ${SLURM_QCDWI}
    echo "#SBATCH -q normal" >> ${SLURM_QCDWI}
    echo "#SBATCH --nodes=1" >> ${SLURM_QCDWI}
    echo "#SBATCH --ntasks=1" >> ${SLURM_QCDWI}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_QCDWI}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_QCDWI}
    echo "" >> ${SLURM_QCDWI}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_QCDWI}
    echo "" >> ${SLURM_QCDWI}
    echo "# Load Neurocontainers ------" >> ${SLURM_QCDWI}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_QCDWI}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_QCDWI}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_QCDWI}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_QCDWI}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_QCDWI}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_QCDWI}
    echo "" >> ${SLURM_QCDWI}
    FSTR="${TKNIPIPES}/tkniQCDWI.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${QCDWI_DIR_ID} ]]; then      FSTR="${FSTR} --dir-id ${QCDWI_DIR_ID}"; fi
    if [[ -z ${QCDWI_DIR_RAW} ]]; then     FSTR="${FSTR} --dir-raw ${QCDWI_DIR_RAW}"; fi
    if [[ -z ${QCDWI_DIR_CLEAN} ]]; then   FSTR="${FSTR} --dir-clean ${QCDWI_DIR_CLEAN}"; fi
    if [[ -z ${QCDWI_DIR_SCALAR} ]]; then  FSTR="${FSTR} --dir-scalar ${QCDWI_DIR_SCALAR}"; fi
    if [[ -z ${QCDWI_DIR_MASK} ]]; then    FSTR="${FSTR} --dir-mask ${QCDWI_DIR_MASK}"; fi
    if [[ -z ${QCDWI_DIR_LABEL} ]]; then   FSTR="${FSTR} --dir-label ${QCDWI_DIR_LABEL}"; fi
    if [[ -z ${QCDWI_DIR_XFM} ]]; then     FSTR="${FSTR} --dir-xfm ${QCDWI_DIR_XFM}"; fi
    if [[ -z ${QCDWI_MASK_FG} ]]; then     FSTR="${FSTR} --mask-fg ${QCDWI_MASK_FG}"; fi
    if [[ -z ${QCDWI_MASK_BRAIN} ]]; then  FSTR="${FSTR} --mask-brain ${QCDWI_MASK_BRAIN}"; fi
    if [[ -z ${QCDWI_MASK_WM} ]]; then     FSTR="${FSTR} --mask-wm ${QCDWI_MASK_WM}"; fi
    if [[ -z ${QCDWI_MASK_CC} ]]; then     FSTR="${FSTR} --mask-cc ${QCDWI_MASK_CC}"; fi
    if [[ -z ${QCDWI_REDO_FRAME} ]]; then  FSTR="${FSTR} --redo-frame"; fi
    if [[ -z ${QCDWI_RESET_CSV} ]]; then   FSTR="${FSTR} --reset-csv"; fi
    if [[ -z ${QCDWI_DIR_SAVE} ]]; then    FSTR="${FSTR} --dir-save ${QCDWI_DIR_SAVE}"; fi
    if [[ -z ${QCDWI_DIR_SCRATCH} ]]; then FSTR="${FSTR} --dir-scratch ${QCDWI_SCRATCH}"; fi
    if [[ -z ${QCDWI_FORCE} ]]; then       FSTR="${FSTR} --force"; fi
    echo ${FSTR} >> ${SLURM_QCDWI}
    echo "" >> ${SLURM_QCDWI}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_QCDWI}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_QCDWI}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_QCDWI}
    echo "" >> ${SLURM_QCDWI}
  fi

  ###############################################################################
  ## tkniQCFUNC - BOLD Functional Quality Control
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"QCFUNC"* ]]; then
    SLURM_QCFUNC=${DIR_JOB}/QCFUNC_${SLURM_SUFFIX}.slurm
    if [[ -z ${QCFUNC_NTHREADS} ]]; then QCFUNC_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_QCFUNC}
    echo "#SBATCH --output=${DIR_LOG}/QCFUNC_${SLURM_SUFFIX}.txt" >> ${SLURM_QCFUNC}
    echo "#SBATCH -p normal" >> ${SLURM_QCFUNC}
    echo "#SBATCH -q normal" >> ${SLURM_QCFUNC}
    echo "#SBATCH --nodes=1" >> ${SLURM_QCFUNC}
    echo "#SBATCH --ntasks=1" >> ${SLURM_QCFUNC}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_QCFUNC}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_QCFUNC}
    echo "" >> ${SLURM_QCFUNC}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_QCFUNC}
    echo "" >> ${SLURM_QCFUNC}
    echo "# Load Neurocontainers ------" >> ${SLURM_QCFUNC}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_QCFUNC}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_QCFUNC}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_QCFUNC}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_QCFUNC}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_QCFUNC}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_QCFUNC}
    echo "" >> ${SLURM_QCFUNC}
    FSTR="${TKNIPIPES}/tkniQCFUNC.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -n ${QCFUNC_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${QCFUNC_DIR_ID}"; fi
    if [[ -z ${QCFUNC_DIR_RAW} ]]; then       FSTR="${FSTR} --dir-raw ${QCFUNC_DIR_RAW}"; fi
    if [[ -z ${QCFUNC_DIR_CLEAN} ]]; then     FSTR="${FSTR} --dir-clean ${QCFUNC_DIR_CLEAN}"; fi
    if [[ -z ${QCFUNC_DIR_RESIDUAL} ]]; then  FSTR="${FSTR} --dir-residual ${QCFUNC_DIR_RESIDUAL}"; fi
    if [[ -z ${QCFUNC_DIR_REGRESSOR} ]]; then FSTR="${FSTR} --dir-regressor ${QCFUNC_DIR_REGRESSOR}"; fi
    if [[ -z ${QCFUNC_DIR_MASK} ]]; then      FSTR="${FSTR} --dir-mask ${QCFUNC_DIR_MASK}"; fi
    if [[ -z ${QCFUNC_DIR_MEAN} ]]; then      FSTR="${FSTR} --dir-mean ${QCFUNC_DIR_MEAN}"; fi
    if [[ -z ${QCFUNC_DIR_XFM} ]]; then       FSTR="${FSTR} --dir-xfm ${QCFUNC_DIR_XFM}"; fi
    if [[ -z ${QCFUNC_MASK_BRAIN} ]]; then    FSTR="${FSTR} --mask-brain ${QCFUNC_MASK_BRAIN}"; fi
    if [[ -z ${QCFUNC_REDO_FRAME} ]]; then    FSTR="${FSTR} --redo-frame"; fi;
    if [[ -z ${QCFUNC_DIR_SAVE} ]]; then      FSTR="${FSTR} --dir-save ${QCFUNC_DIR_SAVE}"; fi
    if [[ -z ${QCFUNC_DIR_SCRATCH} ]]; then   FSTR="${FSTR} --dir-scratch ${QCFUNC_SCRATCH}"; fi
    if [[ -z ${QCFUNC_FORCE} ]]; then         FSTR="${FSTR} --force ${QCFUNC_}"; fi
    echo ${FSTR} >> ${SLURM_QCFUNC}
    echo "" >> ${SLURM_QCFUNC}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_QCFUNC}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_QCFUNC}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_QCFUNC}
    echo "" >> ${SLURM_QCFUNC}
  fi

  ###############################################################################
  ## Summarize - Summarize results and add to datasets
  ###############################################################################
#  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
#    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
#    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
#    echo "#/bin/bash" > ${SLURM_****}
#    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
#    echo "#SBATCH -p normal" >> ${SLURM_****}
#    echo "#SBATCH -q normal" >> ${SLURM_****}
#    echo "#SBATCH --nodes=1" >> ${SLURM_****}
#    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
#    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
#    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "# Load Neurocontainers ------" >> ${SLURM_****}
#    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
#    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
#    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
#    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
#    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
#    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    FSTR="${TKNIPIPES}/tkni****.sh"
#    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
#    if [[ -n ${****_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${****_DIR_ID}"; fi
#    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
#    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
#    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
#    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
#    echo ${FSTR} >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
#    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
#    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#  fi

  ###############################################################################
  ## tkniXINIT - Ex Vivo Preprocessing
  ###############################################################################
#  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
#    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
#    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
#    echo "#/bin/bash" > ${SLURM_****}
#    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
#    echo "#SBATCH -p normal" >> ${SLURM_****}
#    echo "#SBATCH -q normal" >> ${SLURM_****}
#    echo "#SBATCH --nodes=1" >> ${SLURM_****}
#    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
#    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
#    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "# Load Neurocontainers ------" >> ${SLURM_****}
#    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
#    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
#    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
#    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
#    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
#    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    FSTR="${TKNIPIPES}/tkni****.sh"
#    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
#    if [[ -n ${****_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${****_DIR_ID}"; fi
#    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
#    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
#    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
#    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
#    echo ${FSTR} >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
#    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
#    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#  fi

  ###############################################################################
  ## tkniXSEGMENT - Ex vivo Watershed Segmentation
  ###############################################################################
#  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
#    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
#    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
#    echo "#/bin/bash" > ${SLURM_****}
#    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
#    echo "#SBATCH -p normal" >> ${SLURM_****}
#    echo "#SBATCH -q normal" >> ${SLURM_****}
#    echo "#SBATCH --nodes=1" >> ${SLURM_****}
#    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
#    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
#    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "# Load Neurocontainers ------" >> ${SLURM_****}
#    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
#    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
#    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
#    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
#    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
#    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    FSTR="${TKNIPIPES}/tkni****.sh"
#    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
#    if [[ -n ${****_DIR_ID} ]]; then        FSTR="${FSTR} --dir-id ${****_DIR_ID}"; fi
#    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
#    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
#    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
#    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
#    echo ${FSTR} >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
#    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
#    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
#    echo "" >> ${SLURM_****}
#  fi


  ###############################################################################
  ## SUBMIT JOBS WITH DEPENDENCIES
  ###############################################################################

  # Reset Job IDs for iteration
  TFLOW=(${WORKFLOWS//,/ })
  for (( i=0; i<${#TFLOW[@]}; i++ )); do unset JOB_${TFLOW[${i}]^^}; done

  if [[ ${WORKFLOWS^^} == *"AINIT"* ]]; then
    JOB_AINIT=$(sbatch --parseable ${SLURM_AINIT})
  fi
  if [[ ${WORKFLOWS^^} == *"FSSYNTH"* ]]; then
    JOB_FSSYNTH=$(sbatch --parseable ${JOB_AINIT:+--dependency=afterok:${JOB_AINIT}} ${SLURM_FSSYNTH})
  fi
  if [[ ${WORKFLOWS^^} == *"MALF"* ]]; then
    JOB_MALF=$(sbatch --parseable ${JOB_AINIT:+--dependency=afterok:${JOB_AINIT}} ${SLURM_MALF})
  fi
  if [[ ${WORKFLOWS^^} == *"MATS"* ]]; then
    JOB_MATS=$(sbatch --parseable ${JOB_AINIT:+--dependency=afterok:${JOB_AINIT}} ${SLURM_MATS})
  fi
  if [[ ${WORKFLOWS^^} == *"AMOD"* ]]; then
    DEP_AMOD="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MALF}${JOB_MALF:+:}${JOB_MATS}"
    DEP_AMOD=$(echo "${DEP_AMOD}" | sed -E 's/:+/:/g; s/^:|:$//g')
    JOB_AMOD=$(sbatch --parseable ${DEP_AMOD:+--dependency=afterok:${DEP_AMOD}} ${SLURM_AMOD})
  fi
  if [[ ${WORKFLOWS^^} == *"QALAS"* ]]; then
    JOB_QALAS=$(sbatch --parseable ${JOB_AINIT:+--dependency=afterok:${JOB_AINIT}} ${SLURM_QALAS})
  fi
  if [[ ${WORKFLOWS^^} == *"DPREP"* ]]; then
    JOB_DPREP=$(sbatch --parseable ${JOB_AINIT:+--dependency=afterok:${JOB_AINIT}} ${SLURM_DPREP})
  fi
  if [[ ${WORKFLOWS^^} == *"DSCALE"* ]]; then
    DEP_DSCALE="${JOB_AINIT}${JOB_AINIT:+:}${JOB_DPREP}"
    JOB_DSCALE=$(sbatch --parseable ${DEP_DSCALE:+--dependency=afterok:${DEP_DSCALE}} ${SLURM_DSCALE})
  fi
  if [[ ${WORKFLOWS^^} == *"DMICRO"* ]]; then
    DEP_DMICRO="${JOB_AINIT}${JOB_AINIT:+:}${JOB_DPREP}"
    JOB_DMICRO=$(sbatch --parseable ${DEP_DMICRO:+--dependency=afterok:${DEP_DMICRO}} ${SLURM_DMICRO})
  fi
  if [[ ${WORKFLOWS^^} == *"DTRACT"* ]]; then
    DEP_DTRACT="${JOB_AINIT}${JOB_AINIT:+:}${JOB_DPREP}${JOB_DPREP:+:}${JOB_MATS}"
    DEP_DTRACT=$(echo "${DEP_DTRACT}" | sed -E 's/:+/:/g; s/^:|:$//g')
    JOB_DTRACT=$(sbatch --parseable ${DEP_DTRACT:+--dependency=afterok:${DEP_DTRACT}} ${SLURM_DTRACT})
  fi
  if [[ ${WORKFLOWS^^} == *"PCASL"* ]]; then
    DEP_PCASL="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MALF}"
    JOB_PCASL=$(sbatch --parseable ${DEP_PCASL:+--dependency=afterok:${DEP_PCASL}} ${SLURM_PCASL})
  fi
  if [[ ${WORKFLOWS^^} == *"FUNK"* ]]; then
    DEP_FUNK="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MATS}"
    JOB_FUNK=$(sbatch --parseable ${DEP_FUNK:+--dependency=afterok:${DEP_FUNK}} ${SLURM_FUNK})
  fi
  if [[ ${WORKFLOWS^^} == *"FCON"* ]]; then
    DEP_FCON="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MALF}${JOB_MALF:+:}${JOB_MATS}${JOB_MATS:+:}${JOB_FUNK}"
    DEP_FCON=$(echo "${DEP_FCON}" | sed -E 's/:+/:/g; s/^:|:$//g')
    JOB_FCON=$(sbatch --parseable ${DEP_FCON:+--dependency=afterok:${DEP_FCON}} ${SLURM_FCON})
  fi
  if [[ ${WORKFLOWS^^} == *"MRS"* ]]; then
    DEP_MRS="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MATS}"
    JOB_MRS=$(sbatch --parseable ${DEP_MRS:+--dependency=afterok:${DEP_MRS}} ${SLURM_MRS})
  fi
  if [[ ${WORKFLOWS^^} == *"QCANAT"* ]]; then
    DEP_QCANAT="${JOB_AINIT}${JOB_AINIT:+:}${JOB_FSSYNTH}${JOB_FSSYNTH:+:}${JOB_MALF}${JOB_MALF:+:}${JOB_MATS}${JOB_MATS:+:}${JOB_AMOD}${JOB_AMOD:+:}${JOB_QALAS}"
    DEP_QCANAT=$(echo "${DEP_QCANAT}" | sed -E 's/:+/:/g; s/^:|:$//g')
    JOB_QCANAT=$(sbatch --parseable ${DEP_QCANAT:+--dependency=afterok:${DEP_QCANAT}} ${SLURM_QCANAT})
  fi
  if [[ ${WORKFLOWS^^} == *"QCDWI"* ]]; then
    DEP_QCDWI="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MATS}${JOB_MATS:+:}${JOB_DPREP}${JOB_DPREP:+:}${JOB_DSCALE}${JOB_DSCALE:+:}${JOB_DMICRO}${JOB_DMICRO:+:}${JOB_QCDWI}"
    DEP_QCDWI=$(echo "${DEP_QCDWI}" | sed -E 's/:+/:/g; s/^:|:$//g')
    JOB_QCDWI=$(sbatch --parseable ${DEP_QCDWI:+--dependency=afterok:${DEP_QCDWI}} ${SLURM_QCDWI})
  fi
  if [[ ${WORKFLOWS^^} == *"QCFUNC"* ]]; then
    DEP_QCFUNC="${JOB_AINIT}${JOB_AINIT:+:}${JOB_MALF}${JOB_MALF:+:}${JOB_MATS}${JOB_MATS:+:}${JOB_FUNK}${JOB_FUNK:+:}${JOB_FCON}"
    DEP_QCFUNC=$(echo "${DEP_QCFUNC}" | sed -E 's/:+/:/g; s/^:|:$//g')
    JOB_QCFUNC=$(sbatch --parseable ${DEP_QCFUNC:+--dependency=afterok:${DEP_QCFUNC}} ${SLURM_QCFUNC})
  fi
done
