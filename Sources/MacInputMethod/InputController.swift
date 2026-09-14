import AppKit
import Carbon
import InputMethodKit
import InputCore

@objc(FeatherInputController)
final class InputController: IMKInputController {
    private var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    private func bypassSecureInput() -> Bool {
        guard secureInputEnabled() else { return false }
        session?.clear()
        _ = session?.takeCommit()
        invalidateRecommendation(clearContext: true)
        frozenPrediction = nil
        candidatesPanel.hide()
        modeIndicator.hide()
        rightControlTap.reset()
        return true
    }
    private var expandedTexts: [String]?
    private var expandedIndex = 0
    private var expandedRows = 5
    private var expansionTask: Task<Void, Never>?
    private var expansionID = UUID()
    private func closeExpanded() {
        expansionTask?.cancel(); expansionTask = nil
        expansionID = UUID(); expandedTexts = nil
    }
    private func renderExpanded(_ client: IMKTextInput, loading: Bool = false) {
        guard let texts = expandedTexts, !texts.isEmpty else { return }
        let version = expansionID
        candidatesPanel.showExpanded(texts: texts, highlight: expandedIndex,
            caret: lastCaret ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20)),
            rows: expandedRows, loading: loading) { [weak self, weak client] index in
                guard let self, let client, self.expansionID == version, !self.bypassSecureInput() else { return }
                self.selectExpanded(index, client: client)
            }
    }
    private func selectExpanded(_ index: Int, client: IMKTextInput) {
        guard let texts = expandedTexts, texts.indices.contains(index), let session else { return }
        if session.selectGlobalCandidate(at: index) {
            closeExpanded()
            refresh(client)
        }
    }
    private func openExpanded(_ client: IMKTextInput) {
        guard let session else { return }
        expandedRows = session.candidateCount
        invalidateRecommendation()
        closeExpanded()
        expandedTexts = session.candidateSlice(offset: 0)
        guard expandedTexts?.isEmpty == false else { closeExpanded(); return }
        expandedIndex = 0
        let preedit = session.preedit.text
        let version = expansionID
        renderExpanded(client, loading: expandedTexts?.count == 128)
        expansionTask = Task { @MainActor [weak self, weak client] in
            while let self, let client, self.expansionID == version, let texts = self.expandedTexts,
                  self.isActive, !self.bypassSecureInput(), session.preedit.text == preedit {
                do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
                guard self.expansionID == version, !Task.isCancelled else { return }
                let more = session.candidateSlice(offset: texts.count)
                self.expandedTexts?.append(contentsOf: more)
                self.renderExpanded(client, loading: more.count == 128)
                if more.count < 128 { return }
            }
        }
    }
    private var session: Session?
    private let candidatesPanel = CandidatePanel()
    private let modeIndicator = ModeIndicator()
    private var ascii = false
    private var recommendationTask: Task<Void, Never>?
    private var recommendationVersion = UUID()
    private var recentContext = ""
    private var rankingTask: Task<Void, Never>?
    private var rankingVersion = UUID()
    private var cachedPrediction: [LocalRecommendation.RankedToken] = []
    private var cachedPredictionDelayMS: Int?
    private var frozenPredictionDelayMS: Int?
    private var frozenPrediction: [LocalRecommendation.RankedToken]? {
        didSet { if frozenPrediction == nil { frozenPredictionDelayMS = nil } }
    }
    private var displayedOrder: [Int] = []
    private var displayedOriginal: [String] = []
    private var displayedPreedit = ""
    private var displayedHighlight = 0
    private var scoringEnabled: Bool { UserDefaults.standard.bool(forKey: "aiCandidateScoringEnabled") }
    private var scoredPreedit = ""
    private var scoredOriginal: [String] = []
    private var scoredContext = ""
    private var scoredSettings = ""
    private var scoringTiming: ScoringTiming { ScoringTiming() }
    private var scoringSettings: String { "\(UserDefaults.standard.object(forKey: "aiFusionWeight") as? Double ?? 0.35)|\(UserDefaults.standard.string(forKey: "aiScoreNormalization") ?? "character")|\(scoringTiming.debounceMS)|\(scoringTiming.responseLimitMS)" }
    private var scoringLockedPreedit = ""
    private var scoringLockedOriginal: [String] = []
    private var requestScoring: (String, String, [String]) async throws -> [LocalRecommendation.RankedToken] = {
        try await LocalRecommendation.scoreCandidates(context: $0, preedit: $1, candidates: $2)
    }
    private func scheduleScoring(_ client: IMKTextInput, preedit: String, candidates: [String]) {
        guard scoringEnabled, isActive, !ascii, !recentContext.isEmpty, candidates.count > 1,
              scoredPreedit != preedit || scoredOriginal != candidates || scoredContext != recentContext || scoredSettings != scoringSettings else { return }
        guard scoringLockedPreedit != preedit || scoringLockedOriginal != candidates else { return }
        let settings = scoringSettings
        let timing = scoringTiming
        let version = recommendationVersion
        let context = recentContext
        let range = client.selectedRange()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let request = requestScoring
        recommendationTask = Task { @MainActor [weak self, weak client] in
            do {
                try await Task.sleep(nanoseconds: UInt64(timing.debounceMS) * 1_000_000)
                try Task.checkCancellation()
                let started = DispatchTime.now().uptimeNanoseconds
                guard self?.secureInputEnabled() == false else { return }
                let result = try await request(context, preedit, candidates)
                let delay = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                try Task.checkCancellation()
                guard let self, let client, !self.bypassSecureInput(), self.isActive, !self.ascii, self.scoringEnabled,
                      self.recommendationVersion == version, self.recentContext == context, self.scoringSettings == settings,
                      self.session?.preedit.text == preedit, self.session?.candidates.texts == candidates,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                      NSEqualRanges(client.selectedRange(), range), delay <= timing.responseLimitMS,
                      !self.candidatesPanel.contains(NSEvent.mouseLocation) else { return }
                self.scoredPreedit = preedit
                self.scoredOriginal = candidates
                self.scoredContext = context
                self.scoredSettings = settings
                self.frozenPrediction = result
                self.frozenPredictionDelayMS = delay
                self.refresh(client, allowScoring: false)
            } catch { /* Rime's current page remains usable if scoring fails. */ }
        }
    }
    private var rankingEnabled: Bool { UserDefaults.standard.bool(forKey: "aiRerankingEnabled") }
    private var requestRanking: (String) async throws -> [LocalRecommendation.RankedToken] = {
        try await LocalRecommendation.mlxRankedTokens(context: $0)
    }
    private func cancelRanking(clearCache: Bool) {
        rankingTask?.cancel()
        rankingTask = nil
        rankingVersion = UUID()
        if clearCache { cachedPrediction = []; cachedPredictionDelayMS = nil }
    }
    private func scheduleRanking(_ client: IMKTextInput) {
        cancelRanking(clearCache: true)
        guard !scoringEnabled, rankingEnabled, isActive, !ascii, !recentContext.isEmpty else { return }
        let version = rankingVersion
        let context = recentContext
        let range = client.selectedRange()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let count = UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5
        let request = requestRanking
        rankingTask = Task { @MainActor [weak self, weak client] in
            do {
                let started = DispatchTime.now().uptimeNanoseconds
                guard self?.secureInputEnabled() == false else { return }
                let tokens = try await request(context)
                let delayMS = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                try Task.checkCancellation()
                guard let self, let client, !self.bypassSecureInput(), self.isActive, !self.ascii, self.rankingEnabled,
                      self.rankingVersion == version, self.recentContext == context,
                      self.session?.preedit.text.isEmpty == true, self.frozenPrediction == nil,
                      (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == count,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                      NSEqualRanges(client.selectedRange(), range) else { return }
                self.cachedPrediction = tokens
                self.cachedPredictionDelayMS = delayMS
            } catch { /* A missing prediction leaves Rime order unchanged. */ }
        }
    }
    private func selectDisplayed(_ index: Int, client: IMKTextInput) -> Bool {
        guard let session, session.preedit.text == displayedPreedit,
              session.candidates.texts == displayedOriginal, displayedOrder.indices.contains(index) else { return false }
        guard session.selectCandidate(at: displayedOrder[index]) else { return false }
        refresh(client)
        return true
    }
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
    // Query after the host has processed navigation/deletion, before creating marked text.
    private func restoreContextBeforeComposition(_ client: IMKTextInput) {
        guard !bypassSecureInput() else { return }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location >= 0 else { return }
        let count = min(selection.location, 320) // IMK ranges are UTF-16, not Swift characters.
        let range = NSRange(location: selection.location - count, length: count)
        var actual = NSRange(location: NSNotFound, length: 0)
        let plain = client.string(from: range, actualRange: &actual)
        let text: String?
        if let plain, NSEqualRanges(actual, range), plain.utf16.count == count {
            text = plain
        } else if let attributed = client.attributedSubstring(from: range), attributed.length == count {
            text = attributed.string
        } else {
            text = nil // Some terminal clients expose marked text only.
        }
        guard let text else { return }
        let context = String(text.suffix(80))
        if context != recentContext {
            invalidateRecommendation(clearContext: true)
            recentContext = context
        }
    }
    private func invalidateRecommendation(clearContext: Bool = false) {
        recommendationTask?.cancel()
        recommendationTask = nil
        if continuationText != nil { candidatesPanel.hide(); continuationText = nil }
        recommendationVersion = UUID()
        candidatesPanel.markRecommendation(nil)
        if clearContext {
            closeExpanded()
            recentContext = ""
            scoredPreedit = ""; scoredOriginal = []; scoredContext = ""
            cancelRanking(clearCache: true)
            if session?.preedit.text.isEmpty != false { frozenPrediction = nil }
        }
    }
    deinit { recommendationTask?.cancel(); rankingTask?.cancel(); expansionTask?.cancel() }
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
        frozenPrediction = nil
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
        guard !bypassSecureInput() else { return false }
        guard let event, let client = sender as? IMKTextInput else { return false }
        if expandedTexts != nil, [.leftMouseDown, .rightMouseDown, .scrollWheel].contains(event.type), candidatesPanel.contains(NSEvent.mouseLocation) { return false }
        if event.type == .leftMouseDown, continuationText != nil, candidatesPanel.contains(NSEvent.mouseLocation) { return false }
        session?.setCandidateCount(UserDefaults.standard.object(forKey: "candidateCount") as? Int ?? 5)
        let composing = session?.preedit.text.isEmpty == false
        let changesPosition = event.type != .keyDown || event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false || (!composing && [51, 117, 123, 124, 125, 126, 115, 119, 36, 48].contains(event.keyCode))
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
        // Fn+arrows may retain the physical arrow keyCode while characters carry
        // the logical Home/End/PageUp/PageDown function key.
        let navigation: [UInt32: Int32] = [UInt32(NSHomeFunctionKey): 0xff50,
            UInt32(NSEndFunctionKey): 0xff57, UInt32(NSPageUpFunctionKey): 0xff55,
            UInt32(NSPageDownFunctionKey): 0xff56]
        let logicalNavigation = characters?.unicodeScalars.count == 1
            ? characters?.unicodeScalars.first.flatMap { navigation[$0.value] } : nil
        var key: Int32
        if let value = logicalNavigation { key = value }
        else if let value = special[event.keyCode] { key = value }
        else if let chars = characters, chars.unicodeScalars.count == 1,
                let scalar = chars.unicodeScalars.first, scalar.value < 128 { key = Int32(scalar.value) }
        else { return false }
        if let texts = expandedTexts {
            if [0xff51, 0xff53, 0xff52, 0xff54].contains(key) {
                expandedIndex = CandidateGrid.move(index: expandedIndex, count: texts.count, rows: expandedRows,
                    horizontal: key == 0xff51 ? -1 : key == 0xff53 ? 1 : 0,
                    vertical: key == 0xff52 ? -1 : key == 0xff54 ? 1 : 0)
                renderExpanded(client)
                return true
            }
            if (49...57).contains(key), !flags.contains(.shift) {
                if let index = CandidateGrid.numberedIndex(number: Int(key - 48), highlight: expandedIndex,
                    count: texts.count, rows: expandedRows) {
                    selectExpanded(index, client: client)
                }
                return true // An unassigned number must not select from the ordinary Rime page.
            }
            if key == 32 || key == 0xff0d { selectExpanded(expandedIndex, client: client); return true }
            if key == 0xff1b { closeExpanded(); refresh(client, allowScoring: false); return true }
            closeExpanded()
        }
        if !ascii, !session.preedit.text.isEmpty, key == 0xff53 {
            openExpanded(client)
            return true
        }
        if !ascii, !session.preedit.text.isEmpty, key == 0xff51 { key = 0xff55 }
        if scoringEnabled, !session.preedit.text.isEmpty, [0xff52, 0xff54, 0xff50, 0xff57].contains(key) {
            scoringLockedPreedit = session.preedit.text
            scoringLockedOriginal = session.candidates.texts
        }
        if !ascii, session.preedit.text.isEmpty, (97...122).contains(key) {
            restoreContextBeforeComposition(client)
            scoringLockedPreedit = ""; scoringLockedOriginal = []
            frozenPrediction = rankingEnabled && !scoringEnabled ? cachedPrediction : []
            frozenPredictionDelayMS = rankingEnabled ? cachedPredictionDelayMS : nil
            cancelRanking(clearCache: true)
        }
        if !ascii, !session.preedit.text.isEmpty, !displayedOrder.isEmpty,
           displayedOrder != Array(displayedOriginal.indices),
           session.preedit.text == displayedPreedit, session.candidates.texts == displayedOriginal {
            if key == 32 { return selectDisplayed(displayedHighlight, client: client) }
            if (49...57).contains(key), !flags.contains(.shift) {
                let index = Int(key - 49)
                if displayedOrder.indices.contains(index) { return selectDisplayed(index, client: client) }
            }
            if key == 0xff52 || key == 0xff54 {
                displayedHighlight = min(displayedOrder.count - 1, max(0, displayedHighlight + (key == 0xff54 ? 1 : -1)))
                refresh(client)
                return true
            }
        }
        let handled = session.process(key, modifiers: flags.contains(.shift) ? 1 : 0)
        refresh(client)
        if !handled, ascii, flags.contains(.capsLock), let characters, characters != event.characters {
            client.insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
        return handled
    }
    override func commitComposition(_ sender: Any!) {
        guard !bypassSecureInput() else { return }
        guard let client = sender as? IMKTextInput, let session else { return }
        session.commit()
        refresh(client)
        session.clear()
        candidatesPanel.hide()
        invalidateRecommendation(clearContext: true)
    }
    private func refresh(_ client: IMKTextInput, allowScoring: Bool = true) {
        closeExpanded()
        guard !bypassSecureInput() else { return }
        invalidateRecommendation()
        guard let session else { return }
        let committed = session.takeCommit()
        if let text = committed {
            frozenPrediction = nil
            scoredPreedit = ""; scoredOriginal = []; scoredContext = ""
            cancelRanking(clearCache: true)
            recentContext = String((recentContext + text).suffix(80))
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let preedit = session.preedit
        client.setMarkedText(preedit.text, selectionRange: NSRange(location: preedit.cursor, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let candidates = session.candidates
        guard !preedit.text.isEmpty, !candidates.texts.isEmpty else {
            candidatesPanel.hide()
            displayedOrder = []
            if preedit.text.isEmpty {
                frozenPrediction = nil
                if let committed, !committed.isEmpty {
                    if scoringEnabled { /* Wait for Rime candidates. */ }
                    else if rankingEnabled { scheduleRanking(client) }
                    else { scheduleContinuation(client) }
                }
            }
            return
        }
        var caret = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0 { lastCaret = caret }
        let anchor = lastCaret ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
        if scoringEnabled && (scoredPreedit != preedit.text || scoredOriginal != candidates.texts || scoredContext != recentContext || scoredSettings != scoringSettings) {
            frozenPrediction = nil
        }
        let order = CandidateRanking.order(candidates.texts, predictions: (frozenPrediction ?? []).map(\.text))
        if displayedOriginal != candidates.texts || displayedPreedit != preedit.text { displayedHighlight = 0 }
        displayedOriginal = candidates.texts
        displayedPreedit = preedit.text
        displayedOrder = order
        Task { @MainActor [predictions = frozenPrediction ?? [], scoring = scoringEnabled, delay = frozenPredictionDelayMS] in
            CandidateDebugWindow.shared.update(preedit: preedit.text, rime: candidates.texts,
                predictions: predictions, final: order.map { candidates.texts[$0] }, scoring: scoring, delay: delay)
        }
        let reordered = order != Array(candidates.texts.indices)
        candidatesPanel.show(texts: order.map { candidates.texts[$0] },
                             highlight: reordered ? displayedHighlight : candidates.highlight, caret: anchor,
                             llmTokens: frozenPrediction ?? [], llmDelayMS: frozenPredictionDelayMS, llmTitle: scoringEnabled ? "Rime + LLM · 融合排序" : "LLM top-k · 本轮预测") { [weak self, weak client] index in
            guard let self, !self.bypassSecureInput(), self.isActive, let client, let session = self.session,
                  session.preedit.text == preedit.text, session.candidates.texts == candidates.texts,
                  self.displayedOrder == order else { return }
            self.rightControlTap.cancel()
            _ = self.selectDisplayed(index, client: client)
        }
        if scoringEnabled {
            if allowScoring { scheduleScoring(client, preedit: preedit.text, candidates: candidates.texts) }
        } else if !rankingEnabled && frozenPrediction?.isEmpty != false {
            scheduleRecommendation(preedit: preedit.text, texts: candidates.texts)
        }
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
                guard self?.secureInputEnabled() == false, self?.isActive == true, self?.recommendationVersion == version,
                      UserDefaults.standard.bool(forKey: "aiRecommendationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == model else { return }
                let index = try await request(model, token, context, preedit, texts)
                try Task.checkCancellation()
                guard let self, !self.bypassSecureInput(), self.isActive, !self.ascii, self.recommendationVersion == version,
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
                guard self?.secureInputEnabled() == false, self?.isActive == true, self?.recommendationVersion == version,
                      UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == savedModel,
                      UserDefaults.standard.string(forKey: "aiContinuationBackend") == backend,
                      (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == candidateCount else { return }
                let texts = try await request(model, token, context)
                guard let text = texts.first else { return }
                try Task.checkCancellation()
                guard let self, let client, !self.bypassSecureInput(), self.isActive, !self.ascii,
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
                    guard let self, let client, !self.bypassSecureInput(), self.isActive, !self.ascii, self.recommendationVersion == version,
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
        let candidatesDebug = NSMenuItem(title: "候选对比调试…", action: #selector(showCandidateDebug(_:)), keyEquivalent: "")
        candidatesDebug.target = self; menu.addItem(candidatesDebug)
        return menu
    }
    @objc private func showCandidateDebug(_ sender: Any?) {
        Task { @MainActor in CandidateDebugWindow.shared.show() }
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

    static func verifyRepeatedPaging(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let saved = ["scheme", "candidateCount", "aiCandidateScoringEnabled", "aiRerankingEnabled", "aiRecommendationEnabled"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set(7, forKey: "candidateCount")
        for key in ["aiCandidateScoringEnabled", "aiRerankingEnabled", "aiRecommendationEnabled"] { defaults.set(false, forKey: key) }
        for scheme in [InputScheme.full, .flypy] {
            defaults.set(scheme.rawValue, forKey: "scheme")
            let client = SmokeTextClient()
            guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
            controller.activateServer(client)
            func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
                _ = controller.handle(event, client: client)
            }
            for (text, code) in [("b", UInt16(11)), ("i", 34), ("r", 15), ("u", 32)] { key(text, code: code) }
            guard controller.displayedOriginal.contains("比如") else { throw Engine.Failure.schemaUnavailable }
            let first = controller.displayedOriginal
            guard first.count == 7 else { throw Engine.Failure.schemaUnavailable }
            let next = String(UnicodeScalar(NSPageDownFunctionKey)!)
            let previous = String(UnicodeScalar(NSPageUpFunctionKey)!)
            var pages = [first]
            for _ in 0..<3 {
                key(next, code: 125, flags: [.function])
                guard controller.displayedOriginal != pages.last! else { throw Engine.Failure.schemaUnavailable }
                pages.append(controller.displayedOriginal)
            }
            for _ in 0..<3 { key(previous, code: 126, flags: [.function]) }
            guard controller.displayedOriginal == first else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            guard let all = controller.expandedTexts, all.count > 16, all.first == first.first else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            guard controller.expandedRows == 7, controller.expandedIndex == 7 else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
            guard controller.expandedIndex == 8 else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
            guard controller.expandedIndex == 1 else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            let expected = all[9]
            key("3", code: 20)
            guard controller.expandedTexts == nil else { throw Engine.Failure.schemaUnavailable }
            if client.committed.isEmpty { key(" ", code: 49) }
            guard client.committed.hasPrefix(expected) else { throw Engine.Failure.schemaUnavailable }
            controller.deactivateServer(client)
        }
        print("PASS: biru full/Flypy continuous paging beyond page two, expanded grid column/row movement and global candidate selection")
    }

    static func verifySecureInput(server: IMKServer) throws {
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(client)
        controller.ascii = false
        controller.session?.setASCII(false)
        controller.session?.process(110)
        controller.recentContext = "synthetic context"
        controller.secureInputEnabled = { true }
        for (text, code) in [("u", UInt16(32)), ("a", UInt16(0)), ("1", UInt16(18)), ("", UInt16(51))] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            guard !controller.handle(event, client: client) else { throw Engine.Failure.schemaUnavailable }
        }
        controller.commitComposition(client)
        guard client.committed.isEmpty, client.marked.isEmpty, controller.recentContext.isEmpty,
              controller.session?.preedit.text.isEmpty == true, !controller.ascii else { throw Engine.Failure.schemaUnavailable }
        controller.secureInputEnabled = { false }
        controller.deactivateServer(client)
        print("PASS: secure input passes u/letters/digits/delete to host, discards composition without insertion")
    }

    static func verifyScoringLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let saved = ["aiCandidateScoringEnabled", "scheme", "debugScoringTimingEnabled"].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "debugScoringTimingEnabled")
        defaults.set(true, forKey: "aiCandidateScoringEnabled")
        defaults.set(InputScheme.full.rawValue, forKey: "scheme")
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(client)
        controller.recentContext = "我们"
        controller.requestScoring = { _, _, texts in
            texts.reversed().enumerated().map { .init(text: $0.element, rank: $0.offset + 1) }
        }
        func key(_ text: String, code: UInt16 = 0) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: code)!
            return controller.handle(event, client: client)
        }
        _ = key("n"); _ = key("i")
        guard let original = controller.session?.candidates.texts, original.count > 1 else { throw Engine.Failure.schemaUnavailable }
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        guard controller.displayedOrder.first == original.count - 1, controller.frozenPredictionDelayMS != nil else { throw Engine.Failure.schemaUnavailable }
        let before = client.committed
        guard key("1", code: 18), client.committed == before + original.last! else { throw Engine.Failure.schemaUnavailable }
        controller.requestScoring = { _, _, texts in
            try? await Task.sleep(nanoseconds: 180_000_000)
            return texts.reversed().enumerated().map { .init(text: $0.element, rank: $0.offset + 1) }
        }
        _ = key("n"); _ = key("i")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        _ = key("", code: 125)
        let locked = controller.displayedOrder
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard controller.displayedOrder == locked else { throw Engine.Failure.schemaUnavailable }
        let context = controller.recentContext
        _ = key("", code: 51)
        guard controller.recentContext == context else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        guard controller.frozenPrediction == nil else { throw Engine.Failure.schemaUnavailable }
        // Host document edits happen after IMK returns the navigation/delete event.
        controller.activateServer(client)
        client.exposesDocument = true
        client.committed = "😀我们需要保护环境"
        client.documentSelection = NSRange(location: ("😀我们需要保护" as NSString).length, length: 0)
        controller.requestScoring = { context, _, texts in
            guard context == "😀我们需要保护" else { throw Engine.Failure.schemaUnavailable }
            return texts.reversed().enumerated().map { .init(text: $0.element, rank: $0.offset + 1) }
        }
        _ = key("", code: 123)
        _ = key("n"); _ = key("i")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard controller.recentContext == "😀我们需要保护", controller.frozenPrediction?.isEmpty == false else { throw Engine.Failure.schemaUnavailable }
        _ = key("", code: 53)
        _ = key("", code: 51)
        client.committed = "😀我们保护环境"
        client.documentSelection = NSRange(location: ("😀我们保护" as NSString).length, length: 0)
        controller.requestScoring = { context, _, texts in
            guard context == "😀我们保护" else { throw Engine.Failure.schemaUnavailable }
            return texts.reversed().enumerated().map { .init(text: $0.element, rank: $0.offset + 1) }
        }
        _ = key("n"); _ = key("i")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard controller.recentContext == "😀我们保护", controller.frozenPrediction?.isEmpty == false else { throw Engine.Failure.schemaUnavailable }
        _ = key("", code: 53)
        client.documentSelection = NSRange(location: 0, length: 0)
        _ = key("n")
        guard controller.recentContext.isEmpty else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: candidate scoring, navigation/delete context recovery, UTF-16 caret, document start and stale rejection")
    }

    static func verifyRankingLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let saved = ["aiRerankingEnabled", "scheme"].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "aiRerankingEnabled")
        defaults.set(InputScheme.full.rawValue, forKey: "scheme")
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil),
              let engine = AppDelegate.engine else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(client)
        controller.session = try engine.session(.full)
        guard let session = controller.session else { throw Engine.Failure.schemaUnavailable }
        func key(_ text: String, code: UInt16 = 0) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                        isARepeat: false, keyCode: code)!
            return controller.handle(event, client: client)
        }
        for method in 0..<4 {
            session.clear()
            for c in "ni".utf8 { session.process(Int32(c)) }
            let original = session.candidates.texts
            guard original.count >= 3 else { throw Engine.Failure.schemaUnavailable }
            let promoted = original[2]
            session.clear()
            controller.frozenPrediction = nil
            controller.recentContext = "我们"
            controller.requestRanking = { _ in [.init(text: promoted, rank: 3)] }
            controller.scheduleRanking(client)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            guard controller.cachedPrediction == [.init(text: promoted, rank: 3)], controller.cachedPredictionDelayMS != nil, controller.continuationText == nil else { throw Engine.Failure.schemaUnavailable }
            _ = key("n"); _ = key("i")
            guard controller.displayedOrder.first == 2, controller.frozenPredictionDelayMS != nil else { throw Engine.Failure.schemaUnavailable }
            let before = client.committed
            var expected = promoted
            switch method {
            case 0: guard key(" ", code: 49) else { throw Engine.Failure.schemaUnavailable }
            case 1: guard key("1", code: 18) else { throw Engine.Failure.schemaUnavailable }
            case 2: guard controller.candidatesPanel.verifyClick(on: 0) else { throw Engine.Failure.schemaUnavailable }
            default:
                _ = key("", code: 125)
                expected = original[controller.displayedOrder[1]]
                guard key(" ", code: 49) else { throw Engine.Failure.schemaUnavailable }
            }
            guard client.committed == before + expected else { throw Engine.Failure.schemaUnavailable }
        }
        session.clear()
        controller.frozenPrediction = nil
        controller.recentContext = "我们"
        controller.requestRanking = { _ in
            try? await Task.sleep(nanoseconds: 180_000_000)
            return [.init(text: "你", rank: 1)]
        }
        controller.scheduleRanking(client)
        _ = key("n"); _ = key("i")
        let order = controller.displayedOrder
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        guard controller.displayedOrder == order, controller.frozenPrediction == [],
              controller.cachedPrediction.isEmpty else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: cached exact ranking, mapped space/digit/click/arrows, frozen order and late prediction rejection")
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
