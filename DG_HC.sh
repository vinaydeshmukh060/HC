#!/bin/bash

# ==========================================
# Data Guard Validation Script
# ==========================================

if [ $# -ne 1 ]; then
    echo "Usage: $0 <sys_password>"
    exit 1
fi

SYSPWD=$1
TMPFILE=/tmp/dg_standby_service_$$.log

echo "-----------------------------------------"
echo "Extracting Standby DGConnectIdentifier..."
echo "-----------------------------------------"

# Get Standby database name from configuration
STANDBY_DB=$(dgmgrl -silent / <<EOF
show configuration;
exit;
EOF
)

# Extract standby database unique name
STANDBY_DB_UNIQUE=$(echo "$STANDBY_DB" | awk '/Physical standby database/ {print $1}' | head -1)

if [ -z "$STANDBY_DB_UNIQUE" ]; then
    echo "ERROR: Could not determine standby database."
    exit 1
fi

echo "Standby DB Unique Name: $STANDBY_DB_UNIQUE"

# Extract DGConnectIdentifier
dgmgrl -silent / <<EOF > $TMPFILE
show database $STANDBY_DB_UNIQUE 'DGConnectIdentifier';
exit;
EOF

STANDBY_SERVICE=$(grep -i DGConnectIdentifier $TMPFILE | awk -F"'" '{print $2}')

if [ -z "$STANDBY_SERVICE" ]; then
    echo "ERROR: Could not extract DGConnectIdentifier."
    rm -f $TMPFILE
    exit 1
fi

echo "Standby Service: $STANDBY_SERVICE"

echo "-----------------------------------------"
echo "Running Data Guard Validations..."
echo "-----------------------------------------"

dgmgrl -silent sys/$SYSPWD@$STANDBY_SERVICE <<EOF

show configuration lag;

validate database $STANDBY_DB_UNIQUE spfile;

validate network configuration for all;

exit;
EOF

rm -f $TMPFILE

echo "-----------------------------------------"
echo "Validation Completed."
echo "-----------------------------------------"
