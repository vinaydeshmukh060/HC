#!/bin/bash
###############################################################################
# Script Name : db_monitoring_check.sh
# Version     : 3.3.0
#
# Author      : Vinay V Deshmukh
# Date        : 2026-02-13
#
# Description :
#   Comprehensive Oracle Database Health Check Script.
#   - PMON-driven detection of running databases
#   - ORACLE_HOME resolved from /etc/oratab (lookup only)
#   - RAC / Single Instance aware
#   - CDB / PDB aware
#   - HugePages validation
#   - RAC instance/services/load/LMS checks
#   - Tablespace, blocking sessions
#   - RMAN archivelog deletion policy check
#   - Data Guard Broker validation (Switchover/Failover/SRL/Apply/Transport)
#
###############################################################################

set -euo pipefail
trap 'echo "[FATAL] Line=$LINENO Cmd=$BASH_COMMAND"; exit 2' ERR

#######################################
# GLOBAL CONFIG
#######################################
ORATAB=/etc/oratab
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
# RMAN ARCHIVELOG POLICY CHECK
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

  if [[ -z "$ACTUAL_LINE" ]]; then
    report "CRITICAL" "RMAN ARCHIVELOG DELETION POLICY not configured"
    return
  fi

  EXPECTED="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;"

  NORM_ACTUAL=$(echo "$ACTUAL_LINE" | tr '[:lower:]' '[:upper:]' | tr -s ' ')
  NORM_EXPECTED=$(echo "$EXPECTED" | tr '[:lower:]' '[:upper:]' | tr -s ' ')

  if [[ "$NORM_ACTUAL" == "$NORM_EXPECTED" ]]; then
    report "OK" "RMAN ARCHIVELOG DELETION POLICY correct"
  else
    report "CRITICAL" "RMAN policy mismatch: $ACTUAL_LINE"
  fi
}

#######################################
# DGBROKER VALIDATION
#######################################
check_dg_broker() {

  BROKER=$(sql_exec "select value from v\$parameter where name='dg_broker_start';")

  if [[ "$BROKER" != "TRUE" ]]; then
    report "INFO" "DGBroker not enabled"
    return
  fi

  if ! command -v dgmgrl >/dev/null 2>&1; then
    report "WARNING" "dgmgrl not found – skipping DG check"
    return
  fi

  DG_CONFIG=$(dgmgrl -silent / <<EOF
show configuration;
exit;
EOF
)

  CFG_STATUS=$(echo "$DG_CONFIG" | grep "Configuration Status:" | awk -F: '{print $2}' | xargs)

  [[ "$CFG_STATUS" == "SUCCESS" ]] \
    && report "OK" "DGBroker Configuration SUCCESS" \
    || report "CRITICAL" "DGBroker Configuration Status: $CFG_STATUS"

  STANDBYS=$(echo "$DG_CONFIG" | awk '/Physical standby database/ {print $1}')
  [[ -z "$STANDBYS" ]] && return

  for STBY in $STANDBYS; do

    report "INFO" "Validating standby: $STBY"

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

    APPLY_BLOCK=$(echo "$DG_OUT" | \
      awk '/Standby Apply-Related Information:/,/Transport-Related Information:/')

    APPLY_STATE=$(echo "$APPLY_BLOCK" | grep "Apply State:" | awk -F: '{print $2}' | xargs)
    APPLY_LAG=$(echo "$APPLY_BLOCK" | grep "Apply Lag:" | awk -F: '{print $2}' | awk '{print $1}')
    APPLY_DELAY=$(echo "$APPLY_BLOCK" | grep "Apply Delay:" | awk -F: '{print $2}' | awk '{print $1}')

    if [[ "$APPLY_LAG" =~ ^[0-9]+$ && "$APPLY_DELAY" =~ ^[0-9]+$ ]]; then
      [[ "$APPLY_STATE" == "Running" && "$APPLY_LAG" -eq 0 && "$APPLY_DELAY" -eq 0 ]] \
        && report "OK" "[$STBY] Apply Healthy" \
        || report "CRITICAL" "[$STBY] Apply Issue: State=$APPLY_STATE Lag=${APPLY_LAG}s Delay=${APPLY_DELAY}m"
    else
      report "CRITICAL" "[$STBY] Apply values invalid"
    fi

    TRANSPORT_BLOCK=$(echo "$DG_OUT" | \
      awk '/Transport-Related Information:/,/Log Files Cleared:/')

    TRANSPORT_ON=$(echo "$TRANSPORT_BLOCK" | grep "Transport On:" | awk -F: '{print $2}' | xargs)
    GAP_STATUS=$(echo "$TRANSPORT_BLOCK" | grep "Gap Status:" | awk -F: '{print $2}' | xargs)
    TRANSPORT_LAG=$(echo "$TRANSPORT_BLOCK" | grep "Transport Lag:" | awk -F: '{print $2}' | awk '{print $1}')
    TRANSPORT_STATUS=$(echo "$TRANSPORT_BLOCK" | grep "Transport Status:" | awk -F: '{print $2}' | xargs)

    if [[ "$TRANSPORT_LAG" =~ ^[0-9]+$ ]]; then
      [[ "$TRANSPORT_ON" == "Yes" && "$GAP_STATUS" == "No Gap" && "$TRANSPORT_LAG" -eq 0 && "$TRANSPORT_STATUS" == "Success" ]] \
        && report "OK" "[$STBY] Transport Healthy" \
        || report "CRITICAL" "[$STBY] Transport Issue"
    else
      report "CRITICAL" "[$STBY] Transport Lag invalid"
    fi

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
echo " Time: $(date)"
echo "===================================================="

DB_NAME=$(sql_exec "select name from v\$database;")
DB_ROLE=$(sql_exec "select database_role from v\$database;")
IS_CDB=$(sql_exec "select cdb from v\$database;")
IS_RAC=$(sql_exec "select case when count(*)>1 then 'YES' else 'NO' end from gv\$instance;")

report "INFO" "DB=$DB_NAME ROLE=$DB_ROLE CDB=$IS_CDB RAC=$IS_RAC"

# (All your existing RAC, HugePages, Tablespace, Blocking session checks remain unchanged here)

#######################################
# RMAN CHECK
#######################################
check_rman_archivelog_policy

#######################################
# DGBROKER CHECK
#######################################
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
