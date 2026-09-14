import AppKit
import SwiftUI
import InputCore

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Feather Input 设置"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @AppStorage("scheme") private var scheme = InputScheme.full.rawValue
    @AppStorage("candidateFontSize") private var fontSize = 17.0
    @AppStorage("candidateCount") private var candidateCount = 5
    @AppStorage("aiCandidateCount") private var aiCandidateCount = 5
    @AppStorage("candidateLayout") private var layout = "vertical"
    @AppStorage("showPersistentMode") private var showPersistentMode = true
    @AppStorage("aiFusionWeight") private var fusionWeight = 0.35
    @AppStorage("aiScoreNormalization") private var scoreNormalization = "character"
    @AppStorage("aiPinyinGenerationEnabled") private var pinyinGenerationEnabled = true
    @AppStorage("aiCandidateScoringEnabled") private var scoringEnabled = false
    @AppStorage("aiRerankingEnabled") private var rerankingEnabled = false
    @AppStorage("aiRecommendationEnabled") private var aiEnabled = false
    @AppStorage("aiContinuationEnabled") private var continuationEnabled = false
    @AppStorage("aiContinuationBackend") private var continuationBackend = "lmstudio"
    @AppStorage("aiModel") private var model = ""
    @ObservedObject private var debugLog = LLMDebugLog.shared
    @State private var token = ""
    @State private var status = ""
    @State private var models: [String] = []
    @State private var testing = false
    var body: some View {
        ScrollView {
            Form {
                Picker("输入方案", selection: $scheme) {
                    ForEach(InputScheme.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Toggle("屏幕左下角常驻显示中／英", isOn: $showPersistentMode)
                Picker("候选排列", selection: $layout) {
                    Text("竖排").tag("vertical")
                    Text("横排").tag("horizontal")
                }
                Stepper("拼音每页候选：\(candidateCount)", value: $candidateCount, in: 1...9)
                Text("完成当前拼音后生效，无需重启。").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Text("候选字号")
                    Slider(value: $fontSize, in: 14...24, step: 1)
                    Text("\(Int(fontSize))").monospacedDigit()
                }
                Text("Caps Lock 或单按右 Control 切换中英文\n点击或数字键选词 · 空格上屏 · Page Up / Down 翻页")
                    .font(.footnote).foregroundStyle(.secondary)
                Divider()
                Toggle("根据上下文和拼音生成新词（实验）", isOn: $pinyinGenerationEnabled)
                Text("完整输入 2–6 个音节后，侧边显示最多 3 个 AI 建议，点击上屏。支持全拼、小鹤双拼；不占用原候选数字键。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("用 MLX 给当前拼音候选打分", isOn: $scoringEnabled)
                HStack {
                    Text("LLM 排序权重")
                    Slider(value: $fusionWeight, in: 0...1, step: 0.05)
                    Text("\(Int((fusionWeight * 100).rounded()))%")
                }
                Text("0% 保留 Rime 顺序，100% 只看模型评分；默认 35%。").font(.footnote).foregroundStyle(.secondary)
                Picker("候选长度处理", selection: $scoreNormalization) {
                    Text("按字符平均").tag("character")
                    Text("按 token 平均").tag("token")
                    Text("不归一化").tag("none")
                }
                Text("优先使用此模式：默认停顿 120 ms 后给当前页 Rime 候选评分，支持多 token 词。默认 700 ms 内返回才更新；可在候选对比调试面板调整。继续输入或选择会取消旧请求。侧窗名次是候选评分排名。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("用 MLX 下一 token 给拼音候选排序", isOn: $rerankingEnabled)
                Text("上屏后后台预测；下一轮拼音固定使用已缓存结果。当前页精确匹配的候选优先，未匹配项保持原顺序；无结果时沿用 Rime。开启后不显示独立预测窗口。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("启用本地 AI 候选推荐", isOn: $aiEnabled)
                Toggle("上屏后 AI 预测", isOn: $continuationEnabled)
                Picker("续写后端", selection: $continuationBackend) {
                    Text("LM Studio").tag("lmstudio")
                    Text("MLX 下一 token · 本机 1235").tag("mlx")
                }
                Stepper("MLX top-k 数量：\(aiCandidateCount)", value: $aiCandidateCount, in: 1...20)
                Button("测试 MLX 概率候选") {
                    testing = true
                    Task { @MainActor in
                        defer { testing = false }
                        do {
                            let texts = try await LocalRecommendation.mlxContinuations(context: "今天的天气很好，适合")
                            status = "MLX：" + texts.joined(separator: " / ")
                        } catch { status = "MLX 请求失败，请检查 1235 端口后端；详细响应见调试窗口。" }
                    }
                }.disabled(testing)
                Text("上屏后停顿 400 ms。MLX 显示下一 token 的所设数量的高概率候选（含标点）；LM Studio 生成短语。点击插入，继续输入取消。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("LM Studio · 127.0.0.1:1234\n发送本次输入位置最近上屏的最多 80 个字符、拼音及候选。✦ 标记推荐项，原编号和空格行为不变。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("模型 ID", text: $model)
                if !models.isEmpty {
                    Picker("可用模型", selection: $model) {
                        Text("请选择").tag("")
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
                SecureField("API Token", text: $token)
                Text("Token 明文保存在本机配置文件，仅用于本机服务。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("打开 Token 文件所在文件夹") {
                    NSWorkspace.shared.selectFile(ModelCredential.fileURL.path, inFileViewerRootedAtPath: ModelCredential.fileURL.deletingLastPathComponent().path)
                }
                HStack {
                    Button("保存 Token") {
                        do { try ModelCredential.save(token); status = "Token 已保存到本机配置文件。" }
                        catch { status = "Token 保存失败，请检查文件权限，且不要包含换行。" }
                    }
                    Button(testing ? "测试中…" : "连接并测试模型") {
                        testing = true
                        Task { @MainActor in
                            defer { testing = false }
                            do {
                                try ModelCredential.save(token)
                                models = try await LocalRecommendation.models(token: token)
                                guard !models.isEmpty else { status = "服务没有提供模型，请在 LM Studio 中加载模型。"; return }
                                if !models.contains(model) { model = models.first(where: { $0.lowercased().contains("qwen3") && $0.contains("0.6") }) ?? models[0] }
                                let start = Date()
                                let index = try await LocalRecommendation.recommend(model: model, token: token, context: "我们需要保护", preedit: "huanjing", candidates: ["环境", "幻境"])
                                status = "连接成功，样例推荐：\(["环境", "幻境"][index])（\(Int(Date().timeIntervalSince(start) * 1000)) ms）。"
                            } catch { status = (error as? LocalRecommendation.Failure)?.errorDescription ?? "连接或推理失败，请检查本地服务、Token 和模型。" }
                        }
                    }.disabled(testing)
                }
                Toggle("LLM 调试模式（仅内存记录）", isOn: $debugLog.enabled)
                Button("打开 LLM 调试窗口") { LLMDebugWindow.shared.show() }
                Button("打开候选对比调试面板") { CandidateDebugWindow.shared.show() }
                if !status.isEmpty { Text(status).font(.footnote).textSelection(.enabled) }
                Text("词库和学习记录保存在本机。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .onAppear { token = ModelCredential.read() }
            .padding(24)
            .frame(width: 460)
        }
    }
}
