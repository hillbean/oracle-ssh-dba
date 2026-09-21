#!/bin/bash
# Online RMAN incremental backup (LEVEL 0 or 1). Run as oracle. Does NOT delete obsolete files.
set -euo pipefail

. "$(dirname "$0")/oracle_env.sh"
: "${BACKUP_ROOT:?}"
LEVEL="${LEVEL:-0}"
TAG_PREFIX="${TAG_PREFIX:-ORA_SSH_L${LEVEL}}"
DATE_TAG="${DATE_TAG:-$(date +%Y%m%d_%H%M%S)}"
COPY_ARCH="${COPY_ARCH:-1}"

export PATH="$ORACLE_HOME/bin:$PATH"

BACKUP_SET_DIR="${BACKUP_ROOT}/${DATE_TAG}"
ARCH_STAGE="${BACKUP_ROOT}/${DATE_TAG}_archivelog"
LOG_DIR="${LOG_DIR}"
mkdir -p "$BACKUP_SET_DIR" "$ARCH_STAGE" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ora_ssh_l${LEVEL}_${DATE_TAG}.log"
TAG_FILE="${LOG_DIR}/ora_ssh_backup_latest.tag"

{
  echo "==== ora_ssh backup start $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo "SID=$ORACLE_SID LEVEL=$LEVEL DATE_TAG=$DATE_TAG"
  echo "BACKUP_SET_DIR=$BACKUP_SET_DIR"
  df -h "$BACKUP_ROOT" / 2>/dev/null || df -h /

  sqlplus -s / as sysdba <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'DB='||name||' DBID='||dbid||' MODE='||open_mode FROM v\$database;
SELECT 'INSTANCE='||instance_name||' STATUS='||status FROM v\$instance;
SQL

  SEQ_START=$(sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT sequence# FROM v$log WHERE status='CURRENT';
SQL
)
  SEQ_START=$(echo "$SEQ_START" | tr -d '[:space:]')
  echo "SEQ_START=$SEQ_START"

  rman target / <<EOF
CONFIGURE CONTROLFILE AUTOBACKUP OFF;
RUN {
  ALLOCATE CHANNEL c1 DEVICE TYPE DISK FORMAT '${BACKUP_SET_DIR}/data_%U';
  BACKUP INCREMENTAL LEVEL ${LEVEL} DATABASE TAG '${TAG_PREFIX}';
  BACKUP CURRENT CONTROLFILE FORMAT '${BACKUP_SET_DIR}/controlfile_%d_%T.bkp';
  BACKUP SPFILE FORMAT '${BACKUP_SET_DIR}/spfile_%d_%T.bkp';
}
EXIT;
EOF

  if ! ls -1 "$BACKUP_SET_DIR"/controlfile_* >/dev/null 2>&1; then
    echo "RMAN_BACKUP_FAILED"
    ls -l "$BACKUP_SET_DIR" || true
    exit 1
  fi

  sqlplus -s / as sysdba <<'SQL'
ALTER SYSTEM ARCHIVE LOG CURRENT;
SQL

  if [ "$COPY_ARCH" = "1" ]; then
    SEQ_END=$(sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT MAX(sequence#) FROM v$archived_log WHERE dest_id=1 AND status='A';
SQL
)
    SEQ_END=$(echo "$SEQ_END" | tr -d '[:space:]')
    echo "SEQ_END=$SEQ_END"
    sqlplus -s / as sysdba <<SQL > "${ARCH_STAGE}/archlist.txt"
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400
SELECT name FROM v\$archived_log
 WHERE dest_id=1 AND status='A'
   AND sequence# >= ${SEQ_START}
   AND sequence# <= ${SEQ_END};
SQL
    copied=0
    while IFS= read -r f; do
      f=$(echo "$f" | tr -d '\r')
      [ -z "$f" ] && continue
      if [ -f "$f" ]; then
        cp -p "$f" "$ARCH_STAGE/"
        copied=$((copied+1))
        echo "COPIED_ARCH=$f"
      else
        echo "MISSING_ARCH=$f"
      fi
    done < "${ARCH_STAGE}/archlist.txt"
    echo "ARCH_COPIED=$copied"
  fi

  echo "BACKUP_SET_DIR=$BACKUP_SET_DIR"
  echo "ARCH_STAGE=$ARCH_STAGE"
  echo "---- backup set ----"
  ls -lh "$BACKUP_SET_DIR"
  echo "==== ora_ssh backup end $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo BACKUP_OK
} >> "$LOG_FILE" 2>&1

echo "$DATE_TAG" > "$TAG_FILE"
echo "OK DATE_TAG=$DATE_TAG LOG=$LOG_FILE DIR=$BACKUP_SET_DIR"
