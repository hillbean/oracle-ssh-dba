#!/bin/bash
# RMAN restore from a backup set directory. DESTRUCTIVE. Run as oracle.
# One RMAN session: spfile + controlfile + catalog + restore + recover [+ resetlogs].
set -euo pipefail

. "$(dirname "$0")/oracle_env.sh"
: "${BACKUP_SET_DIR:?}"
: "${DBID:?}"
ARCH_DIR="${ARCH_DIR:-}"
UNTIL_SEQUENCE="${UNTIL_SEQUENCE:-}"
OPEN_RESETLOGS="${OPEN_RESETLOGS:-1}"
LISTENER_HOST="${LISTENER_HOST:-}"
LISTENER_PORT="${LISTENER_PORT:-1521}"

CTL=$(ls -1 ${BACKUP_SET_DIR}/controlfile_*.bkp 2>/dev/null | head -1 || true)
SPF=$(ls -1 ${BACKUP_SET_DIR}/spfile_*.bkp 2>/dev/null | head -1 || true)
if [ -z "$CTL" ] || [ -z "$SPF" ]; then
  echo "ERROR=controlfile or spfile backup not found in $BACKUP_SET_DIR"
  ls -lh "$BACKUP_SET_DIR" || true
  exit 2
fi

LOG_DIR="${LOG_DIR}"
DATE_TAG="${DATE_TAG:-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ora_ssh_restore_${DATE_TAG}.log"

ARCH_SQL=""
if [ -n "$ARCH_DIR" ]; then
  ARCH_SQL="CATALOG START WITH '${ARCH_DIR}/' NOPROMPT;"
fi

if [ -n "$UNTIL_SEQUENCE" ]; then
  RESTORE_SQL="
RUN {
  SET UNTIL SEQUENCE ${UNTIL_SEQUENCE} THREAD 1;
  RESTORE DATABASE;
  RECOVER DATABASE;
}
"
else
  RESTORE_SQL="
RESTORE DATABASE;
RECOVER DATABASE;
"
fi

OPEN_SQL=""
if [ "$OPEN_RESETLOGS" = "1" ]; then
  OPEN_SQL="ALTER DATABASE OPEN RESETLOGS;"
fi

{
  echo "==== ora_ssh restore start $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo "SID=$ORACLE_SID DBID=$DBID"
  echo "BACKUP_SET_DIR=$BACKUP_SET_DIR CTL=$CTL SPF=$SPF"
  echo "ARCH_DIR=${ARCH_DIR:-none} UNTIL_SEQUENCE=${UNTIL_SEQUENCE:-none}"
  ls -lh "$BACKUP_SET_DIR"
  [ -n "$ARCH_DIR" ] && ls -lh "$ARCH_DIR"

  sqlplus -s / as sysdba <<'SQL' || true
WHENEVER SQLERROR CONTINUE
SHUTDOWN IMMEDIATE;
SHUTDOWN ABORT;
EXIT;
SQL

  rman target / <<RMAN
SET ECHO ON;
SET DBID ${DBID};
STARTUP NOMOUNT;
RESTORE SPFILE FROM '${SPF}';
STARTUP FORCE NOMOUNT;
RESTORE CONTROLFILE FROM '${CTL}';
ALTER DATABASE MOUNT;
CATALOG START WITH '${BACKUP_SET_DIR}/' NOPROMPT;
${ARCH_SQL}
${RESTORE_SQL}
${OPEN_SQL}
EXIT;
RMAN

  sqlplus -s / as sysdba <<'SQL' || true
SET LINES 200
SELECT instance_name, status, database_status FROM v$instance;
SELECT name, open_mode, dbid FROM v$database;
EXIT;
SQL

  lsnrctl start || true
  if [ -n "$LISTENER_HOST" ]; then
    sqlplus -s / as sysdba <<SQL
ALTER SYSTEM SET local_listener='(ADDRESS=(PROTOCOL=TCP)(HOST=${LISTENER_HOST})(PORT=${LISTENER_PORT}))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
EXIT;
SQL
  fi
  lsnrctl status || true
  echo "==== ora_ssh restore end $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo RESTORE_OK
} >> "$LOG_FILE" 2>&1

echo "OK LOG=$LOG_FILE"
