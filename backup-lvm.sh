#!/bin/bash

PATH="${PATH}:/usr/sbin:/sbin:/usr/bin:/bin"

# ----------------------------------------------------------------------------------------------
# only run as root

if [ "$(id -u)" != '0' ]
then
        echo "this script has to be run as root"
        exit 1
fi

# ----------------------------------------------------------------------------------------------
# Check preconditions and prepare snapshot

# Check backup and lockfile lock folder
if [ ! -d "$LOCK_FOLDER" ]
then
   echo "Creating lock folder because it does not exist."
   echo "[TRY]  mkdir $LOCK_FOLDER "
   mkdir $LOCK_FOLDER && echo "[SUCCESS]" || echo  "[FAILED]"
fi

if [ ! -d "$BACKDIR" ]
then
   echo "Creating lock folder because it does not exist."
   echo "[TRY]  mkdir $BACKDIR"
   mkdir $BACKDIR  && echo "[SUCCESS]" || echo  "[FAILED]"
fi

# Check space left for snapshot
SPACE_LEFT=`vgs --noheadings --nosuffix --unit g -o vg_free $VOLGRP`
SPACE_LEFT=${SPACE_LEFT/,/.}

echo "Checking preconditions for snapshot (Space left: $SPACE_LEFT, Minimum left: $MIN_SPACE_LEFT)"

if [ $(bc <<< "$SPACE_LEFT < $MIN_SPACE_LEFT") -eq 1 ]
then
    echo "There is not enough space left for the snapshot!"
    echo "Actual space left < minimum space left: ${MIN_SPACE_LEFT}g > ${SPACE_LEFT}g"
    exit 1
fi

# Check abandoned snapshots
if test -f "$SNAPSHOT_LOCKFILE"; then
    echo "There seems to be an abandoned snapshot lockfile: $SNAPSHOT_LOCKFILE"
    echo "This could be the result of an aborted backup process. Please check the LVM state and snapshots manually."
    echo "To proceed backup, delete the snapshot lockfile and restart this script."
    exit 1
fi

echo "Creating snapshot lock file: $SNAPSHOT_LOCKFILE"
echo "[TRY]  touch $SNAPSHOT_LOCKFILE"
touch $SNAPSHOT_LOCKFILE  && echo "[SUCCESS]" || echo  "[FAILED]"

echo "Creating snapshot '${SNAPSHOT_NAME}' with size of ${MIN_SPACE_LEFT}g (on /dev/${VOLGRP}/${LOGVOL})"
echo "[TRY]  lvcreate -L ${MIN_SPACE_LEFT}G -s -n ${SNAPSHOT_NAME} /dev/${VOLGRP}/${LOGVOL}"

lvcreate -L ${MIN_SPACE_LEFT}G -s -n ${SNAPSHOT_NAME} /dev/${VOLGRP}/${LOGVOL}  && echo "[SUCCESS]" || echo  "[FAILED]"

# ----------------------------------------------------------------------------------------------
# main command of the script that does the real stuff

start=`date +%s`

echo "Starting fsarchiver..."
echo "  fsarchiver savefs ${FSAOPTS} ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.fsa /dev/${VOLGRP}/${LOGVOL}"
if fsarchiver savefs ${FSAOPTS} ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.fsa /dev/${VOLGRP}/${LOGVOL}
then
        echo "[SUCCESS]"
        md5sum ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.fsa > ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.md5
        RES=0
else
        echo "[FAILED]"
        echo "fsarchiver failed"
        RES=1
fi

end=`date +%s`
runtime=$((end-start))

echo "Cleanup...removing snapshot '${VOLGRP}/${SNAPSHOT_NAME}'"
echo "[TRY]  lvremove -y ${VOLGRP}/${SNAPSHOT_NAME}"
lvremove -y ${VOLGRP}/${SNAPSHOT_NAME} && echo "[SUCCESS]" || echo "[FAILED]"

echo "Releasing lock and removing file: $SNAPSHOT_LOCKFILE"
echo "[TRY] rm -f $SNAPSHOT_LOCKFILE"
rm -f $SNAPSHOT_LOCKFILE  && echo "[SUCCESS]" || echo  "[FAILED]"

echo -n "[FINISHED] Backup took "
echo `date -d@$runtime -u +%H:%M:%S`

exit ${RES}
