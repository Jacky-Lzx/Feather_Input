import AppKit
import InputMethodKit
import InputCore

@objc(FeatherInputController)
final class InputController: IMKInputController {
    private var session: Session?
    private let candidatesPanel = CandidatePanel()
    private let modeIndicator = ModeIndicator()
    private var ascii = false
    private var recommendationTask: Task<Void, Never>?
    private var recommendationVersion = UUID()
    private var recentContext = ""
    private var continuationText: String?
    private var requestContinuation: (String, String, String) async throws -> [String] = {
        if UserDefaults.standard.string(forKey: "aiContinuationBackend") == "mlx" {
            return try await LocalRecommendation.mlxContinuations(context: $2)
        }
        return [try await LocalRecommendation.continueText(model: $0, token: $1, context: $2)]
    }
    private var requestRecommendation: (String, String, String, String, [String]) async throws -> Int = {
        try await LocalRecommendation.recommend(model: $0, token: $1, context: $2, preedit: $3, candidates: $4)
    }
    private func invalidateRecommendation(clearContext: Bool = false) {
        recommendationTask?.cancel()
        recommendationTask = nil
        if continuationText != nil { candidatesPanel.hide(); continuationText = nil }
        recommendationVersion = UUID()
        candidatesPanel.markRecommendation(nil)
        if clearContext { recentContext = "" }
    }
    deinit { recommendationTask?.cancel() }
    private var rightControlTap = RightControlTap()
    private var capsLockSwitch = CapsLockSwitch()
    private var isActive = false
    private var lastCaret: NSRect?
    private var activeScheme: InputScheme?
    private var scheme: InputScheme {
        InputScheme(rawValue: UserDefaults.standard.string(forKey: "scheme") ?? "") ?? .full
    }
    override func activateServer(_ sender: Any!) {
        invalidateRecommendation(clearContext: true)
        rightControlTap.reset()
        capsLockSwitch.reset(isLocked: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift))
        isActive = true
        lastCaret = nil
        if session == nil { session = try? AppDelegate.engine?.session(scheme) }
        session?.setCandidateCount(UserDefaults.standard.object(forKey: "candidateCount") as? Int ?? 5)
        session?.select(scheme)
        activeScheme = scheme
        session?.setASCII(ascii)
        PersistentModeIndicator.shared.update(ascii: ascii)
    }
    override func deactivateServer(_ sender: Any!) {
        invalidateRecommendation(clearContext: true)
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
        if event.type == .leftMouseDown, continuationText != nil, candidatesPanel.contains(NSEvent.mouseLocation) { return false }
        session?.setCandidateCount(UserDefaults.standard.object(forKey: "candidateCount") as? Int ?? 5)
        let changesPosition = event.type != .keyDown || event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false || [51, 117, 123, 124, 125, 126, 115, 119, 36, 48].contains(event.keyCode)
        invalidateRecommendation(clearContext: changesPosition)
        if event.type == .flagsChanged {
            if capsLockSwitch.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue) {
                rightControlTap.cancel()
                toggleASCII([kIMKCommandClientName as String: client])
                return true
            }
            if rightControlTap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags.rawValue,
                                            timestamp: event.timestamp > 0 ? event.timestamp : nil) {
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
        invalidateRecommendation(clearContext: true)
    }
    private func refresh(_ client: IMKTextInput) {
        invalidateRecommendation()
        guard let session else { return }
        let committed = session.takeCommit()
        if let text = committed {
            recentContext = String((recentContext + text).suffix(80))
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let preedit = session.preedit
        client.setMarkedText(preedit.text, selectionRange: NSRange(location: preedit.cursor, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let candidates = session.candidates
        guard !preedit.text.isEmpty, !candidates.texts.isEmpty else {
            candidatesPanel.hide()
            if preedit.text.isEmpty, let committed, !committed.isEmpty { scheduleContinuation(client) }
            return
        }
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
        scheduleRecommendation(preedit: preedit.text, texts: candidates.texts)
    }
    private func scheduleRecommendation(preedit: String, texts: [String]) {
        let defaults = UserDefaults.standard
        guard isActive, !ascii, defaults.bool(forKey: "aiRecommendationEnabled"), texts.count > 1,
              let model = defaults.string(forKey: "aiModel"), !model.isEmpty else { return }
        let version = recommendationVersion
        let context = recentContext
        let token = ModelCredential.read()
        let request = requestRecommendation
        recommendationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                try Task.checkCancellation()
                guard self?.isActive == true, self?.recommendationVersion == version,
                      UserDefaults.standard.bool(forKey: "aiRecommendationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == model else { return }
                let index = try await request(model, token, context, preedit, texts)
                try Task.checkCancellation()
                guard let self, self.isActive, !self.ascii, self.recommendationVersion == version,
                      UserDefaults.standard.bool(forKey: "aiRecommendationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == model,
                      self.session?.preedit.text == preedit, self.session?.candidates.texts == texts else { return }
                self.candidatesPanel.markRecommendation(index)
            } catch { /* Ordinary candidates remain usable on cancellation, timeout or invalid output. */ }
        }
    }
    private func scheduleContinuation(_ client: IMKTextInput) {
        let defaults = UserDefaults.standard
        let candidateCount = defaults.object(forKey: "aiCandidateCount") as? Int ?? 5
        let backend = defaults.string(forKey: "aiContinuationBackend")
        let savedModel = defaults.string(forKey: "aiModel")
        let model = savedModel ?? ""
        guard isActive, !ascii, defaults.bool(forKey: "aiContinuationEnabled"), !recentContext.isEmpty,
              (backend == "mlx" || !model.isEmpty) else { return }
        let version = recommendationVersion
        let context = recentContext
        let range = client.selectedRange()
        guard range.length == 0 else { return }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let token = ModelCredential.read()
        let request = requestContinuation
        recommendationTask = Task { @MainActor [weak self, weak client] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                try Task.checkCancellation()
                guard self?.isActive == true, self?.recommendationVersion == version,
                      UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == savedModel,
                      UserDefaults.standard.string(forKey: "aiContinuationBackend") == backend,
                      (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == candidateCount else { return }
                let texts = try await request(model, token, context)
                guard let text = texts.first else { return }
                try Task.checkCancellation()
                guard let self, let client, self.isActive, !self.ascii,
                      self.recommendationVersion == version, self.recentContext == context,
                      self.session?.preedit.text.isEmpty == true,
                      UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == savedModel,
                      UserDefaults.standard.string(forKey: "aiContinuationBackend") == backend,
                      (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == candidateCount,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                      NSEqualRanges(client.selectedRange(), range) else { return }
                var caret = NSRect.zero
                _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
                let anchor = caret.height > 0 && caret.origin.x.isFinite && caret.origin.y.isFinite ? caret : self.lastCaret
                guard let anchor else { return }
                self.continuationText = text
                self.candidatesPanel.show(texts: texts, highlight: -1, caret: anchor, continuation: true) { [weak self, weak client] index in
                    guard let self, let client, self.isActive, !self.ascii, self.recommendationVersion == version,
                          self.continuationText == text, self.session?.preedit.text.isEmpty == true,
                          UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
                          UserDefaults.standard.string(forKey: "aiModel") == savedModel,
                      UserDefaults.standard.string(forKey: "aiContinuationBackend") == backend,
                      (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == candidateCount,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                          NSEqualRanges(client.selectedRange(), range) else { return }
                    guard texts.indices.contains(index) else { return }
                    let selected = texts[index]
                    self.invalidateRecommendation()
                    client.insertText(selected, replacementRange: NSRange(location: NSNotFound, length: 0))
                    self.recentContext = String((context + selected).suffix(80))
                }
            } catch { /* A continuation is optional; failures never affect committed text. */ }
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
        let debug = NSMenuItem(title: "LLM 调试…", action: #selector(showLLMDebug(_:)), keyEquivalent: "")
        debug.target = self
        menu.addItem(debug)
        return menu
    }
    @objc private func showLLMDebug(_ sender: Any?) {
        Task { @MainActor in LLMDebugWindow.shared.show() }
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
        invalidateRecommendation(clearContext: true)
        commitComposition(commandClient(sender))
        // A command can arrive before the first key event creates a session.
        if session == nil { session = try? AppDelegate.engine?.session(mode) }
        guard session?.select(mode) == true else { NSSound.beep(); return }
        UserDefaults.standard.set(mode.rawValue, forKey: "scheme")
        activeScheme = mode
        session?.setASCII(ascii)
    }
    @objc private func toggleASCII(_ sender: Any?) {
        invalidateRecommendation(clearContext: true)
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

    static func verifyContinuationLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: "aiContinuationEnabled")
        let oldModel = defaults.object(forKey: "aiModel")
        defer {
            for (key, value) in [("aiContinuationEnabled", oldEnabled), ("aiModel", oldModel)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "aiContinuationEnabled")
        defaults.set("test-model", forKey: "aiModel")
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(client)
        controller.requestContinuation = { _, _, _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return ["好，明天见", "好，周末见"]
        }
        for key in "ni ".utf8 { controller.session?.process(Int32(key)) }
        controller.refresh(client)
        let committed = client.committed
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        guard !committed.isEmpty, client.committed == committed, controller.continuationText == "好，明天见",
              controller.candidatesPanel.verifyClick(on: 1), client.committed == committed + "好，周末见",
              controller.continuationText == nil else { throw Engine.Failure.schemaUnavailable }
        controller.scheduleContinuation(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.42))
        controller.invalidateRecommendation(clearContext: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard controller.continuationText == nil else { throw Engine.Failure.schemaUnavailable }
        controller.recentContext = "我们明天下午"
        controller.scheduleContinuation(client)
        client.insertText("改变位置", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        guard controller.continuationText == nil else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: post-commit continuation, click-only insertion, cancelled reply and changed selection rejection")
    }

    static func verifyRecommendationLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: "aiRecommendationEnabled")
        let oldModel = defaults.object(forKey: "aiModel")
        defer {
            for (key, value) in [("aiRecommendationEnabled", oldEnabled), ("aiModel", oldModel)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "aiRecommendationEnabled")
        defaults.set("test-model", forKey: "aiModel")
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(client)
        controller.requestRecommendation = { _, _, _, _, _ in
            // Deliberately return even after cancellation to test stale response rejection.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return 1
        }
        for key in "ni".utf8 { controller.session?.process(Int32(key)) }
        controller.refresh(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        guard controller.candidatesPanel.recommendedIndex == 1 else { throw Engine.Failure.schemaUnavailable }
        let before = controller.session?.candidates.texts
        controller.refresh(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.28))
        controller.invalidateRecommendation(clearContext: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard controller.candidatesPanel.recommendedIndex == nil,
              controller.session?.candidates.texts == before else { throw Engine.Failure.schemaUnavailable }
        controller.refresh(client)
        controller.deactivateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard controller.candidatesPanel.recommendedIndex == nil else { throw Engine.Failure.schemaUnavailable }
        print("PASS: async recommendation marker, stable candidate order, stale result cancellation and deactivation")
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
