import AppKit
import InputCore

private final class CandidateWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CandidateButton: NSButton {
    var isCurrentCandidate = false
    var isRecommended = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if isCurrentCandidate || isHighlighted {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title + (isRecommended ? " ✦" : ""), attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 17),
            .foregroundColor: isCurrentCandidate || isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        let height = text.size().height
        text.draw(in: NSRect(x: 10, y: (bounds.height - height) / 2, width: max(0, bounds.width - 20), height: height))
    }
}

final class CandidatePanel {
    private let panel: CandidateWindow
    private let background: NSView
    private let scroll = NSScrollView()
    private let predictions = PredictionPanel()
    private var selection: ((Int) -> Void)?
    private var buttons: [CandidateButton] = []
    init() {
        panel = CandidateWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            // Content must be inside the glass so AppKit can adapt its appearance.
            glass.contentView = scroll
            background = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.state = .active
            material.blendingMode = .behindWindow
            material.wantsLayer = true
            material.layer?.cornerRadius = 16
            material.layer?.masksToBounds = true
            material.addSubview(scroll)
            background = material
        }
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        panel.contentView = background
    }
    var recommendedIndex: Int? { buttons.firstIndex(where: { $0.isRecommended }) }
    func markRecommendation(_ index: Int?) {
        for (i, button) in buttons.enumerated() {
            button.isRecommended = index == i
            button.needsDisplay = true
            button.setAccessibilityHelp(index == i ? "本地 AI 推荐，按原编号或点击选词" : nil)
        }
    }
    func contains(_ point: NSPoint) -> Bool { (panel.isVisible && panel.frame.contains(point)) || predictions.contains(point) }
    func hide() { panel.orderOut(nil); predictions.hide(); selection = nil }
    @objc private func choose(_ sender: NSButton) { selection?(sender.tag) }
    func showExpanded(texts: [String], highlight: Int, caret: NSRect, rows: Int, loading: Bool, onSelect: @escaping (Int) -> Void) {
        guard !texts.isEmpty else { return }
        predictions.hide()
        selection = onSelect
        let visible = (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let font = NSFont.systemFont(ofSize: 17)
        let labels = texts.enumerated().map { "\($0.offset + 1)  \($0.element)" }
        let width = min(260, max(120, labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 24 }.max() ?? 120))
        let rowHeight: CGFloat = min(34, max(18, (visible.height - 60) / CGFloat(rows)))
        let height = CGFloat(rows) * rowHeight + 44
        let columns = (texts.count + rows - 1) / rows
        let viewportWidth = min(visible.width, min(900, CGFloat(columns) * width + 16))
        let frame = CandidateGeometry.frame(size: NSSize(width: viewportWidth, height: height), caret: caret, visible: visible)
        panel.setFrame(frame, display: false)
        background.frame = NSRect(origin: .zero, size: frame.size)
        scroll.frame = background.bounds
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: max(viewportWidth, CGFloat(columns) * width + 16), height: height - 16))
        let title = NSTextField(labelWithString: "全部候选 · Rime 顺序 · \(texts.count) 个\(loading ? " · 加载中" : "") · ←→ 切列 / ↑↓ 选词 / 空格或回车确认 / Esc 收起")
        title.font = .systemFont(ofSize: 11)
        title.frame = NSRect(x: 8, y: height - 38, width: document.frame.width - 16, height: 18)
        document.addSubview(title)
        let columnHighlight = NSView(frame: NSRect(x: 8 + CGFloat(highlight / rows) * width, y: 2, width: width - 4, height: CGFloat(rows) * rowHeight))
        columnHighlight.wantsLayer = true
        columnHighlight.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        columnHighlight.layer?.cornerRadius = 8
        document.addSubview(columnHighlight)
        buttons.removeAll()
        for (i, label) in labels.enumerated() {
            let button = CandidateButton(frame: NSRect(x: 8 + CGFloat(i / rows) * width, y: height - 40 - CGFloat(i % rows + 1) * rowHeight, width: width - 4, height: rowHeight - 2))
            button.title = label; button.toolTip = texts[i]; button.font = font; button.isBordered = false
            button.tag = i; button.target = self; button.action = #selector(choose(_:))
            button.isCurrentCandidate = i == highlight
            buttons.append(button); document.addSubview(button)
        }
        scroll.documentView = document
        if buttons.indices.contains(highlight) { document.scrollToVisible(buttons[highlight].frame) }
        panel.orderFrontRegardless()
    }
    func show(texts: [String], highlight: Int, caret: NSRect, continuation: Bool = false, llmTokens: [LocalRecommendation.RankedToken] = [], llmDelayMS: Int? = nil, llmTitle: String = "LLM top-k · 本轮预测", onSelect: ((Int) -> Void)? = nil) {
        scroll.hasHorizontalScroller = false
        guard !texts.isEmpty else { hide(); return }
        selection = onSelect
        let anchor = NSRect(x: caret.minX, y: caret.minY, width: max(1, caret.width), height: max(1, caret.height))
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let configuredSize = UserDefaults.standard.double(forKey: "candidateFontSize")
        let fontSize = configuredSize == 0 ? 17 : min(24, max(14, configuredSize))
        let font = NSFont.systemFont(ofSize: fontSize)
        let labels = texts.enumerated().map { index, text in
            continuation ? "AI · " + text.replacingOccurrences(of: " ", with: "␠") : "\(index + 1)  \(text)"
        }
        let recommendationSpace: CGFloat = UserDefaults.standard.bool(forKey: "aiRecommendationEnabled") ? 26 : 0
        let widths = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 20 + recommendationSpace }
        let pad: CGFloat = 8, gap: CGFloat = 4, rowHeight = ceil(fontSize * 1.4) + 12
        let horizontalWidth = widths.reduce(0, +) + gap * CGFloat(texts.count - 1) + pad * 2
        let horizontal = UserDefaults.standard.string(forKey: "candidateLayout") == "horizontal" && horizontalWidth <= visible.width
        let needsScroll = !horizontal && rowHeight * CGFloat(texts.count) + gap * CGFloat(texts.count - 1) + pad * 2 > visible.height
        let scrollerWidth: CGFloat = needsScroll ? 16 : 0
        let itemWidth = min(widths.max() ?? 100, max(1, visible.width - pad * 2 - scrollerWidth))
        let naturalSize = NSSize(width: horizontal ? horizontalWidth : itemWidth + pad * 2 + scrollerWidth,
                                 height: horizontal ? rowHeight + pad * 2 : rowHeight * CGFloat(texts.count) + gap * CGFloat(texts.count - 1) + pad * 2)
        let frame = CandidateGeometry.frame(size: naturalSize, caret: anchor, visible: visible)
        let document = NSView(frame: NSRect(origin: .zero, size: NSSize(width: naturalSize.width - scrollerWidth, height: naturalSize.height)))
        buttons.removeAll()
        var x = pad
        for (index, label) in labels.enumerated() {
            let button = CandidateButton(title: label, target: self, action: #selector(choose(_:)))
            button.isBordered = false
            button.font = font
            button.isCurrentCandidate = index == highlight
            button.tag = index
            button.toolTip = label
            button.setAccessibilityLabel(continuation ? "AI 续写：" + texts[index] + "，点击插入" : "候选 \(index + 1)：\(label)")
            button.frame = NSRect(x: horizontal ? x : pad,
                                  y: naturalSize.height - pad - rowHeight - (horizontal ? 0 : CGFloat(index) * (rowHeight + gap)),
                                  width: horizontal ? widths[index] : itemWidth, height: rowHeight)
            x += widths[index] + gap
            document.addSubview(button)
            buttons.append(button)
        }
        panel.setFrame(frame, display: false)
        scroll.frame = NSRect(origin: .zero, size: frame.size)
        scroll.hasVerticalScroller = needsScroll
        scroll.documentView = document
        let visibleIndex = buttons.indices.contains(highlight) ? highlight : 0
        document.scrollToVisible(buttons[visibleIndex].frame)
        background.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        predictions.show(llmTokens, delayMS: llmDelayMS, title: llmTitle, beside: frame, visible: visible)
    }

    static func verifyPresentation() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "candidateLayout")
        defer {
            if let previous { defaults.set(previous, forKey: "candidateLayout") }
            else { defaults.removeObject(forKey: "candidateLayout") }
        }
        for layout in ["vertical", "horizontal"] {
            defaults.set(layout, forKey: "candidateLayout")
            let candidatePanel = CandidatePanel()
            candidatePanel.panel.appearance = NSAppearance(named: layout == "vertical" ? .aqua : .darkAqua)
            var chosen: Int?
            candidatePanel.show(texts: ["你好", "拟好", "你", "呢", "泥"], highlight: 0,
                                caret: NSRect(x: 300, y: 400, width: 1, height: 20), llmTokens: [.init(text: "你", rank: 8), .init(text: "你好", rank: 3)], llmDelayMS: 42) { chosen = $0 }
            guard candidatePanel.predictions.isVisible,
                  candidatePanel.predictions.text == "LLM top-k · 本轮预测\n延迟 42 ms（请求往返）\n\n#3  你好\n#8  你",
                  candidatePanel.buttons[0].title == "1  你好",
                  candidatePanel.buttons[1].title == "2  拟好" else { throw Engine.Failure.schemaUnavailable }
            if #available(macOS 26.0, *) {
                guard let glass = candidatePanel.background as? NSGlassEffectView,
                      glass.style == .regular, glass.contentView === candidatePanel.scroll,
                      glass.cornerRadius == 16 else { throw Engine.Failure.schemaUnavailable }
            }
            guard candidatePanel.verifyClick(on: 1), chosen == 1,
                  let bitmap = candidatePanel.background.bitmapImageRepForCachingDisplay(in: candidatePanel.background.bounds) else {
                throw Engine.Failure.schemaUnavailable
            }
            candidatePanel.background.cacheDisplay(in: candidatePanel.background.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FeatherInput-candidates-\(layout).png"))
            }
            candidatePanel.hide()
            guard !candidatePanel.predictions.isVisible else { throw Engine.Failure.schemaUnavailable }
            chosen = nil
            _ = candidatePanel.verifyClick(on: 0)
            guard chosen == nil else { throw Engine.Failure.schemaUnavailable }
            let all = (0..<19).map { "候选\($0)" }
            candidatePanel.showExpanded(texts: all, highlight: 9, caret: NSRect(x: 300, y: 400, width: 1, height: 20), rows: 8, loading: false) { chosen = $0 }
            guard candidatePanel.buttons.count == 19, candidatePanel.buttons[9].isCurrentCandidate,
                  candidatePanel.buttons[0].frame.minX < candidatePanel.buttons[8].frame.minX,
                  candidatePanel.buttons[8].frame.minY > candidatePanel.buttons[9].frame.minY,
                  !candidatePanel.panel.canBecomeKey, candidatePanel.verifyClick(on: 18), chosen == 18 else { throw Engine.Failure.schemaUnavailable }
            candidatePanel.hide()
        }
        print("PASS: native candidate buttons, horizontal/vertical presentation, non-key window and hidden callback invalidation")
    }

    func verifyClick(on index: Int) -> Bool {
        guard buttons.indices.contains(index), !panel.canBecomeKey, !panel.canBecomeMain else { return false }
        buttons[index].performClick(nil)
        return true
    }
}
