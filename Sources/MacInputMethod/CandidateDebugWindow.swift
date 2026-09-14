import AppKit
import SwiftUI
import InputCore

@MainActor
final class CandidateDebugWindow: ObservableObject {
    static let shared = CandidateDebugWindow()
    @Published var enabled = false { didSet { if !enabled { clear() } } }
    @Published var paused = false
    @Published private(set) var preedit = ""
    @Published private(set) var rime: [String] = []
    @Published private(set) var llm: [String] = []
    @Published private(set) var final: [String] = []
    @Published private(set) var detail = "等待新的拼音候选"
    private var panel: NSPanel?

    func clear() {
        preedit = ""; rime = []; llm = []; final = []; detail = "等待新的拼音候选"
    }
    func update(preedit: String, rime: [String], predictions: [LocalRecommendation.RankedToken], final: [String], scoring: Bool, delay: Int?) {
        guard enabled, !paused else { return }
        self.preedit = preedit
        self.rime = rime.enumerated().map { "#\($0.offset + 1)  \($0.element)" }
        func score(_ value: Double?) -> String { value.map { String(format: "  · %.4f", $0) } ?? "" }
        if scoring {
            let model = predictions.filter { $0.modelScore != nil }.sorted {
                if $0.modelScore != $1.modelScore { return $0.modelScore! > $1.modelScore! }
                return (rime.firstIndex(of: $0.text) ?? Int.max) < (rime.firstIndex(of: $1.text) ?? Int.max)
            }
            self.llm = model.enumerated().map { "#\($0.offset + 1)  \($0.element.text)" + score($0.element.modelScore) }
        } else {
            self.llm = predictions.sorted { $0.rank < $1.rank }.map { "#\($0.rank)  \($0.text.replacingOccurrences(of: " ", with: "␠"))" }
        }
        self.final = final.enumerated().map { row in
            "#\(row.offset + 1)  \(row.element)" + score(predictions.first { $0.text == row.element }?.fusionScore)
        }
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        detail = "\(time) · 最近一次快照 · " + (scoring ? "LLM 列为候选纯模型分数；最终列为融合结果" : "LLM 列为冻结的 next-token top-k")
        if let delay { detail += " · \(delay) ms" }
        if predictions.isEmpty { detail += " · 暂无已采用的模型结果，保留 Rime 顺序" }
    }
    static func verify() throws {
        let log = CandidateDebugWindow()
        log.enabled = true
        let predictions: [LocalRecommendation.RankedToken] = [
            .init(text: "环境", rank: 1, modelScore: -3, fusionScore: -1),
            .init(text: "幻境", rank: 2, modelScore: -1, fusionScore: -2)]
        log.update(preedit: "huanjing", rime: ["环境", "幻境"], predictions: predictions,
                   final: ["环境", "幻境"], scoring: true, delay: 42)
        guard log.rime[0] == "#1  环境", log.llm[0] == "#1  幻境  · -1.0000",
              log.final[0] == "#1  环境  · -1.0000", log.detail.contains("42 ms") else { throw Engine.Failure.schemaUnavailable }
        log.paused = true
        log.update(preedit: "ni", rime: ["你"], predictions: [], final: ["你"], scoring: false, delay: nil)
        guard log.preedit == "huanjing" else { throw Engine.Failure.schemaUnavailable }
        log.enabled = false
        guard log.rime.isEmpty, log.llm.isEmpty, log.final.isEmpty else { throw Engine.Failure.schemaUnavailable }
        print("PASS: candidate debug separates Rime, pure model and fusion ranks; pause and clear")
    }
    func show() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 480),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Feather Input · 候选对比调试"
            window.contentView = NSHostingView(rootView: CandidateDebugView(log: self))
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.minSize = NSSize(width: 720, height: 320)
            window.center()
            panel = window
        }
        enabled = true
        panel?.orderFrontRegardless()
    }
}

private struct CandidateDebugView: View {
    @ObservedObject var log: CandidateDebugWindow
    private func column(_ title: String, rows: [String]) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if rows.isEmpty { Text("暂无结果").foregroundStyle(.secondary) }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("记录候选", isOn: $log.enabled)
                Toggle("暂停更新", isOn: $log.paused)
                Spacer()
                Button("清空") { log.clear() }
            }
            Text("拼音：\(log.preedit.isEmpty ? "—" : log.preedit)").font(.headline)
            Text(log.detail).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                column("Rime · 原始排名", rows: log.rime)
                Divider()
                column("LLM · 模型排名", rows: log.llm)
                Divider()
                column("最终候选 · 显示顺序", rows: log.final)
            }
            Text("仅保留内存中的最近快照；关闭记录会清空，关闭窗口仍继续记录。只显示当前模式已采用的结果，不额外调用后端。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }
}
