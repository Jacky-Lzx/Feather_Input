import AppKit
import InputMethodKit
import InputCore

@objc(FeatherInputController)
final class InputController: IMKInputController {
    private var session: Session?
    private let candidatesPanel = CandidatePanel()
    private var ascii = false
    private var activeScheme: InputScheme?
    private var scheme: InputScheme {
        InputScheme(rawValue: UserDefaults.standard.string(forKey: "scheme") ?? "") ?? .full
    }
    override func activateServer(_ sender: Any!) {
        if session == nil { session = try? AppDelegate.engine?.session(scheme) }
        session?.select(scheme)
        activeScheme = scheme
        session?.setASCII(ascii)
    }
    override func deactivateServer(_ sender: Any!) {
        commitComposition(sender)
        candidatesPanel.hide()
    }
    override func recognizedEvents(_ sender: Any!) -> Int { Int(NSEvent.EventTypeMask.keyDown.rawValue) }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
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
            commitComposition(sender)
            ascii.toggle(); session.setASCII(ascii); return true
        }
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            commitComposition(sender)
            return false
        }
        let special: [UInt16: Int32] = [36: 0xff0d, 76: 0xff0d, 48: 0xff09, 51: 0xff08,
            53: 0xff1b, 117: 0xffff, 123: 0xff51, 124: 0xff53, 125: 0xff54,
            126: 0xff52, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56]
        let key: Int32
        if let value = special[event.keyCode] { key = value }
        else if let chars = event.characters, chars.unicodeScalars.count == 1,
                let scalar = chars.unicodeScalars.first, scalar.value < 128 { key = Int32(scalar.value) }
        else { return false }
        let handled = session.process(key, modifiers: flags.contains(.shift) ? 1 : 0)
        refresh(client)
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
        candidatesPanel.show(texts: candidates.texts, highlight: candidates.highlight, caret: caret)
    }
    override func menu() -> NSMenu! {
        let menu = NSMenu()
        for mode in InputScheme.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(changeScheme(_:)), keyEquivalent: "")
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
    @objc private func showSettings(_ sender: Any?) {
        commitComposition(client())
        SettingsWindow.shared.show()
    }
    @objc private func changeScheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = InputScheme(rawValue: raw) else { return }
        commitComposition(client())
        if session?.select(mode) == true { UserDefaults.standard.set(raw, forKey: "scheme"); activeScheme = mode }
        session?.setASCII(ascii)
    }
    @objc private func toggleASCII(_ sender: Any?) {
        commitComposition(client()); ascii.toggle(); session?.setASCII(ascii)
    }
}
