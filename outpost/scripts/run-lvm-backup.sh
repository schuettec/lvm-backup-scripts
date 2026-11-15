#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=lvm-backup-lib.sh
source "${SCRIPT_DIR}/lvm-backup-lib.sh"

load_config || exit 2
require_commands lvcreate lvremove lvs vgs fsarchiver sha256sum findmnt df find stat awk flock jq date tail mv mkdir rm basename tr || exit 2

mkdir -p -- "$(dirname -- "$LOCK_FILE")" "$LOG_DIR" || exit 2
exec 9>"$LOCK_FILE" || exit 2
if ! flock -n 9; then
    json_result 'BACKUP_FAILED' false 'another backup process is running' ''
    exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
job_id="${MORPHEUS_JOB_ID:-local-$$}"
safe_job_id="${job_id//[^a-zA-Z0-9_.-]/_}"
log_file="${LOG_DIR}/${timestamp}-${safe_job_id}.log"
snapshot_name="${LOGVOL:0:48}-morpheus-${safe_job_id:0:32}"
archive_final="${BACKDIR}/${BACKNAM}-${timestamp}.fsa"
archive_partial="${archive_final}.part"
snapshot_created=false
failure_reason=''
AVAILABLE_BYTES=0 ESTIMATED_BYTES=0 REQUIRED_BYTES=0 HISTORY_COUNT=0 ESTIMATE_SOURCE=unknown SNAPSHOTS=''

cleanup() {
    local cleanup_rc=0
    if [[ "$snapshot_created" == true ]]; then
        if lvremove -f -- "${VOLGRP}/${snapshot_name}" >>"$log_file" 2>&1; then
            snapshot_created=false
        else
            cleanup_rc=$?
        fi
    fi
    if ((cleanup_rc != 0)) && [[ -z "$failure_reason" ]]; then
        failure_reason='backup completed but snapshot cleanup failed'
    fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

exec 3>&1
exec >>"$log_file" 2>&1
printf 'Starting LVM backup job %s at %s\n' "$job_id" "$timestamp"

if ! collect_preconditions; then
    failure_reason="$CHECK_REASON"
elif ! lvcreate --snapshot --size "${SNAPSHOT_SIZE_GIB}G" --name "$snapshot_name" -- "${VOLGRP}/${LOGVOL}"; then
    failure_reason='failed to create LVM snapshot'
else
    snapshot_created=true
    if ! fsarchiver savefs "${FSAOPTS[@]}" -- "$archive_partial" "/dev/${VOLGRP}/${snapshot_name}"; then
        failure_reason='fsarchiver failed'
    elif ! fsarchiver archinfo "$archive_partial"; then
        failure_reason='fsarchiver could not verify the archive'
    else
        snapshot_percent="$(lvs --noheadings --nosuffix -o data_percent "${VOLGRP}/${snapshot_name}" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "$snapshot_percent" ]] && awk -v value="$snapshot_percent" 'BEGIN { exit !(value >= 100) }'; then
            failure_reason='LVM snapshot overflowed during backup'
        elif ! checksum_value="$(sha256sum -- "$archive_partial" | awk '{print $1}')" || [[ ! "$checksum_value" =~ ^[a-fA-F0-9]{64}$ ]]; then
            failure_reason='failed to write archive checksum'
        elif ! printf '%s  %s\n' "$checksum_value" "$(basename -- "$archive_final")" >"${archive_final}.sha256.part"; then
            failure_reason='failed to write archive checksum'
        elif ! mv -- "$archive_partial" "$archive_final" || ! mv -- "${archive_final}.sha256.part" "${archive_final}.sha256"; then
            failure_reason='failed to publish completed archive atomically'
        fi
    fi
fi

cleanup
if [[ -n "$failure_reason" ]]; then
    rm -f -- "$archive_partial" "${archive_final}.sha256.part"
    # Keep enough headroom for JSON escaping and the other result fields below maxOutput.
    log_tail="$(tail -n "$LOG_TAIL_LINES" -- "$log_file" 2>&1 | tail -c 49152)"
    json_result 'BACKUP_FAILED' false "$failure_reason" "$log_tail" >&3
else
    printf 'Backup completed: %s\n' "$archive_final"
    jq -cn --arg status 'BACKUP_SUCCESSFUL' --arg archive "$archive_final" \
        --arg checksum "${archive_final}.sha256" --arg log "$log_file" --arg jobId "$job_id" \
        --argjson size "$(stat -c %s -- "$archive_final")" \
        '{status:$status,backupPossible:true,reason:"",archive:$archive,checksum:$checksum,archiveBytes:$size,logFile:$log,logTail:"",jobId:$jobId}' >&3
fi
trap - INT TERM HUP
