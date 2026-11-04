#!/bin/sh
# Remove the AWDL guard and leave AWDL enabled, so AirDrop/AirPlay are not left switched off.
set -eu

if [ "$(id -u)" != 0 ]; then
    echo "Run it with sudo:" >&2
    echo "    sudo $0" >&2
    exit 1
fi

launchctl bootout system/app.bluebloom.awdl-guard 2>/dev/null || true
rm -f /Library/LaunchDaemons/app.bluebloom.awdl-guard.plist /usr/local/libexec/aptx-awdl-guard
rm -f /Users/Shared/.aptx-awdl-suppress
/sbin/ifconfig awdl0 up 2>/dev/null || true

echo "Removed the AWDL guard; AWDL is enabled again."
