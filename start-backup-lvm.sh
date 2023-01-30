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

##--------------------------------------------------------------------------------------------------------------
## Check all commands the script needs:


## Check LVM support installed?
if ! command -v lvcreate &> /dev/null
then
    echo "LVM commands could not be found. Is LVM support installed?"
    echo "To install LVM support run:"
    echo "  sudo apt-get install lvm2"
    exit 1
fi

## Check FSArchiver installed?
if ! command -v fsarchiver &> /dev/null
then
    echo "FSarchiver could not be found. FSarchiver needs to be installed."
    echo "To install run:"
    echo "  sudo apt-get install fsarchiver"
    exit 1
fi

##--------------------------------------------------------------------------------------------------------------
## Maybe we can work with systemd inhibitors to avoid someone shuts down the system during backup
## systemd-inhibit --why="Doing weekly backup" bash ./backup-lvm.sh  2>&1 | tee -a "${BACKDIR}/${BACKNAM}.log"

##--------------------------------------------------------------------------------------------------------------
## Do real stuff
if command -v notify-send &> /dev/null
then
    notify-send -u critical --app-name="LVM Backup Script" "LVM Backup Script is running!" "Please make sure to wait until the script finished."
fi


#for i in {0..100..5}; do echo "$i"; sleep 0.3; done | yad --progress \
#                                                          --progress-text "You have to admit it's getting better" \
#                                                          --percentage=0 \
#                                                          --auto-close


./backup-lvm.sh  2>&1 | tee -a "${BACKDIR}/${BACKNAM}.log"
