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
    presenter.hide()
    ownerID = id
  }

  func deactivate(_ id: UUID) {
    guard ownerID == id else { return }
    presenter.actionHandler = nil
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

  func activate() {
    store.activate(ownershipID)
  }

  func deactivate() {
    store.deactivate(ownershipID)
  }

  func update(
    candidates: [FeatherCandidateValue],
    highlighted: Int?,
    anchor: NSRect
  ) {
    store.presenter(for: ownershipID)?.update(
      candidates: candidates,
      highlighted: highlighted,
      anchor: anchor
    )
  }

  func updateExpanded(
    candidates: [FeatherCandidateValue],
    highlighted: Int,
    rows: Int,
    hasMore: Bool,
    anchor: NSRect
  ) {
    store.presenter(for: ownershipID)?.updateExpanded(
      candidates: candidates,
      highlighted: highlighted,
      rows: rows,
      hasMore: hasMore,
      anchor: anchor
    )
  }

  func hide() {
    store.presenter(for: ownershipID)?.hide()
  }
}
