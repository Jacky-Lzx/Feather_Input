#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/prepare-data.sh
swift build -c release
app="dist/FeatherInput.app"
# Only replace the generated artifact in this repository.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp .build/release/FeatherInput "$app/Contents/MacOS/"
swiftc -O scripts/register-input-source.swift -o "$app/Contents/MacOS/register-input-source"
cp Resources/Info.plist "$app/Contents/"
cp -R Resources/*.lproj "$app/Contents/Resources/"
# Compile string tables as property lists for system input-menu consumers.
for strings in "$app"/Contents/Resources/*.lproj/*.strings; do
  plutil -convert binary1 "$strings"
done
cp -R dist/rime "$app/Contents/Resources/"
cp -R dist/licenses "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
python3 scripts/bundle-libraries.py "$(brew --prefix librime)/lib/librime.dylib" "$app/Contents/Frameworks"
# Compile schemas outside the interactive input process and validate bundled libraries.
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
.build/release/EngineCheck "$PWD/$app/Contents/Frameworks/librime.dylib" "$PWD/$app/Contents/Resources/rime" "$check_dir"
cp -R "$check_dir/build" "$app/Contents/Resources/rime/"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$PWD/$app"
