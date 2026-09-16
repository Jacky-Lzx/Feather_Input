#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/prepare-data.sh
swift build -c release
app="dist/FeatherInput.app"

# InputMethodKit and Text Input Sources cache bundles by identity and build
# version. Reusing a CFBundleVersion can leave the previous executable or
# metadata cached until the user removes and re-adds the input source. Derive a
# new local build number from every bundle that may have been built or installed
# already, so each packaged update has a strictly newer version on this Mac.
highest_build_version=0
for plist in \
  "Resources/Info.plist" \
  "$app/Contents/Info.plist" \
  "$HOME/Library/Input Methods/FeatherInput.app/Contents/Info.plist"
do
  [ -f "$plist" ] || continue
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)
  if [[ "$version" =~ ^[0-9]+$ ]] && (( 10#$version > highest_build_version )); then
    highest_build_version=$((10#$version))
  fi
done
build_version=$((highest_build_version + 1))

# Only replace the generated artifact in this repository.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp .build/release/FeatherInput "$app/Contents/MacOS/"
swiftc -O scripts/register-input-source.swift -o "$app/Contents/MacOS/register-input-source"
cp Resources/Info.plist "$app/Contents/"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$app/Contents/Info.plist"
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
printf 'Built %s (build %s)\n' "$PWD/$app" "$build_version"
