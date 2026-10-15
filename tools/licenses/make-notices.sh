#!/bin/zsh
# Generate ThirdPartyNotices.txt, the third-party notices shipped with the app: called at build time by third_party_notices in App/BUILD.bazel,
# with the content taken from each library's own license, NOTICE and VERSION in third_party, so it matches the code actually compiled in.
# Usage: make-notices.sh <output> LICENSE ldac/LICENSE ldac/NOTICE ldac/VERSION sbc/NOTICE sbc/VERSION freeaptx/COPYING freeaptx/VERSION
set -euo pipefail
out=$1 app_license=$2 ldac_license=$3 ldac_notice=$4 ldac_version=$5 sbc_notice=$6 sbc_version=$7 aptx_copying=$8 aptx_version=$9
rule='────────────────────────────────────────────────────────────'
# Line 1 of VERSION is the library name, commit and date; line 2 (if present) is the source URL of that commit
source_lines() {
    print "Source: $(head -1 $1)"
    local url=$(sed -n 2p $1)
    if [[ $url == http* ]]; then print "        $url"; fi
}
{
    print "Blue Bloom — Notices"
    print
    print "Blue Bloom: Copyright (c) 2026 Blue Bloom contributors, licensed under the MIT License (full text below)."
    print "It includes the third-party software listed below, each under its own license."
    print
    print "LDAC is a trademark of Sony Corporation. aptX is a trademark of Qualcomm Technologies, Inc."
    print "Bluetooth is a registered trademark of Bluetooth SIG, Inc. Other names are trademarks of their"
    print "respective owners. Blue Bloom is not affiliated with, endorsed by or certified by any of them."
    print; print $rule
    print "libldac — LDAC encoder"
    print "Copyright (C) 2003–2017 Sony Corporation"
    source_lines $ldac_version
    print "License: Apache License 2.0 (full text below)"
    print; print "NOTICE:"; cat $ldac_notice
    print; print $rule
    print "SBC encoder — Android Open Source Project (packages/modules/Bluetooth)"
    print "Copyright 1999–2012 Broadcom Corporation"
    source_lines $sbc_version
    print "License: Apache License 2.0 (full text below)"
    print; print "Attribution notices from the source repository's NOTICE file:"; print
    # Skip the full Apache license text at the start (a separate copy is attached below); from the first separator line on are the per-component attributions
    awk 'found || /^-----/ { found = 1; print }' $sbc_notice
    print; print $rule
    print "libfreeaptx — aptX and aptX HD encoder"
    print "Copyright (C) 2017 Aurelien Jacobs; (C) 2018–2020 Pali Rohár; (C) 2025 Hunter Wardlaw"
    source_lines $aptx_version
    print "License: GNU Lesser General Public License, version 2.1 or (at your option) any later version (full text below)"
    print
    print "Blue Bloom links libfreeaptx statically. The complete source code of libfreeaptx as used in this"
    print "build is part of Blue Bloom's source code (third_party/libfreeaptx); you may modify it and rebuild"
    print "Blue Bloom from that source to use your modified version."
    print; print $rule
    print "Apache License 2.0"; print
    cat $ldac_license
    print; print $rule
    print "GNU Lesser General Public License 2.1"; print
    cat $aptx_copying
    print; print $rule
    print "MIT License (Blue Bloom)"; print
    cat $app_license
} > $out
