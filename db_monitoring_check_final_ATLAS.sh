#!/bin/bash
###############################################################################
# Script Name : db_monitoring_check.sh
# Version     : 3.2.2
#
# Author      : Vinay V Deshmukh
# Date        : 2026-01-29
#
# Description :
#   Comprehensive Oracle Database Health Check Script.
#   - PMON-driven detection of running databases
#   - ORACLE_HOME resolved from /etc/oratab (lookup only)
#   - RAC / Single Instance aware
#   - CDB / PDB aware
#   - HugePages validated using Oracle MOS Doc ID 401749.1
#   - RAC instance status, services, load, LMS checks
#   - Tablespace, blocking session, parameter consistency checks,RMAN config check for archivelog deletion
#
# Usage :
#   ./db_hc_experi.sh -d <ORACLE_SID>
#   ./db_hc_experi.sh --all
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
# PMON-BASED DISCOVERY (SOURCE OF TRUTH)
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
# RMAN ARCHIVELOG POLICY CHECK (ADDED)
#######################################
check_rman_archivelog_policy() {
  # Ensure RMAN is available
  if ! command -v rman >/dev/null 2>&1; then
    report "WARNING" "RMAN not found in PATH – skipping ARCHIVELOG DELETION POLICY check"
    return
  fi

  report "INFO" "Checking RMAN ARCHIVELOG DELETION POLICY"

  # Capture RMAN SHOW ALL output
  local RMAN_OUT
  RMAN_OUT=$(rman target / <<EOF
set echo off;
show all;
exit;
EOF
)

#######################################
# DATA GUARD BROKER VALIDATION (ADDED)
#######################################
check_dg_broker() {

  BROKER=$(sql_exec "select value from v\$parameter where name='dg_broker_start';")
  [[ "$BROKER" != "TRUE" ]] && return

  command -v dgmgrl >/dev/null 2>&1 || {
    report "WARNING" "dgmgrl not found – skipping DG Broker check"
    return
  }

  report "INFO" "Checking Data Guard Broker configuration"

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

    ################ TEMP FILE MATCH ################
    TEMP_BLOCK=$(echo "$DG_OUT" | awk '/Temporary Tablespace File Information:/,/Data file Online Move in Progress:/')
    PRIMARY_TEMP=$(echo "$TEMP_BLOCK" | awk '/TEMP Files:/ {print $NF}' | head -1)
    STBY_TEMP=$(echo "$TEMP_BLOCK" | awk '/TEMP Files:/ {print $NF}' | tail -1)

    [[ "$PRIMARY_TEMP" == "$STBY_TEMP" ]] \
      && report "OK" "[$STBY] TEMP files match ($PRIMARY_TEMP)" \
      || report "CRITICAL" "[$STBY] TEMP mismatch Primary=$PRIMARY_TEMP Standby=$STBY_TEMP"

    ################ APPLY ################
    APPLY_STATE=$(echo "$DG_OUT" | grep "Apply State:" | awk -F: '{print $2}' | xargs)
    APPLY_LAG=$(echo "$DG_OUT" | grep "Apply Lag:" | awk -F: '{print $2}' | awk '{print $1}')
    APPLY_DELAY=$(echo "$DG_OUT" | grep "Apply Delay:" | awk -F: '{print $2}' | awk '{print $1}')

    [[ "$APPLY_STATE" == "Running" && "$APPLY_LAG" -eq 0 && "$APPLY_DELAY" -eq 0 ]] \
      && report "OK" "[$STBY] Apply Healthy" \
      || report "CRITICAL" "[$STBY] Apply Issue: State=$APPLY_STATE Lag=${APPLY_LAG}s Delay=${APPLY_DELAY}m"

    ################ TRANSPORT ################
    TRANSPORT_ON=$(echo "$DG_OUT" | grep "Transport On:" | awk -F: '{print $2}' | xargs)
    GAP_STATUS=$(echo "$DG_OUT" | grep "Gap Status:" | awk -F: '{print $2}' | xargs)
    TRANSPORT_LAG=$(echo "$DG_OUT" | grep "Transport Lag:" | awk -F: '{print $2}' | awk '{print $1}')
    TRANSPORT_STATUS=$(echo "$DG_OUT" | grep "Transport Status:" | awk -F: '{print $2}' | xargs)

    [[ "$TRANSPORT_ON" == "Yes" && "$GAP_STATUS" == "No Gap" && "$TRANSPORT_LAG" -eq 0 && "$TRANSPORT_STATUS" == "Success" ]] \
      && report "OK" "[$STBY] Transport Healthy" \
      || report "CRITICAL" "[$STBY] Transport Issue"

    ################ SRL +1 RULE ################
    CURRENT_BLOCK=$(echo "$DG_OUT" | awk '/Current Log File Groups Configuration:/,/Future Log File Groups Configuration:/')
    echo "$CURRENT_BLOCK" | awk '/^[0-9]+/' | while read -r THREAD ONLINE SRL STATUS; do
      REQUIRED=$((ONLINE + 1))
      [[ "$SRL" -ge "$REQUIRED" ]] \
        && report "OK" "[$STBY] Thread $THREAD SRL OK ($SRL >= $REQUIRED)" \
        || report "CRITICAL" "[$STBY] Thread $THREAD SRL insufficient ($SRL < $REQUIRED)"
    done

    ################ REDO SIZE MATCH ################
    SIZE_BLOCK=$(echo "$DG_OUT" | awk '/Current Configuration Log File Sizes:/,/Future Configuration Log File Sizes:/')
    echo "$SIZE_BLOCK" | awk '/^[0-9]+/' | while read -r THREAD ONLINE_SIZE UNIT1 STBY_SIZE UNIT2; do
      [[ "$ONLINE_SIZE" == "$STBY_SIZE" ]] \
        && report "OK" "[$STBY] Redo Size Match ($ONLINE_SIZE)" \
        || report "CRITICAL" "[$STBY] Redo Size Mismatch"
    done

  done
}


  # Extract the ARCHIVELOG DELETION POLICY line
  local ACTUAL_LINE
  ACTUAL_LINE=$(printf '%s\n' "$RMAN_OUT" | \
    grep -i '^CONFIGURE ARCHIVELOG DELETION POLICY' | head -1 | tr -s ' ' | sed 's/[[:space:]]*$//')

  if [[ -z "$ACTUAL_LINE" ]]; then
    report "CRITICAL" "RMAN ARCHIVELOG DELETION POLICY not configured or not visible in SHOW ALL"
    return
  fi

  # Expected configuration (including DISK)
  local EXPECTED="CONFIGURE ARCHIVELOG DELETION POLICY TO APPLIED ON ALL STANDBY BACKED UP 1 TIMES TO DISK;"

  # Normalize case and spaces for robust comparison
  local NORM_ACTUAL NORM_EXPECTED
  NORM_ACTUAL=$(echo "$ACTUAL_LINE" | tr '[:lower:]' '[:upper:]' | tr -s ' ')
  NORM_EXPECTED=$(echo "$EXPECTED"  | tr '[:lower:]' '[:upper:]' | tr -s ' ')

  if [[ "$NORM_ACTUAL" == "$NORM_EXPECTED" ]]; then
    report "OK" "RMAN: $ACTUAL_LINE"
  else
    report "CRITICAL" "RMAN ARCHIVELOG DELETION POLICY mismatch. Current: [$ACTUAL_LINE] | Expected: [$EXPECTED]"
  fi
}

#######################################
# CORE HEALTH CHECK
#######################################
run_health_check() {

ORACLE_SID="$1"
DATE=$(date '+%Y%m%d_%H%M%S')

ORACLE_HOME=$(get_oracle_home "$ORACLE_SID")
if [[ -z "$ORACLE_HOME" || ! -d "$ORACLE_HOME" ]]; then
  echo "[CRITICAL] ORACLE_HOME not found for running SID=$ORACLE_SID"
  return
fi

# Base DB name for RAC (e.g. RSWPF04A from RSWPF04A1/RSWPF04A2)
DB_BASE=${ORACLE_SID%[0-9]}

export ORACLE_SID ORACLE_HOME
export PATH=$ORACLE_HOME/bin:/usr/bin:/usr/sbin
export LD_LIBRARY_PATH=$ORACLE_HOME/lib
export TNS_ADMIN=$ORACLE_HOME/network/admin

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/db_health_${ORACLE_SID}_${DATE}.log"

#######################################
# HEADER
#######################################
echo "===================================================="
echo " Oracle DB Health Check Started"
echo " SID : $ORACLE_SID"
echo " Time: $(date)"
echo "===================================================="

#######################################
# DATABASE INFO
#######################################
DB_NAME=$(sql_exec "select name from v\$database;")
DB_ROLE=$(sql_exec "select database_role from v\$database;")
IS_CDB=$(sql_exec "select cdb from v\$database;")
IS_RAC=$(sql_exec "select case when count(*)>1 then 'YES' else 'NO' end from gv\$instance;")

report "INFO" "DB=$DB_NAME ROLE=$DB_ROLE CDB=$IS_CDB RAC=$IS_RAC"

#######################################
# RAC INSTANCE STATUS
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Instance Status"
  sql_exec "
    select inst_id, instance_name, host_name, status,
           to_char(startup_time,'YYYY-MM-DD HH24:MI')
    from gv\$instance
    order by inst_id;
  " | while read -r i n h s t; do
      report "INFO" "INST=$i NAME=$n HOST=$h STATUS=$s STARTED=$t"
  done
fi

#######################################
# RAC SERVICES (USER ONLY)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Services Status"
  sql_exec "
    select name, inst_id
    from gv\$active_services
    where name not like 'SYS$%'
      and name not like 'SYS%'
    order by name, inst_id;
  " | while read -r svc inst; do
      report "INFO" "SERVICE=$svc RUNNING_ON_INST=$inst"
  done
fi

#######################################
# HUGEPAGES CHECK (SUMMARY + USAGE + MOS)
#######################################
if [[ -f /proc/meminfo ]]; then

  HP_SIZE_KB=$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)
  HP_TOTAL=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)
  HP_FREE=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)

  report "INFO" "HugePages Summary: Total=${HP_TOTAL} Free=${HP_FREE} PageSize=${HP_SIZE_KB}KB"

  ULP=$(sql_exec "
    select nvl(value,'UNSET')
    from v\$parameter
    where name='use_large_pages';
  ")

  if [[ "$HP_TOTAL" -gt 0 ]]; then
    if [[ "$HP_TOTAL" -ne "$HP_FREE" ]]; then
      report "OK" "HugePages are being used"
    else
      if [[ "$ULP" =~ TRUE|ONLY ]]; then
        report "CRITICAL" "HugePages configured but NOT used – check with Unix team"
      else
        report "CRITICAL" "HugePages configured at OS level but database level is set to FALSE"
        report "CRITICAL" "Set use_large_pages=TRUE|ONLY and restart database"
      fi
    fi
  else
    report "WARNING" "HugePages not configured at OS level"
  fi

  if command -v ipcs >/dev/null 2>&1; then
    NUM_PG=0
    for SEG in $(ipcs -m | awk '{print $5}' | grep -E '^[0-9]+$'); do
      PAGES=$(echo "$SEG / ($HP_SIZE_KB * 1024)" | bc)
      [[ "$PAGES" -gt 0 ]] && NUM_PG=$(echo "$NUM_PG + $PAGES + 1" | bc)
    done

    if [[ "$NUM_PG" -gt 0 ]]; then
      report "INFO" "HugePages Sizing: configured=$HP_TOTAL required=$NUM_PG"
      report "INFO" "Recommended: vm.nr_hugepages=$NUM_PG"

      [[ "$HP_TOTAL" -eq "$NUM_PG" ]] && report "OK" "HugePages correctly sized"
      [[ "$HP_TOTAL" -gt "$NUM_PG" ]] && report "WARNING" "HugePages over-allocated by $((HP_TOTAL-NUM_PG))"
      [[ "$HP_TOTAL" -lt "$NUM_PG" ]] && report "CRITICAL" "HugePages under-allocated by $((NUM_PG-HP_TOTAL))"
    fi
  fi
fi

#######################################
# USE_LARGE_PAGES PARAMETER (UNCHANGED)
#######################################
[[ "$ULP" =~ ONLY|TRUE ]] \
  && report "OK" "USE_LARGE_PAGES=$ULP" \
  || report "CRITICAL" "USE_LARGE_PAGES=$ULP"

#######################################
# RAC PARAMETER CONSISTENCY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  for P in use_large_pages sga_target sga_max_size memory_target cluster_database; do
    CNT=$(sql_exec "select count(distinct value) from gv\$parameter where name='$P';")
    [[ "$CNT" -gt 1 ]] && report "CRITICAL" "RAC param $P inconsistent" \
                      || report "OK" "RAC param $P consistent"
  done
fi

#######################################
# TABLESPACE CHECK
#######################################
check_tablespaces() {
  local C="$1"
  sql_exec "
    select tablespace_name, round(used_percent,2)
    from dba_tablespace_usage_metrics
    where used_percent >= $TBS_WARN;
  " | while read -r t u; do
    (( $(echo "$u >= $TBS_CRIT" | bc) )) \
      && report "CRITICAL" "[$C] $t ${u}%" \
      || report "WARNING"  "[$C] $t ${u}%"
  done
}

if [[ "$IS_CDB" == "YES" ]]; then
  sql_exec "alter session set container=CDB\$ROOT;"
  check_tablespaces "CDB\$ROOT"
  sql_exec "select name from v\$pdbs where open_mode='READ WRITE';" |
  while read -r pdb; do
    sql_exec "alter session set container=$pdb;"
    check_tablespaces "$pdb"
  done
else
  check_tablespaces "NON-CDB"
fi

#######################################
# BLOCKING SESSIONS (CLEAN DELIMITED OUTPUT)
#######################################
LOCKS=$(sql_exec "select count(*) from gv\$session where blocking_session is not null;")

if [[ "$LOCKS" -eq 0 ]]; then
  report "OK" "No blocking sessions"
else
  report "WARNING" "Blocking sessions detected – listing details"

  sql_exec "
    set pages 0 feed off head off trimspool on lines 400;

    select
      to_char(s.inst_id)
      ||'|'||to_char(s.sid)
      ||'|'||to_char(s.serial#)
      ||'|'||nvl(s.username,'(BACKGROUND)')
      ||'|'||nvl(s.sql_id,'-')
      ||'|'||to_char(s.blocking_session)
      ||'|'||to_char(s.blocking_instance)
      ||'|'||to_char(p.serial#)
      ||'|'||nvl(p.username,'(BACKGROUND)')
      ||'|'||nvl(p.sql_id,'-')
    from gv\$session s
    left join gv\$session p
      on p.sid = s.blocking_session
     and p.inst_id = s.blocking_instance
    where s.blocking_session is not null
    order by s.inst_id, s.sid;
  " | while read -r line; do
      report "INFO" "BLOCK: $line"
    done
fi

#######################################
# RAC LOAD SUMMARY
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "RAC Load Summary (DB Time)"
  sql_exec "
    select inst_id, round(value/100,2)
    from gv\$sysstat where name='DB time';
  " | while read -r i v; do
      report "INFO" "INST=$i DB_TIME=$v"
  done
fi

#######################################
# LMS RR THREAD CHECK (LOCAL, FILTERED BY SID)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  report "INFO" "LMS RR Thread Validation"
  # Only capture LMS processes for this ORACLE_SID on local host
  LMS=$(ps -eLo cls,cmd | grep "ora_lms[0-9]_${ORACLE_SID}" | grep -v ASM | grep -v grep || true)
  [[ -z "$LMS" ]] && report "CRITICAL" "No LMS processes found for SID=$ORACLE_SID on local host" || {
    echo "$LMS" | awk '{print $2}' | sort -u | while read -r l; do
      RR=$(echo "$LMS" | grep "$l" | awk '$1=="RR"' | wc -l)
      [[ "$RR" -ge 1 ]] \
        && report "OK" "LMS $l has RR thread" \
        || report "WARNING" "LMS $l has NO RR thread"
    done
  }
fi

#######################################
# LMS RR THREAD CHECK ON OTHER RAC NODES (FILTERED BY DB BASE)
#######################################
if [[ "$IS_RAC" == "YES" ]]; then
  # Get local host in short form
  LOCAL_HOST=$(hostname -s 2>/dev/null || hostname)

  # Get RAC node hostnames from gv$instance
  RAC_HOSTS=$(sql_exec "
    select distinct host_name
    from gv\$instance;
  " | awk '{print $1}')

  for HOST in $RAC_HOSTS; do
    # Skip current node
    if [[ "$HOST" == "$LOCAL_HOST" ]]; then
      continue
    fi

    report "INFO" "LMS RR Thread Validation on remote host $HOST"

    # Capture LMS processes for this DB base (e.g. RSWPF04A) on the remote host
    REM_LMS=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
      "ps -eLo cls,cmd | grep 'ora_lms[0-9]_''${DB_BASE}' | grep -v ASM | grep -v grep" 2>/dev/null || true)

    if [[ -z "$REM_LMS" ]]; then
      report "CRITICAL" "No LMS processes found for DB base=${DB_BASE} on host $HOST or SSH/ps failed"
      continue
    fi

    echo "$REM_LMS" | awk '{print $2}' | sort -u | while read -r l; do
      RR=$(echo "$REM_LMS" | grep "$l" | awk '$1=="RR"' | wc -l)
      if [[ "$RR" -ge 1 ]]; then
        report "OK" "Host=$HOST LMS $l has RR thread"
      else
        report "WARNING" "Host=$HOST LMS $l has NO RR thread"
      fi
    done
  done
fi

#######################################
# RMAN ARCHIVELOG DELETION POLICY CHECK (ADDED)
#######################################
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
  ps -ef | grep "[o]ra_pmon_${2}$" >/dev/null || { echo "[ERROR] SID $2 not running"; exit 1; }
  run_health_check "$2"
else
  usage
fi