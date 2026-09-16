import AppKit
import InputCore

/// Process-wide input UI. InputMethodKit keeps one controller per client, so
/// putting NSPanels directly on a controller multiplies hidden WindowServer
/// windows as applications create text-input sessions.
final class InputOverlays {
    enum CandidateRole { case primary, generated }

    static let shared = InputOverlays()

    private let primary = CandidatePanel()
    private let generated = CandidatePanel()
    private let mode = ModeIndicator()
    private weak var owner: AnyObject?

    private init() {}

    func activate(_ controller: AnyObject) {
        guard owner !== controller else { return }
        hideAll()
        owner = controller
    }

    func deactivate(_ controller: AnyObject) {
        guard owner === controller else { return }
        hideAll()
        owner = nil
    }

    func owns(_ controller: AnyObject) -> Bool { owner === controller }

    fileprivate func candidate(_ role: CandidateRole, for controller: AnyObject) -> CandidatePanel? {
        guard owns(controller) else { return nil }
        return role == .primary ? primary : generated
    }

    fileprivate func mode(for controller: AnyObject) -> ModeIndicator? {
        owns(controller) ? mode : nil
    }

    private func hideAll() {
        primary.hide()
        generated.hide()
        mode.hide()
    }
}

/// Controller-local handle that cannot mutate another active client's panels.
final class OwnedCandidatePanel {
    private weak var owner: AnyObject?
    private let role: InputOverlays.CandidateRole

    init(owner: AnyObject, role: InputOverlays.CandidateRole) {
        self.owner = owner
        self.role = role
    }

    private var panel: CandidatePanel? {
        guard let owner else { return nil }
        return InputOverlays.shared.candidate(role, for: owner)
    }

    var compositionText: String { panel?.compositionText ?? "" }
    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: NSRect { panel?.frame ?? .zero }
    var companionAnchor: NSRect { panel?.companionAnchor ?? .zero }
    var recommendedIndex: Int? { panel?.recommendedIndex }

    func markRecommendation(_ index: Int?) { panel?.markRecommendation(index) }
    func contains(_ point: NSPoint) -> Bool { panel?.contains(point) ?? false }
    func hide() { panel?.hide() }
    func verifyClick(on index: Int) -> Bool { panel?.verifyClick(on: index) ?? false }

    func showExpanded(texts: [String], highlight: Int, caret: NSRect, rows: Int, loading: Bool,
                      clientLevel: Int = 0, onSelect: @escaping (Int) -> Void) {
        panel?.showExpanded(texts: texts, highlight: highlight, caret: caret, rows: rows,
                            loading: loading, clientLevel: clientLevel, onSelect: onSelect)
    }

    func show(texts: [String], highlight: Int, composition: String = "", cursor: Int = 0,
              caret: NSRect, clientLevel: Int = 0, beside: NSRect? = nil,
              continuation: Bool = false, optionNumbers: Bool = false,
              llmTokens: [LocalRecommendation.RankedToken] = [], llmDelayMS: Int? = nil,
              llmTitle: String = "LLM top-k · 本轮预测", onSelect: ((Int) -> Void)? = nil) {
        panel?.show(texts: texts, highlight: highlight, composition: composition, cursor: cursor,
                    caret: caret, clientLevel: clientLevel, beside: beside,
                    continuation: continuation, optionNumbers: optionNumbers,
                    llmTokens: llmTokens, llmDelayMS: llmDelayMS, llmTitle: llmTitle,
                    onSelect: onSelect)
    }
}

/// Controller-local handle for the one shared transient mode indicator.
final class OwnedModeIndicator {
    private weak var owner: AnyObject?

    init(owner: AnyObject) { self.owner = owner }

    private var indicator: ModeIndicator? {
        guard let owner else { return nil }
        return InputOverlays.shared.mode(for: owner)
    }

    var waitsForInput: Bool { indicator?.waitsForInput ?? false }
    var text: String { indicator?.text ?? "" }
    var isVisible: Bool { indicator?.isVisible ?? false }

    func show(ascii: Bool, caret: NSRect, clientLevel: Int = 0,
              untilInput: Bool = false, duration: TimeInterval = 0.8) {
        indicator?.show(ascii: ascii, caret: caret, clientLevel: clientLevel,
                        untilInput: untilInput, duration: duration)
    }

    func hide() { indicator?.hide() }
}
