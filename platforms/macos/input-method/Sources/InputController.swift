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
  let rows: Int
  var hasMore: Bool
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
  private var injectedModePresenter: ModeIndicatorPresenting?
  private lazy var ownedModePresenter = OwnedModeIndicatorPresenter()
  var modePresenter: ModeIndicatorPresenting {
    get { injectedModePresenter ?? ownedModePresenter }
    set { injectedModePresenter = newValue }
  }
  var modeMemory = InputModeMemory.shared
  var schemeMemory = InputSchemeMemory.shared
  var focusIndicatorSettings = FocusIndicatorSettings.shared
  var focusIndicatorRetryDelaysMilliseconds: [UInt64] = [80, 120, 200]
  private var session: FeatherSession?
  private var currentResponse: FeatherResponseValue?
  private var expandedCandidates: ExpandedCandidateState?
  private weak var activeClient: AnyObject?
  private var active = false
  private var lastCaret: NSRect?
  private var activeApplication = "unknown"
  private var activeScheme = InputScheme.fullPinyin
  private var rightControlTap = RightControlTap()
  private var focusIndicatorTask: Task<Void, Never>?
  private var focusIndicatorVersion = UUID()

  override func activateServer(_ sender: Any!) {
    cancelFocusIndicator()
    activeClient = sender as AnyObject?
    lastCaret = nil
    rightControlTap.reset()
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
    if injectedModePresenter == nil {
      ownedModePresenter.activate()
    }
    candidatePresenter.actionHandler = { [weak self] action in
      self?.handleCandidateWindowAction(action)
    }
    do {
      activeScheme = schemeMemory.load()
      let session = try requireSession()
      _ = try session.activate()
      _ = try session.setSchema(activeScheme.rawValue)
      currentResponse = try session.setMode(
        direct: modeMemory.activate(application: activeApplication)
      )
      active = true
      if let client = sender as? IMKTextInput {
        scheduleFocusIndicator(for: client)
      }
    } catch {
      active = false
      report(error, operation: "activate")
    }
  }

  override func deactivateServer(_ sender: Any!) {
    cancelFocusIndicator()
    guard let session else {
      active = false
      currentResponse = nil
      expandedCandidates = nil
      activeClient = nil
      lastCaret = nil
      rightControlTap.reset()
      candidatePresenter.actionHandler = nil
      candidatePresenter.hide()
      modePresenter.hide()
      if injectedCandidatePresenter == nil {
        ownedCandidatePresenter.deactivate()
      }
      if injectedModePresenter == nil {
        ownedModePresenter.deactivate()
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
    rightControlTap.reset()
    candidatePresenter.actionHandler = nil
    candidatePresenter.hide()
    modePresenter.hide()
    if injectedCandidatePresenter == nil {
      ownedCandidatePresenter.deactivate()
    }
    if injectedModePresenter == nil {
      ownedModePresenter.deactivate()
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
      cancelEngineComposition()
      return false
    }

    guard textInputAvailable(client) else {
      cancelFocusIndicator()
      modePresenter.hide()
      cancelEngineComposition()
      return false
    }
    cancelFocusIndicator()
    if event.type == .keyDown {
      modePresenter.hide()
    }
    if event.type == .flagsChanged {
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
    if event.keyCode == 124, hasComposition, currentResponse?.candidates.isEmpty == false,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    {
      openExpandedCandidates(for: client)
      return true
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
    _ = dispatch(.enter, to: client)
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
    expandedCandidates = nil
    currentResponse = response
    if let commit = response.commit, !commit.isEmpty {
      client.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
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
      candidatePresenter.hide()
    } else {
      candidatePresenter.update(
        candidates: response.candidates,
        highlighted: response.highlighted,
        anchor: candidateAnchor(for: client)
      )
    }
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

  private func openExpandedCandidates(for client: IMKTextInput) {
    guard let response = currentResponse, !response.candidates.isEmpty else { return }
    do {
      let rows = max(1, min(9, response.candidates.count))
      let pageSize = rows * CandidateWindowStyle.expandedColumnCount
      let slice = try ensureActive().candidateSlice(
        revision: response.revision, offset: 0, limit: pageSize)
      guard currentResponse?.revision == slice.revision, !slice.candidates.isEmpty else { return }
      let highlightedID = response.highlighted.flatMap { index in
        response.candidates.indices.contains(index) ? response.candidates[index] : nil
      }
      let highlighted =
        highlightedID.flatMap { candidate in
          slice.candidates.firstIndex { $0.value == candidate.value }
        } ?? 0
      expandedCandidates = ExpandedCandidateState(
        revision: slice.revision,
        candidates: slice.candidates,
        highlighted: highlighted,
        rows: rows,
        hasMore: slice.hasMore
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
        offset: expandedCandidates.candidates.count,
        limit: expandedCandidates.rows * CandidateWindowStyle.expandedColumnCount
      )
      guard currentResponse?.revision == slice.revision else {
        self.expandedCandidates = nil
        return false
      }
      expandedCandidates.candidates.append(contentsOf: slice.candidates)
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
      rows: expandedCandidates.rows,
      hasMore: expandedCandidates.hasMore,
      anchor: candidateAnchor(for: client)
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
      anchor: candidateAnchor(for: client)
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
    if let characters = event.charactersIgnoringModifiers,
      let number = Int(characters),
      (1...expandedCandidates.rows).contains(number)
    {
      let column = expandedCandidates.highlighted / expandedCandidates.rows
      let index = column * expandedCandidates.rows + number - 1
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

    let currentColumn = expandedCandidates.highlighted / expandedCandidates.rows
    if horizontal > 0,
      (currentColumn + 1) * expandedCandidates.rows >= expandedCandidates.candidates.count,
      expandedCandidates.hasMore
    {
      guard loadMoreExpandedCandidates() else {
        closeExpandedCandidates(for: client)
        return true
      }
      guard let loaded = self.expandedCandidates else { return true }
      expandedCandidates = loaded
    }
    let maximumColumn = (expandedCandidates.candidates.count - 1) / expandedCandidates.rows
    let column = min(maximumColumn, max(0, currentColumn + horizontal))
    let currentRow = expandedCandidates.highlighted % expandedCandidates.rows
    let maximumRow = min(
      expandedCandidates.rows - 1,
      expandedCandidates.candidates.count - 1 - column * expandedCandidates.rows
    )
    let row = min(maximumRow, max(0, currentRow + vertical))
    expandedCandidates.highlighted = column * expandedCandidates.rows + row
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
      let response = try ensureActive().setSchema(scheme.rawValue)
      guard response.handled else { return false }
      activeScheme = scheme
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
      guard let text = event.charactersIgnoringModifiers, isPrintableASCII(text) else {
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
    guard hasComposition, let session else { return }
    currentResponse = try? session.send(.escape)
    expandedCandidates = nil
    candidatePresenter.hide()
  }

  private func report(_ error: Error, operation: String) {
    NSLog("Feather Input Rust Dev \(operation) 失败：\(error.localizedDescription)")
  }
}
