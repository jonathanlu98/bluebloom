#!/bin/zsh
# Build the app and install it into /Applications, replacing whatever Blue Bloom is there (a release or an earlier local build),
# so there is only ever one copy (launch at login needs the app at a fixed location); launch it once installed.
# The About pane marks it as a local build; with user.bazelrc it includes the private codec plugins
set -euo pipefail
cd "${0:A:h}/.."
# Build for this Mac's architecture (.bazelrc defaults to arm64); hw.optional.arm64 is also 1 in a Rosetta shell, where
# uname -m would say x86_64 although Core Audio needs an arm64 driver
if [[ $(sysctl -in hw.optional.arm64) == 1 ]]; then cpu=arm64; else cpu=x86_64; fi
bazel build --macos_cpus=$cpu //App:BlueBloom
DEST=/Applications
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
# Earlier versions of this script installed into ~/Applications; remove that copy so it can't be launched by mistake
if [[ -d "$HOME/Applications/BlueBloom.app" ]]; then
    rm -rf "$HOME/Applications/BlueBloom.app"
    echo "Removed the old copy in ~/Applications"
fi
ditto -x -k "$(bazel cquery --macos_cpus=$cpu --output=files //App:BlueBloom 2>/dev/null)" "$DEST"
echo "Installed: $DEST/BlueBloom.app"
open "$DEST/BlueBloom.app"
