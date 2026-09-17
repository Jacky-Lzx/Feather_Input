#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
source_root="$repo_root/platforms/macos/input-method"
shared_root="$repo_root/platforms/macos/shared"
build_root="$repo_root/.build/macos-input-method-tests"
app="$build_root/FeatherInputMethodSmoke.app"
executable="$app/Contents/MacOS/FeatherInputMethodSmoke"
frameworks="$app/Contents/Frameworks"
rust_library="$repo_root/rust/target/debug/libfeather_ffi.dylib"

if [ -n "${FEATHER_RIME_SHARED_DATA_DIR:-}" ]; then
    shared_data=$FEATHER_RIME_SHARED_DATA_DIR
else
    shared_data="$repo_root/dist/FeatherInput.app/Contents/Resources/rime"
fi

if [ ! -f "$shared_data/essay.txt" ]; then
    echo "Rime 共享数据无效或缺少 essay.txt：$shared_data" >&2
    echo "请设置 FEATHER_RIME_SHARED_DATA_DIR。" >&2
    exit 1
fi

cargo build --manifest-path "$repo_root/rust/Cargo.toml" -p feather-ffi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$frameworks"
mkdir -p "$build_root/module-cache"
cp "$source_root/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string FeatherInputMethodSmoke "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier \
    -string im.feather.inputmethod.rustdev.Smoke \
    "$app/Contents/Info.plist"
plutil -replace InputMethodConnectionName \
    -string im.feather.inputmethod.rustdev.Smoke_Connection \
    "$app/Contents/Info.plist"
cp "$rust_library" "$frameworks/libfeather_ffi.dylib"
install_name_tool -id @rpath/libfeather_ffi.dylib "$frameworks/libfeather_ffi.dylib"
swiftc \
    -parse-as-library \
    -module-cache-path "$build_root/module-cache" \
    -I "$shared_root/CFeatherIME" \
    -L "$repo_root/rust/target/debug" \
    -lfeather_ffi \
    -framework AppKit \
    -framework Carbon \
    -framework InputMethodKit \
    -Xlinker -rpath \
    -Xlinker @executable_path/../Frameworks \
    "$shared_root"/Sources/*.swift \
    "$source_root"/Sources/CandidateWindowStyle.swift \
    "$source_root"/Sources/CandidateWindowController.swift \
    "$source_root"/Sources/FeatherInputEnvironment.swift \
    "$source_root"/Sources/FocusIndicatorSettings.swift \
    "$source_root"/Sources/InputModeMemory.swift \
    "$source_root"/Sources/InputScheme.swift \
    "$source_root"/Sources/InputController.swift \
    "$source_root"/Sources/InputOverlays.swift \
    "$source_root"/Sources/ModeIndicatorController.swift \
    "$source_root"/Sources/RightControlTap.swift \
    "$source_root"/Sources/SettingsWindowController.swift \
    "$source_root"/Sources/TextCoordinates.swift \
    "$source_root"/Tests/*.swift \
    -o "$executable"

rust_install_name=$(otool -D "$rust_library" | tail -n 1 | sed 's/^[[:space:]]*//')
install_name_tool -change "$rust_install_name" @rpath/libfeather_ffi.dylib "$executable"
codesign --force --sign - "$app" >/dev/null

user_data=$(mktemp -d /tmp/feather-input-method-smoke.XXXXXX)
trap 'rm -rf "$user_data"' EXIT HUP INT TERM
"$executable" "$shared_data" "$user_data"
