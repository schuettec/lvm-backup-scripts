#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lvm-backup-lib.sh
source "${SCRIPT_DIR}/lvm-backup-lib.sh"

if ! load_config; then
    command -v jq >/dev/null 2>&1 && json_result 'BACKUP_NOT_POSSIBLE' false 'invalid or missing configuration'
    exit 0
fi

mkdir -p -- "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
exec 9>"$LOCK_FILE" || { json_result 'BACKUP_NOT_POSSIBLE' false 'cannot open backup lock'; exit 0; }
if ! flock -n 9; then
    json_result 'BACKUP_NOT_POSSIBLE' false 'another backup process is running'
elif collect_preconditions; then
    json_result 'BACKUP_POSSIBLE' true ''
else
    json_result 'BACKUP_NOT_POSSIBLE' false "$CHECK_REASON"
fi
