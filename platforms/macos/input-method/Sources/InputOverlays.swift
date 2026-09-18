import AppKit

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
  static let shared = GeneratedCandidateOverlayStore(presenter: CandidateWindowController())

  private let presenter: GeneratedCandidatePresenting
  private var ownerID: UUID?

  init(presenter: GeneratedCandidatePresenting) {
    self.presenter = presenter
  }

  func activate(_ id: UUID) {
    guard ownerID != id else { return }
    presenter.generatedActionHandler = nil
    presenter.hide()
    ownerID = id
  }

  func deactivate(_ id: UUID) {
    guard ownerID == id else { return }
    presenter.generatedActionHandler = nil
    presenter.hide()
    ownerID = nil
  }

  func presenter(for id: UUID) -> GeneratedCandidatePresenting? {
    ownerID == id ? presenter : nil
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

  func update(candidates: [FeatherGeneratedCandidateValue], beside anchor: NSRect) {
    store.presenter(for: ownershipID)?.update(candidates: candidates, beside: anchor)
  }

  func reposition(beside anchor: NSRect) {
    store.presenter(for: ownershipID)?.reposition(beside: anchor)
  }

  func hide() {
    store.presenter(for: ownershipID)?.hide()
  }
}
