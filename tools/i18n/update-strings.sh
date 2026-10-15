#!/bin/zsh
# Sync UI strings: use the Swift compiler to extract every localized string in App/Sources (Text, String(localized:), etc.),
# update App/Resources/Localizable.xcstrings (add new keys, mark keys no longer used as stale), then list the entries each language has not translated yet.
# Run after changing UI strings; write translations into tools/i18n/translations/<language>.json, then merge them with apply-translations.py.
set -euo pipefail
cd "${0:A:h}/../.."
OUT=$(mktemp -d)
bazel build //App:AppLib --spawn_strategy=local --strategy=SwiftCompile=local \
    --@rules_swift//swift:copt=-emit-localized-strings \
    --@rules_swift//swift:copt=-emit-localized-strings-path --@rules_swift//swift:copt="$OUT" >/dev/null
CATALOG=App/Resources/Localizable.xcstrings
[[ -f $CATALOG ]] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > $CATALOG
args=()
for f in $OUT/*.stringsdata; do args+=(--stringsdata $f); done
xcrun xcstringstool sync $CATALOG $args
rm -rf "$OUT"
python3 tools/i18n/apply-translations.py --report
