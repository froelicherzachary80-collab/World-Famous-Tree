#!/usr/bin/env bash
# Packages an archived .app into an .ipa (Payload/ zip).
# Usage: scripts/package-ipa.sh <path/to/App.xcarchive> <output.ipa>
set -euo pipefail
ARCHIVE="$1"; OUT="$2"
APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -n1)
[ -n "$APP" ] || { echo "No .app found in $ARCHIVE" >&2; exit 1; }
WORK=$(mktemp -d)
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
( cd "$WORK" && zip -qry "ipa.zip" Payload )
mv "$WORK/ipa.zip" "$OUT"
echo "Packaged $(basename "$APP") -> $OUT ($(du -h "$OUT" | cut -f1))"
# Sanity checks: the executable exists and is arm64.
EXE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
lipo -info "$EXE"
