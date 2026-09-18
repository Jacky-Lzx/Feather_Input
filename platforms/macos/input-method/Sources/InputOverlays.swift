import AppKit
import Carbon

@MainActor
protocol ContinuationShortcutRegistering: AnyObject {
  @discardableResult
  func activate(action: @escaping () -> Void) -> Bool
  func deactivate()
}

private let continuationHotKeySignature: OSType = 0x4641_4943  // "FAIC"
private let continuationHotKeyIdentifier: UInt32 = 1

private func handleContinuationHotKey(
  _ nextHandler: EventHandlerCallRef?,
  _ event: EventRef?,
  _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr,
    hotKeyID.signature == continuationHotKeySignature,
    hotKeyID.id == continuationHotKeyIdentifier
  else {
    return OSStatus(eventNotHandledErr)
  }
  let shortcut = Unmanaged<CarbonContinuationShortcut>.fromOpaque(userData)
    .takeUnretainedValue()
  MainActor.assumeIsolated {
    shortcut.performAction()
  }
  return noErr
}

@MainActor
final class CarbonContinuationShortcut: ContinuationShortcutRegistering {
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?
  private var action: (() -> Void)?

  @discardableResult
  func activate(action: @escaping () -> Void) -> Bool {
    deactivate()
    self.action = action

    if eventHandler == nil {
      var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
      )
      let status = InstallEventHandler(
        GetApplicationEventTarget(),
        handleContinuationHotKey,
        1,
        &eventType,
        Unmanaged.passUnretained(self).toOpaque(),
        &eventHandler
      )
      guard status == noErr else {
        NSLog("FeatherInput AI continuation event handler failed: %d", status)
        self.action = nil
        return false
      }
    }

    let hotKeyID = EventHotKeyID(
      signature: continuationHotKeySignature,
      id: continuationHotKeyIdentifier
    )
    let status = RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(optionKey),
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
    guard status == noErr else {
      NSLog("FeatherInput AI continuation shortcut registration failed: %d", status)
      self.action = nil
      hotKey = nil
      return false
    }
    return true
  }

  func deactivate() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      self.hotKey = nil
    }
    action = nil
  }

  fileprivate func performAction() {
    action?()
  }
}

@MainActor
final class CandidateOverlayStore {
  static let shared = CandidateOverlayStore(presenter: CandidateWindowController())

  private let presenter: CandidatePresenting
  private var ownerID: UUID?

  init(presenter: CandidatePresenting) {
    self.presenter = presenter
  }

  func activate(_ id: UUID) {
    guard ownerID != id else { return }
    presenter.actionHandler = nil
    presenter.interactionHandler = nil
    presenter.hide()
    ownerID = id
  }

  func deactivate(_ id: UUID) {
    guard ownerID == id else { return }
    presenter.actionHandler = nil
    presenter.interactionHandler = nil
    presenter.hide()
    ownerID = nil
  }

  func presenter(for id: UUID) -> CandidatePresenting? {
    ownerID == id ? presenter : nil
  }
}

@MainActor
final class OwnedCandidatePresenter: CandidatePresenting {
  private let ownershipID = UUID()
  private let store: CandidateOverlayStore

  init() {
    store = CandidateOverlayStore.shared
  }

  init(store: CandidateOverlayStore) {
    self.store = store
  }

  deinit {
    let ownershipID = ownershipID
    let store = store
    Task { @MainActor in
      store.deactivate(ownershipID)
    }
  }

  var actionHandler: ((CandidateWindowAction) -> Void)? {
    get { store.presenter(for: ownershipID)?.actionHandler }
    set { store.presenter(for: ownershipID)?.actionHandler = newValue }
  }

  var interactionHandler: (() -> Void)? {
    get { store.presenter(for: ownershipID)?.interactionHandler }
    set { store.presenter(for: ownershipID)?.interactionHandler = newValue }
  }

  var compactLayout: CandidateLayout {
    store.presenter(for: ownershipID)?.compactLayout ?? .vertical
  }

  var frame: NSRect {
    store.presenter(for: ownershipID)?.frame ?? .zero
  }

  func activate() {
    store.activate(ownershipID)
  }

  func deactivate() {
    store.deactivate(ownershipID)
  }

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    preedit: String,
    anchor: NSRect
  ) {
    store.presenter(for: ownershipID)?.update(
      candidates: candidates,
      highlighted: highlighted,
      preedit: preedit,
      anchor: anchor
    )
  }

  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    pageSize: Int,
    layout: CandidateLayout,
    hasMore: Bool,
    preedit: String,
    anchor: NSRect
  ) {
    store.presenter(for: ownershipID)?.updateExpanded(
      candidates: candidates,
      highlighted: highlighted,
      pageSize: pageSize,
      layout: layout,
      hasMore: hasMore,
      preedit: preedit,
      anchor: anchor
    )
  }

  func setRerankingActive(_ active: Bool) {
    store.presenter(for: ownershipID)?.setRerankingActive(active)
  }

  func hide() {
    store.presenter(for: ownershipID)?.hide()
  }
}

@MainActor
final class GeneratedCandidateOverlayStore {
  static let shared = GeneratedCandidateOverlayStore(
    presenter: CandidateWindowController(),
    continuationShortcut: CarbonContinuationShortcut()
  )

  private let presenter: GeneratedCandidatePresenting
  private let continuationShortcut: ContinuationShortcutRegistering
  private var ownerID: UUID?

  init(presenter: GeneratedCandidatePresenting) {
    self.presenter = presenter
    continuationShortcut = CarbonContinuationShortcut()
  }

  init(
    presenter: GeneratedCandidatePresenting,
    continuationShortcut: ContinuationShortcutRegistering
  ) {
    self.presenter = presenter
    self.continuationShortcut = continuationShortcut
  }

  func activate(_ id: UUID) {
    guard ownerID != id else { return }
    continuationShortcut.deactivate()
    presenter.generatedActionHandler = nil
    presenter.hide()
    ownerID = id
  }

  func deactivate(_ id: UUID) {
    guard ownerID == id else { return }
    continuationShortcut.deactivate()
    presenter.generatedActionHandler = nil
    presenter.hide()
    ownerID = nil
  }

  func presenter(for id: UUID) -> GeneratedCandidatePresenting? {
    ownerID == id ? presenter : nil
  }

  func update(
    _ id: UUID,
    candidates: [FeatherGeneratedCandidateValue],
    beside anchor: NSRect,
    title: String?
  ) {
    guard ownerID == id else { return }
    presenter.update(candidates: candidates, beside: anchor, title: title)
    if title != nil, !candidates.isEmpty {
      _ = continuationShortcut.activate { [weak self] in
        guard let self, self.ownerID == id, self.presenter.isVisible else { return }
        self.presenter.generatedActionHandler?(0)
      }
    } else {
      continuationShortcut.deactivate()
    }
  }

  func hide(_ id: UUID) {
    guard ownerID == id else { return }
    continuationShortcut.deactivate()
    presenter.hide()
  }
}

@MainActor
final class OwnedGeneratedCandidatePresenter: GeneratedCandidatePresenting {
  private let ownershipID = UUID()
  private let store: GeneratedCandidateOverlayStore

  init() {
    store = GeneratedCandidateOverlayStore.shared
  }

  init(store: GeneratedCandidateOverlayStore) {
    self.store = store
  }

  deinit {
    let ownershipID = ownershipID
    let store = store
    Task { @MainActor in
      store.deactivate(ownershipID)
    }
  }

  var generatedActionHandler: ((Int) -> Void)? {
    get { store.presenter(for: ownershipID)?.generatedActionHandler }
    set { store.presenter(for: ownershipID)?.generatedActionHandler = newValue }
  }

  var isVisible: Bool {
    store.presenter(for: ownershipID)?.isVisible ?? false
  }

  func activate() {
    store.activate(ownershipID)
  }

  func deactivate() {
    store.deactivate(ownershipID)
  }

  func update(
    candidates: [FeatherGeneratedCandidateValue],
    beside anchor: NSRect,
    title: String?
  ) {
    store.update(
      ownershipID,
      candidates: candidates,
      beside: anchor,
      title: title
    )
  }

  func reposition(beside anchor: NSRect) {
    store.presenter(for: ownershipID)?.reposition(beside: anchor)
  }

  func hide() {
    store.hide(ownershipID)
  }
}
