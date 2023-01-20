#!/bin/bash

VOLGRP='test-neon-vg'
LOGVOL='root-lv'

FSAOPTS='-v'                          # options to pass to fsarchiver
BACKDIR="$PWD"                             # where to put the backup

# ----------------------------------------------------------------------------------------------

PATH="${PATH}:/usr/sbin:/sbin:/usr/bin:/bin"

# check backnam
if [ -z ${1+x} ]
then
	echo "Start this script with backup file as first argument."
	exit 1
fi

BACKNAM=$1 

# only run as root
if [ "$(id -u)" != '0' ]
then
        echo "this script has to be run as root"
        exit 1
fi

# main command of the script that does the real stuff
echo "fsarchiver restfs ${FSAOPTS} ${BACKDIR}/${BACKNAM} id=0,dest=/dev/${VOLGRP}/${LOGVOL}"

if fsarchiver restfs ${FSAOPTS} ${BACKDIR}/${BACKNAM} id=0,dest=/dev/${VOLGRP}/${LOGVOL}
then
        RES=0
else
        echo "fsarchiver failed"
        RES=1

##      exit (1);  # don't remove the snapshot just yet
                   # perhaps we will want to try again ?

fi

exit ${RES}
