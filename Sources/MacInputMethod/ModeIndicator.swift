import AppKit
import InputCore

private final class ModeIndicatorWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A brief, noninteractive label anchored to the text insertion point.
final class ModeIndicator {
    private let panel: ModeIndicatorWindow
    private let label = NSTextField(labelWithString: "")
    private var dismissTimer: Timer?
    private(set) var waitsForInput = false
    var text: String { label.stringValue }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = ModeIndicatorWindow(contentRect: NSRect(x: 0, y: 0, width: 66, height: 32),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 66, height: 32))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 8, width: 50, height: 17)
        background.addSubview(label)
        panel.contentView = background
    }
    deinit { dismissTimer?.invalidate() }

    func show(ascii: Bool, caret: NSRect, clientLevel: Int = 0, untilInput: Bool = false, duration: TimeInterval = 0.8) {
        hide()
        label.stringValue = ascii ? "英文" : "中文"
        let anchor = NSRect(x: caret.minX, y: caret.minY, width: max(1, caret.width), height: max(1, caret.height))
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, clientLevel + 1))
        panel.setFrame(CandidateGeometry.frame(size: NSSize(width: 66, height: 32), caret: anchor, visible: visible), display: true)
        panel.orderFrontRegardless()
        waitsForInput = untilInput
        guard !untilInput else { return }
        let timer = Timer(timeInterval: max(0.1, min(5.0, duration.isFinite ? duration : 0.8)), repeats: false) { [weak self] _ in self?.hide() }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func hide() {
        waitsForInput = false
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel.orderOut(nil)
    }
}
