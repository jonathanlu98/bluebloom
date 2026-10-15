#!/usr/bin/env python3
"""Merge tools/i18n/translations/<language>.json (English key → translation) into App/Resources/Localizable.xcstrings and check for missing translations.

Usage:
  python3 tools/i18n/apply-translations.py            merge translations and report
  python3 tools/i18n/apply-translations.py --report   only report which keys each language is missing
The number of %@ in a translation must match the key (interpolated arguments are substituted in order; use %1$@, %2$@ when the order must change).
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CATALOG = ROOT / "App/Resources/Localizable.xcstrings"
TRANSLATIONS = ROOT / "tools/i18n/translations"
LANGUAGES = ["zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es"]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?@")


def live_keys(catalog):
    return [key for key, entry in catalog["strings"].items()
            if key.strip() and entry.get("extractionState") != "stale" and entry.get("shouldTranslate", True)]


def main():
    report_only = "--report" in sys.argv
    catalog = json.loads(CATALOG.read_text())
    keys = live_keys(catalog)
    problems = 0
    for language in LANGUAGES:
        path = TRANSLATIONS / f"{language}.json"
        table = json.loads(path.read_text()) if path.exists() else {}
        missing = []
        for key in keys:
            entry = catalog["strings"][key]
            value = table.get(key)
            if value is None:
                existing = entry.get("localizations", {}).get(language)
                if not existing:
                    missing.append(key)
                continue
            if len(PLACEHOLDER.findall(value)) != len(PLACEHOLDER.findall(key)):
                print(f"[{language}] placeholder count mismatch: {key!r} → {value!r}")
                problems += 1
                continue
            if not report_only:
                entry.setdefault("localizations", {})[language] = {"stringUnit": {"state": "translated", "value": value}}
        unused = sorted(set(table) - set(keys))
        print(f"{language}: {len(keys) - len(missing)}/{len(keys)} translated" + (f", {len(missing)} missing" if missing else "")
              + (f", {len(unused)} unused in the translation table" if unused else ""))
        for key in missing:
            print(f"    missing: {key!r}")
        problems += len(missing)
    if not report_only:
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
