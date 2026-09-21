#!/bin/bash
# Data Pump import. DESTRUCTIVE for target schemas. Run as oracle.
set -euo pipefail

. "$(dirname "$0")/oracle_env.sh"
: "${DUMP_PATH:?}"
DUMP_DIR_NAME="${DUMP_DIR_NAME:-ORA_SSH_DP}"
SCHEMAS="${SCHEMAS:-}"
FULL="${FULL:-0}"
TABLE_EXISTS="${TABLE_EXISTS:-SKIP}"
REMAP_SCHEMA="${REMAP_SCHEMA:-}"

STAGE=$(dirname "$DUMP_PATH")
DUMPFILE=$(basename "$DUMP_PATH")
DATE_TAG="${DATE_TAG:-$(date +%Y%m%d_%H%M%S)}"
LOG_DIR="${LOG_DIR}"
mkdir -p "$STAGE" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ora_ssh_impdp_${DATE_TAG}.log"
DPLOG="imp_${DATE_TAG}.log"

{
  echo "==== ora_ssh impdp start $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo "SID=$ORACLE_SID DUMP=$DUMP_PATH FULL=$FULL SCHEMAS=${SCHEMAS:-}"
  ls -lh "$DUMP_PATH"

  sqlplus -s / as sysdba <<SQL
WHENEVER SQLERROR EXIT SQL.SQLCODE
CREATE OR REPLACE DIRECTORY ${DUMP_DIR_NAME} AS '${STAGE}';
EXIT;
SQL

  EXTRA=""
  if [ "$FULL" = "1" ]; then
    EXTRA="FULL=Y"
  elif [ -n "$SCHEMAS" ]; then
    EXTRA="SCHEMAS=${SCHEMAS}"
  fi
  if [ -n "$REMAP_SCHEMA" ]; then
    EXTRA="${EXTRA} REMAP_SCHEMA=${REMAP_SCHEMA}"
  fi

  impdp \'/ as sysdba\' DIRECTORY=${DUMP_DIR_NAME} DUMPFILE=${DUMPFILE} LOGFILE=${DPLOG} TABLE_EXISTS_ACTION=${TABLE_EXISTS} ${EXTRA}

  echo "==== ora_ssh impdp end $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo RESTORE_OK
} >> "$LOG_FILE" 2>&1

echo "OK LOG=$LOG_FILE"
