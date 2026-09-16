import AppKit
import Carbon
import InputMethodKit
import InputCore

@objc(FeatherInputController)
final class InputController: IMKInputController {
    private var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    private func bypassSecureInput() -> Bool {
        guard secureInputEnabled() else { return false }
        cancelFocusIndicator()
        session?.clear()
        _ = session?.takeCommit()
        invalidateRecommendation(clearContext: true)
        frozenPrediction = nil
        candidatesPanel.hide()
        modeIndicator.hide()
        rightControlTap.reset()
        rightControlHeld = false
        capsLockHeld = false
        return true
    }
    private var expandedTexts: [String]?
    private var expandedCandidateIDs: [Int] = []
    private var expandedLoadedCount = 0
    private var expandedPinnedIDs: Set<Int> = []
    private var expandedIndex = 0
    private var expandedRows = 5
    private var expansionTask: Task<Void, Never>?
    private var expansionID = UUID()
    private func closeExpanded() {
        expansionTask?.cancel(); expansionTask = nil
        expansionID = UUID(); expandedTexts = nil
        expandedCandidateIDs = []; expandedPinnedIDs = []; expandedLoadedCount = 0
    }
    private func renderExpanded(_ client: IMKTextInput, loading: Bool = false) {
        guard let texts = expandedTexts, !texts.isEmpty else { return }
        let version = expansionID
        candidatesPanel.showExpanded(texts: texts, highlight: expandedIndex,
            caret: lastCaret ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20)),
            rows: expandedRows, loading: loading, clientLevel: Int(client.windowLevel())) { [weak self, weak client] index in
                guard let self, let client, self.expansionID == version, !self.bypassSecureInput() else { return }
                self.selectExpanded(index, client: client)
            }
    }
    private func selectExpanded(_ index: Int, client: IMKTextInput) {
        guard let texts = expandedTexts, texts.indices.contains(index), let session else { return }
        guard expandedCandidateIDs.indices.contains(index) else { return }
        if session.selectGlobalCandidate(at: expandedCandidateIDs[index]) {
            closeExpanded()
            refresh(client)
        }
    }
    private func appendExpanded(_ batch: [String]) {
        for (offset, text) in batch.enumerated() {
            let id = expandedLoadedCount + offset
            if !expandedPinnedIDs.contains(id) {
                expandedCandidateIDs.append(id)
                expandedTexts?.append(text)
            }
        }
        expandedLoadedCount += batch.count
    }
    private func openExpanded(_ client: IMKTextInput) {
        guard let session else { return }
        expandedRows = session.candidateCount
        invalidateRecommendation()
        closeExpanded()
        let original = session.candidates.texts
        let order = displayedOriginal == original && displayedPreedit == session.preedit.text
            ? displayedOrder : Array(original.indices)
        let pageOffset = session.candidatePageOffset
        if scoringEnabled, let submitted = frozenScoringCandidates, let scores = frozenPrediction,
           scoredPreedit == session.preedit.text, scoredOriginal == original,
           scoredContext == recentContext, scoredSettings == scoringSettings,
           scores.count == submitted.count,
           Set(scores.compactMap(\.sourceIndex)) == Set(submitted.indices),
           scores.allSatisfy({ row in row.sourceIndex.map { submitted.indices.contains($0) && submitted[$0] == row.text } ?? false }),
           session.candidateSlice(offset: pageOffset, count: submitted.count) == submitted {
            // The parsed rank is the fusion-score order; preserve IDs even for identical text.
            let ranked = scores.sorted { $0.rank < $1.rank }
            expandedCandidateIDs = ranked.map { pageOffset + $0.sourceIndex! }
            expandedTexts = ranked.map(\.text)
        } else {
            expandedCandidateIDs = order.map { pageOffset + $0 }
            expandedTexts = order.map { original[$0] }
        }
        expandedPinnedIDs = Set(expandedCandidateIDs)
        let firstBatch = session.candidateSlice(offset: 0)
        appendExpanded(firstBatch)
        guard expandedTexts?.isEmpty == false else { closeExpanded(); return }
        expandedIndex = 0
        let preedit = session.preedit.text
        let version = expansionID
        renderExpanded(client, loading: firstBatch.count == 128)
        expansionTask = Task { @MainActor [weak self, weak client] in
            while let self, let client, self.expansionID == version, self.expandedTexts != nil,
                  self.isActive, !self.bypassSecureInput(), session.preedit.text == preedit {
                do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return }
                guard self.expansionID == version, !Task.isCancelled else { return }
                let more = session.candidateSlice(offset: self.expandedLoadedCount)
                self.appendExpanded(more)
                self.renderExpanded(client, loading: more.count == 128)
                if more.count < 128 { return }
            }
        }
    }
    private var session: Session?
    private let candidatesPanel = CandidatePanel()
    private let modeIndicator = ModeIndicator()
    private var focusModeUntilInput: Bool { UserDefaults.standard.object(forKey: "focusModeUntilInput") as? Bool ?? true }
    private var focusModeDuration: TimeInterval {
        let value = UserDefaults.standard.object(forKey: "focusModeDuration") as? Double ?? 0.8
        return value.isFinite ? max(0.1, min(5.0, value)) : 0.8
    }
    private var focusIndicatorTask: Task<Void, Never>?
    private var focusIndicatorVersion = UUID()
    private func cancelFocusIndicator() {
        focusIndicatorTask?.cancel(); focusIndicatorTask = nil
        focusIndicatorVersion = UUID()
    }
    private func scheduleFocusIndicator(_ client: IMKTextInput) {
        cancelFocusIndicator()
        modeIndicator.hide()
        let version = focusIndicatorVersion
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        focusIndicatorTask = Task { @MainActor [weak self, weak client] in
            // Focus callbacks can precede the application's caret layout. Retry briefly.
            for delay in [80, 120, 200] {
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) } catch { return }
                guard let self, let client, !Task.isCancelled, self.isActive,
                      self.focusIndicatorVersion == version, !self.secureInputEnabled(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else { return }
                var caret = NSRect.zero
                let selection = client.selectedRange()
                _ = client.attributes(forCharacterIndex: selection.location == NSNotFound ? 0 : selection.location,
                                      lineHeightRectangle: &caret)
                guard caret.origin.x.isFinite, caret.origin.y.isFinite, caret.width.isFinite,
                      caret.height.isFinite, caret.height > 0 else { continue }
                self.lastCaret = caret
                self.modeIndicator.show(ascii: self.ascii, caret: caret, clientLevel: Int(client.windowLevel()), untilInput: self.focusModeUntilInput, duration: self.focusModeDuration)
                return
            }
        }
    }
    private var ascii = false
    private var recommendationTask: Task<Void, Never>?
    private var recommendationVersion = UUID()
    private var recentContext = ""
    private var rankingTask: Task<Void, Never>?
    private var rankingVersion = UUID()
    private var cachedPrediction: [LocalRecommendation.RankedToken] = []
    private var cachedPredictionDelayMS: Int?
    private var frozenScoringCandidates: [String]?
    private var frozenPredictionDelayMS: Int?
    private var frozenPrediction: [LocalRecommendation.RankedToken]? {
        didSet { if frozenPrediction == nil { frozenPredictionDelayMS = nil; frozenScoringCandidates = nil } }
    }
    private var displayedOrder: [Int] = []
    private var displayedOriginal: [String] = []
    private var displayedPreedit = ""
    private var displayedHighlight = 0
    private let generatedPanel = CandidatePanel()
    private var chooseGenerated: ((Int, IMKTextInput) -> Bool)?
    private var consumedGeneratedKey: UInt16?
    private var generationTask: Task<Void, Never>?
    private var generationEnabled: Bool { UserDefaults.standard.object(forKey: "aiPinyinGenerationEnabled") as? Bool ?? true }
    private var requestGeneration: (String, String, String) async throws -> LocalRecommendation.GeneratedCandidates = {
        try await LocalRecommendation.generateCandidates(context: $0, input: $1, scheme: $2)
    }
    private func scheduleGeneration(_ client: IMKTextInput) {
        guard generationEnabled, isActive, !ascii, !recentContext.isEmpty, expandedTexts == nil,
              let session, !session.preedit.text.isEmpty,
              session.preedit.text.utf8.allSatisfy({ (97...122).contains($0) || $0 == 32 || $0 == 39 }),
              session.preedit.cursor == session.preedit.text.utf16.count else { return }
        generationTask?.cancel()
        let version = recommendationVersion
        let context = recentContext, raw = session.rawInput, preedit = session.preedit.text
        let schema = scheme.rawValue
        let range = client.selectedRange()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let request = requestGeneration
        let debounce = scoringTiming.debounceMS
        generationTask = Task { @MainActor [weak self, weak client] in
            do {
                try await Task.sleep(nanoseconds: UInt64(debounce) * 1_000_000)
                try Task.checkCancellation()
                guard let self, let client, !self.bypassSecureInput(), self.generationEnabled,
                      self.recommendationVersion == version else { return }
                let started = DispatchTime.now().uptimeNanoseconds
                let reply = try await request(context, raw, schema)
                try Task.checkCancellation()
                guard !self.bypassSecureInput(), self.isActive, !self.ascii, self.generationEnabled,
                      self.recommendationVersion == version, self.recentContext == context,
                      self.scheme.rawValue == schema, session.rawInput == raw, session.preedit.text == preedit,
                      self.expandedTexts == nil, NSEqualRanges(client.selectedRange(), range),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else { return }
                let delay = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                let existing = Set(session.candidates.texts + (self.frozenScoringCandidates ?? []))
                let suggestions = reply.candidates.map(\.text).filter { !existing.contains($0) }
                CandidateDebugWindow.shared.updateGeneration(input: raw, result: reply, delay: delay)
                guard !suggestions.isEmpty else { return }
                self.chooseGenerated = { [weak self, weak client] index, target in
                    guard let self, let client, target === client, !self.bypassSecureInput(), self.isActive, !self.ascii,
                          self.generatedPanel.isVisible, self.generationEnabled, self.recommendationVersion == version,
                          suggestions.indices.contains(index), session.rawInput == raw,
                          session.preedit.text == preedit, self.recentContext == context,
                          self.scheme.rawValue == schema, NSEqualRanges(client.selectedRange(), range),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else { return false }
                    // Generation covers the entire raw composition. Never use a Rime candidate ID.
                    let text = suggestions[index]
                    session.clear()
                    _ = session.takeCommit()
                    self.invalidateRecommendation()
                    self.frozenPrediction = nil
                    self.scoredPreedit = ""; self.scoredOriginal = []; self.scoredContext = ""
                    self.scoringLockedPreedit = ""; self.scoringLockedOriginal = []
                    self.recentContext = String((context + text).suffix(80))
                    client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    self.refresh(client)
                    return true
                }
                self.generatedPanel.show(texts: suggestions, highlight: -1,
                    caret: self.lastCaret ?? self.candidatesPanel.frame, clientLevel: Int(client.windowLevel()),
                    beside: self.candidatesPanel.companionAnchor, continuation: true, optionNumbers: true) { [weak self, weak client] index in
                        guard let client else { return }
                        _ = self?.chooseGenerated?(index, client)
                    }
            } catch { /* Optional suggestions never block ordinary input. */ }
        }
    }
    private var scoringEnabled: Bool { UserDefaults.standard.bool(forKey: "aiCandidateScoringEnabled") }
    private var scoredPreedit = ""
    private var scoredOriginal: [String] = []
    private var scoredContext = ""
    private var scoredSettings = ""
    private var scoringCandidateCount: Int { ScoringCandidateLimit.count(pageCount: session?.candidateCount ?? 5) }
    private var scoringTiming: ScoringTiming { ScoringTiming() }
    private var scoringSettings: String { "\(UserDefaults.standard.object(forKey: "aiFusionWeight") as? Double ?? 0.35)|\(UserDefaults.standard.string(forKey: "aiScoreNormalization") ?? "character")|\(scoringTiming.debounceMS)|\(scoringTiming.responseLimitMS)|\(scoringCandidateCount)" }
    private var scoringLockedPreedit = ""
    private var scoringLockedOriginal: [String] = []
    private var requestScoring: (String, String, [String]) async throws -> [LocalRecommendation.RankedToken] = {
        try await LocalRecommendation.scoreCandidates(context: $0, preedit: $1, candidates: $2)
    }
    private func scheduleScoring(_ client: IMKTextInput, preedit: String, candidates: [String]) {
        guard scoringEnabled, isActive, !ascii, !recentContext.isEmpty, !candidates.isEmpty,
              scoredPreedit != preedit || scoredOriginal != candidates || scoredContext != recentContext || scoredSettings != scoringSettings else { return }
        guard scoringLockedPreedit != preedit || scoringLockedOriginal != candidates else { return }
        let settings = scoringSettings
        let timing = scoringTiming
        let candidateLimit = scoringCandidateCount
        let pageOffset = session?.candidatePageOffset ?? 0
        let version = recommendationVersion
        let context = recentContext
        let range = client.selectedRange()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let request = requestScoring
        recommendationTask = Task { @MainActor [weak self, weak client] in
            defer {
                if let self, let client, self.recommendationVersion == version, !Task.isCancelled { self.scheduleGeneration(client) }
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(timing.debounceMS) * 1_000_000)
                try Task.checkCancellation()
                let started = DispatchTime.now().uptimeNanoseconds
                guard let live = self, !live.bypassSecureInput(), live.recommendationVersion == version,
                      live.scoringSettings == settings, live.session?.preedit.text == preedit,
                      live.session?.candidates.texts == candidates else { return }
                let submitted = live.session?.candidateSlice(offset: pageOffset, count: candidateLimit) ?? []
                guard !submitted.isEmpty else { return }
                let result = try await request(context, preedit, submitted)
                let delay = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                try Task.checkCancellation()
                guard let self, let client, !self.bypassSecureInput(), self.isActive, !self.ascii, self.scoringEnabled,
                      self.recommendationVersion == version, self.recentContext == context, self.scoringSettings == settings,
                      self.session?.preedit.text == preedit, self.session?.candidates.texts == candidates,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                      NSEqualRanges(client.selectedRange(), range), delay <= timing.responseLimitMS else { return }
                self.scoredPreedit = preedit
                self.scoredOriginal = candidates
                self.scoredContext = context
                self.scoredSettings = settings
                self.frozenPrediction = result
                self.frozenScoringCandidates = submitted
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
        let continuationBackend = UserDefaults.standard.string(forKey: "aiContinuationBackend")
        let continuationModel = UserDefaults.standard.string(forKey: "aiModel")
        let continuationVersion = recommendationVersion
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
                guard continuationBackend == "mlx", UserDefaults.standard.bool(forKey: "aiContinuationEnabled") else { return }
                let remainingDelayMS = max(0, 400 - delayMS)
                if remainingDelayMS > 0 {
                    try await Task.sleep(nanoseconds: UInt64(remainingDelayMS) * 1_000_000)
                }
                try Task.checkCancellation()
                self.presentContinuation(tokens.map(\.text), client: client, context: context,
                    version: continuationVersion, range: range, foreground: foreground,
                    savedModel: continuationModel, backend: continuationBackend, candidateCount: count)
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
    private func presentContinuation(_ texts: [String], client: IMKTextInput, context: String, version: UUID,
                                     range: NSRange, foreground: pid_t?, savedModel: String?, backend: String?,
                                     candidateCount: Int) {
        guard let text = texts.first, !bypassSecureInput(), isActive, !ascii,
              recommendationVersion == version, recentContext == context,
              session?.preedit.text.isEmpty == true,
              UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
              UserDefaults.standard.string(forKey: "aiModel") == savedModel,
              UserDefaults.standard.string(forKey: "aiContinuationBackend") == backend,
              (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == candidateCount,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
              NSEqualRanges(client.selectedRange(), range) else { return }
        var caret = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        let anchor = caret.height > 0 && caret.origin.x.isFinite && caret.origin.y.isFinite ? caret : lastCaret
        guard let anchor else { return }
        continuationText = text
        candidatesPanel.show(texts: texts, highlight: -1, caret: anchor,
            clientLevel: Int(client.windowLevel()), continuation: true) { [weak self, weak client] index in
                guard let self, let client, !self.bypassSecureInput(), self.isActive, !self.ascii,
                      self.recommendationVersion == version, self.continuationText == text,
                      self.session?.preedit.text.isEmpty == true,
                      UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
                      UserDefaults.standard.string(forKey: "aiModel") == savedModel,
                      UserDefaults.standard.string(forKey: "aiContinuationBackend") == backend,
                      (UserDefaults.standard.object(forKey: "aiCandidateCount") as? Int ?? 5) == candidateCount,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                      NSEqualRanges(client.selectedRange(), range), texts.indices.contains(index) else { return }
                let selected = texts[index]
                self.invalidateRecommendation()
                client.insertText(selected, replacementRange: NSRange(location: NSNotFound, length: 0))
                self.recentContext = String((context + selected).suffix(80))
            }
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
        generationTask?.cancel(); generationTask = nil
        generatedPanel.hide(); chooseGenerated = nil
        Task { @MainActor in CandidateDebugWindow.shared.clearGeneration() }
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
    deinit { focusIndicatorTask?.cancel(); generationTask?.cancel(); recommendationTask?.cancel(); rankingTask?.cancel(); expansionTask?.cancel() }
    private var rightControlTap = RightControlTap()
    private var capsLockSwitch = CapsLockSwitch()
    private var rightControlHeld = false
    private var capsLockHeld = false
    private var isActive = false
    private var lastCaret: NSRect?
    private var activeScheme: InputScheme?
    private var activeApplication = "unknown"
    private var scheme: InputScheme {
        InputScheme(rawValue: UserDefaults.standard.string(forKey: "scheme") ?? "") ?? .full
    }
    override func activateServer(_ sender: Any!) {
        invalidateRecommendation(clearContext: true)
        rightControlTap.reset()
        rightControlHeld = false
        capsLockHeld = false
        capsLockSwitch.reset(isLocked: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift))
        isActive = true
        frozenPrediction = nil
        lastCaret = nil
        if let client = sender as? IMKTextInput {
            activeApplication = client.bundleIdentifier() ??
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        } else {
            activeApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        }
        ascii = InputModeMemory.shared.activate(application: activeApplication)
        if session == nil { session = try? AppDelegate.engine?.session(scheme) }
        session?.setCandidateCount(UserDefaults.standard.object(forKey: "candidateCount") as? Int ?? 5)
        session?.setEnglishCandidateMinimum(UserDefaults.standard.object(forKey: "englishCandidateMinimum") as? Int ?? 3)
        session?.select(scheme)
        activeScheme = scheme
        session?.setASCII(ascii)
        PersistentModeIndicator.shared.update(ascii: ascii)
        if let client = sender as? IMKTextInput { scheduleFocusIndicator(client) }
    }
    override func deactivateServer(_ sender: Any!) {
        cancelFocusIndicator()
        invalidateRecommendation(clearContext: true)
        isActive = false
        modeIndicator.hide()
        rightControlTap.reset()
        rightControlHeld = false
        capsLockHeld = false
        commitComposition(sender)
        candidatesPanel.hide()
    }
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]).rawValue)
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard !bypassSecureInput() else { return false }
        guard let event, let client = sender as? IMKTextInput else { return false }
        // Some applications activate an input source for key handling even when
        // the focused view is not text-editable. Do not start a Rime composition
        // in that case; IMK reports this with an unavailable selection range.
        if event.type == .keyDown, event.keyCode == 53 {
            guard session?.preedit.text.isEmpty == false else { return false }
            session?.clear()
            _ = session?.takeCommit()
            invalidateRecommendation(clearContext: true)
            candidatesPanel.hide()
            generatedPanel.hide()
            modeIndicator.hide()
            return true
        }
        if event.type == .keyDown, !textInputAvailable(client),
           event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty,
           event.keyCode != 53 {
            invalidateRecommendation(clearContext: true)
            candidatesPanel.hide()
            generatedPanel.hide()
            return false
        }
        if event.type == .keyDown || event.type == .flagsChanged {
            cancelFocusIndicator()
            if event.type == .keyDown { modeIndicator.hide() }
        }
        let shortcutFlags = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
        let finishedGeneratedShortcut = consumedGeneratedKey != nil && event.type == .flagsChanged &&
            [UInt16(58), 61].contains(event.keyCode) && shortcutFlags.isEmpty
        if shortcutFlags != .option { consumedGeneratedKey = nil }
        if finishedGeneratedShortcut {
            rightControlTap.cancel()
            return false
        }
        if event.type == .keyDown, shortcutFlags == .option {
            if event.isARepeat, consumedGeneratedKey == event.keyCode { return true }
            consumedGeneratedKey = nil
            if generatedPanel.isVisible, let index = [UInt16(18): 0, 19: 1, 20: 2, 83: 0, 84: 1, 85: 2][event.keyCode] {
                _ = chooseGenerated?(index, client)
                consumedGeneratedKey = event.keyCode
                rightControlTap.cancel()
                return true
            }
        }
        // Pressing/releasing Option alone must preserve the suggestions until the digit arrives.
        if event.type == .flagsChanged, [UInt16(58), 61].contains(event.keyCode),
           generatedPanel.isVisible, shortcutFlags == .option || shortcutFlags.isEmpty {
            rightControlTap.cancel()
            return false
        }
        if [.leftMouseDown, .rightMouseDown, .scrollWheel].contains(event.type), generatedPanel.contains(NSEvent.mouseLocation) { return false }
        if expandedTexts != nil, [.leftMouseDown, .rightMouseDown, .scrollWheel].contains(event.type), candidatesPanel.contains(NSEvent.mouseLocation) { return false }
        if event.type == .leftMouseDown, continuationText != nil, candidatesPanel.contains(NSEvent.mouseLocation) { return false }
        session?.setCandidateCount(UserDefaults.standard.object(forKey: "candidateCount") as? Int ?? 5)
        session?.setEnglishCandidateMinimum(UserDefaults.standard.object(forKey: "englishCandidateMinimum") as? Int ?? 3)
        let composing = session?.preedit.text.isEmpty == false
        let clearsComposition = event.type == .keyDown && composing && event.keyCode == 13 &&
            shortcutFlags.contains(.control) && shortcutFlags.intersection([.command, .option]).isEmpty
        if clearsComposition {
            rightControlTap.cancel()
            session?.clear()
            _ = session?.takeCommit()
            frozenPrediction = nil
            invalidateRecommendation(clearContext: true)
            candidatesPanel.hide()
            generatedPanel.hide()
            refresh(client, allowScoring: false)
            return true
        }
        let expandedNavigation = expandedTexts != nil &&
            (event.type == .flagsChanged || [UInt16(4), 37, 38, 40].contains(event.keyCode))
        let changesPosition = !expandedNavigation && (event.type != .keyDown || event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false || (!composing && [51, 117, 123, 124, 125, 126, 115, 119, 36, 48].contains(event.keyCode)))
        invalidateRecommendation(clearContext: changesPosition)
        if event.type == .flagsChanged {
            if event.keyCode == 62 {
                rightControlHeld = event.modifierFlags.contains(.control) ||
                    event.modifierFlags.rawValue & RightControlTap.rightControl != 0
                if composing { rightControlTap.cancel(); return true }
            }
            if event.keyCode == 57 || event.keyCode == 0 {
                capsLockHeld = event.modifierFlags.contains(.capsLock)
                if composing { rightControlTap.cancel(); return true }
            }
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
        if !modeIndicator.waitsForInput { modeIndicator.hide() }
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
        // The expanded panel is a keyboard navigation surface.  IMK can
        // deliver a keyDown from a held right-Control chord without the
        // modifier bit (and Ctrl-H may arrive as a control character), so
        // use the physical keyCode while the panel is visible.  This also
        // keeps navigation reliable after releasing and pressing Control
        // again.
        if let texts = expandedTexts {
            let expandedVimKey: Int32? = switch event.keyCode {
            case 4: 0xff51  // h / left
            case 38: 0xff54 // j / down
            case 40: 0xff52 // k / up
            case 37: 0xff53 // l / right
            default: nil
            }
            if let expandedVimKey {
                expandedIndex = CandidateGrid.move(index: expandedIndex, count: texts.count, rows: expandedRows,
                    horizontal: expandedVimKey == 0xff51 ? -1 : expandedVimKey == 0xff53 ? 1 : 0,
                    vertical: expandedVimKey == 0xff52 ? -1 : expandedVimKey == 0xff54 ? 1 : 0)
                renderExpanded(client)
                return true
            }
        }
        let vimModifierDown = rightControlHeld || capsLockHeld ||
            flags.contains(.capsLock) ||
            event.modifierFlags.rawValue & RightControlTap.rightControl != 0 ||
            // Once the expanded grid owns navigation, some keyboard paths
            // report only the aggregate Control flag (without the side bit
            // or a preceding flagsChanged event). Keep physical h/j/k/l
            // usable in that state instead of translating Ctrl-H to delete.
            (expandedTexts != nil && flags.contains(.control))
        if composing, vimModifierDown {
            // Control changes NSEvent.characters (Ctrl-H is backspace, Ctrl-J
            // is newline, etc.), so use the physical macOS keyCode as the
            // fallback. This is also what lets right-Control + h work in Kitty.
            let character = event.characters?.lowercased()
            let vimKey: Int32? = switch event.keyCode {
            case 4: 0xff51  // h / left
            case 38: 0xff54 // j / down
            case 40: 0xff52 // k / up
            case 37: 0xff53 // l / right
            default: switch character {
            case "h": 0xff51 // left
            case "j": 0xff54 // down
            case "k": 0xff52 // up
            case "l": 0xff53 // right
            default: nil
            }
            }
            if let vimKey {
                if let texts = expandedTexts {
                    expandedIndex = CandidateGrid.move(index: expandedIndex, count: texts.count, rows: expandedRows,
                        horizontal: vimKey == 0xff51 ? -1 : vimKey == 0xff53 ? 1 : 0,
                        vertical: vimKey == 0xff52 ? -1 : vimKey == 0xff54 ? 1 : 0)
                    renderExpanded(client)
                } else if vimKey == 0xff51 || vimKey == 0xff53 {
                    // In the ordinary candidate list, h/l are the Vim-style
                    // command to open the full candidate grid. Once expanded,
                    // they are handled above as horizontal column movement.
                    openExpanded(client)
                } else {
                    _ = session.process(vimKey)
                    refresh(client, allowScoring: false)
                }
                return true
            }
        }
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
        if !ascii, candidatesPanel.isVisible, let symbol = characters,
           RawSymbolCommit.shouldCommit(rawInput: session.rawInput, symbol: symbol) {
            let text = session.rawInput + symbol
            session.clear()
            _ = session.takeCommit()
            invalidateRecommendation()
            frozenPrediction = nil
            scoredPreedit = ""; scoredOriginal = []; scoredContext = ""
            scoringLockedPreedit = ""; scoringLockedOriginal = []
            recentContext = String((recentContext + text).suffix(80))
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            refresh(client)
            return true
        }
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
        if !ascii, !session.preedit.text.isEmpty, !session.candidates.texts.isEmpty, key == 0xff53 {
            openExpanded(client)
            return true
        }
        if !ascii, !session.preedit.text.isEmpty, !session.candidates.texts.isEmpty, key == 0xff51 { key = 0xff55 }
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

    private func textInputAvailable(_ client: IMKTextInput) -> Bool {
        let range = client.selectedRange()
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return false }
        return client.supportsUnicode()
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
        let composition = preedit.text.isEmpty ? session.rawInput : preedit.text
        guard !composition.isEmpty else {
            candidatesPanel.hide()
            displayedOrder = []
            if preedit.text.isEmpty {
                frozenPrediction = nil
                if let committed, !committed.isEmpty {
                    if !scoringEnabled && rankingEnabled { scheduleRanking(client) }
                    let backend = UserDefaults.standard.string(forKey: "aiContinuationBackend")
                    if UserDefaults.standard.bool(forKey: "aiContinuationEnabled"),
                       !(!scoringEnabled && rankingEnabled && backend == "mlx") {
                        scheduleContinuation(client)
                    }
                }
            }
            return
        }
        var caret = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0 { lastCaret = caret }
        let anchor = lastCaret ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
        if candidates.texts.isEmpty {
            frozenPrediction = nil
            scoredPreedit = ""; scoredOriginal = []; scoredContext = ""
            displayedOrder = []; displayedOriginal = []; displayedPreedit = preedit.text
            candidatesPanel.show(texts: [], highlight: -1, composition: composition,
                cursor: preedit.text.isEmpty ? composition.utf16.count : preedit.cursor,
                caret: anchor, clientLevel: Int(client.windowLevel()))
            Task { @MainActor in
                CandidateDebugWindow.shared.update(preedit: composition, rime: [], predictions: [], final: [], scoring: false, delay: nil)
            }
            return
        }
        if scoringEnabled && (scoredPreedit != preedit.text || scoredOriginal != candidates.texts || scoredContext != recentContext || scoredSettings != scoringSettings) {
            frozenPrediction = nil
        }
        let order = CandidateRanking.order(candidates.texts, predictions: (frozenPrediction ?? []).map(\.text))
        if displayedOriginal != candidates.texts || displayedPreedit != preedit.text { displayedHighlight = 0 }
        displayedOriginal = candidates.texts
        displayedPreedit = preedit.text
        displayedOrder = order
        Task { @MainActor [predictions = frozenPrediction ?? [], scoring = scoringEnabled, delay = frozenPredictionDelayMS, submitted = frozenScoringCandidates] in
            CandidateDebugWindow.shared.update(preedit: preedit.text, rime: submitted ?? candidates.texts,
                predictions: predictions, final: order.map { candidates.texts[$0] }, scoring: scoring, delay: delay)
        }
        let reordered = order != Array(candidates.texts.indices)
        candidatesPanel.show(texts: order.map { candidates.texts[$0] },
                             highlight: reordered ? displayedHighlight : candidates.highlight, composition: composition, cursor: preedit.cursor, caret: anchor, clientLevel: Int(client.windowLevel()),
                             llmTokens: frozenPrediction ?? [], llmDelayMS: frozenPredictionDelayMS, llmTitle: scoringEnabled ? "Rime + LLM · 融合排序" : "LLM top-k · 本轮预测") { [weak self, weak client] index in
            guard let self, !self.bypassSecureInput(), self.isActive, let client, let session = self.session,
                  session.preedit.text == preedit.text, session.candidates.texts == candidates.texts,
                  self.displayedOrder == order else { return }
            self.rightControlTap.cancel()
            _ = self.selectDisplayed(index, client: client)
        }
        if scoringEnabled {
            if allowScoring { scheduleScoring(client, preedit: preedit.text, candidates: candidates.texts) }
            else { scheduleGeneration(client) }
        } else if !rankingEnabled && frozenPrediction?.isEmpty != false {
            scheduleRecommendation(preedit: preedit.text, texts: candidates.texts)
        }
        if !scoringEnabled { scheduleGeneration(client) }
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
                try Task.checkCancellation()
                guard let self, let client else { return }
                self.presentContinuation(texts, client: client, context: context, version: version,
                    range: range, foreground: foreground, savedModel: savedModel,
                    backend: backend, candidateCount: candidateCount)
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
        let keepFocusIndicator = modeIndicator.isVisible && modeIndicator.waitsForInput && focusModeUntilInput
        cancelFocusIndicator()
        invalidateRecommendation(clearContext: true)
        let target = commandClient(sender)
        commitComposition(target)
        ascii.toggle()
        InputModeMemory.shared.update(ascii: ascii, application: activeApplication)
        session?.setASCII(ascii)
        PersistentModeIndicator.shared.update(ascii: ascii)
        guard let textClient = target as? IMKTextInput else { modeIndicator.hide(); return }
        var caret = NSRect.zero
        _ = textClient.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        if caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 0, caret.height.isFinite {
            lastCaret = caret
        }
        guard let anchor = lastCaret else { modeIndicator.hide(); return }
        modeIndicator.show(ascii: ascii, caret: anchor, clientLevel: Int(textClient.windowLevel()), untilInput: keepFocusIndicator)
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
            controller.frozenPrediction = first.reversed().enumerated().map { .init(text: $0.element, rank: $0.offset + 1) }
            controller.refresh(client, allowScoring: false)
            key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            guard let all = controller.expandedTexts, all.count > 16,
                  Array(all.prefix(7)) == Array(first.reversed()),
                  Array(controller.expandedCandidateIDs.prefix(7)) == Array((0..<7).reversed()),
                  Set(controller.expandedCandidateIDs).count == controller.expandedCandidateIDs.count else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
            guard controller.expandedRows == 7, controller.expandedIndex == 7 else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
            guard controller.expandedIndex == 8 else { throw Engine.Failure.schemaUnavailable }
            key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
            guard controller.expandedIndex == 1 else { throw Engine.Failure.schemaUnavailable }
            // Verify the physical Ctrl-H/L path after the grid is already
            // open.  The modifier may arrive without the right-side flag on
            // the second press, so this must still move across columns.
            let controlDown = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .control,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 62)!
            let controlUp = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 62)!
            let ctrlL = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "\u{0c}", charactersIgnoringModifiers: "l",
                isARepeat: false, keyCode: 37)!
            _ = controller.handle(controlDown, client: client)
            _ = controller.handle(ctrlL, client: client)
            _ = controller.handle(controlUp, client: client)
            guard controller.expandedIndex == 8 else { throw Engine.Failure.schemaUnavailable }
            let plainH = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "\u{08}", charactersIgnoringModifiers: "h",
                isARepeat: false, keyCode: 4)!
            _ = controller.handle(plainH, client: client)
            guard controller.expandedIndex == 1 else { throw Engine.Failure.schemaUnavailable }
            let expected = all[2]
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

    static func verifyControlW(server: IMKServer) throws {
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else {
            throw Engine.Failure.schemaUnavailable
        }
        controller.activateServer(client)
        guard let session = controller.session else { throw Engine.Failure.schemaUnavailable }
        for key in "nihao".utf8 { session.process(Int32(key)) }
        controller.refresh(client)
        guard !session.preedit.text.isEmpty, !client.marked.isEmpty else { throw Engine.Failure.schemaUnavailable }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{17}", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13)!
        guard controller.handle(event, client: client), session.preedit.text.isEmpty, session.rawInput.isEmpty,
              client.marked.isEmpty, client.committed.isEmpty,
              !controller.candidatesPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
        guard !controller.handle(event, client: client), client.committed.isEmpty else {
            throw Engine.Failure.schemaUnavailable
        }
        controller.deactivateServer(client)
        print("PASS: Ctrl-W clears active pinyin without reaching the host and passes through when idle")
    }

    static func verifyRawSymbolCommit(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let keys = ["scheme", "englishCandidateMinimum", "aiCandidateScoringEnabled",
                    "aiRerankingEnabled", "aiRecommendationEnabled", "aiPinyinGenerationEnabled"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(5, forKey: "englishCandidateMinimum")
        for key in ["aiCandidateScoringEnabled", "aiRerankingEnabled", "aiRecommendationEnabled", "aiPinyinGenerationEnabled"] {
            defaults.set(false, forKey: key)
        }
        for mode in InputScheme.allCases {
            defaults.set(mode.rawValue, forKey: "scheme")
            let client = SmokeTextClient()
            guard let controller = InputController(server: server, delegate: nil, client: nil) else {
                throw Engine.Failure.schemaUnavailable
            }
            controller.secureInputEnabled = { false }
            controller.activateServer(client)
            func key(_ text: String, flags: NSEvent.ModifierFlags = []) -> Bool {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
                return controller.handle(event, client: client)
            }
            for (symbol, flags) in [(".", NSEvent.ModifierFlags()), ("@", .shift),
                                    ("/", NSEvent.ModifierFlags()), ("-", NSEvent.ModifierFlags())] {
                for character in "github" { _ = key(String(character)) }
                guard controller.candidatesPanel.isVisible,
                      controller.session?.candidates.texts.contains("GitHub") == true,
                      key(symbol, flags: flags), client.committed.hasSuffix("github" + symbol),
                      controller.session?.rawInput.isEmpty == true,
                      !controller.candidatesPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
            }
            controller.deactivateServer(client)
        }
        defaults.set(InputScheme.full.rawValue, forKey: "scheme")
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else {
            throw Engine.Failure.schemaUnavailable
        }
        controller.secureInputEnabled = { false }
        controller.activateServer(client)
        func chineseKey(_ text: String) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: 0)!
            return controller.handle(event, client: client)
        }
        _ = chineseKey("n"); _ = chineseKey("i")
        guard controller.session?.candidates.texts.isEmpty == false,
              chineseKey(","), client.committed == "ni," else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: symbols commit raw letter input for English and Chinese compositions in full/Flypy")
    }

    static func verifyFocusIndicator(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "focusModeUntilInput")
        let savedDuration = defaults.object(forKey: "focusModeDuration")
        defer {
            if let saved { defaults.set(saved, forKey: "focusModeUntilInput") } else { defaults.removeObject(forKey: "focusModeUntilInput") }
            if let savedDuration { defaults.set(savedDuration, forKey: "focusModeDuration") } else { defaults.removeObject(forKey: "focusModeDuration") }
        }
        defaults.set(false, forKey: "focusModeUntilInput")
        defaults.set(0.2, forKey: "focusModeDuration")
        let client = SmokeTextClient()
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.secureInputEnabled = { false }
        controller.activateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.14))
        guard controller.modeIndicator.isVisible, controller.modeIndicator.text == "中文" else { throw Engine.Failure.schemaUnavailable }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard !controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        InputModeMemory.shared.update(ascii: true, application: client.bundleIdentifier() ?? "unknown")
        client.caretRectangle = .zero
        controller.activateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard !controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        client.caretRectangle = NSRect(x: 400, y: 500, width: 1, height: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard controller.modeIndicator.isVisible, controller.modeIndicator.text == "英文" else { throw Engine.Failure.schemaUnavailable }
        defaults.set(true, forKey: "focusModeUntilInput")
        controller.activateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        guard controller.modeIndicator.isVisible, controller.modeIndicator.waitsForInput else { throw Engine.Failure.schemaUnavailable }
        controller.toggleASCII([kIMKCommandClientName as String: client])
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))
        guard controller.modeIndicator.isVisible, controller.modeIndicator.text == "中文" else { throw Engine.Failure.schemaUnavailable }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        _ = controller.handle(event, client: client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard !controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        controller.activateServer(client)
        controller.deactivateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard !controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        controller.secureInputEnabled = { true }
        controller.activateServer(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard !controller.modeIndicator.isVisible else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: focus duration preference, persistent mode updates, caret retry, typing/deactivation cancellation and secure suppression")
    }
    static func verifyCompositionFallback(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "scheme")
        defer { if let saved { defaults.set(saved, forKey: "scheme") } else { defaults.removeObject(forKey: "scheme") } }
        // These deliberately absent strings exercise raw fallback without
        // colliding with either the Chinese schemas or English completion.
        for (scheme, raw) in [(InputScheme.full, "vvqzxx"), (.flypy, "qzvvxx"), (.flypy, "qzvvxy")] {
            defaults.set(scheme.rawValue, forKey: "scheme")
            let client = SmokeTextClient()
            client.ignoresMarkedText = true
            guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
            controller.secureInputEnabled = { false }
            controller.activateServer(client)
            func key(_ text: String, code: UInt16 = 0) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: code)!
                _ = controller.handle(event, client: client)
            }
            for c in raw { key(String(c)) }
            guard controller.session?.candidates.texts.isEmpty == true, client.marked.isEmpty,
                  controller.candidatesPanel.isVisible, controller.candidatesPanel.compositionText == controller.session?.preedit.text,
                  !controller.candidatesPanel.verifyClick(on: 0) else { throw Engine.Failure.schemaUnavailable }
            key("\r", code: 36)
            guard client.committed == raw, !controller.candidatesPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
            for c in raw { key(String(c)) }
            key("", code: 51)
            guard controller.session?.rawInput == String(raw.dropLast()),
                  controller.candidatesPanel.compositionText == controller.session?.preedit.text else { throw Engine.Failure.schemaUnavailable }
            key("", code: 53)
            guard client.committed == raw, !controller.candidatesPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
            // With ordinary candidates, the input line is still visible in non-inline clients.
            for c in "ni" { key(String(c)) }
            guard controller.session?.candidates.texts.isEmpty == false, controller.candidatesPanel.isVisible,
                  !controller.candidatesPanel.compositionText.isEmpty, client.marked.isEmpty else { throw Engine.Failure.schemaUnavailable }
            controller.secureInputEnabled = { true }
            key("a")
            guard !controller.candidatesPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
            controller.deactivateServer(client)
        }
        print("PASS: non-inline clients show composition with/without candidates; Return, Backspace, Escape and secure hiding")
    }

    static func verifyNoTextField(server: IMKServer) throws {
        let client = SmokeTextClient()
        client.textInputUnavailable = true
        guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
        controller.secureInputEnabled = { false }
        controller.activateServer(client)
        func key(_ text: String, code: UInt16 = 0) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: code)!
            _ = controller.handle(event, client: client)
        }
        for c in "abc" { key(String(c)) }
        guard client.committed.isEmpty, client.marked.isEmpty,
              controller.session?.preedit.text.isEmpty == true,
              !controller.candidatesPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: non-text clients do not open composition; Escape and candidate windows remain app-owned")
    }
    static func verifyGenerationLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let keys = ["aiPinyinGenerationEnabled", "aiCandidateScoringEnabled", "aiRerankingEnabled", "aiRecommendationEnabled", "scheme"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.set(true, forKey: "aiPinyinGenerationEnabled")
        defaults.set(false, forKey: "aiCandidateScoringEnabled")
        defaults.set(false, forKey: "aiRerankingEnabled")
        defaults.set(false, forKey: "aiRecommendationEnabled")
        for mode in InputScheme.allCases {
            defaults.set(mode.rawValue, forKey: "scheme")
            defaults.set(mode == .flypy, forKey: "aiCandidateScoringEnabled")
            let client = SmokeTextClient()
            guard let controller = InputController(server: server, delegate: nil, client: nil) else { throw Engine.Failure.schemaUnavailable }
            controller.secureInputEnabled = { false }
            controller.activateServer(client)
            controller.recentContext = "落霞与"
            controller.requestScoring = { _, _, texts in texts.enumerated().map { .init(text: $0.element, rank: $0.offset + 1, sourceIndex: $0.offset) } }
            var receivedInput = ""
            controller.requestGeneration = { context, raw, schema in
                guard context == "落霞与", schema == mode.rawValue else { throw Engine.Failure.schemaUnavailable }
                receivedInput = raw
                try? await Task.sleep(nanoseconds: 50_000_000)
                return try LocalRecommendation.parseGenerated(Data("{\"candidates\":[{\"text\":\"菰鹜\",\"score\":-1},{\"text\":\"罛鹜\",\"score\":-2},{\"text\":\"蓇鹜\",\"score\":-3}],\"syllables\":[[\"gu\",\"wu\"]],\"elapsed_ms\":20,\"truncated\":false}".utf8))
            }
            func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], repeating: Bool = false) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: repeating, keyCode: code)!
                _ = controller.handle(event, client: client)
            }
            for c in "guwu" { key(String(c)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard receivedInput == "guwu", controller.generatedPanel.isVisible, controller.generatedPanel.verifyClick(on: 0), client.committed == "菰鹜",
                  client.marked.isEmpty, controller.session?.rawInput.isEmpty == true else { throw Engine.Failure.schemaUnavailable }
            func option(_ pressed: Bool) {
                let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: pressed ? .option : [], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
                _ = controller.handle(event, client: client)
            }
            for (code, expected) in [(UInt16(18), "菰鹜"), (UInt16(19), "罛鹜"), (UInt16(20), "蓇鹜")] {
                controller.recentContext = "落霞与"
                for c in "guwu" { key(String(c)) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                option(true)
                guard controller.generatedPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
                let before = client.committed
                key("™", code: code, flags: .option)
                guard client.committed == before + expected, client.marked.isEmpty,
                      !controller.generatedPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
                key("™", code: code, flags: .option, repeating: true)
                guard client.committed == before + expected else { throw Engine.Failure.schemaUnavailable }
                option(false)
                guard controller.recentContext == "落霞与" + expected else { throw Engine.Failure.schemaUnavailable }
            }
            let beforeCancellation = client.committed
            controller.recentContext = "落霞与"
            for c in "guwu" { key(String(c)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.14))
            key("", code: 51)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            _ = controller.generatedPanel.verifyClick(on: 0)
            guard !controller.generatedPanel.isVisible, client.committed == beforeCancellation else { throw Engine.Failure.schemaUnavailable }
            controller.secureInputEnabled = { true }
            key("a")
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            guard !controller.generatedPanel.isVisible else { throw Engine.Failure.schemaUnavailable }
            controller.deactivateServer(client)
        }
        print("PASS: full/Flypy raw-input generation, click/Option 1–3 commit generated text, modifier press preserved, repeats and stale/secure replies rejected")
    }
    static func verifyScoringLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let saved = ["aiCandidateScoringEnabled", "scheme", "debugScoringTimingEnabled", "debugScoringCandidateLimitEnabled", "debugScoringCandidateLimit"].map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: "debugScoringCandidateLimitEnabled")
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
        defaults.set(true, forKey: "debugScoringCandidateLimitEnabled")
        defaults.set(20, forKey: "debugScoringCandidateLimit")
        client.exposesDocument = false
        client.documentSelection = nil
        controller.activateServer(client)
        controller.recentContext = "我们"
        controller.requestScoring = { _, _, texts in
            guard texts.count == 20 else { throw Engine.Failure.schemaUnavailable }
            return texts.reversed().enumerated().map { .init(text: $0.element, rank: $0.offset + 1, fusionScore: -Double($0.offset + 1), sourceIndex: texts.count - $0.offset - 1) }
        }
        _ = key("n"); _ = key("i")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard controller.frozenScoringCandidates?.count == 20,
              controller.displayedOrder.count == controller.session?.candidateCount else { throw Engine.Failure.schemaUnavailable }
        let submitted = controller.frozenScoringCandidates!
        let beforeExpandedCommit = client.committed
        _ = key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        guard Array((controller.expandedTexts ?? []).prefix(20)) == Array(submitted.reversed()),
              Array(controller.expandedCandidateIDs.prefix(20)) == Array((0..<20).reversed()),
              Set(controller.expandedCandidateIDs).count == controller.expandedCandidateIDs.count else { throw Engine.Failure.schemaUnavailable }
        _ = key("1", code: 18)
        guard client.committed == beforeExpandedCommit + submitted.last! else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: candidate scoring, expanded 20-candidate fusion order and original-index numeric selection")
    }

    static func verifyRankingLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let keys = ["aiRerankingEnabled", "aiCandidateScoringEnabled", "aiContinuationEnabled",
                    "aiContinuationBackend", "aiCandidateCount", "scheme"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "aiRerankingEnabled")
        defaults.set(false, forKey: "aiCandidateScoringEnabled")
        defaults.set(true, forKey: "aiContinuationEnabled")
        defaults.set("mlx", forKey: "aiContinuationBackend")
        defaults.set(5, forKey: "aiCandidateCount")
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
        session.clear()
        controller.frozenPrediction = nil
        controller.recentContext = "我们"
        controller.requestRanking = { _ in [.init(text: "继续", rank: 1), .init(text: "完成", rank: 2)] }
        controller.scheduleRanking(client)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard controller.cachedPrediction.map(\.text) == ["继续", "完成"],
              controller.continuationText == "继续" else { throw Engine.Failure.schemaUnavailable }
        controller.deactivateServer(client)
        print("PASS: shared MLX ranking/continuation, mapped selection, frozen order and late prediction rejection")
    }

    static func verifyContinuationLifecycle(server: IMKServer) throws {
        let defaults = UserDefaults.standard
        let keys = ["aiContinuationEnabled", "aiContinuationBackend", "aiModel",
                    "aiCandidateScoringEnabled", "aiRerankingEnabled"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "aiContinuationEnabled")
        defaults.set("lmstudio", forKey: "aiContinuationBackend")
        defaults.set("test-model", forKey: "aiModel")
        defaults.set(true, forKey: "aiCandidateScoringEnabled")
        defaults.set(true, forKey: "aiRerankingEnabled")
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
        print("PASS: post-commit continuation alongside scoring, click-only insertion, cancellation and selection rejection")
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
        // A held mode key belongs to Vim candidate navigation while composing;
        // a bare tap switches language again after the composition is closed.
        let controlDown = flags(1 << 18)
        let controlUp = flags(0)
        guard controlDown, controlUp, !controller.ascii, textClient.committed == "你好",
              !textClient.marked.isEmpty else { throw Engine.Failure.schemaUnavailable }
        controller.commitComposition(textClient)
        guard textClient.committed == "你好你好", textClient.marked.isEmpty,
              !flags(1 << 18), flags(0), controller.ascii,
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
