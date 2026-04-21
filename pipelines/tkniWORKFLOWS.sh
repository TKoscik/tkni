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
    echo "${TKNIPIPES}/tkniAINIT.sh \\" >> ${SLURM_AINIT}
    echo "  --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null \\" >> ${SLURM_AINIT}
    if [[ -n ${DIR_PROJECT} ]]; then        echo "  --dir-project ${AINIT_DIR_PROJECT} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_DIR_SAVE} ]]; then     echo "  --dir-save ${AINIT_DIR_SAVE} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_DIR_SCRATCH} ]]; then  echo "  --dir-scratch ${AINIT_DIR_SCRATCH} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_BASE_IMG} ]]; then     echo "  --base-img ${AINIT_BASE_IMG} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_BASE_MOD} ]]; then     echo "  --base-mod ${AINIT_BASE_MOD} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_ALIGN_MANUAL} ]]; then echo "  --align-manual ${AINIT_ALIGN_MANUAL} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_ALIGN_TO} ]]; then     echo "  --align-to ${AINIT_ALIGN_TO} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_FG_CLIP} ]]; then      echo "  --fg-clip ${AINIT_FG_CLIP} \\" >> ${SLURM_AINIT}; fi
    if [[ -n ${AINIT_FORCE} ]]; then        echo "  --force \\" >> ${SLURM_AINIT}; fi
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
    echo "${TKNIPIPES}/tkniFSSYNTH.sh \\" >> ${SLURM_FSSYNTH}
    echo "  --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_IMAGE} ]]; then    echo "  --image ${FSSYNTH_IMAGE} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_MOD} ]]; then      echo "  --mod ${FSSYNTH_MOD} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_LABELS} ]]; then   echo "  --labels ${FSSYNTH_LABELS} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_NTHREADS} ]]; then echo "  --nthreads ${FSSYNTH_NTHREADS} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_DIR_FS} ]]; then   echo "  --dir-fs ${FSSYNTH_DIR_FS} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_DIR_SAVE} ]]; then echo "  --dir-save ${FSSYNTH_DIR_SAVE} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_SCRATCH} ]]; then  echo "  --dir-scratch ${FSSYNTH_SCRATCH} \\" >> ${SLURM_FSSYNTH}
    if [[ -z ${FSSYNTH_FORCE} ]]; then    echo "  --force \\" >> ${SLURM_FSSYNTH}
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
    echo "${TKNIPIPES}/tkniMALF.sh \\" >> ${SLURM_MALF}
    echo "  --pi ${PI} --project ${PROJECT} --id ${IDPFX} --requires null \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_IMAGE} ]]; then         echo "  --image ${MALF_IMAGE} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MOD} ]]; then           echo "  --mod ${MALF_MOD} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MASK} ]]; then          echo "  --mask ${MALF_MASK} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MASK_DIL} ]]; then      echo "  --mask-dil ${MALF_MASK_DIL} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_NAME} ]]; then    echo "  --atlas-name ${MALF_ATLAS_NAME} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_REF} ]]; then     echo "  --atlas-ref ${MALF_ATLAS_REF} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_MASK} ]]; then    echo "  --atlas-mask ${MALF_ATLAS_MASK} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_EX} ]]; then      echo "  --atlas-ex ${MALF_ATLAS_EX} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_LABEL} ]]; then   echo "  --atlas-label ${MALF_ATLAS_LABEL} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_ATLAS_DIL} ]]; then     echo "  --atlas-dil ${MALF_ATLAS_DIL} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_NO_PREMASK} ]]; then    echo "  --no-premask  \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_MASK_RESTRICT} ]]; then echo "  --mask-restrict ${MALF_MASK_RESTRICT} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_NO_JAC} ]]; then        echo "  --no-jac ${MALF_NO_JAC} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_DIR_SAVE} ]]; then      echo "  --dir-save ${MALF_DIR_SAVE} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_DIR_PROJECT} ]]; then   echo "  --dir-scratch ${MALF_SCRATCH} \\" >> ${SLURM_MALF}
    if [[ -z ${MALF_FORCE} ]]; then         echo "  --force \\" >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
    echo "PROC_END=\"$(date -u +%s.%N)\"" >> ${SLURM_MALF}
    echo "ELAPSED=$(echo \"$PROC_END - $PROC_START\" | bc)" >> ${SLURM_MALF}
    echo "echo -e \"Processing Time:\t${ELAPSED}s\"" >> ${SLURM_MALF}
    echo "" >> ${SLURM_MALF}
  fi

  ###############################################################################
  ## tkniMATS - Multi-Approach Tissue Segmentation
  ###############################################################################

  ###############################################################################
  ## tkniAMOD - Additional Anatomical Modality Processing
  ###############################################################################

  ###############################################################################
  ## tkniQALAS - QALAS Processing
  ###############################################################################

  ###############################################################################
  ## tkniDPREP - Diffusion Image Preprocessing
  ###############################################################################

  ###############################################################################
  ## tkniDSCALE - Diffusion Scalars
  ###############################################################################

  ###############################################################################
  ## tkniMICRO - Diffusion Microstructure, NODDI and SANDI
  ###############################################################################

  ###############################################################################
  ## tkniDTRACT - Diffusion Tractography
  ###############################################################################

  ###############################################################################
  ## tkniPCASL - Cerebral Blood Flow from PCASL
  ###############################################################################

  ###############################################################################
  ## tkniFUNK - BOLD Functional Preprocessing
  ###############################################################################

  ###############################################################################
  ## tkniFCON - Functional Connectivity
  ###############################################################################

  ###############################################################################
  ## tkniMRS - Magnetic Resonance Spectroscopy
  ###############################################################################

  ###############################################################################
  ## tkniQCANAT - Anatomical Quality Control
  ###############################################################################

  ###############################################################################
  ## tkniQCDWI - Diffusion Quality Control
  ###############################################################################

  ###############################################################################
  ## tkniQCFUNC - BOLD Functional Quality Control
  ###############################################################################

  ###############################################################################
  ## Summarize - Summarize results and add to datasets
  ###############################################################################

  ###############################################################################
  ## tkniXINIT - Ex Vivo Preprocessing
  ###############################################################################

  ###############################################################################
  ## tkniXSEGMENT - Ex vivo Watershed Segmentation
  ###############################################################################


  ###############################################################################
  ## SUBMIT JOBS WITH DEPENDENCIES
  ###############################################################################
done
