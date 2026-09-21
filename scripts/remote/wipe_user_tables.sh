#!/bin/bash
# Drop all non-Oracle user tables on the current instance. DESTRUCTIVE.
# Never run against the source/production database.
set -euo pipefail

. "$(dirname "$0")/oracle_env.sh"
OWNERS="${OWNERS:-}"
ALLOW_NOT_OPEN="${ALLOW_NOT_OPEN:-0}"
OWNERS_SQL=$(printf '%s' "$OWNERS" | tr 'a-z' 'A-Z' | sed "s/'/''/g")

LOG_DIR="${LOG_DIR}"
DATE_TAG="${DATE_TAG:-$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ora_ssh_wipe_${DATE_TAG}.log"

{
  echo "==== ora_ssh wipe tables start $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo "SID=$ORACLE_SID HOST=$(hostname) OWNERS=${OWNERS:-ALL_USER}"

  MODE=$(sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT REPLACE(open_mode,' ','') FROM v$database;
EXIT;
SQL
)
  MODE=$(echo "$MODE" | tr -d '[:space:]')
  echo "OPEN_MODE=$MODE"
  if [ "$MODE" != "READWRITE" ]; then
    echo "WIPE_SKIPPED=database not OPEN READ WRITE"
    if [ "$ALLOW_NOT_OPEN" = "1" ]; then
      echo WIPE_OK
      exit 0
    fi
    exit 3
  fi

  sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR CONTINUE
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINES 400 PAGES 0 FEEDBACK OFF HEADING OFF
DECLARE
  v_n    NUMBER := 0;
  v_fail NUMBER := 0;
  v_owners VARCHAR2(4000) := '${OWNERS_SQL}';
  v_sql VARCHAR2(1000);
BEGIN
  FOR r IN (
    SELECT t.owner, t.table_name
      FROM dba_tables t
      JOIN dba_users u ON u.username = t.owner
     WHERE t.nested = 'NO'
       AND NVL(t.dropped, 'NO') = 'NO'
       AND (
            (v_owners IS NOT NULL AND v_owners <> ''
             AND INSTR(','||v_owners||',', ','||t.owner||',') > 0)
         OR ( (v_owners IS NULL OR v_owners = '')
             AND NVL(u.oracle_maintained, 'N') = 'N'
             AND t.owner NOT IN (
               'SYS','SYSTEM','OUTLN','DBSNMP','APPQOSSYS','DBSFWUSER','GGSYS',
               'ANONYMOUS','XDB','OJVMSYS','CTXSYS','ORDDATA','ORDPLUGINS',
               'ORDSYS','SI_INFORMTN_SCHEMA','MDSYS','OLAPSYS','WMSYS','EXFSYS',
               'SYSMAN','MGMT_VIEW','AUDSYS','GSMADMIN_INTERNAL','DIP','ORACLE_OCM',
               'SYSBACKUP','SYSDG','SYSKM','SYSRAC','DVSYS','DVF','LBACSYS',
               'GSMCATUSER','GSMUSER','MDDATA','REMOTE_SCHEDULER_AGENT','FLOWS_FILES'
             ))
       )
     ORDER BY t.owner, t.table_name
  ) LOOP
    BEGIN
      v_sql := 'DROP TABLE "'||r.owner||'"."'||r.table_name||'" CASCADE CONSTRAINTS PURGE';
      EXECUTE IMMEDIATE v_sql;
      v_n := v_n + 1;
      DBMS_OUTPUT.PUT_LINE('DROPPED='||r.owner||'.'||r.table_name);
    EXCEPTION
      WHEN OTHERS THEN
        v_fail := v_fail + 1;
        DBMS_OUTPUT.PUT_LINE('FAIL='||r.owner||'.'||r.table_name||' '||SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('DROP_OK_COUNT='||v_n);
  DBMS_OUTPUT.PUT_LINE('DROP_FAIL_COUNT='||v_fail);
END;
/
PURGE DBA_RECYCLEBIN;
SELECT 'REMAIN_USER_TABLES='||COUNT(*)
  FROM dba_tables t
  JOIN dba_users u ON u.username = t.owner
 WHERE t.nested = 'NO'
   AND NVL(u.oracle_maintained, 'N') = 'N';
SELECT 'REMAIN='||owner||' '||COUNT(*)
  FROM dba_tables t
  JOIN dba_users u ON u.username = t.owner
 WHERE t.nested = 'NO'
   AND NVL(u.oracle_maintained, 'N') = 'N'
 GROUP BY owner
 ORDER BY 1;
EXIT;
EOF

  fail=$(awk -F= '/^DROP_FAIL_COUNT=/ {print \$2}' "$LOG_FILE" | tail -1)
  echo "PARSED_FAIL=${fail:-unset}"
  if [ "${fail:-1}" != "0" ]; then
    echo WIPE_FAILED
    exit 1
  fi
  echo "==== ora_ssh wipe tables end $(date '+%Y-%m-%d %H:%M:%S') ===="
  echo WIPE_OK
} >> "$LOG_FILE" 2>&1

echo "OK LOG=$LOG_FILE"
