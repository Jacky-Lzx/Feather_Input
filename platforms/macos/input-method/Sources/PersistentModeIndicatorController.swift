import AppKit
import Carbon
import CoreGraphics

@MainActor
protocol PersistentModeIndicatorPresenting: AnyObject {
  var isVisible: Bool { get }
  func show(directMode: Bool)
  func hide()
}

@MainActor
private final class PersistentModeIndicatorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class PersistentModeIndicatorController: PersistentModeIndicatorPresenting {
  private static let panelSize = NSSize(width: 34, height: 34)
  private let settings: PersistentModeIndicatorSettings
  private let inputSourceIsSelected: @MainActor () -> Bool
  private let panel: PersistentModeIndicatorPanel
  private let label = NSTextField(labelWithString: "")
  private var requestedVisible = false
  private var directMode = false
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var inputSourceObserver: NSObjectProtocol?

  var isVisible: Bool { panel.isVisible }

  init(
    settings: PersistentModeIndicatorSettings = .shared,
    inputSourceIsSelected: @escaping @MainActor () -> Bool = PersistentModeIndicatorController
      .currentInputSourceIsFeather
  ) {
    self.settings = settings
    self.inputSourceIsSelected = inputSourceIsSelected
    panel = PersistentModeIndicatorPanel(
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
    panel.level = .popUpMenu
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

    let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
    background.material = .popover
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 8
    background.layer?.masksToBounds = true
    label.font = .systemFont(ofSize: 17, weight: .semibold)
    label.textColor = .labelColor
    label.alignment = .center
    label.frame = NSRect(x: 3, y: 6, width: 28, height: 22)
    background.addSubview(label)
    panel.contentView = background

    func observe(_ center: NotificationCenter, _ name: Notification.Name) {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      observers.append((center, observer))
    }
    observe(.default, NSApplication.didChangeScreenParametersNotification)
    observe(.default, .persistentModeIndicatorSettingsDidChange)
    observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
    inputSourceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  deinit {
    for (center, observer) in observers {
      center.removeObserver(observer)
    }
    if let inputSourceObserver {
      DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
    }
  }

  func show(directMode: Bool) {
    self.directMode = directMode
    requestedVisible = true
    refresh()
  }

  func hide() {
    requestedVisible = false
    panel.orderOut(nil)
  }

  private func refresh() {
    guard requestedVisible, settings.isEnabled, inputSourceIsSelected(),
      let screen = primaryScreen()
    else {
      panel.orderOut(nil)
      return
    }
    label.stringValue = directMode ? "英" : "中"
    label.setAccessibilityLabel(directMode ? "英文输入" : "中文输入")
    panel.setFrameOrigin(NSPoint(x: screen.frame.minX + 12, y: screen.frame.minY + 40))
    panel.orderFrontRegardless()
  }

  private func primaryScreen() -> NSScreen? {
    let primaryID = CGMainDisplayID()
    return NSScreen.screens.first { screen in
      let key = NSDeviceDescriptionKey("NSScreenNumber")
      return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == primaryID
    }
  }

  private static func currentInputSourceIsFeather() -> Bool {
    guard
      let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return false }
    let currentID = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    var acceptedIDs = Set<String>()
    if let baseID = Bundle.main.object(forInfoDictionaryKey: "TISInputSourceID") as? String {
      acceptedIDs.insert(baseID)
    }
    if let component = Bundle.main.object(forInfoDictionaryKey: "ComponentInputModeDict")
      as? [String: Any],
      let modes = component["tsInputModeListKey"] as? [String: Any]
    {
      acceptedIDs.formUnion(modes.keys)
    }
    return acceptedIDs.contains(currentID)
  }
}

@MainActor
final class PersistentModeIndicatorOverlayStore {
  static let shared = PersistentModeIndicatorOverlayStore(
    presenter: PersistentModeIndicatorController()
  )

  private let presenter: PersistentModeIndicatorPresenting
  private var ownerID: UUID?

  init(presenter: PersistentModeIndicatorPresenting) {
    self.presenter = presenter
  }

  func activate(_ id: UUID) {
    guard ownerID != id else { return }
    ownerID = id
  }

  func deactivate(_ id: UUID) {
    guard ownerID == id else { return }
    ownerID = nil
  }

  func presenter(for id: UUID) -> PersistentModeIndicatorPresenting? {
    ownerID == id ? presenter : nil
  }
}

@MainActor
final class OwnedPersistentModeIndicatorPresenter: PersistentModeIndicatorPresenting {
  private let ownershipID = UUID()
  private let store: PersistentModeIndicatorOverlayStore

  init() {
    store = PersistentModeIndicatorOverlayStore.shared
  }

  init(store: PersistentModeIndicatorOverlayStore) {
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

  func show(directMode: Bool) {
    store.presenter(for: ownershipID)?.show(directMode: directMode)
  }

  func hide() {
    store.presenter(for: ownershipID)?.hide()
  }
}
