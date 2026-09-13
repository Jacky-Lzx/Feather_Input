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

## Input-source menu fix

The system menu calls `IMKInputController.doCommand(by:command:)`, which forwards a dictionary containing `kIMKCommandMenuItemName` and `kIMKCommandClientName`. The original scheme callback incorrectly required an NSMenuItem sender. Scheme menu entries now use distinct full-pinyin/Flypy selectors accepting the command context, obtain the supplied client for committing composition, and create the engine session when the menu is used before the first key event.

The installed-app smoke check exercises IMK's actual command dispatcher with dictionary senders for Flypy → full pinyin → Flypy, verifies preference/active-scheme/checkmark agreement, and commits `你好` with each scheme's spelling. It restores the previous scheme preference afterward. The final installed-app check ran with the old input-method process stopped to avoid a duplicate server connection. Both engine integration and signature verification passed.

Added English and Simplified Chinese InfoPlist.strings for the application title and mode ID. After replacement, TISGetInputSourceProperty reports localized name `Feather Input` and enabled state `1`. Visual inspection of a physical system-menu click remains a separate check; the regression test validates the same IMK dispatch route programmatically.

## Right Control and candidate window

- Standalone right Control toggles on release, recognizing the right-side device modifier bit. Other modifier/key/mouse/scroll activity cancels the tap; activation/deactivation resets tracking. Pending composition is confirmed before switching. No per-application language preference was added.
- Candidate buttons use librime's current-page selection API, validate the displayed composition/list before selecting, and clear callbacks when hidden. The nonactivating panel refuses key/main status, supports horizontal/vertical settings, draws a selection background, falls back to vertical for wide rows, provides full-text tooltips and vertical scrolling for oversized lists.
- Seven unit tests passed, including modifier cancellation, left/right Control separation, session reset, bottom-edge flipping, negative-origin displays and oversized frames. Real-engine integration additionally verified selecting the second candidate on page two and rejecting invalid indices.
- Packaged smoke tests passed native button actions, hidden-callback invalidation, NSEvent right-Control dispatch through InputController, Control-shortcut pass-through, pending composition commit and candidate-button insertion into an in-process IMK client. This fixture is supplied to event handlers, not the IMK controller initializer, which requires a system client.
- Rendered light vertical and dark horizontal candidate panels and visually inspected both. These checks do not replace physical keyboard/mouse testing or live multi-display/Space behavior in third-party applications.
