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

# Parse input options ----------------------------------------------------------
OPTS=$(getopt -o hv --long pi:,project:,dir-project:,pipe-list:,id:,id-vars:,\
dir-scratch:,help,verbose,force -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values -----------------------------------------------------------
PI=
PROJECT=
DIR_PROJECT=
DIR_SCRATCH="/home/${USER}/scratch"
PIPELS=("AINIT" "AMOD" "FSSYNTH" "MALF" "MATS" "QALAS" \
        "DPREP" "DSCALE" "DMICRO" "DTRACT" \
        "FUNK" "FCON" \
        "MRS" \
        "PCASL" \
        "QCANAT" "QCDWI" "QCFUNC")
ID="all"
IDVARS=("participant_id" "session_id" "assessment_id")
IDFLAG=("sub" "ses" "aid")

# gather input options ---------------------------------------------------------
while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=true ; shift ;;
    --force) FORCE="true" ; shift ;;
    --pi) PI="$2" ; shift 2 ;;
    --project) PROJECT="$2" ; shift 2 ;;
    --dir-project) DIR_PROJECT="$2" ; shift 2 ;;
    --dir-scratch) DIR_SCRATCH="$2" ; shift 2 ;;
    --pipe-list) PIPELS="$2" ; shift 2 ;;
    --id) IDPFX="$2" ; shift 2 ;;
    -- ) shift ; break ;;
    * ) break ;;
  esac
done

# Check inputs -----------------------------------------------------------------
if [[ -z ${PI} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] PI must be provided"
  exit 1
fi
if [[ -z ${PROJECT} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] PROJECT must be provided"
  exit 1
fi
if [[ -z ${DIR_PROJECT} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] DIR_PROJECT must be provided"
  exit 1
fi

# Parse participants -----------------------------------------------------------
unset IDLS
if [[ ${ID,,} == "all" ]]; then
  N=($(wc -l ${DIR_PROJECT}/participants.tsv))
  TLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f ${IDVARS[0]}))
  for (( i=1; i<${N}; i++ )); do
    IDLS[${i}]="${IDFLAG[0]}-${TLS[$i]}"
  done
  for (( j=1; j<${#IDVARS[@]}; j++ )); do
    TLS=($(getColumn -i ${DIR_PROJECT}/participants.tsv -f ${IDVARS[${j}]}))
    for (( i=1; i<${N}; i++ )); do
      IDLS[${i}]="${IDLS[${i}]}_${IDFLAG[${j}]}-${TLS[$i]}"
    done
  done
else
  IDLS=("" ${ID//,/ })
fi
N=${#IDLS[@]}

# Loop over participants -------------------------------------------------------
for (( i=1; i<=${N}; i++ )); then
  IDPFX=${IDLS[${i}]}
  CHK_DONE="${DIR_PROJECT}/status/tkni/DONE_tkni_${IDPFX}.txt"
  if [[ ! -f ${CHK_DONE} ]] || [[ ${FORCE} == "true" ]]; then
    # run AINIT
    JOB_AINIT=$(sbatch --parsable \
                       --job-name=${PI}_${PROJECT}_${IDPFX}_tkniAINIT \
                       ${TKNIPIPES}/tkniAINIT.slurm \
                       ${PI} ${PROJECT} ${DIR_PROJECT} ${IDPFX})
    sbatch
    # run AMOD
    # run FSSYNTH
    # run MALF
    # run MATS
    # run QALAS
    # run DPREP
    # run DSCALE
    # run DMICRO
    # run DTRACT
    # run FUNK
    # run FCON
    # run MRS
    # run PCASL
    # run QCANAT
    # run QCDWI
    # run QCFUNC
    # append to summaries
  fi
done




