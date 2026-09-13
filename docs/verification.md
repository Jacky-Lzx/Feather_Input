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

## Caret language indicator

Mode changes from right Control, Control-Shift-Space and the menu now share one switch path. A nonactivating, mouse-transparent panel displays 中文 or 英文 beside the current client caret for 0.8 seconds. Repeated switches replace the timer; input/mouse activity and session deactivation hide the panel. The indicator uses the current text-client rectangle (falling back only to this session's last valid caret), clamps to the screen and inherits a level above the client.

Release build and engine checks passed. The packaged smoke test verified visible 英文/中文 labels after NSEvent-driven switches and automatic dismissal via the main run loop. Physical cross-application caret positioning remains subject to the client's text-input geometry support.

## Physical right-Control event fix

A temporary modifier-only trace of the user's physical right-Control presses captured `key=62, flags=262144 (0x40000)` on press and `key=62, flags=0` on release, with a valid IMK client. The old detector required NX_DEVICERCTLKEYMASK (0x2000), which was absent after IMK normalization. This explains why synthesized smoke events containing the device bit passed while the real key did nothing.

The detector now uses keyCode to identify the side and the aggregate Control flag when device bits are absent, while retaining device-bit support and left-Control/chord cancellation. Two regression tests failed against the old implementation and passed after the fix; all six detector tests passed. The installed-app event smoke check now uses the captured normalized flag sequence. Temporary diagnostic logging was removed from the final build.

## Persistent corner mode display

Added a shared, mouse-transparent, nonactivating panel on each connected screen at frame.minX + 12 / frame.minY + 40 points (34 × 34 points). It displays 中/英 while Feather is selected, updates on client activation and language toggles, survives normal focus changes and joins Spaces. It observes input-source, display, Space and preference notifications, and hides when another input source is selected or the setting is disabled. Screen frame rather than visibleFrame preserves the intended strip beside a left-side Dock.

Release build, engine regression and packaged smoke checks passed. The new checks verified both labels, window reuse, non-key/mouse-transparent properties, hiding for other sources and the settings toggle. Inspected the rendered badge. Actual fullscreen and multi-screen switching remain subject to live GUI verification.

## Primary-display-only badge

The persistent badge now targets CGMainDisplayID instead of every connected display. Existing secondary-display panels are removed on refresh, and display-configuration notifications relocate it when the primary display changes. It does not follow the focused window to another monitor. The packaged smoke check requires exactly one panel on the primary display.

## Native Caps Lock switching

The user reported a Karabiner simple modification mapping Caps Lock to right Control. The selected profile's single matching rule was removed after saving a timestamped backup beside karabiner.json; no other rules were changed. This changes the physical key's route rather than proving all prior failures were caused by that rule.

Added native Caps Lock latch-change detection, seeded from the current hardware state on activation. Duplicate flagsChanged events do not toggle twice. Plain letter input is normalized to lowercase (Shift gives uppercase) inside Feather even when the system Caps Lock flag is set. Existing right-Control/menu shortcuts remain available; temporary input tracing was removed.

All 11 unit tests and the installed-app smoke checks passed, including latch edges, duplicate suppression, pending input, mode labels and lowercase English output. The independent AppKit test window provides a separate test through CGEvent → system IMK routing; it is not a physical hardware-key test.

The installed native-Caps version passed the independent system-route run: text progressed from `你` to `你ni ` to `你ni 你` across two Caps Lock switches. This confirms both language directions and lowercase English through a real system text-input session.

## Both language-switch keys

The user clarified that the keyboard itself sends right Control. Both existing handlers remain enabled; settings and README now explicitly describe both keys. The packaged smoke check alternates right Control and Caps Lock on the same controller, including normalized right-Control events while the Caps Lock flag is set. All 11 unit tests, both engine schema checks, and packaged smoke checks passed. Build 10 was installed and its signature and input-source registration verified. Physical keyboard behavior in the user's existing application sessions still requires user verification.

## macOS 26 Liquid Glass candidate window

The candidate panel uses one regular-style NSGlassEffectView on macOS 26, with the scroll view assigned to contentView so AppKit can adapt foreground appearance. The 16-point outer corners and 8-point selection corners share an 8-point inset. Selection keeps the system accent color; earlier macOS versions retain a popover material. Native glass handles the system's material preferences; accessibility preference combinations were not manually toggled during this check.

Design references: [Apple HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials) recommends regular glass for text-heavy floating controls; [WWDC25 AppKit design guidance](https://developer.apple.com/videos/play/wwdc2025/310/) explains contentView placement and concentric geometry.

All 11 unit tests, both engine schema checks, and packaged smoke checks passed. Native window captures of light vertical and dark horizontal layouts were visually inspected; view bitmap caching alone does not capture the glass compositor faithfully. The smoke check also asserts native regular glass and its content hierarchy. Tests ran in a temporary bundle with a separate bundle ID and IMK connection name, without restarting the installed input method. An attempted class-based IMK test initializer crashed and was discarded; production initialization is unchanged.

The user confirmed that restarting existing client apps restored modifier-key switching after the prior input-method replacement. After installing build 11, existing clients may again require a complete restart. Prior temporary event tracing was removed from the source.

## Repeated right-Control taps

The retained diagnostic trace `/tmp/FeatherInput-live-route.log` contains right-Control events (key code 62, normalized Control flag 262144, release flag 0) in one Codex controller. At Unix times 1789313499.184970 and 1789313499.192268, it toggled to English and back to Chinese only 7.3 ms apart. Each toggle followed a complete down/up pair; duplicate releases alone were already ignored. This is historical evidence of duplicate complete taps, not proof of whether firmware, a remapper, or system routing produced them.

RightControlTap now rejects a press starting within 40 ms of the previous release, including replayed older timestamps. Rejected taps extend the quiet period; a rejected press cannot later toggle just by being held longer. The first accepted release still toggles immediately. Session reset clears held state while preserving the short quiet period. This deliberately treats two intended taps separated by less than 40 ms as one burst. Caps Lock behavior is unchanged.

Regression tests replay the trace ordering, a burst, preserved timestamps, reset, held rejected presses, and shortcut cancellation. The controller supplies NSEvent's monotonic timestamp; synthetic events with no usable timestamp retain their untimed behavior. Physical keyboard confirmation remains necessary after installation.

Build 12 passed all 14 unit tests, both schema engine checks and the isolated packaged smoke checks. It was installed, signature-verified, started, and the prior input-source selection restored.
