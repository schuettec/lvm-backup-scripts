#!/bin/bash
MAIL="LVM Backup for Morpheus finished.\n"
MAIL+="Backup disk space:\n"
MAIL+=`df -h | grep "/media/backups"`
MAIL+="\n"

echo -e "$MAIL" | mail -s "Morpheus Backup Results" cschue88@gmail.com

