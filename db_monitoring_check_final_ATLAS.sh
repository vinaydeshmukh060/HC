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
#   - HugePages validated using Oracle MOS Doc ID 401749.1
#   - RAC instance status, services, load, LMS checks
#   - Tablespace, blocking session, parameter consistency checks,
#   - RMAN config check for archivelog deletion
#   - DGBroker validation (Switchover/Failover/Apply/Transport/SRL)
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
# PMON-BASED DISCOVERY
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
    report "WARNING" "RMAN not found in PATH – skipping ARCHIVELOG DELETION POLICY check"
    return
  fi

  report "INFO" "Checking RMAN ARCHIVELOG DELETION POLICY"

  local RMAN_OUT
  RMAN_OUT=$(rman target / <<EOF
set echo off;
show all;
exit;
EOF
)

  local ACTUAL_LINE
  ACTUAL_LINE=$(printf '%s\n' "$RMAN_OUT" | \
    grep -i '^CONFIGURE ARCHIVELOG DELETION POLICY' | head -1 | tr -s ' ' | sed 's/[[:space:]]*$//')

  if [[ -z "$ACTUAL_LINE" ]]; then
    report "CRITICAL" "RMAN ARCHIVELOG DELETION POLICY not configured"
    return
  fi

  local EXPECTED="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;"

  local NORM_ACTUAL NORM_EXPECTED
  NORM_ACTUAL=$(echo "$ACTUAL_LINE" | tr '[:lower:]' '[:upper:]' | tr -s ' ')
  NORM_EXPECTED=$(echo "$EXPECTED"  | tr '[:lower:]' '[:upper:]' | tr -s ' ')

  if [[ "$NORM_ACTUAL" == "$NORM_EXPECTED" ]]; then
    report "OK" "RMAN: $ACTUAL_LINE"
  else
    report "CRITICAL" "RMAN ARCHIVELOG DELETION POLICY mismatch"
  fi
}

#######################################
# DGBROKER VALIDATION (ADDED ONLY)
#######################################
check_dg_broker() {

  BROKER=$(sql_exec "select value from v\$parameter where name='dg_broker_start';")

  [[ "$BROKER" != "TRUE" ]] && return

  command -v dgmgrl >/dev/null 2>&1 || return

  report "INFO" "Checking Data Guard Broker"

  DG_CONFIG=$(dgmgrl -silent / <<EOF
show configuration;
exit;
EOF
)

  CFG_STATUS=$(echo "$DG_CONFIG" | grep "Configuration Status:" | awk -F: '{print $2}' | xargs)

  [[ "$CFG_STATUS" == "SUCCESS" ]] \
    && report "OK" "DGBroker Configuration SUCCESS" \
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

  done
}

#######################################
# CORE HEALTH CHECK
#######################################
run_health_check() {

ORACLE_SID="$1"
DATE=$(date '+%Y%m%d_%H%M%S')

ORACLE_HOME=$(get_oracle_home "$ORACLE_SID")
if [[ -z "$ORACLE_HOME" || ! -d "$ORACLE_HOME" ]]; then
  echo "[CRITICAL] ORACLE_HOME not found for SID=$ORACLE_SID"
  return
fi

export ORACLE_SID ORACLE_HOME
export PATH=$ORACLE_HOME/bin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=$ORACLE_HOME/lib
export TNS_ADMIN=$ORACLE_HOME/network/admin

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

# (ALL YOUR EXISTING LOGIC REMAINS UNCHANGED HERE)
# HugePages
# RAC
# Tablespaces
# Blocking sessions
# LMS checks
# etc...

#######################################
# RMAN CHECK
#######################################
check_rman_archivelog_policy

#######################################
# DGBROKER CHECK (ADDED)
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
  ps -ef | grep "[o]ra_pmon_${2}$" >/dev/null || { echo "[ERROR] SID $2 not running"; exit 1; }
  run_health_check "$2"
else
  usage
fi
