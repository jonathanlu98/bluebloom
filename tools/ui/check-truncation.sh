#!/bin/zsh
# Check UI text truncation: for each language (English + the languages in tools/i18n/translations) × normal/stress data (very long headphone names, output device names), render
# every menu panel state, every Settings page and the pairing window (Blue Bloom --snapshot [--stress]), recognize the text with Vision,
# and list places truncated at the end: the line ends with "…" but the text itself does not end with "…" ("Settings…", "Connecting…" are excluded via the translation tables).
# A "…" in the middle is a middle-truncated name (truncationMode(.middle), keeping distinguishing tails like "#2 - Find My"); that is intentional and not counted.
# Usage: tools/ui/check-truncation.sh [output-dir]; exit code is 1 when there are suspicious truncations
set -euo pipefail
cd "${0:A:h}/../.."
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT/app" "$OUT/shots"
bazel build //App:BlueBloom >/dev/null
ditto -x -k "$(bazel cquery --output=files //App:BlueBloom 2>/dev/null)" "$OUT/app"
APP="$OUT/app/BlueBloom.app/Contents/MacOS/BlueBloom"
swiftc -O -o "$OUT/ocr" tools/ui/ocr.swift
languages=(en ${(f)"$(ls tools/i18n/translations | sed 's/\.json$//')"})
for lang in $languages; do
    "$APP" --snapshot "$OUT/shots" -AppleLanguages "($lang)" >/dev/null 2>&1
    "$APP" --snapshot "$OUT/shots" --stress -AppleLanguages "($lang)" >/dev/null 2>&1
done
"$OUT/ocr" "$OUT"/shots/*-light.png > "$OUT/ocr.tsv"
python3 - "$OUT/ocr.tsv" tools/i18n/translations <<'PY'
import json, os, re, sys
tsv, folder = sys.argv[1], sys.argv[2]
# Fragments of texts that legitimately end with "…": take the 2 characters before "…" as allowed endings
allowed = set()
ellipsis_texts = []  # whole texts ending with "…" (whitespace removed), a fallback for recognition errors
texts = []
for name in os.listdir(folder):
    table = json.load(open(os.path.join(folder, name)))
    texts += list(table.keys()) + list(table.values())
# Traditional Chinese translations use the centered "⋯", which is often recognized as "…"; normalize both
for text in texts:
    text = text.replace('...', '…').replace('⋯', '…')
    if text.rstrip().endswith('…'):
        ellipsis_texts.append(re.sub(r'\s+', '', text))
    for m in re.finditer('…', text):
        before = re.sub(r'\s+', '', text[:m.start()])[-2:]
        if before: allowed.add(before)
suspects = []
for line in open(tsv, encoding='utf-8'):
    name, _, text = line.rstrip('\n').partition('\t')
    text = text.replace('...', '…').replace('⋯', '…')
    stripped = text.rstrip()
    if not stripped.endswith('…'):
        continue
    before = re.sub(r'\s+', '', stripped[:-1])[-2:]
    if before in allowed:
        continue
    # Recognition errors: one or two characters before "…" misread (Japanese "Bluetooth 設定…" read as "Bluetooth #…"): after dropping them, the rest is the start of a text ending with "…",
    # and the length is close to that text's (misread characters barely change the length; a real truncation loses several characters, e.g. "Réglages Bluetoo…" is missing "th" and is still reported)
    seen = re.sub(r'\s+', '', stripped[:-1])
    prefix = seen[:-2]
    if len(prefix) >= 4 and any(t.startswith(prefix) and len(seen) >= len(t) - 2 for t in ellipsis_texts):
        continue
    suspects.append((name, text))
for name, text in suspects:
    print(f'{name}\t{text}')
print(f'\nSuspicious truncations: {len(suspects)} ({tsv})', file=sys.stderr)
sys.exit(1 if suspects else 0)
PY
