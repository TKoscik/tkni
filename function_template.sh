#!/bin/bash -e
#===============================================================================
# <<DESCRIPTION>>
# Authors: <GIVENNAME> <FAMILYNAME>, 
# Date: <date of initial commit>
# CHANGELOG: <description of major changes to functionality>
#===============================================================================
PROC_START=$(date +%Y-%m-%dT%H:%M:%S%z)
FCN_NAME=($(basename "$0"))
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
OPTS=$(getopt -o hvkl --long prefix:,other:,dir-save:,dir-scratch:,\
help,verbose,keep,no-log -n 'parse-options' -- "$@")
if [ $? != 0 ]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values for function ---------------------------------------------
PREFIX=
OTHER=
DIR_SAVE=
DIR_SCRATCH=${INC_SCRATCH}/${OPERATOR}_${DATE_SUFFIX}
HELP=false
VERBOSE=false

while true; do
  case "$1" in
    -h | --help) HELP=true ; shift ;;
    -v | --verbose) VERBOSE=1 ; shift ;;
    -l | --no-log) NO_LOG=true ; shift ;;
    -p | --no-png) NO_PNG=true ; shift ;;
    -k | --keep) KEEP=true ; shift ;;
    --prefix) PREFIX="$2" ; shift 2 ;;
    --other) OTHER="$2" ; shift 2 ;;
    --dir-save) DIR_SAVE="$2" ; shift 2 ;;
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
  echo '  -h | --help              display command help'
  echo '  -l | --no-log            disable writing to output log'
  echo '  --prefix  <optional>     filename, without extension to use for file'
  echo '  --other                  other inputs as needed'
  echo '  --dir-save               location to save output'
  echo '  --dir-scratch            location for temporary files'
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
if [[ -z ${DIR_SAVE} ]]; then DIR_SAVE=$(dirname ${T1}); fi
if [[ -z ${PREFIX} ]]; then PREFIX=$(getBidsBase -i ${T1} -s); fi

mkdir -p ${DIR_SAVE}
mkdir -p ${DIR_SCRATCH}

# body of function here --------------------------------------------------------
## insert comments for important chunks
## use dashes as above to separate chunks of code visually
## move files to appropriate locations

#===============================================================================
# End of Function
#===============================================================================
exit 0


