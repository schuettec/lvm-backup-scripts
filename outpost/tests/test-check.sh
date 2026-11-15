#!/bin/bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
TEST_ROOT="$(mktemp -d /tmp/lvm-backup-outpost-test.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/mount/backups" "$TEST_ROOT/log"

cat >"$TEST_ROOT/bin/lvs" <<'MOCK'
#!/bin/bash
if [[ " $* " == *" -o vg_name,lv_name,origin "* ]]; then
    [[ -z "${MOCK_SNAPSHOT:-}" ]] || printf ' vg | snap | root\n'
else
    printf ' root\n'
fi
MOCK
cat >"$TEST_ROOT/bin/vgs" <<'MOCK'
#!/bin/bash
printf ' 1073741824000\n'
MOCK
cat >"$TEST_ROOT/bin/findmnt" <<'MOCK'
#!/bin/bash
exit 0
MOCK
cat >"$TEST_ROOT/bin/df" <<'MOCK'
#!/bin/bash
printf 'Avail\n%s\n' "${MOCK_AVAILABLE:-1073741824000}"
MOCK
chmod 0755 "$TEST_ROOT/bin/"*

cat >"$TEST_ROOT/config.sh" <<EOF
VOLGRP='vg'
LOGVOL='root'
BACKUP_MOUNT='$TEST_ROOT/mount'
BACKDIR='$TEST_ROOT/mount/backups'
BACKNAM='backup'
SNAPSHOT_SIZE_GIB=10
HISTORY_DAYS=28
INITIAL_ESTIMATE_GIB=100
SPACE_SAFETY_PERCENT=125
SPACE_RESERVE_GIB=10
FSAOPTS=(-A -Z15)
LOCK_FILE='$TEST_ROOT/backup.lock'
LOG_DIR='$TEST_ROOT/log'
LOG_TAIL_LINES=20
EOF

run_check() {
    PATH="$TEST_ROOT/bin:$PATH" LVM_BACKUP_CONFIG="$TEST_ROOT/config.sh" \
        "$ROOT/outpost/scripts/check-lvm-backup.sh"
}

result="$(run_check)"
jq -e '.status == "BACKUP_POSSIBLE" and .backupPossible == true and .historySamples == 0 and .estimateSource == "configured_initial_estimate"' <<<"$result" >/dev/null

result="$(MOCK_AVAILABLE=1000 run_check)"
jq -e '.status == "BACKUP_NOT_POSSIBLE" and (.reason | contains("does not fit"))' <<<"$result" >/dev/null

result="$(MOCK_SNAPSHOT=1 run_check)"
jq -e '.status == "BACKUP_NOT_POSSIBLE" and .activeSnapshots == ["vg/snap"]' <<<"$result" >/dev/null

truncate -s 10G "$TEST_ROOT/mount/backups/backup-one.fsa"
truncate -s 30G "$TEST_ROOT/mount/backups/backup-two.fsa"
result="$(run_check)"
jq -e '.status == "BACKUP_POSSIBLE" and .historySamples == 2 and .estimatedBackupBytes == 21474836480 and .estimateSource == "history_average"' <<<"$result" >/dev/null

printf 'All check-script tests passed.\n'
