#!/bin/bash
# Data Pump export. Run as oracle.
set -euo pipefail

: "${ORACLE_SID:?}"
: "${ORACLE_HOME:?}"
: "${BACKUP_ROOT:?}"
DATE_TAG="${DATE_TAG:-$(date +%Y%m%d_%H%M%S)}"
SCHEMAS="${SCHEMAS:-}"
FULL="${FULL:-0}"
DUMP_DIR_NAME="${DUMP_DIR_NAME:-ORA_SSH_DP}"

export ORACLE_SID ORACLE_HOME
export PATH="$ORACLE_HOME/bin:$PATH"

STAGE="${BACKUP_ROOT}/datapump/${DATE_TAG}"
LOG_DIR="${LOG_DIR:-/home/oracle/scripts/logs}"
mkdir -p "$STAGE" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ora_ssh_dp_${DATE_TAG}.log"
DUMPFILE="exp_${DATE_TAG}.dmp"
DPLOG="exp_${DATE_TAG}.log"

{
  echo "==== ora_ssh datapump start $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo "SID=$ORACLE_SID STAGE=$STAGE SCHEMAS=${SCHEMAS:-} FULL=$FULL"
  df -h "$BACKUP_ROOT" / 2>/dev/null || df -h /

  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
CREATE OR REPLACE DIRECTORY ${DUMP_DIR_NAME} AS '${STAGE}';
GRANT READ, WRITE ON DIRECTORY ${DUMP_DIR_NAME} TO SYSTEM;
SELECT 'DB='||name||' MODE='||open_mode FROM v\$database;
EXIT;
SQL

  if [ "$FULL" = "1" ]; then
    expdp \'/ as sysdba\' DIRECTORY=${DUMP_DIR_NAME} DUMPFILE=${DUMPFILE} LOGFILE=${DPLOG} FULL=Y
  else
    if [ -z "$SCHEMAS" ]; then
      echo "ERROR=SCHEMAS required unless FULL=1"
      exit 2
    fi
    expdp \'/ as sysdba\' DIRECTORY=${DUMP_DIR_NAME} DUMPFILE=${DUMPFILE} LOGFILE=${DPLOG} SCHEMAS=${SCHEMAS}
  fi

  echo "DUMP=${STAGE}/${DUMPFILE}"
  ls -lh "$STAGE"
  echo "==== ora_ssh datapump end $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo BACKUP_OK
} >> "$LOG_FILE" 2>&1

echo "OK DATE_TAG=$DATE_TAG LOG=$LOG_FILE DIR=$STAGE DUMP=$DUMPFILE"
