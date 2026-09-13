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
    @AppStorage("candidateLayout") private var layout = "vertical"
    @AppStorage("showPersistentMode") private var showPersistentMode = true
    @AppStorage("aiRecommendationEnabled") private var aiEnabled = false
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
                HStack {
                    Text("候选字号")
                    Slider(value: $fontSize, in: 14...24, step: 1)
                    Text("\(Int(fontSize))").monospacedDigit()
                }
                Text("Caps Lock 或单按右 Control 切换中英文\n点击或数字键选词 · 空格上屏 · Page Up / Down 翻页")
                    .font(.footnote).foregroundStyle(.secondary)
                Divider()
                Toggle("启用本地 AI 候选推荐", isOn: $aiEnabled)
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
