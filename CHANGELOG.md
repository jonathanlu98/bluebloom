# Changelog

All notable changes to Blue Bloom are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/). Versions before 1.0 are pre-releases.

## [0.1.0] - 2026-10-15

First public pre-release.

### Added

- Menu bar app that streams the Mac's audio to Bluetooth headphones over A2DP with LDAC (up to 96 kHz / 24-bit at 330, 660 or 990 kbps), aptX HD, aptX, AAC (up to 320 kbps) and SBC, including SBC XQ.
- Adaptive bitrate for LDAC, SBC and AAC when the Bluetooth link gets congested.
- Sample rate follows the Apple Music track while it plays, otherwise the output device.
- AVRCP absolute volume, so the Mac volume drives the headphones' amplifier; the headphones' play, pause and skip buttons control the Mac.
- Headphone battery level in the menu.
- Automatic mode: Blue Bloom takes over only headphones that support a better codec than macOS (LDAC or aptX); other headphones stay with macOS.
- Blue Bloom virtual audio device, installed on first launch with an administrator password.
- Uninstaller in Settings › Advanced that removes the audio device, the login item, settings and log.
- Settings › About › Export Diagnostics… saves a zip with Blue Bloom's logs, the Bluetooth part of System Information and the last two hours of the macOS Bluetooth log, with Bluetooth addresses masked; Copy Diagnostics copies a summary without names or addresses. Issue forms for bug reports and headphone reports ask for both.
- The log records the version, build number and source commit at launch, and each pair of headphones' Device ID (vendor, product, version); the previous log is kept when the log is rotated.
- Command-line tool `bluebloom` (build from source) for probing headphones and testing codecs.
- User interface in English, Simplified Chinese, Traditional Chinese, Japanese, Korean, German, French and Spanish.

### Known issues

- The app is not signed with an Apple Developer ID or notarized. macOS blocks it the first time; allow it in System Settings › Privacy & Security. After each update macOS asks for Bluetooth access again.
- Tested only on macOS 27 on Apple silicon, with Focal Bathys and Sony WH-1000XM4 headphones.
- While Blue Bloom is connected, other apps can't use the headphones' microphone.
- After Blue Bloom disconnects them, some headphones (observed with Focal Bathys) can't be reached for 20 to 35 seconds.

[0.1.0]: https://github.com/JBoomRadio/bluebloom/releases/tag/v0.1.0
