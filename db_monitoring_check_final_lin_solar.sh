#!/usr/bin/env bash
###############################################################################
# Script Name : db_monitoring_check.sh
# Version     : 3.4.2
#
# Author      : Vinay V Deshmukh
# Date        : 2026-02-13
#
# Description :
#   Comprehensive Oracle Database Health Check Script.
#   Linux + Solaris Compatible
###############################################################################

set -euo pipefail
trap 'echo "[FATAL] Line=$LINENO Cmd=$BASH_COMMAND"; exit 2' ERR

#######################################
# OS DETECTION
#######################################
OS_TYPE=$(uname -s)

#######################################
# ORATAB AUTO-DETECTION
#######################################
if [[ -f /etc/oratab ]]; then
  ORATAB=/etc/oratab
elif [[ -f /var/opt/oracle/oratab ]]; then
  ORATAB=/var/opt/oracle/oratab
else
  echo "[CRITICAL] oratab file not found"
  exit 1
fi

#######################################
# GLOBAL CONFIG
#######################################
LOG_DIR=/tmp
TBS_WARN=80
TBS_CRIT=90
SCRIPT_NAME=$(basename "$0")

#######################################
# COMMON FUNCTIONS
#######################################
usage() {
  echo "Usage:"
  echo "  $SCRIPT_NAME -d <ORACLE_SID>"
  echo "  $SCRIPT_NAME --all"
  exit 1
}

report() {
  printf "[%-8s] %s\n" "$1" "$2"
  echo "$(date '+%F %T') | $1 | $2" >> "$LOG_FILE"
}

sql_exec() {
sqlplus -s / as sysdba <<EOF
set pages 0 feed off head off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure
$1
EOF
}

#######################################
# PMON DISCOVERY
#######################################
get_running_sids() {
  ps -ef | awk '
    /ora_pmon_/ && !/ASM/ {
      sub(".*ora_pmon_", "", $NF)
      print $NF
    }
  ' | sort -u
}

get_oracle_home() {
  local sid="$1"
  awk -F: -v s="$sid" '
    $1 == s && $2 !~ /^#/ && $2 != "" {print $2}
  ' "$ORATAB"
}

#######################################
# RMAN CHECK
#######################################
check_rman_archivelog_policy() {

  if ! command -v rman >/dev/null 2>&1; then
    report "WARNING" "RMAN not found in PATH – skipping check"
    return
  fi

  RMAN_OUT=$(rman target / <<EOF
set echo off;
show all;
exit;
EOF
)

  ACTUAL_LINE=$(printf '%s\n' "$RMAN_OUT" | \
    grep -i '^CONFIGURE ARCHIVELOG DELETION POLICY' | \
    head -1 | tr -s ' ' | sed 's/[[:space:]]*$//')

  [[ -z "$ACTUAL_LINE" ]] && {
    report "CRITICAL" "RMAN ARCHIVELOG DELETION POLICY not configured"
    return
  }

  EXPECTED="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;"

  NORM_ACTUAL=$(echo "$ACTUAL_LINE" | tr '[:lower:]' '[:upper:]' | tr -s ' ')
  NORM_EXPECTED=$(echo "$EXPECTED" | tr '[:lower:]' '[:upper:]' | tr -s ' ')

  [[ "$NORM_ACTUAL" == "$NORM_EXPECTED" ]] \
    && report "OK" "RMAN ARCHIVELOG DELETION POLICY correct" \
    || report "CRITICAL" "RMAN policy mismatch: $ACTUAL_LINE"
}

#######################################
# DGBROKER VALIDATION
#######################################
check_dg_broker() {

  BROKER=$(sql_exec "select value from v\$parameter where name='dg_broker_start';")
  [[ "$BROKER" != "TRUE" ]] && return

  command -v dgmgrl >/dev/null 2>&1 || return

  DG_CONFIG=$(dgmgrl -silent / <<EOF
show configuration;
exit;
EOF
)

  CFG_STATUS=$(echo "$DG_CONFIG" | grep "Configuration Status:" | awk -F: '{print $2}' | xargs)

  [[ "$CFG_STATUS" == "SUCCESS" ]] \
    && report "OK" "DGBroker SUCCESS" \
    || report "CRITICAL" "DGBroker Status: $CFG_STATUS"

  STANDBYS=$(echo "$DG_CONFIG" | awk '/Physical standby database/ {print $1}')
  [[ -z "$STANDBYS" ]] && return

  for STBY in $STANDBYS; do

    DG_OUT=$(dgmgrl -silent / <<EOF
validate database verbose $STBY;
exit;
EOF
)

    SW_READY=$(echo "$DG_OUT" | grep "Ready for Switchover:" | awk -F: '{print $2}' | xargs)
    FO_READY=$(echo "$DG_OUT" | grep "Ready for Failover:" | awk -F: '{print $2}' | xargs)

    [[ "$SW_READY" == "Yes" ]] \
      && report "OK" "[$STBY] Ready for Switchover" \
      || report "WARNING" "[$STBY] Switchover: $SW_READY"

    [[ "$FO_READY" == Yes* ]] \
      && report "OK" "[$STBY] Ready for Failover" \
      || report "CRITICAL" "[$STBY] Failover: $FO_READY"

    THREAD_BLOCK=$(echo "$DG_OUT" | \
      awk '/Current Log File Groups Configuration:/,/Future Log File Groups Configuration:/')

    echo "$THREAD_BLOCK" | awk '/^[0-9]+/' | while read -r THREAD ONLINE SRL STATUS; do
      if [[ "$ONLINE" =~ ^[0-9]+$ && "$SRL" =~ ^[0-9]+$ ]]; then
        REQUIRED=$((ONLINE + 1))
        [[ "$SRL" -ge "$REQUIRED" ]] \
          && report "OK" "[$STBY] Thread $THREAD SRL OK ($SRL >= $REQUIRED)" \
          || report "CRITICAL" "[$STBY] Thread $THREAD SRL insufficient ($SRL < $REQUIRED)"
      fi
    done
  done
}

#######################################
# HUGE PAGES (Linux Only)
#######################################
check_memory() {

  if [[ "$OS_TYPE" == "Linux" && -f /proc/meminfo ]]; then
    HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
    HP_FREE=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)

    report "INFO" "HugePages Total=$HP_TOTAL Free=$HP_FREE"

    [[ "$HP_TOTAL" -gt 0 && "$HP_TOTAL" -ne "$HP_FREE" ]] \
      && report "OK" "HugePages in use" \
      || report "WARNING" "HugePages not properly used"

  elif [[ "$OS_TYPE" == "SunOS" ]]; then
    report "INFO" "Solaris detected – HugePages not applicable"
  fi
}

#######################################
# LMS CHECK (Portable)
#######################################
check_lms() {

  [[ "$IS_RAC" != "YES" ]] && return

  if [[ "$OS_TYPE" == "Linux" ]]; then
    PS_CMD="ps -eLo cls,cmd"
  else
    PS_CMD="ps -eo class,args"
  fi

  LMS=$($PS_CMD | grep "ora_lms[0-9]_${ORACLE_SID}" | grep -v ASM | grep -v grep || true)

  [[ -z "$LMS" ]] && {
    report "CRITICAL" "No LMS processes found"
    return
  }

  echo "$LMS" | awk '{print $2}' | sort -u | while read -r l; do
    RR=$(echo "$LMS" | grep "$l" | awk '$1=="RR"' | wc -l)
    [[ "$RR" -ge 1 ]] \
      && report "OK" "LMS $l has RR thread" \
      || report "WARNING" "LMS $l missing RR thread"
  done
}

#######################################
# CORE HEALTH CHECK
#######################################
run_health_check() {

ORACLE_SID="$1"
DATE=$(date '+%Y%m%d_%H%M%S')

ORACLE_HOME=$(get_oracle_home "$ORACLE_SID")
[[ -z "$ORACLE_HOME" || ! -d "$ORACLE_HOME" ]] && {
  echo "[CRITICAL] ORACLE_HOME not found for SID=$ORACLE_SID"
  return
}

export ORACLE_SID ORACLE_HOME
export PATH=$ORACLE_HOME/bin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=$ORACLE_HOME/lib

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/db_health_${ORACLE_SID}_${DATE}.log"

echo "===================================================="
echo " Oracle DB Health Check Started"
echo " SID : $ORACLE_SID"
echo " OS  : $OS_TYPE"
echo "===================================================="

DB_NAME=$(sql_exec "select name from v\$database;")
IS_RAC=$(sql_exec "select case when count(*)>1 then 'YES' else 'NO' end from gv\$instance;")

report "INFO" "DB=$DB_NAME RAC=$IS_RAC"

check_memory
check_lms
check_rman_archivelog_policy
check_dg_broker

report "INFO" "Health check completed"
report "INFO" "Log file: $LOG_FILE"
}

#######################################
# MAIN
#######################################
[[ "$#" -eq 0 ]] && usage

if [[ "$1" == "--all" ]]; then
  for SID in $(get_running_sids); do
    run_health_check "$SID"
  done
elif [[ "$1" == "-d" && -n "${2:-}" ]]; then
  ps -ef | grep "[o]ra_pmon_${2}$" >/dev/null || {
    echo "[ERROR] SID $2 not running"
    exit 1
  }
  run_health_check "$2"
else
  usage
fi
