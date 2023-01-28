#!/bin/bash

export VOLGRP='kde-vg'
export LOGVOL='lvroot'

export LOCK_FOLDER="./locks"

export SNAPSHOT_NAME="$LOGVOL-SNAP-BACKUP"
export SNAPSHOT_LOCKFILE="${LOCK_FOLDER}/${SNAPSHOT_NAME}.snapshot"

export FSAOPTS='-A -Z15 -j3 -v'                   # options to pass to fsarchiver
                                                  # -A means that the filesystem remains mounted rw,
                                                  # because changes are not possible when creating a snapshot before archiving.

export BACKDIR="$PWD/backups"                     # where to put the backup
export BACKNAM='chris-kde-neon-lvm-backup'        # name of the archive

export MIN_SPACE_LEFT=3                           # 3g is minimum space that must be free on the volume group
                                                  # to create a snapshot

if [ "$(id -u)" != '0' ]
then
        echo "this script has to be run as root"
        exit 1
fi

./backup-lvm.sh  2>&1 | tee -a "${BACKDIR}/${BACKNAM}.log"
