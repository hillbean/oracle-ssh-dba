#!/bin/bash
# Print Oracle identity in KEY=value lines. Run as oracle (login env).
set -u
. "$(dirname "$0")/oracle_env.sh"

list_sids() {
  if [ -n "${ORATAB:-}" ]; then
    awk -F: '!/^#/ && NF>=2 && $1!="" {print $1":"$2}' "$ORATAB"
  fi
}

echo "HOST=$(hostname)"
echo "ORACLE_SID=$ORACLE_SID"
echo "ORACLE_HOME=$ORACLE_HOME"
echo "ORACLE_USER_HOME=$ORACLE_USER_HOME"
echo "BACKUP_ROOT=$BACKUP_ROOT"
echo "ORATAB=${ORATAB:-none}"
echo "---- oratab ----"
list_sids
echo "---- processes ----"
ps -ef | grep -E "[o]ra_pmon_${ORACLE_SID}|[t]nslsnr" || echo "NO_PMON_OR_LISTENER"
echo "---- df ----"
df -h / "$ORACLE_HOME" "$ORACLE_USER_HOME" 2>/dev/null | awk 'NR==1 || !seen[$1]++'
echo "---- sqlplus ----"

sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR CONTINUE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMSPOOL ON
SELECT 'INSTANCE='||instance_name||' STATUS='||status||' HOST_NAME='||host_name FROM v$instance;
SELECT 'VERSION='||version FROM v$instance;
SELECT 'VERSION_FULL='||version_full FROM v$instance;
SELECT 'EDITION_COL='||edition FROM v$instance;
SELECT 'BANNER='||banner FROM v$version;
SELECT 'BANNER_FULL='||banner_full FROM v$version WHERE banner_full IS NOT NULL;
SELECT CASE
         WHEN SUM(CASE WHEN banner LIKE '%Enterprise Edition%' THEN 1 ELSE 0 END)>0 THEN 'EDITION=Enterprise Edition'
         WHEN SUM(CASE WHEN banner LIKE '%Standard Edition 2%' THEN 1 ELSE 0 END)>0 THEN 'EDITION=Standard Edition 2'
         WHEN SUM(CASE WHEN banner LIKE '%Standard Edition One%' THEN 1 ELSE 0 END)>0 THEN 'EDITION=Standard Edition One'
         WHEN SUM(CASE WHEN banner LIKE '%Standard Edition%' THEN 1 ELSE 0 END)>0 THEN 'EDITION=Standard Edition'
         WHEN SUM(CASE WHEN banner LIKE '%Express%' THEN 1 ELSE 0 END)>0 THEN 'EDITION=Express Edition'
         WHEN SUM(CASE WHEN banner LIKE '%Personal Edition%' THEN 1 ELSE 0 END)>0 THEN 'EDITION=Personal Edition'
         ELSE 'EDITION=unknown'
       END FROM v$version;
SELECT 'DB_NAME='||name||' DBID='||dbid||' OPEN_MODE='||open_mode||' LOG_MODE='||log_mode||' ROLE='||database_role FROM v$database;
SELECT 'PLATFORM='||platform_name FROM v$database;
SELECT 'DB_UNIQUE_NAME='||db_unique_name FROM v$database;
SELECT 'CDB='||cdb FROM v$database;
SELECT 'CREATED='||TO_CHAR(created,'YYYY-MM-DD HH24:MI:SS') FROM v$database;
SELECT 'RESETLOGS='||TO_CHAR(resetlogs_time,'YYYY-MM-DD HH24:MI:SS') FROM v$database;
SELECT 'COMP='||product||'|'||version||'|'||status FROM product_component_version WHERE product LIKE 'Oracle%' AND ROWNUM<=8;
EXIT;
SQL

echo "---- listener ----"
lsnrctl status 2>/dev/null | grep -E 'Alias|VERSION|STATUS of the LISTENER|Instance|READY|BLOCKED|Service ' | head -40 || echo "LISTENER=unknown"
echo "INSPECT_DONE"
