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
    echo "#/bin/bash" > ${SLURM_AINIT}
    echo "#SBATCH --output=${DIR_LOG}/AINIT_${SLURM_SUFFIX}.txt" >> ${SLURM_AINIT}
    echo "#SBATCH -p normal" >> ${SLURM_AINIT}
    echo "#SBATCH -q normal" >> ${SLURM_AINIT}
    echo "#SBATCH --nodes=1" >> ${SLURM_AINIT}
    echo "#SBATCH --ntasks=1" >> ${SLURM_AINIT}
    echo "#SBATCH --cpus-per-task=1" >> ${SLURM_AINIT}
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
    if [[ -n ${DIR_PROJECT} ]]; then        FSTR="${FSTR} --dir-project ${AINIT_DIR_PROJECT}"; fi
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
    if [[ -z ${MALF_IMAGE} ]]; then         echo "  --image         ${MALF_IMAGE} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MOD} ]]; then           echo "  --mod           ${MALF_MOD} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MASK} ]]; then          echo "  --mask          ${MALF_MASK} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MASK_DIL} ]]; then      echo "  --mask-dil      ${MALF_MASK_DIL} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_NAME} ]]; then    echo "  --atlas-name    ${MALF_ATLAS_NAME} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_REF} ]]; then     echo "  --atlas-ref     ${MALF_ATLAS_REF} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_MASK} ]]; then    echo "  --atlas-mask    ${MALF_ATLAS_MASK} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_EX} ]]; then      echo "  --atlas-ex      ${MALF_ATLAS_EX} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_LABEL} ]]; then   echo "  --atlas-label   ${MALF_ATLAS_LABEL} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_DIL} ]]; then     echo "  --atlas-dil     ${MALF_ATLAS_DIL} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_NO_PREMASK} ]]; then    echo "  --no-premask  \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MASK_RESTRICT} ]]; then echo "  --mask-restrict ${MALF_MASK_RESTRICT} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_NO_JAC} ]]; then        echo "  --no-jac        ${MALF_NO_JAC} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_DIR_SAVE} ]]; then      echo "  --dir-save      ${MALF_DIR_SAVE} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_DIR_SCRATCH} ]]; then   echo "  --dir-scratch   ${MALF_SCRATCH} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_FORCE} ]]; then         echo "  --force \\" >> ${SLURM_MALF}
    echo ${FSTR} >> ${SLURM_}
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
    if [[ -z ${MATS_SRC_ANAT} ]]; then     echo "  --src-anat     ${MATS_SRC_ANAT} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_IMAGE} ]]; then        echo "  --image        ${MATS_IMAGE}    \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_MOD} ]]; then          echo "  --mod          ${MATS_MOD}      \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_MASK} ]]; then         echo "  --mask         ${MATS_MASK}     \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_MASK_DIL} ]]; then     echo "  --mask-dil     ${MATS_MASK_DIL} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_METHOD} ]]; then       echo "  --method       ${MATS_METHOD}   \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_ATLAS} ]]; then        echo "  --atlas        ${MATS_ATLAS} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_ROI} ]]; then          echo "  --roi          ${MATS_ROI} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_PROB} ]]; then         echo "  --prob         ${MATS_PROB} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_PRIOR} ]]; then        echo "  --prior        ${MATS_PRIOR} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_K_CLASS} ]]; then      echo "  --k-class      ${MATS_K_CLASS} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_WEIGHT_ANTS} ]]; then  echo "  --weight-ants  ${MATS_WEIGHT_ANTS}  \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_WEIGHT_5TT} ]]; then   echo "  --weight-5tt   ${MATS_WEIGHT_5TT}   \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_WEIGHT_SYNTH} ]]; then echo "  --weight-synth ${MATS_WEIGHT_SYNTH} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_NO_KEEP} ]]; then      echo "  --no-keep      ${MATS_NO_KEEP}  \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_NO_THICKNESS} ]]; then echo "  --no-thickness ${MATS_NO_THICKNESS}  \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_REFINE} ]]; then       echo "  --refine       ${MATS_REFINE}  \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_KEEP_PARTS} ]]; then   echo "  --keep-parts   ${MATS_KEEP_PARTS}  \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_DIR_SAVE} ]]; then     echo "  --dir-save     ${MATS_DIR_SAVE} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_DIR_SCRATCH} ]]; then  echo "  --dir-scratch  ${MATS_SCRATCH} \\" >> ${SLURM_MATS}
    if [[ -z ${MATS_FORCE} ]]; then        echo "  --force \\" >> ${SLURM_MATS}
    echo ${FSTR} >> ${SLURM_}
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
    if [[ -z ${AMOD_NTHREADS} ]]; then AMOD_NTHREADS=4; fi
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
    echo ${FSTR} >> ${SLURM_}
    echo "" >> ${SLURM_AMOD}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_AMOD}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_AMOD}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_AMOD}
    echo "" >> ${SLURM_AMOD}
  fi

  ###############################################################################
  ## tkniQALAS - QALAS Processing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniDPREP - Diffusion Image Preprocessing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniDSCALE - Diffusion Scalars
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniMICRO - Diffusion Microstructure, NODDI and SANDI
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniDTRACT - Diffusion Tractography
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniPCASL - Cerebral Blood Flow from PCASL
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniFUNK - BOLD Functional Preprocessing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniFCON - Functional Connectivity
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniMRS - Magnetic Resonance Spectroscopy
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniQCANAT - Anatomical Quality Control
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniQCDWI - Diffusion Quality Control
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniQCFUNC - BOLD Functional Quality Control
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## Summarize - Summarize results and add to datasets
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniXINIT - Ex Vivo Preprocessing
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi

  ###############################################################################
  ## tkniXSEGMENT - Ex vivo Watershed Segmentation
  ###############################################################################
  if [[ ${WORKFLOWS^^} == *"****"* ]]; then
    SLURM_****=${DIR_JOB}/****_${SLURM_SUFFIX}.slurm
    if [[ -z ${****_NTHREADS} ]]; then ****_NTHREADS=4; fi
    echo "#/bin/bash" > ${SLURM_****}
    echo "#SBATCH --output=${DIR_LOG}/****_${SLURM_SUFFIX}.txt" >> ${SLURM_****}
    echo "#SBATCH -p normal" >> ${SLURM_****}
    echo "#SBATCH -q normal" >> ${SLURM_****}
    echo "#SBATCH --nodes=1" >> ${SLURM_****}
    echo "#SBATCH --ntasks=1" >> ${SLURM_****}
    echo "#SBATCH --cpus-per-task=${MATS_NTHREADS}" >> ${SLURM_****}
    echo "#SBATCH --mem-per-cpu=8G" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_START=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "# Load Neurocontainers ------" >> ${SLURM_****}
    echo "ND_CONTAINERS=(\"afni_26.0.07_20260128\" \\" >> ${SLURM_****}
    echo "               \"ants_2.6.5_20260225\" \\" >> ${SLURM_****}
    echo "               \"convert3d_1.1.0_20251212\" \\" >> ${SLURM_****}
    echo "               \"freesurfer_7.4.1_20231214\" \\" >> ${SLURM_****}
    echo "               \"mrtrix3_3.0.8_20260107\" \\" >> ${SLURM_****}
    echo "               \"niimath_1.0.20250804_20251016\")" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    FSTR="${TKNIPIPES}/tkni****.sh"
    FSTR="${FSTR} --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null"
    if [[ -z ${****_} ]]; then  FSTR="${FSTR} --**** ${****_}"; fi
    if [[ -z ${****_DIR_SAVE} ]]; then     FSTR="${FSTR} --dir-save ${****_DIR_SAVE}"; fi
    if [[ -z ${****_DIR_SCRATCH} ]]; then  FSTR="${FSTR} --dir-scratch ${****_SCRATCH}"; fi
    if [[ -z ${****_FORCE} ]]; then  FSTR="${FSTR} --force ${****_}"; fi
    echo ${FSTR} >> ${SLURM_****}
    echo "" >> ${SLURM_****}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_****}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_****}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_****}
    echo "" >> ${SLURM_****}
  fi


  ###############################################################################
  ## SUBMIT JOBS WITH DEPENDENCIES
  ###############################################################################
done
