#!/bin/bash
if [ "$(id -u)" != '0' ]
then
        echo "this script has to be run as root"
        exit 1
fi
start-backup-lvm.sh && shutdown -h now
