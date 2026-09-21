#!/bin/bash
# Resolve SID, HOME, BACKUP_ROOT on the server. Source this file.
# HOME: oratab/pmon. BACKUP_ROOT: $ORACLE_USER_HOME/backup/full (source)
# or $ORACLE_USER_HOME/backup/from_source (backup). User does not fill these.

_ora_oratab() {
  if [ -f /etc/oratab ]; then echo /etc/oratab
  elif [ -f /var/opt/oracle/oratab ]; then echo /var/opt/oracle/oratab
  fi
}

_ora_user_home() {
  _u="${ORACLE_OS_USER:-oracle}"
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$_u" | cut -d: -f6
    return
  fi
  eval echo "~$_u"
}

ORATAB=$(_ora_oratab)

if [ -z "${ORACLE_SID:-}" ]; then
  PMON_SID=$(ps -ef | awk '/[o]ra_pmon_/ {sub(/.*ora_pmon_/, ""); print; exit}')
  if [ -n "${PMON_SID:-}" ]; then
    ORACLE_SID=$PMON_SID
  elif [ -n "${ORATAB:-}" ]; then
    ORACLE_SID=$(awk -F: '!/^#/ && NF>=2 && $1!="" {print $1; exit}' "$ORATAB")
  fi
fi

if [ -z "${ORACLE_HOME:-}" ] && [ -n "${ORATAB:-}" ] && [ -n "${ORACLE_SID:-}" ]; then
  ORACLE_HOME=$(awk -F: -v sid="$ORACLE_SID" '!/^#/ && $1==sid {print $2; exit}' "$ORATAB")
fi

if [ -z "${ORACLE_HOME:-}" ] && command -v sqlplus >/dev/null 2>&1; then
  _sqlplus_bin=$(command -v sqlplus)
  ORACLE_HOME=$(cd "$(dirname "$_sqlplus_bin")/.." && pwd)
fi

ORACLE_USER_HOME=$(_ora_user_home)
if [ -z "${ORACLE_USER_HOME:-}" ]; then
  ORACLE_USER_HOME=${HOME:-/home/oracle}
fi

if [ -z "${BACKUP_ROOT:-}" ]; then
  if [ "${ORA_SSH_ROLE:-}" = "backup" ]; then
    BACKUP_ROOT="${ORACLE_USER_HOME}/backup/from_source"
  else
    BACKUP_ROOT="${ORACLE_USER_HOME}/backup/full"
  fi
fi

if [ -z "${LOG_DIR:-}" ]; then
  LOG_DIR="${ORACLE_USER_HOME}/scripts/logs"
fi

if [ -z "${ORACLE_SID:-}" ] || [ -z "${ORACLE_HOME:-}" ]; then
  echo "ERROR=cannot resolve ORACLE_SID/ORACLE_HOME from oratab/pmon" >&2
  echo "ORATAB=${ORATAB:-missing} SID=${ORACLE_SID:-} HOME=${ORACLE_HOME:-}" >&2
  return 2 2>/dev/null || exit 2
fi

export ORACLE_SID ORACLE_HOME ORATAB ORACLE_USER_HOME BACKUP_ROOT LOG_DIR
export PATH="$ORACLE_HOME/bin:$PATH"
