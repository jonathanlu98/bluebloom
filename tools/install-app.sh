#!/bin/zsh
# Build the app and install it into ~/Applications (launch at login needs the app at a fixed location); launch it once installed
set -euo pipefail
cd "${0:A:h}/.."
bazel build //App:BlueBloom
DEST="$HOME/Applications"
mkdir -p "$DEST"
# First quit the running version so it hands the headphones back to macOS (the app treats SIGTERM as a normal quit)
pkill -TERM -x BlueBloom || true
for i in {1..20}; do pgrep -xq BlueBloom || break; sleep 0.5; done
# If it has not quit after 10 seconds (stuck), force kill it; otherwise the open below would only bring the old process to the front
if pgrep -xq BlueBloom; then
    echo "Old version did not quit within 10 seconds, force killing it"
    pkill -KILL -x BlueBloom || true
    sleep 1
fi
rm -rf "$DEST/Blue Bloom.app" "$DEST/BlueBloom.app"
ditto -x -k "$(bazel cquery --output=files //App:BlueBloom 2>/dev/null)" "$DEST"
echo "Installed: $DEST/BlueBloom.app"
open "$DEST/BlueBloom.app"
