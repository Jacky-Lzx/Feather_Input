import AppKit

final class CandidatePanel {
    private let panel: NSPanel
    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    func contains(_ point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }
    func hide() { panel.orderOut(nil) }
    func show(texts: [String], highlight: Int, caret: NSRect) {
        guard !texts.isEmpty else { hide(); return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for (index, text) in texts.enumerated() {
            let label = NSTextField(labelWithString: "\(index + 1)  \(text)")
            let configuredSize = UserDefaults.standard.double(forKey: "candidateFontSize")
            label.font = .systemFont(ofSize: configuredSize == 0 ? 17 : min(24, max(14, configuredSize)), weight: index == highlight ? .semibold : .regular)
            label.textColor = index == highlight ? .controlAccentColor : .labelColor
            stack.addArrangedSubview(label)
        }
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
        let size = stack.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(caret.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        var y = caret.minY - size.height - 6
        if y < visible.minY { y = caret.maxY + 6 }
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
    }
}
