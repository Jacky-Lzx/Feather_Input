import AppKit
import InputMethodKit
import InputCore

@objc(FeatherInputController)
final class InputController: IMKInputController {
    private var session: Session?
    private let candidatesPanel = CandidatePanel()
    private let modeIndicator = ModeIndicator()
    private var ascii = false
    private var rightControlTap = RightControlTap()
    private var capsLockSwitch = CapsLockSwitch()
    private var isActive = false
    private var lastCaret: NSRect?
    private var activeScheme: InputScheme?
    private var scheme: InputScheme {
        InputScheme(rawValue: UserDefaults.standard.string(forKey: "scheme") ?? "") ?? .full
    }
    override func activateServer(_ sender: Any!) {
        rightControlTap.reset()
        capsLockSwitch.reset(isLocked: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift))
        isActive = true
        lastCaret = nil
        if session == nil { session = try? AppDelegate.engine?.session(scheme) }
        session?.select(scheme)
        activeScheme = scheme
        session?.setASCII(ascii)
        PersistentModeIndicator.shared.update(ascii: ascii)
    }
    override func deactivateServer(_ sender: Any!) {
        isActive = false
        modeIndicator.hide()
        rightControlTap.reset()
        commitComposition(sender)
        candidatesPanel.hide()
    }
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]).rawValue)
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        if event.type == .flagsChanged {
            if capsLockSwitch.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
                rightControlTap.cancel()
                toggleASCII([kIMKCommandClientName as String: client])
                return true
            }
            if rightControlTap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
                toggleASCII([kIMKCommandClientName as String: client])
                return true
            }
            return false
        }
        rightControlTap.cancel()
        modeIndicator.hide()
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            // Adding flagsChanged opts out of IMK's keyDown-only default mouse handling.
            if !candidatesPanel.contains(NSEvent.mouseLocation) { commitComposition(sender) }
            return false
        }
        guard event.type == .keyDown else { return false }
        if session == nil { session = try? AppDelegate.engine?.session(scheme) }
        guard let session else { return false }
        if activeScheme != scheme {
            commitComposition(sender)
            if session.select(scheme) { activeScheme = scheme }
            session.setASCII(ascii)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Control-Shift-Space toggles Chinese/English without intercepting bare Shift.
        if event.keyCode == 49 && flags.contains([.control, .shift]) && !flags.contains(.command) {
            toggleASCII([kIMKCommandClientName as String: client])
            return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            commitComposition(sender)
            return false
        }
        let special: [UInt16: Int32] = [36: 0xff0d, 76: 0xff0d, 48: 0xff09, 51: 0xff08,
            53: 0xff1b, 117: 0xffff, 123: 0xff51, 124: 0xff53, 125: 0xff54,
            126: 0xff52, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56]
        var characters = event.characters
        if flags.contains(.capsLock), let chars = characters, chars.unicodeScalars.count == 1,
           let scalar = chars.unicodeScalars.first, (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
            // Caps Lock controls language in Feather; Shift still controls letter case.
            characters = flags.contains(.shift) ? chars.uppercased() : chars.lowercased()
        }
        let key: Int32
        if let value = special[event.keyCode] { key = value }
        else if let chars = characters, chars.unicodeScalars.count == 1,
                let scalar = chars.unicodeScalars.first, scalar.value < 128 { key = Int32(scalar.value) }
        else { return false }
        let handled = session.process(key, modifiers: flags.contains(.shift) ? 1 : 0)
        refresh(client)
        if !handled, ascii, flags.contains(.capsLock), let characters, characters != event.characters {
            client.insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        return handled
    }
    override func commitComposition(_ sender: Any!) {
        guard let client = sender as? IMKTextInput, let session else { return }
        session.commit()
        refresh(client)
        session.clear()
        candidatesPanel.hide()
    }
    private func refresh(_ client: IMKTextInput) {
        guard let session else { return }
        if let text = session.takeCommit() {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let preedit = session.preedit
        client.setMarkedText(preedit.text, selectionRange: NSRange(location: preedit.cursor, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let candidates = session.candidates
        guard !preedit.text.isEmpty, !candidates.texts.isEmpty else { candidatesPanel.hide(); return }
        var caret = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0 { lastCaret = caret }
        let anchor = lastCaret ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
        candidatesPanel.show(texts: candidates.texts, highlight: candidates.highlight, caret: anchor) { [weak self, weak client] index in
            guard let self, self.isActive, let client, let session = self.session,
                  session.preedit.text == preedit.text, session.candidates.texts == candidates.texts else { return }
            self.rightControlTap.cancel()
            if session.selectCandidate(at: index) { self.refresh(client) }
        }
    }
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        for mode in InputScheme.allCases {
            let item = NSMenuItem(title: mode.title, action: mode == .full ? #selector(selectFullPinyin(_:)) : #selector(selectFlypy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = scheme == mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: ascii ? "切换到中文" : "切换到英文", action: #selector(toggleASCII(_:)), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: "")
        settings.target = self; menu.addItem(settings)
        return menu
    }
    private func commandClient(_ sender: Any?) -> Any? {
        (sender as? NSDictionary)?[kIMKCommandClientName as String] ?? client()
    }
    @objc private func showSettings(_ sender: Any?) {
        modeIndicator.hide()
        commitComposition(commandClient(sender))
        SettingsWindow.shared.show()
    }
    @objc private func selectFullPinyin(_ sender: Any?) { changeScheme(.full, sender: sender) }
    @objc private func selectFlypy(_ sender: Any?) { changeScheme(.flypy, sender: sender) }
    private func changeScheme(_ mode: InputScheme, sender: Any?) {
        commitComposition(commandClient(sender))
        // A command can arrive before the first key event creates a session.
        if session == nil { session = try? AppDelegate.engine?.session(mode) }
        guard session?.select(mode) == true else { NSSound.beep(); return }
        UserDefaults.standard.set(mode.rawValue, forKey: "scheme")
        activeScheme = mode
        session?.setASCII(ascii)
    }
    @objc private func toggleASCII(_ sender: Any?) {
        let target = commandClient(sender)
        commitComposition(target)
        ascii.toggle()
        session?.setASCII(ascii)
        PersistentModeIndicator.shared.update(ascii: ascii)
        guard let textClient = target as? IMKTextInput else { modeIndicator.hide(); return }
        var caret = NSRect.zero
        _ = textClient.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0, caret.height.isFinite {
            lastCaret = caret
        }
        guard let anchor = lastCaret else { modeIndicator.hide(); return }
        modeIndicator.show(ascii: ascii, caret: anchor, clientLevel: Int(textClient.windowLevel()))
    }

    static func verifyKeyboardAndClick(server: IMKServer) throws {
        let textClient = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else {
            throw Engine.Failure.schemaUnavailable
        }
        controller.activateServer(textClient)
        guard let session = controller.session else { throw Engine.Failure.schemaUnavailable }
        session.select(.full)
        func flags(_ raw: UInt) -> Bool {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                                        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 62)!
            return controller.handle(event, client: textClient)
        }
        for key in "nihao".utf8 { session.process(Int32(key)) }
        controller.refresh(textClient)
        guard controller.candidatesPanel.verifyClick(on: 0), textClient.committed == "你好", textClient.marked.isEmpty else {
            throw Engine.Failure.schemaUnavailable
        }
        for key in "nihao".utf8 { session.process(Int32(key)) }
        controller.refresh(textClient)
        guard !flags(1 << 18), flags(0), controller.ascii,
              textClient.committed == "你好你好", textClient.marked.isEmpty,
              controller.modeIndicator.isVisible, controller.modeIndicator.text == "英文" else { throw Engine.Failure.schemaUnavailable }
        _ = flags(1 << 18)
        let shortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        guard !controller.handle(shortcut, client: textClient), !flags(0), controller.ascii else { throw Engine.Failure.schemaUnavailable }
        _ = flags(1 << 18)
        guard flags(0), !controller.ascii, controller.modeIndicator.text == "中文", controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        guard !controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(textClient)
        print("PASS: caret mode indicator labels and automatic dismissal")
        print("PASS: NSEvent right-Control tap, shortcut pass-through, pending composition commit, candidate button to IMK client insertion")
    }

    static func verifyCapsLock(server: IMKServer) throws {
        let target = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(target)
        controller.capsLockSwitch.reset(isLocked: false)
        func caps(_ on: Bool) -> Bool {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: on ? .capsLock : [],
                                        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 57)!
            return controller.handle(event, client: target)
        }
        guard caps(true), controller.ascii, !caps(true) else { throw Engine.Failure.schemaUnavailable }
        let letter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .capsLock, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "A", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        guard controller.handle(letter, client: target), target.committed == "a", caps(false), !controller.ascii else { throw Engine.Failure.schemaUnavailable }
        func rightControl(_ down: Bool, capsLocked: Bool) -> Bool {
            var flags: NSEvent.ModifierFlags = capsLocked ? .capsLock : []
            if down { flags.insert(.control) }
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 62)!
            return controller.handle(event, client: target)
        }
        // Alternate both keys, including right Control while Caps Lock is latched.
        guard !rightControl(true, capsLocked: false), rightControl(false, capsLocked: false), controller.ascii,
              caps(true), !controller.ascii,
              !rightControl(true, capsLocked: true), rightControl(false, capsLocked: true), controller.ascii,
              caps(false), !controller.ascii else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(target)
        print("PASS: native Caps Lock switch, duplicate suppression and lowercase English output")
        print("PASS: alternating Caps Lock and right Control toggles with Caps Lock on and off")
    }

    // Exercise IMK's actual command dispatcher with its dictionary sender.
    static func verifyMenuCommands(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "scheme")
        defer {
            if let previous { defaults.set(previous, forKey: "scheme") }
            else { defaults.removeObject(forKey: "scheme") }
        }
        guard let controller = InputController(server: server, delegate: nil, client: nil) else {
            throw Engine.Failure.schemaUnavailable
        }
        for mode in [InputScheme.flypy, .full, .flypy] {
            guard let item = controller.menu().items.first(where: { $0.title == mode.title }),
                  let action = item.action else { throw Engine.Failure.schemaUnavailable }
            controller.doCommand(by: action, command: [kIMKCommandMenuItemName as String: item])
            guard controller.scheme == mode, controller.activeScheme == mode,
                  controller.menu().items.first(where: { $0.title == mode.title })?.state == .on,
                  let session = controller.session else { throw Engine.Failure.schemaUnavailable }
            for key in (mode == .full ? "nihao" : "nihc").utf8 { session.process(Int32(key)) }
            session.process(32)
            guard session.takeCommit() == "你好" else { throw Engine.Failure.schemaUnavailable }
        }
        print("PASS: IMK menu dictionary dispatch, session creation, full/flypy switching, checkmarks and engine output")
    }
}
