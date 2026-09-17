import AppKit

@MainActor
protocol ModeIndicatorPresenting: AnyObject {
  var isVisible: Bool { get }
  func show(directMode: Bool, anchor: NSRect, clientLevel: Int)
  func hide()
}

@MainActor
private final class ModeIndicatorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class ModeIndicatorController: ModeIndicatorPresenting {
  private static let panelSize = NSSize(width: 56, height: 32)
  private let panel: ModeIndicatorPanel
  private let label = NSTextField(labelWithString: "")
  private var dismissTimer: Timer?

  var isVisible: Bool { panel.isVisible }

  init() {
    panel = ModeIndicatorPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
    background.material = .popover
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 8
    background.layer?.masksToBounds = true
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .labelColor
    label.alignment = .center
    label.frame = NSRect(x: 8, y: 8, width: 40, height: 17)
    background.addSubview(label)
    panel.contentView = background
  }

  deinit {
    dismissTimer?.invalidate()
  }

  func show(directMode: Bool, anchor: NSRect, clientLevel: Int) {
    hide()
    label.stringValue = directMode ? "英文" : "中文"
    let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    let gap = CandidateWindowStyle.panelGap
    var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - gap)
    if origin.y < visibleFrame.minY {
      origin.y = anchor.maxY + gap
    }
    let inset = CandidateWindowStyle.screenInset
    origin.x = min(max(origin.x, visibleFrame.minX + inset), visibleFrame.maxX - size.width - inset)
    origin.y = min(
      max(origin.y, visibleFrame.minY + inset), visibleFrame.maxY - size.height - inset)
    panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, clientLevel + 1))
    panel.setFrameOrigin(origin)
    panel.orderFrontRegardless()

    let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
      Task { @MainActor in
        self?.hide()
      }
    }
    dismissTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func hide() {
    dismissTimer?.invalidate()
    dismissTimer = nil
    panel.orderOut(nil)
  }
}

@MainActor
final class ModeIndicatorOverlayStore {
  static let shared = ModeIndicatorOverlayStore(presenter: ModeIndicatorController())

  private let presenter: ModeIndicatorPresenting
  private var ownerID: UUID?

  init(presenter: ModeIndicatorPresenting) {
    self.presenter = presenter
  }

  func activate(_ id: UUID) {
    guard ownerID != id else { return }
    presenter.hide()
    ownerID = id
  }

  func deactivate(_ id: UUID) {
    guard ownerID == id else { return }
    presenter.hide()
    ownerID = nil
  }

  func presenter(for id: UUID) -> ModeIndicatorPresenting? {
    ownerID == id ? presenter : nil
  }
}

@MainActor
final class OwnedModeIndicatorPresenter: ModeIndicatorPresenting {
  private let ownershipID = UUID()
  private let store: ModeIndicatorOverlayStore

  init() {
    store = ModeIndicatorOverlayStore.shared
  }

  init(store: ModeIndicatorOverlayStore) {
    self.store = store
  }

  deinit {
    let ownershipID = ownershipID
    let store = store
    Task { @MainActor in
      store.deactivate(ownershipID)
    }
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

  func show(directMode: Bool, anchor: NSRect, clientLevel: Int) {
    store.presenter(for: ownershipID)?.show(
      directMode: directMode,
      anchor: anchor,
      clientLevel: clientLevel
    )
  }

  func hide() {
    store.presenter(for: ownershipID)?.hide()
  }
}
