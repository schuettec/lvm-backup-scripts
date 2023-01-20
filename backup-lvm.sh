#!/bin/bash

VOLGRP='test-neon-vg'
LOGVOL='root-lv'

FSAOPTS='-Z15 -j3 -v'                          # options to pass to fsarchiver
BACKDIR="$PWD"                             # where to put the backup
BACKNAM='test-nonhost-neon-lvm-backup'     # name of the archive

# ----------------------------------------------------------------------------------------------

PATH="${PATH}:/usr/sbin:/sbin:/usr/bin:/bin"
TIMESTAMP="$(date +%Y%m%d-%Hh%M)"

# only run as root
if [ "$(id -u)" != '0' ]
then
        echo "this script has to be run as root"
        exit 1
fi

# main command of the script that does the real stuff
echo "fsarchiver savefs ${FSAOPTS} ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.fsa /dev/${VOLGRP}/${LOGVOL}"

if fsarchiver savefs ${FSAOPTS} ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.fsa /dev/${VOLGRP}/${LOGVOL}
then
        md5sum ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.fsa > ${BACKDIR}/${BACKNAM}-${TIMESTAMP}.md5
        RES=0
else
        echo "fsarchiver failed"
        RES=1

##      exit (1);  # don't remove the snapshot just yet
                   # perhaps we will want to try again ?

fi

exit ${RES}
