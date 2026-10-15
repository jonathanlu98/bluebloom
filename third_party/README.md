# Third-party components

Blue Bloom itself is licensed under the MIT License (see [`../LICENSE`](../LICENSE)). It includes the third-party code listed below, each under its own license. Every directory keeps the upstream license files next to the code, and a `VERSION` file records exactly where the code came from.

The app ships the same information as `ThirdPartyNotices.txt` (Settings › About › Third-Party Notices). It is generated at build time from the files in this directory by [`tools/licenses/make-notices.sh`](../tools/licenses/make-notices.sh), so it always matches the code that is compiled in.

| Directory | Component | Used for | License | Upstream |
|---|---|---|---|---|
| [`libldac`](libldac) | libldac, Sony Corporation | LDAC encoder and adaptive bitrate | Apache License 2.0 (`LICENSE`, `NOTICE`) | AOSP `platform/external/libldac` at `eeee1a3` (2025-01-10) |
| [`sbc`](sbc) | SBC codec from AOSP `packages/modules/Bluetooth`, Broadcom Corporation | SBC encoder (the decoder is used by tests only) | Apache License 2.0 (`NOTICE`) | AOSP `system/embdrv/sbc` at `745ee92` (2025-03-17) |
| [`libfreeaptx`](libfreeaptx) | libfreeaptx | aptX and aptX HD encoder | GNU LGPL 2.1 or later (`COPYING`) | [regularhunter/libfreeaptx](https://github.com/regularhunter/libfreeaptx) at `476e2d5` (2026-03-25) |

## libldac

- Copyright (C) 2003–2017 Sony Corporation. Apache License 2.0; see [`libldac/LICENSE`](libldac/LICENSE) and [`libldac/NOTICE`](libldac/NOTICE).
- Copied unmodified from upstream: `inc/`, `src/`, `abr/`, `LICENSE`, `NOTICE`. Library version 2.0.2.
- `ldac_a2dp.h` and `ldac_a2dp.c` are Blue Bloom's own A2DP wrapper (MIT), not part of upstream.

## sbc

- Copyright 1999–2012 Broadcom Corporation, with files from Open Interface and the Android Open Source Project. Apache License 2.0; the license text and the per-component attributions are in [`sbc/NOTICE`](sbc/NOTICE), taken from the root of the source repository at the same commit.
- Copied unmodified from upstream: `encoder/include` (without the unused `sbc_if.h`), `encoder/srce`, `decoder/include`, `decoder/srce`.
- `sbc_a2dp.h` and `sbc_a2dp.c` are Blue Bloom's own A2DP wrapper (MIT), not part of upstream.
- The decoder is only used by the codec tests and is not part of the app.

## libfreeaptx

- Copyright (C) 2017 Aurelien Jacobs; (C) 2018–2020 Pali Rohár; (C) 2025 Hunter Wardlaw. GNU Lesser General Public License, version 2.1 or (at your option) any later version; see [`libfreeaptx/COPYING`](libfreeaptx/COPYING).
- `freeaptx.c`, `freeaptx.h` and `COPYING` are identical to the upstream commit above.
- Blue Bloom links libfreeaptx statically. The complete source code of libfreeaptx as used in the build is in this directory; you may modify it and rebuild Blue Bloom from source to use your modified version.

## Test-only code outside this directory

[`tools/codectest/ldacdec`](../tools/codectest/ldacdec) contains the decoder part of [libldacdec](https://github.com/hegdi/libldacdec) (Copyright (c) 2021 Dirk Helbig, MIT License, see its `LICENSE`). It is used only by the codec tests to check the LDAC bitstream and is not part of the app.

## Trademarks

LDAC is a trademark of Sony Corporation. aptX is a trademark of Qualcomm Technologies, Inc. Bluetooth is a registered trademark of Bluetooth SIG, Inc. Other names are trademarks of their respective owners. Blue Bloom is not affiliated with, endorsed by or certified by any of them.
