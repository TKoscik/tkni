#!/bin/bash -e

#===============================================================================
# PIPELINE:      tkni
# WORKFLOW:      BoxBUP
# DESCRIPTION:   TKNI BAckup to Box
# AUTHOR:        Timothy R. Koscik, PhD
# DATE CREATED:  2025-05-08
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
  if [[ "${NO_LOG}" == "false" ]]; then
    writeBenchmark ${OPERATOR} ${HARDWARE} ${KERNEL} ${FCN_NAME} \
      ${PROC_START} ${PROC_STOP} ${EXIT_CODE}
  fi
}
trap egress EXIT

# Parse inputs -----------------------------------------------------------------
OPTS=$(getopt -o hvl --long username:,password:,\
name:,source:,target:,\
no-bup-log,dir-log-local:,dir-log-remote:,\
help,verbose,no-log -n 'parse-options' -- "$@")
if [[ $? != 0 ]]; then
  echo "Failed parsing options" >&2
  exit 1
fi
eval set -- "$OPTS"

# Set default values ----------------------------------------------------------
USERVAR=
PASSVAR=

BNAME=
BSRC=
BTRG=

NO_BLOG="false"
DLOG_LOCAL=
DLOG_REMOTE=

PROTOCOL=ftps
ADDRESS=ftp.box.com
PORT=990
RECONNECT_BASE=5
RECONNECT_MULT=1

PIPE=tkni
FLOW=${FCN_NAME//${PIPE}}

while true; do
  case "$1" in
    -h | --help) HELP="true" ; shift ;;
    -v | --verbose) VERBOSE="true" ; shift ;;
    -l | --no-log) NO_LOG="true" ; shift ;;
    --username) USERVAR="$2" ; shift 2 ;;
    --password) PASSVAR="$2" ; shift 2 ;;
    --name) BNAME="$2" ; shift 2 ;;
    --source) BSRC="$2" ; shift 2 ;;
    --target) BTRG="$2" ; shift 2 ;;
    --no-bup-log) NO_BLOG="true" ; shift ;;
    --dir-log-local) DLOG_LOCAL="$2" ; shift 2 ;;
    --dir-log-remote) DLOG_REMOTE="$2" ; shift 2 ;;
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
  echo ''
  NO_LOG=true
  exit 0
fi

#===============================================================================
# Start of Function
#===============================================================================
# check inputs -----------------------------------------------------------------
if [[ -z ${BNAME} ]]; then BNAME="unnamedBUP"; fi
if [[ -z ${BSRC} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] The SOURCE to be backed up must be provided."
  exit 1
fi
if [[ -z ${BTRG} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] The TARGET folder to back up to must be provided."
  exit 2
fi

BNAME=(${BNAME//;/ })
BSRC=(${BSRC//;/ })
BTRG=(${BTRG//;/ })

if [[ ${#BRSC[@]} -ne ${#BTRG[@]} ]]; then
  echo "ERROR [${PIPE}:${FLOW}] The number of SOURCES must match the number of TARGETS"
  exit 3
fi

NBUP=${#BRSC[@]}

if [[ ${#BNAME[@]} -ne ${NBUP} ]]; then
  if [[ ${NBUP} -gt 1 ]] && [[ ${#BNAME[@]} -eq 1 ]]; then
    for (( i=1; i<${NBUP}; i++ )); do
      BNAME[${i}]=${BNAME[0]}
    done
  elif [[ ${#BNAME[@]} -gt ${NBUP} ]]; then
    echo "WARNING [${PIPE}:${FLOW}] The number of NAMES exceeds the number of SOURCES."
    echo "                          The excess will not be used."
  else
    echo "ERROR [${PIPE}:${FLOW}] Cannot rectify NAMES with SOURCES."
    echo "                        The number should match or be a singular value."
    exit 4
  fi
fi

if [[ ${NO_BLOG} == "false" ]]; then
  if [[ -z ${DLOG_LOCAL} ]]; then
    DLOG_LOCAL=(${BSRC[@]})
  elif [[ ${#DLOG_LOCAL[@]} -eq 1 ]] && [[ ${NBUP} -gt 1 ]]; then
    for (( i=1; i<${NBUP}; i++ )); do DLOG_LOCAL+=${DLOG_LOCAL[0]}; done
  fi
  if [[ -z ${DLOG_REMOTE} ]]; then
    DLOG_REMOTE=(${BTRG[@]})
  elif [[ ${#DLOG_REMOTE[@]} -eq 1 ]] && [[ ${NBUP} -gt 1 ]]; then
    for (( i=1; i<${NBUP}; i++ )); do DLOG_REMOTE+=${DLOG_REMOTE[0]}; done
  fi
fi

# get username and password for box --------------------------------------------
if [[ -z ${USERNAME} ]]; then read -p 'Box FTP User: ' USERVAR; fi
if [[ -z ${PASSVAR} ]]; then read -sp 'Box FTP Password: ' PASSVAR; fi

# Do backups -------------------------------------------------------------------
if [[ ${VERBOSE} == "true" ]]; then echo "Starting TK Backup"; fi
for (( i=0; i<${NBUP}; i++ )); do
  NAME=${BNAME[${i}]}
  SRC=${BSRC[${i}]}
  TRG=${BTRG[${i}]}
  DT=$(date +%Y%m%dT%H%M%S%N)
  if [[ ${VERBOSE} == "true" ]]; then echo "Backing up ${NAME}"; fi

  BFCN='lftp -c "'
  BFCN="${BFCN}set net:reconnect-interval-multiplier ${RECONNECT_MULT};"
  BFCN="${BFCN} set net:reconnect-interval-base ${RECONNECT_BASE};"
  if [[ ${NO_BLOG} == "false" ]]; then
    BFCN="${BFCN} set log:enabled/xfer yes;"
    BFCN="${BFCN} set log:file/xfer ${DLOG}/${NAME}_${DT}.log;"
  fi
  BFCN="${BFCN} open --user ${USERVAR} --password ${PASSVAR} ${PROTOCOL}://${ADDRESS}:${PORT};"
  BFCN="${BFCN} mirror -R -n ${SRC} ${TRG}"
  BFCN=${BFCN}'"'

  eval ${BFCN}

  # send back up logs to box as well ---------------------------------------------
  if [[ ${NO_BLOG} == "false" ]]; then
    lftp -c \
      "set net:reconnect-interval-multiplier ${RECONNECT_MULT}; \
       set net:reconnect-interval-base ${RECONNECT_BASE}; \
       set log:enabled/xfer no; \
       open --user ${USERVAR} --password ${PROTOCOL}://${ADDRESS}:${PORT}; \
       mirror -R -n ${DLOG_LOCAL[${i}]}/ ${DLOG_REMOTE[${i}]}/"
  fi
fi
  if [[ ${VERBOSE} == "true" ]]; then echo "DONE";
done

#===============================================================================
# End of Function
#===============================================================================
exit 0
