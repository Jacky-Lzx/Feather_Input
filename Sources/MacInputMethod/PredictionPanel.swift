import AppKit
import InputCore

private final class PredictionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Read-only view of the same frozen prediction used to rank the current page.
final class PredictionPanel {
    private let panel = PredictionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let scroll = NSScrollView()
    private let label = NSTextField(labelWithString: "")
    var isVisible: Bool { panel.isVisible }
    var text: String { label.stringValue }
    init() {
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            glass.contentView = scroll
            panel.contentView = glass
        } else {
            let glass = NSVisualEffectView()
            glass.material = .popover
            glass.state = .active
            glass.addSubview(scroll)
            panel.contentView = glass
        }
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("本轮 LLM top-k 预测，只读")
    }
    func contains(_ point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }
    func hide() { panel.orderOut(nil) }
    func show(_ tokens: [LocalRecommendation.RankedToken], delayMS: Int? = nil, beside anchor: NSRect, visible: NSRect) {
        guard !tokens.isEmpty else { hide(); return }
        let rows = tokens.sorted { $0.rank < $1.rank }.map {
            "#\($0.rank)  " + $0.text.replacingOccurrences(of: " ", with: "␠")
                .replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
        }
        let delay = delayMS.map { "延迟 \($0) ms（请求往返）" } ?? "延迟 —"
        let lines = ["LLM top-k · 本轮预测", delay, ""] + rows
        label.stringValue = lines.joined(separator: "\n")
        let width: CGFloat = min(300, max(190, lines.map { ($0 as NSString).size(withAttributes: [.font: label.font!]).width + 36 }.max() ?? 190))
        let height = CGFloat(lines.count) * 18 + 24
        let frame = CandidateGeometry.companionFrame(size: NSSize(width: width, height: height), anchor: anchor, visible: visible)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: height))
        label.frame = NSRect(x: 12, y: 12, width: max(1, frame.width - 36), height: height - 24)
        document.addSubview(label)
        scroll.documentView = document
        panel.setFrame(frame, display: false)
        scroll.frame = NSRect(origin: .zero, size: frame.size)
        document.scrollToVisible(NSRect(x: 0, y: height - 1, width: 1, height: 1))
        panel.orderFrontRegardless()
    }
}
