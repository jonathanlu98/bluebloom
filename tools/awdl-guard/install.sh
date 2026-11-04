#!/bin/sh
# Install the AWDL guard: the helper goes where the app looks for it (/usr/local/libexec/aptx-awdl-guard, see
# App/Sources/Services/Services.swift), the LaunchDaemon into /Library/LaunchDaemons. Only these two files are added;
# nothing else on the system is modified.
set -eu

if [ "$(id -u)" != 0 ]; then
    echo "This installs a LaunchDaemon, run it with sudo:" >&2
    echo "    sudo $0" >&2
    exit 1
fi

here=$(cd "$(dirname "$0")" && pwd)
helper=/usr/local/libexec/aptx-awdl-guard
plist=/Library/LaunchDaemons/app.bluebloom.awdl-guard.plist

install -d -m 755 /usr/local/libexec
install -m 755 -o root -g wheel "$here/aptx-awdl-guard" "$helper"
install -m 644 -o root -g wheel "$here/app.bluebloom.awdl-guard.plist" "$plist"

# A previous copy may already be loaded (or bootstrapped with a different path); drop it and load the new one
launchctl bootout system/app.bluebloom.awdl-guard 2>/dev/null || true
launchctl bootstrap system "$plist"
launchctl kickstart -k system/app.bluebloom.awdl-guard 2>/dev/null || true

echo "Installed $helper and $plist"
"$helper" --status
echo
echo "Blue Bloom › Settings › Audio › Playback now offers \"Pause AirDrop and AirPlay discovery while streaming\"."
