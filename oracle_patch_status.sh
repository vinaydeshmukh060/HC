#!/usr/bin/env bash
#===============================================================================
# oracle_patch_status.sh
#
# PURPOSE
#   Read-only pre/post OS-patching health check for Oracle CRS/Grid Infra and
#   databases on a single node. Run it once with "pre" before patching/reboot,
#   and once with "post" after the node is back up. It will:
#     - Discover running DB instances from PMON (excluding ASM/APX/MGMTDB)
#     - Resolve ORACLE_HOME per SID from oratab
#     - Capture: instance status, DB role, open_mode, PDB status (CDB aware),
#       service status + where running, Data Guard apply/transport lag,
#       CRS resource states, srvctl database/service status
#     - Store everything in CSV (easy to diff / load into Excel later)
#     - On "post", automatically diff against the "pre" snapshot
#     - Print a colour console summary
#     - Build a self-contained HTML dashboard report (failures in red)
#     - Email the report (HTML body + attachment) - ON by default
#
# READ-ONLY GUARANTEE
#   This script NEVER issues srvctl start/stop/relocate, crsctl start/stop,
#   or any SQL other than SELECT. Grep this file for "srvctl status",
#   "crsctl stat"/"crsctl status", and "SELECT" - that is the entire set of
#   commands executed against the stack. No DDL/DML, no state changes.
#
# COMPATIBILITY
#   Written for bash 3.2+ or ksh93 (both ship on RHEL/OL and Solaris 10/11).
#   Avoids bash4-only features (no associative arrays, no mapfile) and avoids
#   GNU-only flags (no `date -d`, no `ps --sort`, no `timeout` binary) so it
#   runs unmodified on Solaris. If /usr/bin/env bash is not on PATH on your
#   Solaris box, invoke explicitly: `ksh93 oracle_patch_status.sh pre` or
#   `/usr/gnu/bin/bash oracle_patch_status.sh pre` (either works, untouched).
#
# USAGE
#   ./oracle_patch_status.sh pre   [--dir /path/to/workdir] [--no-email]
#   ./oracle_patch_status.sh post  [--dir /path/to/workdir] [--no-email] \
#                                  [--email-to a@x.com,b@x.com]
#   ./oracle_patch_status.sh --help
#
# EXIT CODES
#   0 = collected cleanly, no failures/mismatches found (post mode)
#   1 = collected cleanly, but failures/mismatches were found (post mode)
#   2 = usage / environment error (oratab missing, no perms, etc.)
#===============================================================================

# ---------------------------------------------------------------------------
# 0. STRICT-ish MODE (kept loose enough for ksh93 portability)
# ---------------------------------------------------------------------------
set -u
umask 022

# ---------------------------------------------------------------------------
# 1. CONFIGURATION - edit this block for your site
# ---------------------------------------------------------------------------
WORKDIR="${ORACLE_PATCHCHK_DIR:-/var/tmp/oracle_patch_check}"
SNAP_DIR="$WORKDIR/snapshots"          # latest pre_*/post_* CSVs live here
ARCHIVE_DIR="$WORKDIR/archive"         # timestamped copies kept for history
REPORT_DIR="$WORKDIR/reports"
LOG_DIR="$WORKDIR/logs"

# Query timeout, seconds, for every sqlplus/srvctl/crsctl call. Requires perl
# (present by default on virtually every Linux and Solaris box). If perl is
# not found, calls simply run without a timeout guard.
CMD_TIMEOUT=25

# Threshold above which Data Guard lag is flagged amber/red, in seconds.
DG_LAG_WARN_SECS=300
DG_LAG_CRIT_SECS=1800

# ---- Email -------------------------------------------------------------
EMAIL_ENABLED=true                      # default ON per requirement
EMAIL_TO="dba-team@example.com"         # comma-separated list, edit me
EMAIL_FROM="oracle-patchcheck@$(uname -n 2>/dev/null || echo localhost)"
EMAIL_SUBJECT_PREFIX="[Oracle Patch Check]"

# oratab search locations (Linux vs Solaris vs custom TNS_ADMIN-style setups)
ORATAB_CANDIDATES="/etc/oratab /var/opt/oracle/oratab"

# ---------------------------------------------------------------------------
# 2. INTERNALS - shouldn't normally need editing below this line
# ---------------------------------------------------------------------------
SCRIPT_NAME=$(basename "$0")
HOSTNAME=$(uname -n 2>/dev/null)
OS_NAME=$(uname -s 2>/dev/null)
NOW_EPOCH=$(date +%s 2>/dev/null || echo 0)
NOW_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
NOW_TAG=$(date '+%Y%m%d_%H%M%S')

MODE=""
NO_EMAIL=0
EMAIL_TO_OVERRIDE=""

INSTANCES_CSV=""
PDBS_CSV=""
SERVICES_CSV=""
DG_CSV=""
CRS_CSV=""

OVERALL_FAIL=0     # set to 1 the moment any RED condition is detected

# Colours (disabled automatically if not an interactive terminal)
if [ -t 1 ]; then
    C_RED="\033[1;31m"; C_GRN="\033[1;32m"; C_YEL="\033[1;33m"
    C_CYA="\033[1;36m"; C_BLD="\033[1m";   C_OFF="\033[0m"
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_BLD=""; C_OFF=""
fi

log()   { printf '%s [INFO ] %s\n'  "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" ; }
warn()  { printf "%s ${C_YEL}[WARN ]${C_OFF} %s\n" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" ; }
error() { printf "%s ${C_RED}[ERROR]${C_OFF} %s\n" "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2 ; }
die()   { error "$*"; exit 2; }

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

# run_with_timeout <seconds> <cmd...>   (perl-alarm trick; no GNU coreutils needed)
run_with_timeout() {
    secs="$1"; shift
    if command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!"' "$secs" "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# 3. ARGUMENT PARSING
# ---------------------------------------------------------------------------
[ $# -lt 1 ] && usage
case "$1" in
    pre|post) MODE="$1"; shift ;;
    -h|--help) usage ;;
    *) die "First argument must be 'pre' or 'post' (got '$1')." ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)       WORKDIR="$2"; shift 2 ;;
        --no-email)  NO_EMAIL=1; shift ;;
        --email-to)  EMAIL_TO_OVERRIDE="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[ -n "$EMAIL_TO_OVERRIDE" ] && EMAIL_TO="$EMAIL_TO_OVERRIDE"
[ "$NO_EMAIL" -eq 1 ] && EMAIL_ENABLED=false

# Re-derive paths in case --dir changed WORKDIR
SNAP_DIR="$WORKDIR/snapshots"
ARCHIVE_DIR="$WORKDIR/archive"
REPORT_DIR="$WORKDIR/reports"
LOG_DIR="$WORKDIR/logs"

for d in "$WORKDIR" "$SNAP_DIR" "$ARCHIVE_DIR" "$REPORT_DIR" "$LOG_DIR"; do
    mkdir -p "$d" 2>/dev/null || die "Cannot create working directory: $d (check permissions)"
done

LOG_FILE="$LOG_DIR/${MODE}_${NOW_TAG}.log"
: > "$LOG_FILE"

INSTANCES_CSV="$SNAP_DIR/instances_${MODE}.csv"
PDBS_CSV="$SNAP_DIR/pdbs_${MODE}.csv"
SERVICES_CSV="$SNAP_DIR/services_${MODE}.csv"
DG_CSV="$SNAP_DIR/dataguard_${MODE}.csv"
CRS_CSV="$SNAP_DIR/crs_${MODE}.csv"

echo "SID,HOST,ORACLE_HOME,DB_NAME,DB_UNIQUE_NAME,DB_ROLE,OPEN_MODE,LOG_MODE,INSTANCE_STATUS,SRVCTL_DB_STATUS" > "$INSTANCES_CSV"
echo "SID,PDB_NAME,PDB_OPEN_MODE"                                                                              > "$PDBS_CSV"
echo "SID,DB_UNIQUE_NAME,SERVICE_NAME,SERVICE_STATE,RUNNING_ON"                                                > "$SERVICES_CSV"
echo "SID,DB_UNIQUE_NAME,DG_ROLE,APPLY_LAG,TRANSPORT_LAG,APPLY_LAG_SECS"                                       > "$DG_CSV"
echo "RESOURCE_NAME,TYPE,STATE,TARGET,NODE"                                                                    > "$CRS_CSV"

log "=== oracle_patch_status.sh : mode=$MODE host=$HOSTNAME os=$OS_NAME ==="
log "Working directory: $WORKDIR"

# ---------------------------------------------------------------------------
# 4. LOCATE oratab
# ---------------------------------------------------------------------------
ORATAB=""
for f in $ORATAB_CANDIDATES; do
    [ -r "$f" ] && { ORATAB="$f"; break; }
done
[ -z "$ORATAB" ] && die "No readable oratab found in: $ORATAB_CANDIDATES"
log "Using oratab: $ORATAB"

ORATAB_MAP="$WORKDIR/.oratab_map.$$"
trap 'rm -f "$ORATAB_MAP" "$PMON_LIST" "$TMP_SQL" "$TMP_SQLOUT" 2>/dev/null' EXIT

# Build "SID:HOME" map, skipping comments/blank lines and ASM/APX/MGMTDB entries
awk -F: '
    /^[[:space:]]*#/ {next}
    NF<2 {next}
    {
        sid=$1; home=$2
        gsub(/^[ \t]+|[ \t]+$/, "", sid)
        gsub(/^[ \t]+|[ \t]+$/, "", home)
        if (sid == "") next
        print sid ":" home
    }
' "$ORATAB" > "$ORATAB_MAP"

is_excluded_sid() {
    case "$1" in
        +ASM*|+APX*|-MGMTDB*|MGMTDB*|-GIMR*) return 0 ;;
        *) return 1 ;;
    esac
}

lookup_home() {
    # $1 = sid -> prints ORACLE_HOME or empty
    awk -F: -v s="$1" '$1==s {print $2; exit}' "$ORATAB_MAP"
}

# ---------------------------------------------------------------------------
# 5. DISCOVER RUNNING INSTANCES FROM PMON (exclude ASM / APX / MGMTDB)
# ---------------------------------------------------------------------------
PMON_LIST="$WORKDIR/.pmon_list.$$"
# The [o] trick avoids matching this grep process itself, on both Linux & Solaris ps -ef
ps -ef | grep '[o]ra_pmon_' | awk '{print $NF}' | sed 's/^ora_pmon_//' > "$PMON_LIST"

RUNNING_SIDS=""
while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    if is_excluded_sid "$sid"; then
        log "Skipping $sid (ASM/APX/MGMTDB - excluded by design)"
        continue
    fi
    RUNNING_SIDS="$RUNNING_SIDS $sid"
done < "$PMON_LIST"
RUNNING_SIDS=$(echo "$RUNNING_SIDS" | sed 's/^ *//')

if [ -z "$RUNNING_SIDS" ]; then
    warn "No eligible (non-ASM/APX/MGMTDB) PMON processes found on this node."
fi
log "Running instances detected via PMON: ${RUNNING_SIDS:-<none>}"

# Fallback: if a running SID isn't in oratab, try to recover ORACLE_HOME from
# the process environment (read-only /proc inspection, no state change).
get_home_from_proc() {
    sid="$1"
    pid=$(ps -ef | grep "[o]ra_pmon_${sid}$" | awk '{print $2}' | head -1)
    [ -z "$pid" ] && return 1
    if [ "$OS_NAME" = "SunOS" ] && command -v pargs >/dev/null 2>&1; then
        pargs -e "$pid" 2>/dev/null | awk -F= '/ORACLE_HOME=/{print $2; exit}'
    elif [ -r "/proc/$pid/environ" ]; then
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | awk -F= '/^ORACLE_HOME=/{print $2; exit}'
    fi
}

# ---------------------------------------------------------------------------
# 6. GRID HOME DETECTION (for crsctl / srvctl) - read-only, best-effort
# ---------------------------------------------------------------------------
GRID_HOME=""
if [ -r /etc/oracle/olr.loc ]; then
    GRID_HOME=$(awk -F= '/^crs_home/{print $2}' /etc/oracle/olr.loc 2>/dev/null)
elif [ -r /var/opt/oracle/olr.loc ]; then
    GRID_HOME=$(awk -F= '/^crs_home/{print $2}' /var/opt/oracle/olr.loc 2>/dev/null)
fi
if [ -z "$GRID_HOME" ]; then
    gpid=$(ps -ef | grep '[o]cssd.bin' | awk '{print $NF}' 2>/dev/null)
fi
[ -n "$GRID_HOME" ] && log "Grid Home detected: $GRID_HOME" || warn "Grid Home not detected - CRS-level checks will be skipped."

# ---------------------------------------------------------------------------
# 7. PER-INSTANCE COLLECTION (SQL is 100% SELECT - see header guarantee)
# ---------------------------------------------------------------------------
TMP_SQL="$WORKDIR/.chk_$$.sql"
TMP_SQLOUT="$WORKDIR/.chk_$$.out"

collect_instance() {
    sid="$1"
    home="$2"

    if [ ! -x "$home/bin/sqlplus" ]; then
        warn "$sid: sqlplus not found under $home - skipping SQL checks"
        echo "$sid,$HOSTNAME,$home,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN" >> "$INSTANCES_CSV"
        return
    fi

    cat > "$TMP_SQL" <<'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 4000 TRIMSPOOL ON VERIFY OFF ECHO OFF TERMOUT OFF TAB OFF
WHENEVER SQLERROR CONTINUE

SELECT 'DBINFO|'||d.name||'|'||d.db_unique_name||'|'||d.database_role||'|'||d.open_mode||'|'||d.log_mode||'|'||i.status
FROM v$database d, v$instance i;

SELECT 'PDB|'||p.name||'|'||p.open_mode
FROM v$pdbs p
WHERE p.name <> 'PDB$SEED';

SELECT 'SVC|'||s.name
FROM v$active_services s
WHERE s.name NOT LIKE 'SYS$%';

SELECT 'DG|'||name||'|'||value
FROM v$dataguard_stats
WHERE name IN ('apply lag','transport lag');

EXIT;
SQLEOF

    : > "$TMP_SQLOUT"
    ( ORACLE_HOME="$home"; ORACLE_SID="$sid"; PATH="$home/bin:$PATH"
      export ORACLE_HOME ORACLE_SID PATH
      run_with_timeout "$CMD_TIMEOUT" sqlplus -s -L "/ as sysdba" "@$TMP_SQL"
    ) > "$TMP_SQLOUT" 2>&1

    if ! grep -q '^DBINFO|' "$TMP_SQLOUT"; then
        warn "$sid: could not read DBINFO (connect issue, or instance mounting/opening). Raw output logged."
        cat "$TMP_SQLOUT" >> "$LOG_FILE"
        echo "$sid,$HOSTNAME,$home,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,STARTING/UNREACHABLE,UNKNOWN" >> "$INSTANCES_CSV"
        return
    fi

    dbline=$(grep '^DBINFO|' "$TMP_SQLOUT" | head -1)
    dbname=$(echo "$dbline"  | awk -F'|' '{print $2}')
    dbuniq=$(echo "$dbline"  | awk -F'|' '{print $3}')
    dbrole=$(echo "$dbline"  | awk -F'|' '{print $4}')
    openmd=$(echo "$dbline"  | awk -F'|' '{print $5}')
    logmd=$(echo "$dbline"   | awk -F'|' '{print $6}')
    inststat=$(echo "$dbline"| awk -F'|' '{print $7}')

    srvctl_db_status="N/A"
    if [ -n "$GRID_HOME" ] && [ -x "$GRID_HOME/bin/srvctl" ]; then
        srvctl_db_status=$(run_with_timeout "$CMD_TIMEOUT" "$GRID_HOME/bin/srvctl" status database -d "$dbuniq" 2>&1 | tr '\n' ' ')
        [ -z "$srvctl_db_status" ] && srvctl_db_status="N/A"
    fi

    srvctl_db_status_clean=$(echo "$srvctl_db_status" | sed 's/,/;/g')
    echo "$sid,$HOSTNAME,$home,$dbname,$dbuniq,$dbrole,$openmd,$logmd,$inststat,$srvctl_db_status_clean" >> "$INSTANCES_CSV"

    grep '^PDB|' "$TMP_SQLOUT" | awk -F'|' -v sid="$sid" '{print sid","$2","$3}' >> "$PDBS_CSV"

    grep '^SVC|' "$TMP_SQLOUT" | awk -F'|' '{print $2}' | while IFS= read -r svcname; do
        [ -z "$svcname" ] && continue
        running_on="$HOSTNAME"
        state="RUNNING"
        if [ -n "$GRID_HOME" ] && [ -x "$GRID_HOME/bin/srvctl" ]; then
            svc_raw=$(run_with_timeout "$CMD_TIMEOUT" "$GRID_HOME/bin/srvctl" status service -d "$dbuniq" -s "$svcname" 2>&1)
            echo "$svc_raw" | grep -qi 'is running' && state="RUNNING" || state="NOT_RUNNING"
            running_on=$(echo "$svc_raw" | sed -n 's/.*on instance(s) //p' | tr -d '\r' | sed 's/\.$//')
            [ -z "$running_on" ] && running_on="$HOSTNAME"
        fi
        echo "$sid,$dbuniq,$svcname,$state,$running_on" >> "$SERVICES_CSV"
    done

    dg_apply=$(grep '^DG|apply lag|'      "$TMP_SQLOUT" | awk -F'|' '{print $3}')
    dg_transport=$(grep '^DG|transport lag|' "$TMP_SQLOUT" | awk -F'|' '{print $3}')
    if [ -n "$dg_apply$dg_transport" ]; then
        # Interval format typically "+00 00:03:12" -> convert apply lag to seconds for thresholding
        secs=$(echo "$dg_apply" | awk -F'[+ :]' 'NF>=5{print ($2*86400)+($3*3600)+($4*60)+$5; next}{print 0}')
        echo "$sid,$dbuniq,$dbrole,${dg_apply:-N/A},${dg_transport:-N/A},${secs:-0}" >> "$DG_CSV"
    fi
}

for sid in $RUNNING_SIDS; do
    home=$(lookup_home "$sid")
    if [ -z "$home" ]; then
        home=$(get_home_from_proc "$sid")
        [ -n "$home" ] && warn "$sid: not in oratab, recovered ORACLE_HOME=$home from process env"
    fi
    if [ -z "$home" ]; then
        warn "$sid: running but no ORACLE_HOME found in oratab or process env - recording as UNKNOWN"
        echo "$sid,$HOSTNAME,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN,UNKNOWN" >> "$INSTANCES_CSV"
        continue
    fi
    log "Collecting: SID=$sid HOME=$home"
    collect_instance "$sid" "$home"
done

# ---------------------------------------------------------------------------
# 8. CRS-LEVEL STATUS (whole-stack view, read-only) - once per run, not per SID
# ---------------------------------------------------------------------------
if [ -n "$GRID_HOME" ] && [ -x "$GRID_HOME/bin/crsctl" ]; then
    CRS_RAW="$WORKDIR/.crs_raw_$$.txt"
    run_with_timeout "$CMD_TIMEOUT" "$GRID_HOME/bin/crsctl" status resource -w \
        "TYPE = ora.database.type or TYPE = ora.service.type or TYPE = ora.diskgroup.type or TYPE = ora.listener.type" \
        -f > "$CRS_RAW" 2>&1

    awk -F= '
        BEGIN { name=""; type=""; state=""; target=""; node="" }
        /^NAME=/        { if (name!="") print name","type","state","target","node; name=$2; type=""; state=""; target=""; node="" }
        /^TYPE=/        { type=$2 }
        /^TARGET=/      { target=$2 }
        /^STATE=/       {
            full=$0; sub(/^STATE=/,"",full)
            split(full, parts, " on ")
            state=parts[1]
            node=(parts[2]=="" ? "-" : parts[2])
        }
        END { if (name!="") print name","type","state","target","node }
    ' "$CRS_RAW" >> "$CRS_CSV"
    rm -f "$CRS_RAW"
else
    warn "crsctl not available/detected - CRS resource table will be empty (standalone/non-RAC instance?)."
fi

log "Snapshot collection complete: $MODE"
log "CSV files: $INSTANCES_CSV | $PDBS_CSV | $SERVICES_CSV | $DG_CSV | $CRS_CSV"

# Keep a timestamped archive copy alongside the "latest" one used for diffing
for f in "$INSTANCES_CSV" "$PDBS_CSV" "$SERVICES_CSV" "$DG_CSV" "$CRS_CSV"; do
    cp "$f" "$ARCHIVE_DIR/$(basename "$f" .csv)_${NOW_TAG}.csv" 2>/dev/null
done

# ---------------------------------------------------------------------------
# 9. CONSOLE OUTPUT
# ---------------------------------------------------------------------------
print_console_summary() {
    printf "\n${C_BLD}=========================================================================${C_OFF}\n"
    printf "${C_BLD} Oracle Patch Check - %-6s  Host: %-20s  %s${C_OFF}\n" "$MODE" "$HOSTNAME" "$NOW_HUMAN"
    printf "${C_BLD}=========================================================================${C_OFF}\n"

    printf "\n${C_CYA}%-12s %-18s %-10s %-14s %-10s %-8s${C_OFF}\n" "SID" "DB_UNIQUE_NAME" "ROLE" "OPEN_MODE" "LOG_MODE" "STATUS"
    tail -n +2 "$INSTANCES_CSV" | while IFS=, read -r sid host home dbname dbuniq role openmd logmd status rest; do
        colour="$C_GRN"
        case "$status" in
            OPEN) : ;;
            MOUNTED) case "$role" in *STANDBY*) : ;; *) colour="$C_YEL" ;; esac ;;
            *) colour="$C_RED"; OVERALL_FAIL=1 ;;
        esac
        printf "${colour}%-12s %-18s %-10s %-14s %-10s %-8s${C_OFF}\n" "$sid" "$dbuniq" "$role" "$openmd" "$logmd" "$status"
    done

    if [ "$(wc -l < "$PDBS_CSV")" -gt 1 ]; then
        printf "\n${C_CYA}%-12s %-20s %-14s${C_OFF}\n" "SID" "PDB_NAME" "OPEN_MODE"
        tail -n +2 "$PDBS_CSV" | while IFS=, read -r sid pdb mode; do
            colour="$C_GRN"; [ "$mode" != "READ WRITE" ] && colour="$C_YEL"
            printf "${colour}%-12s %-20s %-14s${C_OFF}\n" "$sid" "$pdb" "$mode"
        done
    fi

    if [ "$(wc -l < "$SERVICES_CSV")" -gt 1 ]; then
        printf "\n${C_CYA}%-12s %-18s %-14s %-12s %-s${C_OFF}\n" "SID" "DB_UNIQUE_NAME" "SERVICE" "STATE" "RUNNING_ON"
        tail -n +2 "$SERVICES_CSV" | while IFS=, read -r sid dbuniq svc state runon; do
            colour="$C_GRN"; [ "$state" != "RUNNING" ] && { colour="$C_RED"; OVERALL_FAIL=1; }
            printf "${colour}%-12s %-18s %-14s %-12s %-s${C_OFF}\n" "$sid" "$dbuniq" "$svc" "$state" "$runon"
        done
    fi

    if [ "$(wc -l < "$DG_CSV")" -gt 1 ]; then
        printf "\n${C_CYA}%-12s %-18s %-16s %-16s %-16s${C_OFF}\n" "SID" "DB_UNIQUE_NAME" "ROLE" "APPLY_LAG" "TRANSPORT_LAG"
        tail -n +2 "$DG_CSV" | while IFS=, read -r sid dbuniq role apply transport secs; do
            colour="$C_GRN"
            [ "${secs:-0}" -ge "$DG_LAG_WARN_SECS" ] 2>/dev/null && colour="$C_YEL"
            [ "${secs:-0}" -ge "$DG_LAG_CRIT_SECS" ] 2>/dev/null && { colour="$C_RED"; OVERALL_FAIL=1; }
            printf "${colour}%-12s %-18s %-16s %-16s %-16s${C_OFF}\n" "$sid" "$dbuniq" "$role" "$apply" "$transport"
        done
    fi

    if [ "$(wc -l < "$CRS_CSV")" -gt 1 ]; then
        printf "\n${C_CYA}%-30s %-14s %-14s %-s${C_OFF}\n" "CRS_RESOURCE" "STATE" "TARGET" "NODE"
        tail -n +2 "$CRS_CSV" | while IFS=, read -r name type state target node; do
            colour="$C_GRN"; [ "$state" != "ONLINE" ] && { colour="$C_RED"; OVERALL_FAIL=1; }
            printf "${colour}%-30s %-14s %-14s %-s${C_OFF}\n" "$name" "$state" "$target" "$node"
        done
    fi
    echo ""
}
print_console_summary

# ---------------------------------------------------------------------------
# 10. COMPARISON (post mode only, generic key-based CSV diff)
# ---------------------------------------------------------------------------
COMPARE_AVAILABLE=0
DIFF_OUT="$WORKDIR/.diffs_$$.txt"
: > "$DIFF_OUT"

compare_csv() {
    keyfields="$1"; prefile="$2"; postfile="$3"; label="$4"
    [ -r "$prefile" ] || return 1
    awk -F',' -v kf="$keyfields" -v label="$label" '
        function mkkey(f1,   k,i) { k=""; for(i=1;i<=kf;i++) k = k (i>1?"|":"") $i; return k }
        FNR==NR { if (FNR==1) next; pre[mkkey($0)] = $0; next }
        FNR==1 { next }
        {
            k = mkkey($0)
            postseen[k]=1
            if (k in pre) {
                if (pre[k] == $0) { ok++ }
                else { print label",CHANGED,PRE=["pre[k]"],POST=["$0"]" }
            } else {
                print label",NEW,POST=["$0"]"
            }
        }
        END {
            for (k in pre) if (!(k in postseen)) print label",MISSING,PRE=["pre[k]"]"
        }
    ' "$prefile" "$postfile"
    return 0
}

PRE_INSTANCES="$SNAP_DIR/instances_pre.csv"
if [ "$MODE" = "post" ] && [ -r "$PRE_INSTANCES" ]; then
    COMPARE_AVAILABLE=1
    log "Pre-snapshot found - running comparison"
    compare_csv 1 "$SNAP_DIR/instances_pre.csv" "$INSTANCES_CSV" "INSTANCE" >> "$DIFF_OUT"
    compare_csv 2 "$SNAP_DIR/pdbs_pre.csv"       "$PDBS_CSV"       "PDB"      >> "$DIFF_OUT"
    compare_csv 3 "$SNAP_DIR/services_pre.csv"   "$SERVICES_CSV"   "SERVICE"  >> "$DIFF_OUT"
    compare_csv 1 "$SNAP_DIR/dataguard_pre.csv"  "$DG_CSV"         "DATAGUARD" >> "$DIFF_OUT"
    compare_csv 1 "$SNAP_DIR/crs_pre.csv"        "$CRS_CSV"        "CRS"      >> "$DIFF_OUT"

    if [ -s "$DIFF_OUT" ]; then
        warn "Differences found between pre and post snapshot:"
        cat "$DIFF_OUT" | tee -a "$LOG_FILE"
        OVERALL_FAIL=1
    else
        log "No differences between pre and post snapshot - all objects match."
    fi
elif [ "$MODE" = "post" ]; then
    warn "No pre-snapshot found at $PRE_INSTANCES - showing current status only (no diff)."
fi

# ---------------------------------------------------------------------------
# 11. HTML DASHBOARD REPORT
# ---------------------------------------------------------------------------
REPORT_FILE="$REPORT_DIR/oracle_patch_report_${HOSTNAME}_${MODE}_${NOW_TAG}.html"

count_rows() { tail -n +2 "$1" 2>/dev/null | grep -c . ; }

TOTAL_INSTANCES=$(count_rows "$INSTANCES_CSV")
FAIL_INSTANCES=$(tail -n +2 "$INSTANCES_CSV" | awk -F',' '$9!="OPEN" && !($9=="MOUNTED")' | grep -c .)
TOTAL_SERVICES=$(count_rows "$SERVICES_CSV")
FAIL_SERVICES=$(tail -n +2 "$SERVICES_CSV" | awk -F',' '$4!="RUNNING"' | grep -c .)
TOTAL_CRS=$(count_rows "$CRS_CSV")
FAIL_CRS=$(tail -n +2 "$CRS_CSV" | awk -F',' '$3!="ONLINE"' | grep -c .)
DIFF_COUNT=$( [ -s "$DIFF_OUT" ] && wc -l < "$DIFF_OUT" || echo 0 )

if [ "$FAIL_INSTANCES" -gt 0 ] || [ "$FAIL_SERVICES" -gt 0 ] || [ "$FAIL_CRS" -gt 0 ] || [ "$DIFF_COUNT" -gt 0 ]; then
    OVERALL_FAIL=1
fi

if [ "$OVERALL_FAIL" -eq 1 ]; then
    BANNER_TEXT="ACTION REQUIRED - one or more checks failed"
    BANNER_CLASS="banner-fail"
else
    BANNER_TEXT="ALL SYSTEMS NORMAL"
    BANNER_CLASS="banner-ok"
fi

html_row_instances() {
    tail -n +2 "$INSTANCES_CSV" | awk -F',' -v OFS='|' '{
        cls = ($9=="OPEN" || $9=="MOUNTED") ? "ok" : "fail"
        print cls,$1,$2,$4,$5,$6,$7,$8,$9
    }' | while IFS='|' read -r cls sid host dbname dbuniq role openmd logmd status; do
        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
            "$cls" "$sid" "$dbuniq" "$role" "$openmd" "$logmd" "$status" "$host"
    done
}
html_row_pdbs() {
    tail -n +2 "$PDBS_CSV" | while IFS=',' read -r sid pdb mode; do
        cls="ok"; [ "$mode" != "READ WRITE" ] && cls="warn"
        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$cls" "$sid" "$pdb" "$mode"
    done
}
html_row_services() {
    tail -n +2 "$SERVICES_CSV" | while IFS=',' read -r sid dbuniq svc state runon; do
        cls="ok"; [ "$state" != "RUNNING" ] && cls="fail"
        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$cls" "$sid" "$dbuniq" "$svc" "$state" "$runon"
    done
}
html_row_dg() {
    tail -n +2 "$DG_CSV" | while IFS=',' read -r sid dbuniq role apply transport secs; do
        cls="ok"
        [ "${secs:-0}" -ge "$DG_LAG_WARN_SECS" ] 2>/dev/null && cls="warn"
        [ "${secs:-0}" -ge "$DG_LAG_CRIT_SECS" ] 2>/dev/null && cls="fail"
        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$cls" "$sid" "$dbuniq" "$role" "$apply" "$transport"
    done
}
html_row_crs() {
    tail -n +2 "$CRS_CSV" | while IFS=',' read -r name type state target node; do
        cls="ok"; [ "$state" != "ONLINE" ] && cls="fail"
        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$cls" "$name" "$type" "$state" "$target" "$node"
    done
}
html_row_diffs() {
    [ -s "$DIFF_OUT" ] || { printf '<tr><td colspan="3">No differences vs pre-check snapshot.</td></tr>\n'; return; }
    awk -F',' '{print $1","$2","substr($0, index($0,$3))}' "$DIFF_OUT" | while IFS=',' read -r area chtype rest; do
        cls="warn"; [ "$chtype" = "MISSING" ] && cls="fail"
        printf '<tr class="%s"><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$cls" "$area" "$chtype" "$rest"
    done
}

{
cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<title>Oracle Patch Check - $HOSTNAME - $MODE - $NOW_HUMAN</title>
<style>
  body{font-family:Arial,Helvetica,sans-serif;background:#f4f6f8;color:#1f2933;margin:0;padding:24px;}
  h1{font-size:20px;margin-bottom:4px;}
  .meta{color:#5c6b7a;font-size:13px;margin-bottom:20px;}
  .banner{padding:14px 18px;border-radius:6px;font-weight:bold;font-size:16px;margin-bottom:20px;}
  .banner-ok{background:#e2f6e9;color:#166a34;border:1px solid #7fd39c;}
  .banner-fail{background:#fdeaea;color:#9c1c1c;border:1px solid #f2a5a5;}
  .cards{display:flex;gap:14px;flex-wrap:wrap;margin-bottom:24px;}
  .card{background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,0.12);padding:14px 20px;min-width:150px;}
  .card .num{font-size:26px;font-weight:bold;}
  .card .lbl{font-size:12px;color:#5c6b7a;text-transform:uppercase;letter-spacing:.03em;}
  .card.fail .num{color:#c0392b;}
  .card.ok .num{color:#1e8449;}
  section{background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,0.12);padding:16px 20px;margin-bottom:20px;}
  section h2{font-size:15px;margin:0 0 10px 0;color:#1f2933;}
  table{border-collapse:collapse;width:100%;font-size:13px;}
  th{text-align:left;background:#eef1f4;padding:6px 10px;border-bottom:2px solid #d7dde3;}
  td{padding:6px 10px;border-bottom:1px solid #edf0f2;}
  tr.fail{background:#fdeaea;color:#9c1c1c;font-weight:bold;}
  tr.warn{background:#fff8e1;color:#8a6d00;}
  tr.ok{color:#1f2933;}
  footer{color:#8a97a3;font-size:11px;margin-top:10px;}
</style></head><body>
<h1>Oracle Patch Check Report</h1>
<div class="meta">Host: <b>$HOSTNAME</b> &nbsp;|&nbsp; OS: $OS_NAME &nbsp;|&nbsp; Mode: <b>$MODE</b> &nbsp;|&nbsp; Generated: $NOW_HUMAN</div>
<div class="banner $BANNER_CLASS">$BANNER_TEXT</div>
<div class="cards">
  <div class="card $([ "$FAIL_INSTANCES" -gt 0 ] && echo fail || echo ok)"><div class="num">$TOTAL_INSTANCES</div><div class="lbl">Instances Checked</div></div>
  <div class="card $([ "$FAIL_INSTANCES" -gt 0 ] && echo fail || echo ok)"><div class="num">$FAIL_INSTANCES</div><div class="lbl">Instance Issues</div></div>
  <div class="card $([ "$FAIL_SERVICES" -gt 0 ] && echo fail || echo ok)"><div class="num">$FAIL_SERVICES</div><div class="lbl">Services Down</div></div>
  <div class="card $([ "$FAIL_CRS" -gt 0 ] && echo fail || echo ok)"><div class="num">$FAIL_CRS</div><div class="lbl">CRS Resources Not Online</div></div>
  <div class="card $([ "$DIFF_COUNT" -gt 0 ] && echo fail || echo ok)"><div class="num">$DIFF_COUNT</div><div class="lbl">Diffs vs Pre-Check</div></div>
</div>

<section><h2>Database Instances</h2><table>
<tr><th>SID</th><th>DB Unique Name</th><th>Role</th><th>Open Mode</th><th>Log Mode</th><th>Status</th><th>Host</th></tr>
$(html_row_instances)
</table></section>

<section><h2>Pluggable Databases (PDBs)</h2><table>
<tr><th>SID</th><th>PDB Name</th><th>Open Mode</th></tr>
$(html_row_pdbs)
</table></section>

<section><h2>Services</h2><table>
<tr><th>SID</th><th>DB Unique Name</th><th>Service</th><th>State</th><th>Running On</th></tr>
$(html_row_services)
</table></section>

<section><h2>Data Guard Lag</h2><table>
<tr><th>SID</th><th>DB Unique Name</th><th>Role</th><th>Apply Lag</th><th>Transport Lag</th></tr>
$(html_row_dg)
</table></section>

<section><h2>CRS / Grid Infrastructure Resources</h2><table>
<tr><th>Resource</th><th>Type</th><th>State</th><th>Target</th><th>Node</th></tr>
$(html_row_crs)
</table></section>

<section><h2>Changes vs Pre-Check Snapshot</h2><table>
<tr><th>Area</th><th>Change Type</th><th>Detail</th></tr>
$(html_row_diffs)
</table></section>

<footer>Generated by $SCRIPT_NAME (read-only) on $HOSTNAME. Raw CSV snapshots retained under $ARCHIVE_DIR.</footer>
</body></html>
HTMLHEAD
} > "$REPORT_FILE"

log "HTML report written: $REPORT_FILE"

# ---------------------------------------------------------------------------
# 12. EMAIL (MIME multipart, built by hand -> works via /usr/sbin/sendmail on
#     both Linux and Solaris without relying on mailx supporting -a, which
#     Solaris's bundled mailx historically does not)
# ---------------------------------------------------------------------------
send_email() {
    [ "$EMAIL_ENABLED" = "true" ] || { log "Email disabled (--no-email) - skipping."; return; }

    SENDMAIL=""
    for p in /usr/sbin/sendmail /usr/lib/sendmail /sbin/sendmail; do
        [ -x "$p" ] && { SENDMAIL="$p"; break; }
    done
    if [ -z "$SENDMAIL" ]; then
        warn "No sendmail binary found - falling back to mailx (attachment support varies by OS)."
        if command -v mailx >/dev/null 2>&1; then
            mailx -s "$EMAIL_SUBJECT_PREFIX $BANNER_TEXT - $HOSTNAME ($MODE)" -a "$REPORT_FILE" "$EMAIL_TO" < "$REPORT_FILE"
        else
            error "Neither sendmail nor mailx available - cannot send email. Report saved at $REPORT_FILE"
        fi
        return
    fi

    BOUNDARY="ORAPATCH_$$_$(date +%s)"
    SUBJECT="$EMAIL_SUBJECT_PREFIX $BANNER_TEXT - $HOSTNAME ($MODE)"
    ATTACH_B64="$WORKDIR/.attach_$$.b64"
    if command -v base64 >/dev/null 2>&1; then
        base64 "$REPORT_FILE" > "$ATTACH_B64" 2>/dev/null || uuencode -m "$REPORT_FILE" report.html | sed '1d;$d' > "$ATTACH_B64"
    else
        uuencode -m "$REPORT_FILE" report.html | sed '1d;$d' > "$ATTACH_B64"
    fi

    {
        echo "From: $EMAIL_FROM"
        echo "To: $EMAIL_TO"
        echo "Subject: $SUBJECT"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"$BOUNDARY\""
        echo ""
        echo "--$BOUNDARY"
        echo "Content-Type: text/html; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        cat "$REPORT_FILE"
        echo ""
        echo "--$BOUNDARY"
        echo "Content-Type: text/html; name=\"$(basename "$REPORT_FILE")\""
        echo "Content-Transfer-Encoding: base64"
        echo "Content-Disposition: attachment; filename=\"$(basename "$REPORT_FILE")\""
        echo ""
        cat "$ATTACH_B64"
        echo ""
        echo "--$BOUNDARY--"
    } | "$SENDMAIL" -t -f "$EMAIL_FROM"

    rc=$?
    rm -f "$ATTACH_B64"
    [ $rc -eq 0 ] && log "Email sent to: $EMAIL_TO" || error "sendmail exited with code $rc"
}
send_email

# ---------------------------------------------------------------------------
# 13. EXIT
# ---------------------------------------------------------------------------
printf "\nReport: %s\n" "$REPORT_FILE"
printf "Log:    %s\n\n" "$LOG_FILE"

if [ "$MODE" = "post" ]; then
    [ "$OVERALL_FAIL" -eq 1 ] && exit 1 || exit 0
fi
exit 0
