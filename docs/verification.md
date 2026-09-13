# Verification — 2026-09-13

Environment: Apple Silicon, macOS 26, Xcode Swift 6.3.3, librime 1.17.0_2 from Homebrew.

Passed:

- Debug and release compilation of the Swift application and C bridge.
- `swift test`: UTF-8 byte cursor → UTF-16 client cursor conversion, including Chinese and non-BMP text.
- Real bundled-engine integration: full pinyin `nihao` and Flypy `nihc` both produce and commit `你好`; Escape, Backspace, five-entry pages, Page Down/Up, numeric candidate selection, Chinese comma, independent client sessions and ASCII handling.
- Packaging: recursive dylib closure relocation, bundled OpenCC data and upstream license files, pinned schema/dictionary revisions, precompiled dictionaries.
- `codesign --verify --deep --strict dist/FeatherInput.app`.
- Packaged executable `--smoke-test`: actual NSApplication startup, IMKServer creation, Objective-C controller class lookup, bundled precompiled data loading and native candidate panel creation/display/hide. This does not prove client-to-input-method event routing.
- Info.plist syntax and Git whitespace checks.

Not yet verified:

- Visual inspection of System Settings and actual typing after selecting the installed input source.
- End-to-end typing and candidate positioning in Safari, chat apps, VS Code, terminals and multiple displays/Spaces.
- Settings window appearance and interactions by GUI inspection.
- Learning persistence after logout/restart, long-running resource usage and measured key latency.
- Intel, older macOS versions, Developer ID signing and notarization.

The generated bundle is a local development preview. The build script derives its minimum OS from the bundled dylibs (macOS 26.0 on this machine). The corrected bundle has been installed into the user's Input Methods folder; see the registration follow-up below.

## Registration fix

The original bundle returned success from TISRegisterInputSource, but TISCreateInputSourceList could not enumerate it. Adding a visible ComponentInputModeDict alone did not resolve this. Changing the bundle identifier from `im.feather.inputmethod` to `im.feather.inputmethod.FeatherInput` (including the complete `.inputmethod.` segment) resolved enumeration. The server connection now uses the bundle-prefixed name declared in Info.plist.

After rebuilding and replacing the installed app, the registration helper verified a selectable, enabled input source. Installed-app startup smoke testing also passed. The installer now checks enumeration and enabled state instead of treating the registration return code alone as success. It enables the input source without selecting it or modifying other input sources.
