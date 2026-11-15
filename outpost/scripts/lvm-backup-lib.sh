#!/bin/bash

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${LVM_BACKUP_CONFIG:-${SCRIPT_DIR}/lvm-backup-config.sh}"
# The scripts keep descriptors open on purpose (fd 3: JSON result, fd 9: lock). LVM would warn about each of them on
# every call ("File descriptor N leaked on lvcreate invocation"). The Outpost clears the environment, so set it here.
export LVM_SUPPRESS_FD_WARNINGS=1

load_config() {
    if [[ ! -r "$CONFIG_FILE" ]]; then
        printf 'Configuration is not readable: %s\n' "$CONFIG_FILE" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    local name
    for name in VOLGRP LOGVOL BACKUP_MOUNT BACKDIR BACKNAM SNAPSHOT_SIZE_GIB HISTORY_DAYS \
        INITIAL_ESTIMATE_GIB SPACE_SAFETY_PERCENT SPACE_RESERVE_GIB LOCK_FILE LOG_DIR LOG_TAIL_LINES; do
        if [[ -z "${!name:-}" ]]; then
            printf 'Missing configuration value: %s\n' "$name" >&2
            return 1
        fi
    done
    [[ "$VOLGRP" =~ ^[a-zA-Z0-9+_.-]+$ ]] || { echo 'Invalid VOLGRP' >&2; return 1; }
    [[ "$LOGVOL" =~ ^[a-zA-Z0-9+_.-]+$ ]] || { echo 'Invalid LOGVOL' >&2; return 1; }
    [[ "$BACKNAM" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo 'Invalid BACKNAM' >&2; return 1; }
    [[ "$BACKUP_MOUNT" == /* && "$BACKDIR" == /* && "$LOCK_FILE" == /* && "$LOG_DIR" == /* ]] || {
        echo 'Configured paths must be absolute' >&2; return 1;
    }
    case "${BACKDIR}/" in
        "${BACKUP_MOUNT%/}/"*) ;;
        *) echo 'BACKDIR must be inside BACKUP_MOUNT' >&2; return 1 ;;
    esac
    for name in SNAPSHOT_SIZE_GIB HISTORY_DAYS INITIAL_ESTIMATE_GIB SPACE_SAFETY_PERCENT SPACE_RESERVE_GIB LOG_TAIL_LINES; do
        [[ "${!name}" =~ ^[0-9]+$ ]] || { printf '%s must be a non-negative integer\n' "$name" >&2; return 1; }
    done
    (( SNAPSHOT_SIZE_GIB > 0 && HISTORY_DAYS > 0 && INITIAL_ESTIMATE_GIB > 0 && SPACE_SAFETY_PERCENT >= 100 && LOG_TAIL_LINES > 0 )) || {
        echo 'Invalid numeric configuration range' >&2; return 1;
    }
    declare -p FSAOPTS 2>/dev/null | grep -q '^declare -a' || { echo 'FSAOPTS must be a Bash array' >&2; return 1; }
}

require_commands() {
    local command_name missing=()
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if ((${#missing[@]})); then
        printf 'Missing required commands: %s\n' "${missing[*]}" >&2
        return 1
    fi
}

active_snapshots() {
    lvs --noheadings --separator '|' -o vg_name,lv_name,origin 2>/dev/null |
        awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); if ($3 != "") print $1 "/" $2}'
}

bytes_from_gib() {
    printf '%s\n' "$(( $1 * 1024 * 1024 * 1024 ))"
}

collect_capacity() {
    findmnt --mountpoint "$BACKUP_MOUNT" >/dev/null 2>&1 || {
        CHECK_REASON="backup filesystem is not mounted at ${BACKUP_MOUNT}"
        return 1
    }
    mkdir -p -- "$BACKDIR" || { CHECK_REASON="cannot create backup directory ${BACKDIR}"; return 1; }

    AVAILABLE_BYTES="$(df --output=avail -B1 -- "$BACKDIR" | awk 'NR == 2 {gsub(/[[:space:]]/, ""); print}')"
    [[ "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] || { CHECK_REASON='cannot determine available backup space'; return 1; }

    local cutoff total=0 count=0 size archive
    cutoff="$(( $(date +%s) - HISTORY_DAYS * 86400 ))"
    while IFS= read -r -d '' archive; do
        size="$(stat -c %s -- "$archive")" || continue
        (( total += size, count += 1 ))
    done < <(find "$BACKDIR" -maxdepth 1 -type f -name "${BACKNAM}-*.fsa" -newermt "@${cutoff}" -print0)

    HISTORY_COUNT="$count"
    if ((count > 0)); then
        ESTIMATED_BYTES="$(( (total + count - 1) / count ))"
        ESTIMATE_SOURCE='history_average'
    else
        ESTIMATED_BYTES="$(bytes_from_gib "$INITIAL_ESTIMATE_GIB")"
        ESTIMATE_SOURCE='configured_initial_estimate'
    fi
    REQUIRED_BYTES="$(( (ESTIMATED_BYTES * SPACE_SAFETY_PERCENT + 99) / 100 + $(bytes_from_gib "$SPACE_RESERVE_GIB") ))"
    if ((AVAILABLE_BYTES < REQUIRED_BYTES)); then
        CHECK_REASON='estimated backup does not fit with configured safety margin'
        return 1
    fi
}

collect_preconditions() {
    CHECK_REASON=''
    SNAPSHOTS=''
    require_commands lvs vgs findmnt df find stat awk flock jq date || {
        CHECK_REASON='required system command is missing'
        return 1
    }
    lvs --noheadings "${VOLGRP}/${LOGVOL}" >/dev/null 2>&1 || {
        CHECK_REASON="source logical volume ${VOLGRP}/${LOGVOL} does not exist"
        return 1
    }
    SNAPSHOTS="$(active_snapshots)" || { CHECK_REASON='cannot inspect LVM snapshots'; return 1; }
    if [[ -n "$SNAPSHOTS" ]]; then
        CHECK_REASON='another LVM snapshot is active'
        return 1
    fi
    local vg_free
    vg_free="$(vgs --noheadings --units b --nosuffix -o vg_free "$VOLGRP" 2>/dev/null | tr -d '[:space:]')"
    [[ "$vg_free" =~ ^[0-9]+([.][0-9]+)?$ ]] || { CHECK_REASON='cannot determine free volume-group space'; return 1; }
    VG_FREE_BYTES="${vg_free%%.*}"
    SNAPSHOT_BYTES="$(bytes_from_gib "$SNAPSHOT_SIZE_GIB")"
    if ((VG_FREE_BYTES < SNAPSHOT_BYTES)); then
        CHECK_REASON='not enough free volume-group space for snapshot'
        return 1
    fi
    collect_capacity
}

json_result() {
    local status="$1" possible="$2" reason="$3" log_tail="${4:-}"
    jq -cn \
        --arg status "$status" --argjson possible "$possible" --arg reason "$reason" \
        --argjson available "${AVAILABLE_BYTES:-0}" --argjson estimated "${ESTIMATED_BYTES:-0}" \
        --argjson required "${REQUIRED_BYTES:-0}" --argjson history "${HISTORY_COUNT:-0}" \
        --arg estimateSource "${ESTIMATE_SOURCE:-unknown}" --arg snapshots "${SNAPSHOTS:-}" \
        --arg logTail "$log_tail" --arg jobId "${MORPHEUS_JOB_ID:-local}" \
        '{status:$status,backupPossible:$possible,reason:$reason,availableBytes:$available,estimatedBackupBytes:$estimated,requiredBytes:$required,historySamples:$history,estimateSource:$estimateSource,activeSnapshots:($snapshots|split("\n")|map(select(length>0))),logTail:$logTail,jobId:$jobId}'
}
