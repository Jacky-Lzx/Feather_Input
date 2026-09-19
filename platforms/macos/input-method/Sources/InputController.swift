import AppKit
import Carbon
import InputMethodKit

private enum NormalizedInput {
  case key(FeatherKey)
  case text(String)
}

private struct ExpandedCandidateState {
  let revision: UInt64
  var candidates: [FeatherCandidateValue]
  var highlighted: Int
  let pageSize: Int
  let layout: CandidateLayout
  var hasMore: Bool
  var nextRawOffset: Int
}

private struct GenerationSnapshot {
  let requestID: UInt64
  let revision: UInt64
  let context: String
  let input: String
  let schema: String
  let selection: NSRange
}

private struct ContinuationSnapshot {
  let requestID: UInt64
  let revision: UInt64
  let context: String
  let selection: NSRange
  let foregroundProcessIdentifier: pid_t?
}

private struct ScoringSnapshot {
  let requestID: UInt64
  let revision: UInt64
  let context: String
  let preedit: String
  let displayedCandidates: [FeatherCandidateValue]
  let scoringCandidates: [FeatherCandidateValue]
  let selection: NSRange
  let anchor: NSRect
  let weight: Double
  let adoptionDeadlineMilliseconds: UInt64
}

@objc(FeatherRustInputController)
@MainActor
final class InputController: IMKInputController {
  var secureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
  private var injectedCandidatePresenter: CandidatePresenting?
  private lazy var ownedCandidatePresenter = OwnedCandidatePresenter()
  var candidatePresenter: CandidatePresenting {
    get { injectedCandidatePresenter ?? ownedCandidatePresenter }
    set { injectedCandidatePresenter = newValue }
  }
  private var injectedGeneratedCandidatePresenter: GeneratedCandidatePresenting?
  private lazy var ownedGeneratedCandidatePresenter = OwnedGeneratedCandidatePresenter()
  var generatedCandidatePresenter: GeneratedCandidatePresenting {
    get { injectedGeneratedCandidatePresenter ?? ownedGeneratedCandidatePresenter }
    set { injectedGeneratedCandidatePresenter = newValue }
  }
  private var injectedModePresenter: ModeIndicatorPresenting?
  private lazy var ownedModePresenter = OwnedModeIndicatorPresenter()
  var modePresenter: ModeIndicatorPresenting {
    get { injectedModePresenter ?? ownedModePresenter }
    set { injectedModePresenter = newValue }
  }
  private var injectedPersistentModePresenter: PersistentModeIndicatorPresenting?
  private lazy var ownedPersistentModePresenter = OwnedPersistentModeIndicatorPresenter()
  var persistentModePresenter: PersistentModeIndicatorPresenting {
    get { injectedPersistentModePresenter ?? ownedPersistentModePresenter }
    set { injectedPersistentModePresenter = newValue }
  }
  var modeMemory = InputModeMemory.shared
  var schemeMemory = InputSchemeMemory.shared
  var focusIndicatorSettings = FocusIndicatorSettings.shared
  var candidatePageSettings = CandidatePageSettings.shared
  var englishCandidateSettings = EnglishCandidateSettings.shared
  var generationSettings = GenerationSettings.shared
  var continuationSettings = ContinuationSettings.shared
  var rerankingSettings = RerankingSettings.shared
  var capsLockState: () -> Bool = {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
  }
  var focusIndicatorRetryDelaysMilliseconds: [UInt64] = [80, 120, 200]
  var generationDebounceMilliseconds: UInt64 = 120
  var generationPollMilliseconds: UInt64 = 20
  var generationEnabled: (() -> Bool)?
  var generationContextProvider: ((IMKTextInput) -> String?)?
  var generationRequestFactory:
    (
      (FeatherSession, UInt64, UInt64, String, String, String, Int) throws ->
        any FeatherGenerationRequesting
    )?
  var continuationDebounceMilliseconds: UInt64 = 400
  var continuationRequestFactory:
    ((FeatherSession, UInt64, UInt64, String, Int) throws -> any FeatherGenerationRequesting)?
  var scoringDebounceMilliseconds: UInt64?
  var scoringAdoptionDeadlineMilliseconds: UInt64?
  var scoringPollMilliseconds: UInt64 = 20
  var scoringEnabled: (() -> Bool)?
  var scoringRequestFactory:
    (
      (
        FeatherSession, UInt64, UInt64, String, String, [FeatherCandidateValue], Double,
        FeatherScoreNormalization
      ) throws -> any FeatherScoringRequesting
    )?
  private var session: FeatherSession?
  private var currentResponse: FeatherResponseValue?
  private var expandedCandidates: ExpandedCandidateState?
  private weak var activeClient: AnyObject?
  private var active = false
  private var lastCaret: NSRect?
  private var currentCandidateAnchor: NSRect?
  private var activeApplication = "unknown"
  private var activeScheme = InputScheme.fullPinyin
  private var activePageSize: Int?
  private var activeEnglishCandidateMinimum: Int?
  private var rightControlTap = RightControlTap()
  private var capsLockSwitch = CapsLockSwitch()
  private var focusIndicatorTask: Task<Void, Never>?
  private var focusIndicatorVersion = UUID()
  private var generatedCandidates: [FeatherGeneratedCandidateValue] = []
  private var generatedSelectionHandler: ((FeatherGeneratedCandidateValue, IMKTextInput) -> Bool)?
  private var generatedCandidatesAcceptShortcuts = true
  private var generatedCandidatesAreContinuation = false
  private var consumedGeneratedShortcutKey: UInt16?
  private var generationTask: Task<Void, Never>?
  private var generationRequest: (any FeatherGenerationRequesting)?
  private var generationVersion = UUID()
  private var nextGenerationRequestID: UInt64 = 0
  private var continuationTask: Task<Void, Never>?
  private var continuationRequest: (any FeatherGenerationRequesting)?
  private var continuationVersion = UUID()
  private var nextContinuationRequestID: UInt64 = 0
  private var scoringTask: Task<Void, Never>?
  private var scoringRequest: (any FeatherScoringRequesting)?
  private var scoringVersion = UUID()
  private var nextScoringRequestID: UInt64 = 0
  private var candidateOrderLocked = false
  private var candidateOrderIsReranked = false
  private var rerankedCandidateOrder: [FeatherCandidateValue]?
  private var recentContext = ""
  private var rerankingContextAvailable = false
  private var observesGenerationSettings = false
  private var observesContinuationSettings = false
  private var observesRerankingSettings = false

  override func activateServer(_ sender: Any!) {
    startObservingGenerationSettings()
    startObservingContinuationSettings()
    startObservingRerankingSettings()
    cancelFocusIndicator()
    cancelAIWork(clearContext: true)
    candidateOrderLocked = false
    candidateOrderIsReranked = false
    rerankedCandidateOrder = nil
    activeClient = sender as AnyObject?
    lastCaret = nil
    currentCandidateAnchor = nil
    rightControlTap.reset()
    capsLockSwitch.reset(isLocked: capsLockState())
    if let client = sender as? IMKTextInput {
      activeApplication =
        client.bundleIdentifier()
        ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    } else {
      activeApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }
    if injectedCandidatePresenter == nil {
      ownedCandidatePresenter.activate()
    }
    if injectedGeneratedCandidatePresenter == nil {
      ownedGeneratedCandidatePresenter.activate()
    }
    if injectedModePresenter == nil {
      ownedModePresenter.activate()
    }
    if injectedPersistentModePresenter == nil {
      ownedPersistentModePresenter.activate()
    }
    candidatePresenter.actionHandler = { [weak self] action in
      self?.handleCandidateWindowAction(action)
    }
    candidatePresenter.interactionHandler = { [weak self] in
      self?.lockCandidateOrderForInteraction()
    }
    generatedCandidatePresenter.generatedActionHandler = { [weak self] index in
      self?.selectGeneratedCandidate(at: index)
    }
    do {
      activeScheme = schemeMemory.load()
      let session = try requireSession()
      _ = try session.activate()
      _ = try session.setSchema(activeScheme.rawValue)
      let pageSize = candidatePageSettings.count
      _ = try session.setPageSize(pageSize)
      activePageSize = pageSize
      let englishMinimum = englishCandidateSettings.minimumInputLength
      _ = try session.setEnglishCandidateMinimum(englishMinimum)
      activeEnglishCandidateMinimum = englishMinimum
      currentResponse = try session.setMode(
        direct: modeMemory.activate(application: activeApplication)
      )
      active = true
      if secureInputEnabled() {
        persistentModePresenter.hide()
      } else {
        persistentModePresenter.show(directMode: currentResponse?.directMode ?? false)
      }
      if let client = sender as? IMKTextInput {
        scheduleFocusIndicator(for: client)
      }
    } catch {
      active = false
      persistentModePresenter.hide()
      report(error, operation: "activate")
    }
  }

  override func deactivateServer(_ sender: Any!) {
    stopObservingGenerationSettings()
    stopObservingContinuationSettings()
    stopObservingRerankingSettings()
    cancelFocusIndicator()
    cancelAIWork(clearContext: true)
    guard let session else {
      active = false
      currentResponse = nil
      expandedCandidates = nil
      activeClient = nil
      lastCaret = nil
      currentCandidateAnchor = nil
      rightControlTap.reset()
      candidatePresenter.actionHandler = nil
      candidatePresenter.interactionHandler = nil
      candidatePresenter.hide()
      generatedCandidatePresenter.generatedActionHandler = nil
      clearGeneratedCandidates()
      modePresenter.hide()
      persistentModePresenter.hide()
      if injectedCandidatePresenter == nil {
        ownedCandidatePresenter.deactivate()
      }
      if injectedGeneratedCandidatePresenter == nil {
        ownedGeneratedCandidatePresenter.deactivate()
      }
      if injectedModePresenter == nil {
        ownedModePresenter.deactivate()
      }
      if injectedPersistentModePresenter == nil {
        ownedPersistentModePresenter.deactivate()
      }
      return
    }
    do {
      let response = try session.deactivate()
      if let client = sender as? IMKTextInput {
        apply(response, to: client)
      }
    } catch {
      report(error, operation: "deactivate")
    }
    active = false
    currentResponse = nil
    expandedCandidates = nil
    activeClient = nil
    lastCaret = nil
    currentCandidateAnchor = nil
    rightControlTap.reset()
    candidatePresenter.actionHandler = nil
    candidatePresenter.interactionHandler = nil
    candidatePresenter.hide()
    generatedCandidatePresenter.generatedActionHandler = nil
    clearGeneratedCandidates()
    modePresenter.hide()
    persistentModePresenter.hide()
    if injectedCandidatePresenter == nil {
      ownedCandidatePresenter.deactivate()
    }
    if injectedGeneratedCandidatePresenter == nil {
      ownedGeneratedCandidatePresenter.deactivate()
    }
    if injectedModePresenter == nil {
      ownedModePresenter.deactivate()
    }
    if injectedPersistentModePresenter == nil {
      ownedPersistentModePresenter.deactivate()
    }
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
  }

  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event, [.keyDown, .flagsChanged].contains(event.type),
      let client = sender as? IMKTextInput
    else {
      return false
    }
    guard !secureInputEnabled() else {
      cancelFocusIndicator()
      modePresenter.hide()
      persistentModePresenter.hide()
      cancelAIWork(clearContext: true)
      cancelEngineComposition()
      return false
    }

    if event.type == .flagsChanged {
      if !event.modifierFlags.contains(.option) {
        consumedGeneratedShortcutKey = nil
      }
    } else if handleGeneratedCandidateShortcut(event, client: client) {
      return true
    } else if continuationTask != nil || generatedCandidatesAreContinuation {
      cancelContinuation()
    }

    guard textInputAvailable(client) else {
      cancelFocusIndicator()
      modePresenter.hide()
      persistentModePresenter.hide()
      cancelAIWork(clearContext: true)
      cancelEngineComposition()
      return false
    }
    if !hasComposition {
      refreshContext(from: client)
    }
    persistentModePresenter.show(directMode: currentResponse?.directMode ?? false)
    cancelFocusIndicator()
    if event.type == .keyDown {
      modePresenter.hide()
      synchronizeCandidatePageSizeIfIdle()
      synchronizeEnglishCandidateMinimumIfIdle()
    }
    if event.type == .flagsChanged {
      if capsLockSwitch.flagsChanged(
        keyCode: event.keyCode,
        flags: event.modifierFlags.rawValue
      ) {
        rightControlTap.cancel()
        return toggleInputMode(for: client)
      }
      if rightControlTap.flagsChanged(
        keyCode: event.keyCode,
        flags: event.modifierFlags.rawValue,
        timestamp: event.timestamp > 0 ? event.timestamp : nil
      ) {
        return toggleInputMode(for: client)
      }
      return false
    }
    rightControlTap.cancel()
    let modeShortcut =
      event.keyCode == 49
      && event.modifierFlags.contains([.control, .shift])
      && !event.modifierFlags.contains([.command, .option])
    if modeShortcut {
      return toggleInputMode(for: client)
    }
    if let handled = handleExpandedEvent(event, client: client) {
      return handled
    }
    if event.keyCode == 53, hasComposition {
      return dispatch(.escape, to: client)
    }
    if hasComposition, currentResponse?.candidates.isEmpty == false,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    {
      switch candidatePresenter.compactLayout {
      case .vertical where event.keyCode == 124:
        openExpandedCandidates(for: client)
        return true
      case .horizontal where event.keyCode == 125 || event.keyCode == 126:
        openExpandedCandidates(for: client)
        return true
      case .horizontal where event.keyCode == 123 && !candidateOrderIsReranked:
        return dispatch(.up, to: client)
      case .horizontal where event.keyCode == 124 && !candidateOrderIsReranked:
        return dispatch(.down, to: client)
      default:
        break
      }
      if candidateOrderIsReranked {
        let movement: Int?
        switch candidatePresenter.compactLayout {
        case .vertical:
          movement = event.keyCode == 126 ? -1 : event.keyCode == 125 ? 1 : nil
        case .horizontal:
          movement = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : nil
        }
        if let movement {
          return moveInRerankedCandidates(by: movement, client: client)
        }
        if event.keyCode == 49 {
          return selectRerankedCandidate(at: currentResponse?.highlighted ?? 0, client: client)
        }
        if event.keyCode == 36 || event.keyCode == 76 {
          let highlighted = currentResponse?.highlighted ?? 0
          return highlighted == 0
            ? dispatch(.enter, to: client)
            : selectRerankedCandidate(at: highlighted, client: client)
        }
        if let characters = event.charactersIgnoringModifiers ?? event.characters,
          let number = Int(characters), (1...9).contains(number)
        {
          return selectRerankedCandidate(at: number - 1, client: client)
        }
      }
    }
    let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option])
    guard shortcutModifiers.isEmpty, let input = normalizedInput(for: event) else {
      return false
    }
    switch input {
    case .key(let key):
      return dispatch(key, to: client)
    case .text(let text):
      return dispatch(text: text, to: client)
    }
  }

  override func commitComposition(_ sender: Any!) {
    guard hasComposition, let client = sender as? IMKTextInput else { return }
    if candidateOrderIsReranked {
      _ = selectRerankedCandidate(at: currentResponse?.highlighted ?? 0, client: client)
    } else {
      _ = dispatch(.enter, to: client)
    }
  }

  override func composedString(_ sender: Any!) -> Any! {
    currentResponse?.preedit ?? ""
  }

  override func candidates(_ sender: Any!) -> [Any]! {
    currentResponse?.candidates.map(\.text) ?? []
  }

  override func menu() -> NSMenu! {
    let menu = NSMenu()
    for scheme in InputScheme.allCases {
      let action =
        scheme == .fullPinyin
        ? #selector(selectFullPinyin(_:)) : #selector(selectFlypy(_:))
      let item = NSMenuItem(title: scheme.title, action: action, keyEquivalent: "")
      item.target = self
      item.state = scheme == activeScheme ? .on : .off
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let title = currentResponse?.directMode == true ? "切换到中文" : "切换到英文"
    let toggle = NSMenuItem(
      title: title,
      action: #selector(toggleInputModeFromMenu(_:)),
      keyEquivalent: ""
    )
    toggle.target = self
    menu.addItem(toggle)
    menu.addItem(.separator())
    let settings = NSMenuItem(
      title: "设置…",
      action: #selector(showSettings(_:)),
      keyEquivalent: ""
    )
    settings.target = self
    menu.addItem(settings)
    return menu
  }

  private var hasComposition: Bool {
    currentResponse?.preedit.isEmpty == false
  }

  private func requireSession() throws -> FeatherSession {
    if let session { return session }
    let session = try FeatherSession(
      sharedData: FeatherInputEnvironment.sharedData(),
      userData: FeatherInputEnvironment.userData(),
      schema: activeScheme.rawValue
    )
    self.session = session
    return session
  }

  private func ensureActive() throws -> FeatherSession {
    let session = try requireSession()
    if !active {
      currentResponse = try session.activate()
      active = true
    }
    return session
  }

  private func dispatch(_ key: FeatherKey, to client: IMKTextInput) -> Bool {
    let wasComposing = hasComposition
    if wasComposing, isCandidateNavigation(key) {
      candidateOrderLocked = true
      cancelScoring()
    }
    cancelGeneration()
    do {
      let response = try ensureActive().send(key)
      guard response.handled else {
        return wasComposing && isCandidateNavigation(key)
      }
      apply(response, to: client)
      return true
    } catch {
      report(error, operation: "key \(key)")
      return false
    }
  }

  private func isCandidateNavigation(_ key: FeatherKey) -> Bool {
    switch key {
    case .left, .right, .up, .down, .pageUp, .pageDown:
      return true
    default:
      return false
    }
  }

  private func dispatch(text: String, to client: IMKTextInput) -> Bool {
    candidateOrderLocked = false
    cancelGeneration()
    do {
      let response = try ensureActive().send(text: text)
      guard response.handled else { return false }
      apply(response, to: client)
      return true
    } catch {
      report(error, operation: "text")
      return false
    }
  }

  private func apply(_ response: FeatherResponseValue, to client: IMKTextInput) {
    cancelScoring(hideIndicator: false)
    cancelGeneration()
    cancelContinuation()
    expandedCandidates = nil
    candidateOrderIsReranked = false
    rerankedCandidateOrder = nil
    currentResponse = response
    let committed = response.commit.flatMap { $0.isEmpty ? nil : $0 }
    if let commit = committed {
      client.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
      recentContext = String((recentContext + commit).suffix(80))
      rerankingContextAvailable = hasMeaningfulText(recentContext)
    }
    let selection = NSRange(
      location: TextCoordinates.utf16Offset(in: response.preedit, utf8Offset: response.cursorUTF8),
      length: 0
    )
    client.setMarkedText(
      response.preedit,
      selectionRange: selection,
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    if response.preedit.isEmpty || response.candidates.isEmpty {
      currentCandidateAnchor = nil
      candidatePresenter.setRerankingActive(false)
      candidatePresenter.hide()
      if response.preedit.isEmpty, committed != nil {
        scheduleContinuation(for: response, client: client)
      }
    } else {
      let anchor = candidateAnchor(for: client)
      currentCandidateAnchor = anchor
      candidatePresenter.update(
        candidates: response.candidates,
        highlighted: response.highlighted,
        preedit: response.preedit,
        anchor: anchor
      )
      let scoringScheduled: Bool
      if isScoringEnabled, !candidateOrderLocked {
        scoringScheduled = scheduleScoring(for: response, client: client, anchor: anchor)
      } else {
        scoringScheduled = false
      }
      if !scoringScheduled {
        candidatePresenter.setRerankingActive(false)
      }
      scheduleGeneration(for: response, client: client)
    }
  }

  private func scheduleScoring(
    for response: FeatherResponseValue,
    client: IMKTextInput,
    anchor: NSRect
  ) -> Bool {
    guard active, !response.directMode, rerankingContextAvailable,
      hasMeaningfulText(recentContext), !response.preedit.isEmpty,
      !response.candidates.isEmpty, let session
    else { return false }
    let scoringCandidates =
      (try? session.candidateSlice(
        revision: response.revision,
        offset: 0,
        limit: rerankingSettings.candidateCount
      ).candidates).flatMap { $0.isEmpty ? nil : $0 }
      ?? Array(response.candidates.prefix(rerankingSettings.candidateCount))
    nextScoringRequestID &+= 1
    if nextScoringRequestID == 0 { nextScoringRequestID = 1 }
    let snapshot = ScoringSnapshot(
      requestID: nextScoringRequestID,
      revision: response.revision,
      context: recentContext,
      preedit: response.preedit,
      displayedCandidates: response.candidates,
      scoringCandidates: scoringCandidates,
      selection: client.selectedRange(),
      anchor: anchor,
      weight: rerankingSettings.weight,
      adoptionDeadlineMilliseconds: scoringAdoptionDeadlineMilliseconds
        ?? rerankingSettings.adoptionDeadlineMilliseconds
    )
    let version = scoringVersion
    let debounce = scoringDebounceMilliseconds ?? rerankingSettings.debounceMilliseconds
    candidatePresenter.setRerankingActive(true)
    scoringTask = Task { @MainActor [weak self, weak client] in
      do {
        if debounce > 0 {
          try await Task.sleep(nanoseconds: debounce * 1_000_000)
        }
        guard let self else { return }
        guard let client,
          self.scoringSnapshotIsCurrent(snapshot, version: version, client: client),
          let session = self.session
        else {
          self.finishScoring(nil, version: version)
          return
        }
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        let request = try self.makeScoringRequest(session: session, snapshot: snapshot)
        self.scoringRequest = request
        while !Task.isCancelled {
          guard self.scoringSnapshotIsCurrent(snapshot, version: version, client: client) else {
            try? request.cancel()
            self.finishScoring(request, version: version)
            return
          }
          switch try request.poll(
            currentRequestID: snapshot.requestID,
            currentRevision: snapshot.revision
          ) {
          case .pending:
            try await Task.sleep(nanoseconds: self.scoringPollMilliseconds * 1_000_000)
          case .ready(let result):
            let elapsed = (ProcessInfo.processInfo.systemUptime - requestStartedAt) * 1_000
            guard elapsed <= Double(snapshot.adoptionDeadlineMilliseconds),
              self.scoringSnapshotIsCurrent(snapshot, version: version, client: client),
              let reordered = CandidateReranker.apply(
                result,
                requestID: snapshot.requestID,
                revision: snapshot.revision,
                to: snapshot.scoringCandidates
              ),
              let displayed = CandidateReranker.page(
                from: reordered,
                fillingFrom: snapshot.displayedCandidates,
                count: snapshot.displayedCandidates.count
              )
            else {
              try? request.cancel()
              self.finishScoring(request, version: version)
              return
            }
            let highlighted = response.highlighted.flatMap { index in
              displayed.indices.contains(index) ? index : nil
            }
            let updated = FeatherResponseValue(
              handled: response.handled,
              active: response.active,
              directMode: response.directMode,
              commit: response.commit,
              preedit: response.preedit,
              cursorUTF8: response.cursorUTF8,
              revision: response.revision,
              candidates: displayed,
              highlighted: highlighted
            )
            self.currentResponse = updated
            self.candidateOrderIsReranked = true
            self.rerankedCandidateOrder = reordered
            self.candidatePresenter.update(
              candidates: displayed,
              highlighted: highlighted,
              preedit: response.preedit,
              anchor: snapshot.anchor
            )
            self.synchronizeGeneratedCandidatePosition()
            self.finishScoring(request, version: version)
            return
          case .failed, .cancelled, .stale:
            self.finishScoring(request, version: version)
            return
          }
        }
      } catch {
        guard let self, self.scoringVersion == version else { return }
        self.finishScoring(self.scoringRequest, version: version)
      }
    }
    return true
  }

  private func makeScoringRequest(
    session: FeatherSession,
    snapshot: ScoringSnapshot
  ) throws -> any FeatherScoringRequesting {
    if let scoringRequestFactory {
      return try scoringRequestFactory(
        session, snapshot.requestID, snapshot.revision, snapshot.context, snapshot.preedit,
        snapshot.scoringCandidates, snapshot.weight, .character)
    }
    return try session.startScoring(
      requestID: snapshot.requestID,
      revision: snapshot.revision,
      context: snapshot.context,
      preedit: snapshot.preedit,
      candidates: snapshot.scoringCandidates,
      weight: snapshot.weight,
      normalization: .character
    )
  }

  private func scoringSnapshotIsCurrent(
    _ snapshot: ScoringSnapshot,
    version: UUID,
    client: IMKTextInput
  ) -> Bool {
    active && isScoringEnabled && !candidateOrderLocked && !secureInputEnabled()
      && scoringVersion == version && activeClient === client
      && currentResponse?.revision == snapshot.revision
      && currentResponse?.preedit == snapshot.preedit
      && currentResponse?.candidates == snapshot.displayedCandidates
      && recentContext == snapshot.context
      && rerankingContextAvailable
      && NSEqualRanges(client.selectedRange(), snapshot.selection)
  }

  private func finishScoring(
    _ request: (any FeatherScoringRequesting)?,
    version: UUID
  ) {
    request?.close()
    guard scoringVersion == version else { return }
    scoringRequest = nil
    scoringTask = nil
    candidatePresenter.setRerankingActive(false)
  }

  private func cancelScoring(hideIndicator: Bool = true) {
    scoringVersion = UUID()
    scoringTask?.cancel()
    scoringTask = nil
    try? scoringRequest?.cancel()
    scoringRequest?.close()
    scoringRequest = nil
    if hideIndicator {
      candidatePresenter.setRerankingActive(false)
    }
  }

  private var isScoringEnabled: Bool {
    scoringEnabled?() ?? rerankingSettings.isEnabled
  }

  private func startObservingRerankingSettings() {
    guard !observesRerankingSettings else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(rerankingSettingsChanged(_:)),
      name: .rerankingSettingsDidChange,
      object: nil
    )
    observesRerankingSettings = true
  }

  private func stopObservingRerankingSettings() {
    guard observesRerankingSettings else { return }
    NotificationCenter.default.removeObserver(
      self,
      name: .rerankingSettingsDidChange,
      object: nil
    )
    observesRerankingSettings = false
  }

  @objc private func rerankingSettingsChanged(_ notification: Notification) {
    guard notification.object as? RerankingSettings === rerankingSettings else { return }
    cancelScoring()
  }

  private func handleCandidateWindowAction(_ action: CandidateWindowAction) {
    guard let client = activeClient as? IMKTextInput else {
      candidatePresenter.hide()
      return
    }
    switch action {
    case .select(let candidate):
      do {
        let response = try ensureActive().select(candidate)
        guard response.handled else { return }
        apply(response, to: client)
      } catch {
        report(error, operation: "select candidate")
      }
    case .pageUp:
      _ = dispatch(.pageUp, to: client)
    case .pageDown:
      _ = dispatch(.pageDown, to: client)
    }
  }

  private func lockCandidateOrderForInteraction() {
    guard hasComposition, !candidateOrderLocked else { return }
    candidateOrderLocked = true
    cancelScoring()
  }

  private func moveInRerankedCandidates(by offset: Int, client: IMKTextInput) -> Bool {
    guard var response = currentResponse, !response.candidates.isEmpty else { return false }
    lockCandidateOrderForInteraction()
    let current = min(max(0, response.highlighted ?? 0), response.candidates.count - 1)
    let next = min(max(0, current + offset), response.candidates.count - 1)
    response = FeatherResponseValue(
      handled: response.handled,
      active: response.active,
      directMode: response.directMode,
      commit: response.commit,
      preedit: response.preedit,
      cursorUTF8: response.cursorUTF8,
      revision: response.revision,
      candidates: response.candidates,
      highlighted: next
    )
    currentResponse = response
    candidatePresenter.update(
      candidates: response.candidates,
      highlighted: next,
      preedit: response.preedit,
      anchor: currentCandidateAnchor ?? candidateAnchor(for: client)
    )
    synchronizeGeneratedCandidatePosition()
    return true
  }

  private func selectRerankedCandidate(at index: Int, client: IMKTextInput) -> Bool {
    guard let response = currentResponse, response.candidates.indices.contains(index) else {
      return true
    }
    lockCandidateOrderForInteraction()
    do {
      let selected = try ensureActive().select(response.candidates[index])
      guard selected.handled else { return true }
      apply(selected, to: client)
    } catch {
      report(error, operation: "select reranked candidate")
    }
    return true
  }

  func presentGeneratedCandidates(
    _ candidates: [FeatherGeneratedCandidateValue],
    for client: IMKTextInput,
    acceptsShortcuts: Bool = true,
    continuation: Bool = false,
    onSelect: @escaping (FeatherGeneratedCandidateValue, IMKTextInput) -> Bool
  ) {
    guard activeClient === client, !candidates.isEmpty else {
      clearGeneratedCandidates()
      return
    }
    generatedCandidates = Array(candidates.prefix(3))
    generatedCandidatesAcceptShortcuts = acceptsShortcuts
    generatedCandidatesAreContinuation = continuation
    generatedSelectionHandler = onSelect
    generatedCandidatePresenter.update(
      candidates: generatedCandidates,
      beside: candidatePresenter.frame,
      title: continuation ? "AI 续写" : nil
    )
  }

  private func handleGeneratedCandidateShortcut(_ event: NSEvent, client: IMKTextInput) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard generatedCandidatesAcceptShortcuts, modifiers == .option else {
      consumedGeneratedShortcutKey = nil
      return false
    }
    if event.isARepeat, consumedGeneratedShortcutKey == event.keyCode {
      return true
    }
    let index: Int?
    switch event.keyCode {
    case 18, 83: index = 0
    case 19, 84: index = 1
    case 20, 85: index = 2
    case 49: index = 0
    default: index = nil
    }
    guard let index, generatedCandidatePresenter.isVisible else { return false }
    _ = selectGeneratedCandidate(at: index, client: client)
    consumedGeneratedShortcutKey = event.keyCode
    return true
  }

  @discardableResult
  private func selectGeneratedCandidate(at index: Int, client: IMKTextInput? = nil) -> Bool {
    guard generatedCandidatePresenter.isVisible,
      generatedCandidates.indices.contains(index),
      let target = client ?? (activeClient as? IMKTextInput),
      activeClient === target,
      let generatedSelectionHandler
    else {
      clearGeneratedCandidates()
      return false
    }
    let selected = generatedSelectionHandler(generatedCandidates[index], target)
    if selected {
      clearGeneratedCandidates()
    }
    return selected
  }

  private func clearGeneratedCandidates() {
    generatedCandidatePresenter.hide()
    generatedCandidates = []
    generatedSelectionHandler = nil
    generatedCandidatesAcceptShortcuts = true
    generatedCandidatesAreContinuation = false
    consumedGeneratedShortcutKey = nil
  }

  private func synchronizeGeneratedCandidatePosition() {
    guard generatedCandidatePresenter.isVisible else { return }
    generatedCandidatePresenter.reposition(beside: candidatePresenter.frame)
  }

  private func scheduleGeneration(for response: FeatherResponseValue, client: IMKTextInput) {
    guard isGenerationEnabled, active, !response.directMode, !recentContext.isEmpty,
      !response.preedit.isEmpty, !response.candidates.isEmpty,
      response.preedit.utf8.allSatisfy({
        (0x61...0x7a).contains($0) || $0 == 0x20 || $0 == 0x27
      })
    else { return }

    nextGenerationRequestID &+= 1
    if nextGenerationRequestID == 0 {
      nextGenerationRequestID = 1
    }
    let snapshot = GenerationSnapshot(
      requestID: nextGenerationRequestID,
      revision: response.revision,
      context: recentContext,
      input: response.preedit,
      schema: activeScheme.rawValue,
      selection: client.selectedRange()
    )
    let version = generationVersion
    let debounce = generationDebounceMilliseconds
    generationTask = Task { @MainActor [weak self, weak client] in
      do {
        if debounce > 0 {
          try await Task.sleep(nanoseconds: debounce * 1_000_000)
        }
        guard let self, let client,
          self.generationSnapshotIsCurrent(snapshot, version: version, client: client),
          let session = self.session
        else { return }

        let request = try self.makeGenerationRequest(session: session, snapshot: snapshot)
        self.generationRequest = request
        while !Task.isCancelled {
          guard self.generationSnapshotIsCurrent(snapshot, version: version, client: client) else {
            try? request.cancel()
            self.finishGeneration(request, version: version)
            return
          }
          let state = try request.poll(
            currentRequestID: snapshot.requestID,
            currentRevision: snapshot.revision
          )
          switch state {
          case .pending:
            try await Task.sleep(nanoseconds: self.generationPollMilliseconds * 1_000_000)
          case .ready(let result):
            guard result.requestID == snapshot.requestID,
              result.revision == snapshot.revision,
              self.generationSnapshotIsCurrent(snapshot, version: version, client: client)
            else {
              try? request.cancel()
              self.finishGeneration(request, version: version)
              return
            }
            let existing = Set(response.candidates.map(\.text))
            let suggestions = result.candidates.filter { !existing.contains($0.text) }
            self.finishGeneration(request, version: version)
            guard !suggestions.isEmpty else { return }
            self.presentGeneratedCandidates(suggestions, for: client) {
              [weak self, weak client] candidate, target in
              guard let self, let client, target === client,
                self.generationSnapshotIsCurrent(snapshot, version: version, client: client),
                let session = self.session
              else { return false }
              do {
                let cleared = try session.send(.escape)
                self.apply(cleared, to: target)
                target.insertText(
                  candidate.text,
                  replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                self.recentContext = String((snapshot.context + candidate.text).suffix(80))
                self.rerankingContextAvailable = self.hasMeaningfulText(self.recentContext)
                return true
              } catch {
                self.report(error, operation: "select generated candidate")
                return false
              }
            }
            return
          case .failed, .cancelled, .stale:
            self.finishGeneration(request, version: version)
            return
          }
        }
      } catch {
        guard let self, self.generationVersion == version else { return }
        self.finishGeneration(self.generationRequest, version: version)
      }
    }
  }

  private func makeGenerationRequest(
    session: FeatherSession,
    snapshot: GenerationSnapshot
  ) throws -> any FeatherGenerationRequesting {
    if let generationRequestFactory {
      return try generationRequestFactory(
        session,
        snapshot.requestID,
        snapshot.revision,
        snapshot.context,
        snapshot.input,
        snapshot.schema,
        3
      )
    }
    return try session.startGeneration(
      requestID: snapshot.requestID,
      revision: snapshot.revision,
      context: snapshot.context,
      input: snapshot.input,
      schema: snapshot.schema,
      count: 3
    )
  }

  private func generationSnapshotIsCurrent(
    _ snapshot: GenerationSnapshot,
    version: UUID,
    client: IMKTextInput
  ) -> Bool {
    active && isGenerationEnabled && !secureInputEnabled()
      && generationVersion == version
      && activeClient === client
      && currentResponse?.revision == snapshot.revision
      && currentResponse?.preedit == snapshot.input
      && activeScheme.rawValue == snapshot.schema
      && recentContext == snapshot.context
      && NSEqualRanges(client.selectedRange(), snapshot.selection)
  }

  private func finishGeneration(
    _ request: (any FeatherGenerationRequesting)?,
    version: UUID
  ) {
    request?.close()
    guard generationVersion == version else { return }
    generationRequest = nil
    generationTask = nil
  }

  private func cancelGeneration(clearContext: Bool = false) {
    generationVersion = UUID()
    generationTask?.cancel()
    generationTask = nil
    try? generationRequest?.cancel()
    generationRequest?.close()
    generationRequest = nil
    clearGeneratedCandidates()
    if clearContext {
      recentContext = ""
      rerankingContextAvailable = false
    }
  }

  private func scheduleContinuation(for response: FeatherResponseValue, client: IMKTextInput) {
    guard isContinuationEnabled, active, !response.directMode, response.preedit.isEmpty,
      !recentContext.isEmpty, client.selectedRange().length == 0
    else { return }

    nextContinuationRequestID &+= 1
    if nextContinuationRequestID == 0 { nextContinuationRequestID = 1 }
    let snapshot = ContinuationSnapshot(
      requestID: nextContinuationRequestID,
      revision: response.revision,
      context: recentContext,
      selection: client.selectedRange(),
      foregroundProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
    )
    let version = continuationVersion
    let debounce = continuationDebounceMilliseconds
    continuationTask = Task { @MainActor [weak self, weak client] in
      do {
        if debounce > 0 {
          try await Task.sleep(nanoseconds: debounce * 1_000_000)
        }
        guard let self, let client,
          self.continuationSnapshotIsCurrent(snapshot, version: version, client: client),
          let session = self.session
        else { return }
        let request: any FeatherGenerationRequesting
        if let factory = self.continuationRequestFactory {
          request = try factory(session, snapshot.requestID, snapshot.revision, snapshot.context, 3)
        } else {
          request = try session.startContinuation(
            requestID: snapshot.requestID,
            revision: snapshot.revision,
            context: snapshot.context,
            count: 3
          )
        }
        self.continuationRequest = request
        while !Task.isCancelled {
          guard
            self.continuationSnapshotIsCurrent(
              snapshot, version: version, client: client
            )
          else {
            try? request.cancel()
            self.finishContinuation(request, version: version)
            return
          }
          switch try request.poll(
            currentRequestID: snapshot.requestID,
            currentRevision: snapshot.revision
          ) {
          case .pending:
            try await Task.sleep(nanoseconds: self.generationPollMilliseconds * 1_000_000)
          case .ready(let result):
            guard result.requestID == snapshot.requestID,
              result.revision == snapshot.revision,
              self.continuationSnapshotIsCurrent(snapshot, version: version, client: client)
            else {
              try? request.cancel()
              self.finishContinuation(request, version: version)
              return
            }
            let suggestions = result.candidates.filter {
              !$0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
            }
            self.finishContinuation(request, version: version)
            guard !suggestions.isEmpty else { return }
            self.presentGeneratedCandidates(
              suggestions,
              for: client,
              acceptsShortcuts: true,
              continuation: true
            ) { [weak self, weak client] candidate, target in
              guard let self, let client, target === client,
                self.continuationSnapshotIsCurrent(snapshot, version: version, client: client)
              else { return false }
              self.cancelContinuation()
              target.insertText(
                candidate.text,
                replacementRange: NSRange(location: NSNotFound, length: 0)
              )
              self.recentContext = String((snapshot.context + candidate.text).suffix(80))
              self.rerankingContextAvailable = self.hasMeaningfulText(self.recentContext)
              return true
            }
            return
          case .failed, .cancelled, .stale:
            self.finishContinuation(request, version: version)
            return
          }
        }
      } catch {
        guard let self, self.continuationVersion == version else { return }
        self.finishContinuation(self.continuationRequest, version: version)
      }
    }
  }

  private func continuationSnapshotIsCurrent(
    _ snapshot: ContinuationSnapshot,
    version: UUID,
    client: IMKTextInput
  ) -> Bool {
    active && isContinuationEnabled && !secureInputEnabled()
      && continuationVersion == version
      && activeClient === client
      && currentResponse?.revision == snapshot.revision
      && currentResponse?.preedit.isEmpty == true
      && recentContext == snapshot.context
      && NSEqualRanges(client.selectedRange(), snapshot.selection)
      && NSWorkspace.shared.frontmostApplication?.processIdentifier
        == snapshot.foregroundProcessIdentifier
  }

  private func finishContinuation(
    _ request: (any FeatherGenerationRequesting)?,
    version: UUID
  ) {
    request?.close()
    guard continuationVersion == version else { return }
    continuationRequest = nil
    continuationTask = nil
  }

  private func cancelContinuation() {
    continuationVersion = UUID()
    continuationTask?.cancel()
    continuationTask = nil
    try? continuationRequest?.cancel()
    continuationRequest?.close()
    continuationRequest = nil
    if generatedCandidatesAreContinuation {
      clearGeneratedCandidates()
    }
  }

  private func cancelAIWork(clearContext: Bool = false) {
    cancelScoring()
    cancelGeneration(clearContext: clearContext)
    cancelContinuation()
  }

  private var isGenerationEnabled: Bool {
    generationEnabled?() ?? generationSettings.isEnabled
  }

  private var isContinuationEnabled: Bool {
    continuationSettings.isEnabled
  }

  private func startObservingContinuationSettings() {
    guard !observesContinuationSettings else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(continuationSettingsChanged(_:)),
      name: .continuationSettingsDidChange,
      object: nil
    )
    observesContinuationSettings = true
  }

  private func stopObservingContinuationSettings() {
    guard observesContinuationSettings else { return }
    NotificationCenter.default.removeObserver(
      self,
      name: .continuationSettingsDidChange,
      object: nil
    )
    observesContinuationSettings = false
  }

  @objc private func continuationSettingsChanged(_ notification: Notification) {
    guard notification.object as? ContinuationSettings === continuationSettings else { return }
    if !isContinuationEnabled { cancelContinuation() }
  }

  private func startObservingGenerationSettings() {
    guard !observesGenerationSettings else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(generationSettingsChanged(_:)),
      name: .generationSettingsDidChange,
      object: nil
    )
    observesGenerationSettings = true
  }

  private func stopObservingGenerationSettings() {
    guard observesGenerationSettings else { return }
    NotificationCenter.default.removeObserver(
      self,
      name: .generationSettingsDidChange,
      object: nil
    )
    observesGenerationSettings = false
  }

  @objc private func generationSettingsChanged(_ notification: Notification) {
    guard notification.object as? GenerationSettings === generationSettings else { return }
    if !isGenerationEnabled {
      cancelGeneration()
    }
  }

  private func refreshContext(from client: IMKTextInput) {
    if let generationContextProvider {
      if let context = generationContextProvider(client) {
        recentContext = String(context.suffix(80))
        rerankingContextAvailable = hasMeaningfulText(recentContext)
      } else {
        rerankingContextAvailable = false
      }
      return
    }
    let selection = client.selectedRange()
    guard selection.location != NSNotFound, selection.location >= 0 else {
      rerankingContextAvailable = false
      return
    }
    let count = min(selection.location, 320)
    guard count > 0 else {
      rerankingContextAvailable = false
      if activeApplication == "com.openai.codex", !recentContext.isEmpty {
        return
      }
      recentContext = ""
      return
    }
    let range = NSRange(location: selection.location - count, length: count)
    var actual = NSRange(location: NSNotFound, length: 0)
    let plain = client.string(from: range, actualRange: &actual)
    let text: String?
    if let plain, NSEqualRanges(actual, range), plain.utf16.count == count {
      text = plain
    } else if let attributed = client.attributedSubstring(from: range), attributed.length == count {
      text = attributed.string
    } else {
      text = nil
    }
    if let text {
      recentContext = String(text.suffix(80))
      rerankingContextAvailable = hasMeaningfulText(recentContext)
    }
  }

  private func hasMeaningfulText(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
  }

  private func openExpandedCandidates(for client: IMKTextInput) {
    cancelAIWork()
    guard let response = currentResponse, !response.candidates.isEmpty else { return }
    do {
      let compactPageSize = max(1, min(9, response.candidates.count))
      let expandedPageSize = compactPageSize * CandidateWindowStyle.expandedColumnCount
      let layout = candidatePresenter.compactLayout
      let slice = try ensureActive().candidateSlice(
        revision: response.revision, offset: 0, limit: expandedPageSize)
      guard currentResponse?.revision == slice.revision, !slice.candidates.isEmpty else { return }
      var candidates =
        candidateOrderIsReranked
        ? (rerankedCandidateOrder ?? response.candidates) : []
      var candidateIDs = Set(candidates.map(\.value))
      candidates.append(
        contentsOf: slice.candidates.filter { candidateIDs.insert($0.value).inserted })
      let highlightedID = response.highlighted.flatMap { index in
        response.candidates.indices.contains(index) ? response.candidates[index] : nil
      }
      let highlighted =
        highlightedID.flatMap { candidate in
          candidates.firstIndex { $0.value == candidate.value }
        } ?? 0
      expandedCandidates = ExpandedCandidateState(
        revision: slice.revision,
        candidates: candidates,
        highlighted: highlighted,
        pageSize: compactPageSize,
        layout: layout,
        hasMore: slice.hasMore,
        nextRawOffset: slice.candidates.count
      )
      renderExpandedCandidates(for: client)
    } catch {
      expandedCandidates = nil
      report(error, operation: "open expanded candidates")
    }
  }

  private func loadMoreExpandedCandidates() -> Bool {
    guard var expandedCandidates, expandedCandidates.hasMore, let session else { return false }
    do {
      let slice = try session.candidateSlice(
        revision: expandedCandidates.revision,
        offset: expandedCandidates.nextRawOffset,
        limit: expandedCandidates.pageSize * CandidateWindowStyle.expandedColumnCount
      )
      guard currentResponse?.revision == slice.revision else {
        self.expandedCandidates = nil
        return false
      }
      var candidateIDs = Set(expandedCandidates.candidates.map(\.value))
      expandedCandidates.candidates.append(
        contentsOf: slice.candidates.filter { candidateIDs.insert($0.value).inserted }
      )
      expandedCandidates.nextRawOffset += slice.candidates.count
      expandedCandidates.hasMore = slice.hasMore
      self.expandedCandidates = expandedCandidates
      return true
    } catch {
      self.expandedCandidates = nil
      report(error, operation: "load expanded candidates")
      return false
    }
  }

  private func renderExpandedCandidates(for client: IMKTextInput) {
    guard let expandedCandidates else { return }
    candidatePresenter.updateExpanded(
      candidates: expandedCandidates.candidates,
      highlighted: expandedCandidates.highlighted,
      pageSize: expandedCandidates.pageSize,
      layout: expandedCandidates.layout,
      hasMore: expandedCandidates.hasMore,
      preedit: currentResponse?.preedit ?? "",
      anchor: currentCandidateAnchor ?? candidateAnchor(for: client)
    )
  }

  private func closeExpandedCandidates(for client: IMKTextInput) {
    expandedCandidates = nil
    guard let response = currentResponse, !response.preedit.isEmpty, !response.candidates.isEmpty
    else {
      candidatePresenter.hide()
      return
    }
    candidatePresenter.update(
      candidates: response.candidates,
      highlighted: response.highlighted,
      preedit: response.preedit,
      anchor: currentCandidateAnchor ?? candidateAnchor(for: client)
    )
  }

  private func handleExpandedEvent(_ event: NSEvent, client: IMKTextInput) -> Bool? {
    guard var expandedCandidates else { return nil }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option])
    guard modifiers.isEmpty else {
      closeExpandedCandidates(for: client)
      return nil
    }

    if event.keyCode == 48 {
      return false
    }
    if event.keyCode == 53 {
      self.expandedCandidates = nil
      return dispatch(.escape, to: client)
    }
    if event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76 {
      selectExpandedCandidate(
        expandedCandidates.candidates[expandedCandidates.highlighted], client: client)
      return true
    }
    if let characters = event.characters,
      let number = Int(characters),
      (1...expandedCandidates.pageSize).contains(number)
    {
      let axis = expandedCandidates.highlighted / expandedCandidates.pageSize
      let index = axis * expandedCandidates.pageSize + number - 1
      if expandedCandidates.candidates.indices.contains(index) {
        selectExpandedCandidate(expandedCandidates.candidates[index], client: client)
      }
      return true
    }

    let movement: (horizontal: Int, vertical: Int)
    switch event.keyCode {
    case 123: movement = (-1, 0)
    case 124: movement = (1, 0)
    case 125: movement = (0, 1)
    case 126: movement = (0, -1)
    default:
      closeExpandedCandidates(for: client)
      return nil
    }
    let horizontal = movement.horizontal
    let vertical = movement.vertical

    switch expandedCandidates.layout {
    case .vertical:
      let currentColumn = expandedCandidates.highlighted / expandedCandidates.pageSize
      if horizontal > 0,
        (currentColumn + 1) * expandedCandidates.pageSize
          >= expandedCandidates.candidates.count,
        expandedCandidates.hasMore
      {
        guard loadMoreExpandedCandidates() else {
          closeExpandedCandidates(for: client)
          return true
        }
        guard let loaded = self.expandedCandidates else { return true }
        expandedCandidates = loaded
      }
      let maximumColumn =
        (expandedCandidates.candidates.count - 1) / expandedCandidates.pageSize
      let column = min(maximumColumn, max(0, currentColumn + horizontal))
      let currentRow = expandedCandidates.highlighted % expandedCandidates.pageSize
      let maximumRow = min(
        expandedCandidates.pageSize - 1,
        expandedCandidates.candidates.count - 1 - column * expandedCandidates.pageSize
      )
      let row = min(maximumRow, max(0, currentRow + vertical))
      expandedCandidates.highlighted = column * expandedCandidates.pageSize + row
    case .horizontal:
      let currentRow = expandedCandidates.highlighted / expandedCandidates.pageSize
      if vertical > 0,
        (currentRow + 1) * expandedCandidates.pageSize
          >= expandedCandidates.candidates.count,
        expandedCandidates.hasMore
      {
        guard loadMoreExpandedCandidates() else {
          closeExpandedCandidates(for: client)
          return true
        }
        guard let loaded = self.expandedCandidates else { return true }
        expandedCandidates = loaded
      }
      let maximumRow = (expandedCandidates.candidates.count - 1) / expandedCandidates.pageSize
      let row = min(maximumRow, max(0, currentRow + vertical))
      let currentColumn = expandedCandidates.highlighted % expandedCandidates.pageSize
      let maximumColumn = min(
        expandedCandidates.pageSize - 1,
        expandedCandidates.candidates.count - 1 - row * expandedCandidates.pageSize
      )
      let column = min(maximumColumn, max(0, currentColumn + horizontal))
      expandedCandidates.highlighted = row * expandedCandidates.pageSize + column
    }
    self.expandedCandidates = expandedCandidates
    renderExpandedCandidates(for: client)
    return true
  }

  private func selectExpandedCandidate(
    _ candidate: FeatherCandidateValue,
    client: IMKTextInput
  ) {
    do {
      let response = try ensureActive().select(candidate)
      guard response.handled else { return }
      apply(response, to: client)
    } catch {
      expandedCandidates = nil
      report(error, operation: "select expanded candidate")
    }
  }

  @objc private func toggleInputModeFromMenu(_ sender: Any?) {
    let senderClient = (sender as? NSDictionary)?[kIMKCommandClientName as String]
    guard let client = (senderClient as? IMKTextInput) ?? (activeClient as? IMKTextInput) else {
      return
    }
    _ = toggleInputMode(for: client)
  }

  @objc func showSettings(_ sender: Any?) {
    cancelFocusIndicator()
    let senderClient = (sender as? NSDictionary)?[kIMKCommandClientName as String]
    if let client = (senderClient as? IMKTextInput) ?? (activeClient as? IMKTextInput),
      hasComposition
    {
      _ = dispatch(.escape, to: client)
    }
    candidatePresenter.hide()
    modePresenter.hide()
    SettingsWindowController.shared.show()
  }

  @objc private func selectFullPinyin(_ sender: Any?) {
    selectInputScheme(.fullPinyin, sender: sender)
  }

  @objc private func selectFlypy(_ sender: Any?) {
    selectInputScheme(.flypy, sender: sender)
  }

  private func selectInputScheme(_ scheme: InputScheme, sender: Any?) {
    let senderClient = (sender as? NSDictionary)?[kIMKCommandClientName as String]
    guard let client = (senderClient as? IMKTextInput) ?? (activeClient as? IMKTextInput) else {
      return
    }
    _ = selectInputScheme(scheme, for: client)
  }

  func selectInputScheme(_ scheme: InputScheme, for client: IMKTextInput) -> Bool {
    do {
      let session = try ensureActive()
      let schemaResponse = try session.setSchema(scheme.rawValue)
      guard schemaResponse.handled else { return false }
      let pageSize = candidatePageSettings.count
      let pageSizeResponse = try session.setPageSize(pageSize)
      guard pageSizeResponse.handled else { return false }
      let englishMinimum = englishCandidateSettings.minimumInputLength
      let response = try session.setEnglishCandidateMinimum(englishMinimum)
      guard response.handled else { return false }
      activeScheme = scheme
      activePageSize = pageSize
      activeEnglishCandidateMinimum = englishMinimum
      schemeMemory.update(scheme)
      apply(response, to: client)
      return true
    } catch {
      report(error, operation: "select schema \(scheme.rawValue)")
      return false
    }
  }

  private func toggleInputMode(for client: IMKTextInput) -> Bool {
    do {
      let response = try ensureActive().send(.toggleMode)
      guard response.handled else { return false }
      apply(response, to: client)
      modeMemory.update(directMode: response.directMode, application: activeApplication)
      persistentModePresenter.show(directMode: response.directMode)
      modePresenter.show(
        directMode: response.directMode,
        anchor: candidateAnchor(for: client),
        clientLevel: Int(client.windowLevel()),
        waitsUntilInput: false,
        duration: 0.8
      )
      return true
    } catch {
      report(error, operation: "toggle mode")
      return false
    }
  }

  private func candidateAnchor(for client: IMKTextInput) -> NSRect {
    var caret = NSRect.zero
    _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
    if caret.minX.isFinite, caret.minY.isFinite, caret.width.isFinite,
      caret.height.isFinite, caret.height > 0
    {
      lastCaret = caret
    }
    return lastCaret
      ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 20))
  }

  private func synchronizeCandidatePageSizeIfIdle() {
    let pageSize = candidatePageSettings.count
    guard !hasComposition, activePageSize != pageSize, let session else { return }
    do {
      let response = try session.setPageSize(pageSize)
      guard response.handled else { return }
      activePageSize = pageSize
      currentResponse = response
    } catch {
      report(error, operation: "set page size \(pageSize)")
    }
  }

  private func synchronizeEnglishCandidateMinimumIfIdle() {
    let minimum = englishCandidateSettings.minimumInputLength
    guard !hasComposition, activeEnglishCandidateMinimum != minimum, let session else { return }
    do {
      let response = try session.setEnglishCandidateMinimum(minimum)
      guard response.handled else { return }
      activeEnglishCandidateMinimum = minimum
      currentResponse = response
    } catch {
      report(error, operation: "set English candidate minimum \(minimum)")
    }
  }

  @discardableResult
  func showFocusIndicator(for client: IMKTextInput) -> Bool {
    let selection = client.selectedRange()
    guard selection.location != NSNotFound else { return false }
    var caret = NSRect.zero
    _ = client.attributes(
      forCharacterIndex: selection.location,
      lineHeightRectangle: &caret
    )
    guard caret.minX.isFinite, caret.minY.isFinite, caret.width.isFinite,
      caret.height.isFinite, caret.height > 0
    else { return false }
    lastCaret = caret
    modePresenter.show(
      directMode: currentResponse?.directMode ?? false,
      anchor: caret,
      clientLevel: Int(client.windowLevel()),
      waitsUntilInput: focusIndicatorSettings.waitsUntilInput,
      duration: focusIndicatorSettings.duration
    )
    return true
  }

  private func scheduleFocusIndicator(for client: IMKTextInput) {
    cancelFocusIndicator()
    modePresenter.hide()
    let version = focusIndicatorVersion
    let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let delays = focusIndicatorRetryDelaysMilliseconds
    focusIndicatorTask = Task { @MainActor [weak self, weak client] in
      for delay in delays {
        do {
          try await Task.sleep(nanoseconds: delay * 1_000_000)
        } catch {
          return
        }
        guard let self, let client, !Task.isCancelled, self.active,
          self.focusIndicatorVersion == version,
          !self.secureInputEnabled(),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
        else { return }
        if self.showFocusIndicator(for: client) {
          return
        }
      }
    }
  }

  private func cancelFocusIndicator() {
    focusIndicatorTask?.cancel()
    focusIndicatorTask = nil
    focusIndicatorVersion = UUID()
  }

  private func normalizedInput(for event: NSEvent) -> NormalizedInput? {
    switch event.keyCode {
    case 51: return .key(.backspace)
    case 117: return .key(.delete)
    case 49: return .key(.space)
    case 36, 76: return .key(.enter)
    case 53: return .key(.escape)
    case 123: return .key(.pageUp)
    case 124: return .key(.pageDown)
    case 125: return .key(.down)
    case 126: return .key(.up)
    case 116: return .key(.pageUp)
    case 121: return .key(.pageDown)
    default:
      guard let text = event.characters, isPrintableASCII(text) else {
        return nil
      }
      return .text(text)
    }
  }

  private func isPrintableASCII(_ text: String) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { (0x20...0x7e).contains($0) }
  }

  private func textInputAvailable(_ client: IMKTextInput) -> Bool {
    client.selectedRange().location != NSNotFound
  }

  private func cancelEngineComposition() {
    cancelAIWork()
    guard hasComposition, let session else { return }
    currentResponse = try? session.send(.escape)
    expandedCandidates = nil
    candidatePresenter.hide()
  }

  private func report(_ error: Error, operation: String) {
    NSLog("Feather Input Rust Dev \(operation) 失败：\(error.localizedDescription)")
  }
}
