#!/bin/bash
#
# dyn_tray.sh - create a system tray item that can be modified
#             - write changes to the named pipe: $mytraypipe
#
mytraypipe="/tmp/tray1.pipe"

# Make the pipe if required
if ! test -e "$mytraypipe"; then
  mkfifo $mytraypipe
fi

# redirect the stdio (file 1) to the named pipe
exec 1<> $mytraypipe

# create the notification icon
yad --notification                  \
    --listen                        \
    --image="process-working"              \
    --text="Dummy tooltip"   \
    --command="yad --text='Test Tray App' " <&1
