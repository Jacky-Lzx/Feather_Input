import AppKit
import Carbon
import InputCore

private final class CornerModeWindow: NSPanel {
    let label = NSTextField(labelWithString: "中")
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 34, height: 34),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
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
        contentView = background
    }
}

/// One shared display state, never one corner window per IMK client session.
final class PersistentModeIndicator {
    static let shared = PersistentModeIndicator()
    private var windows: [CGDirectDisplayID: CornerModeWindow] = [:]
    private var ascii = false
    private let isSelected: () -> Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sourceObserver: NSObjectProtocol?

    private init(isSelected: @escaping () -> Bool = PersistentModeIndicator.featherIsSelected) {
        self.isSelected = isSelected
        func observe(_ center: NotificationCenter, _ name: Notification.Name) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
            observers.append((center, token))
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification)
        observe(.default, UserDefaults.didChangeNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }
    deinit {
        for (center, token) in observers { center.removeObserver(token) }
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        for window in windows.values { window.orderOut(nil) }
    }
    private static func featherIsSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        return id == "im.feather.inputmethod.FeatherInput.Hans"
    }
    func update(ascii: Bool) { self.ascii = ascii; refresh() }
    func refresh() {
        let enabled = UserDefaults.standard.object(forKey: "showPersistentMode") as? Bool ?? true
        guard enabled && isSelected() else {
            for window in windows.values { window.orderOut(nil) }
            return
        }
        var connected = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            connected.insert(id)
            let window = windows[id] ?? CornerModeWindow()
            windows[id] = window
            window.label.stringValue = ascii ? "英" : "中"
            window.label.setAccessibilityLabel(ascii ? "英文输入" : "中文输入")
            // Screen frame intentionally includes the strip beside a left-side Dock.
            window.setFrameOrigin(NSPoint(x: screen.frame.minX + 12, y: screen.frame.minY + 40))
            window.orderFrontRegardless()
        }
        for id in Set(windows.keys).subtracting(connected) { windows.removeValue(forKey: id)?.orderOut(nil) }
    }

    static func verify() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "showPersistentMode")
        defer {
            if let previous { defaults.set(previous, forKey: "showPersistentMode") }
            else { defaults.removeObject(forKey: "showPersistentMode") }
        }
        defaults.set(true, forKey: "showPersistentMode")
        var selected = true
        let indicator = PersistentModeIndicator(isSelected: { selected })
        indicator.update(ascii: false)
        guard !indicator.windows.isEmpty,
              indicator.windows.values.allSatisfy({ $0.isVisible && $0.label.stringValue == "中" && !$0.canBecomeKey && $0.ignoresMouseEvents }) else {
            throw Engine.Failure.schemaUnavailable
        }
        let count = indicator.windows.count
        indicator.update(ascii: true)
        guard indicator.windows.count == count, indicator.windows.values.allSatisfy({ $0.label.stringValue == "英" }) else { throw Engine.Failure.schemaUnavailable }
        if let view = indicator.windows.values.first?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FeatherInput-corner-mode.png"))
        }
        selected = false
        indicator.refresh()
        guard indicator.windows.values.allSatisfy({ !$0.isVisible }) else { throw Engine.Failure.schemaUnavailable }
        selected = true
        defaults.set(false, forKey: "showPersistentMode")
        indicator.refresh()
        guard indicator.windows.values.allSatisfy({ !$0.isVisible }) else { throw Engine.Failure.schemaUnavailable }
        print("PASS: persistent corner mode labels, shared windows, source visibility and settings toggle")
    }
}
