import AppKit
import SwiftUI
import InputCore

@MainActor
final class LLMDebugWindow {
    static let shared = LLMDebugWindow()
    private var window: NSPanel?
    func show() {
        if window == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Feather Input · LLM 调试"
            panel.contentView = NSHostingView(rootView: LLMDebugView())
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.minSize = NSSize(width: 640, height: 400)
            panel.center()
            window = panel
        }
        window?.orderFrontRegardless()
    }
}

private struct LLMDebugView: View {
    @ObservedObject private var log = LLMDebugLog.shared
    @State private var selected: UUID?
    @State private var followLatest = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("调试模式", isOn: $log.enabled)
                Toggle("跟随最新", isOn: $followLatest)
                Spacer()
                Button("清空记录") { log.clear() }
            }
            Text("只记录开启后的请求，最多保留 30 条；Token 已隐藏。关闭调试会清空记录，关闭窗口则继续记录。")
                .font(.footnote).foregroundStyle(.secondary)
            HSplitView {
                List(log.entries, selection: $selected) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.started, style: .time)
                        Text(entry.endpoint).font(.caption)
                        Text(entry.outcome).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(entry.id)
                }.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                ScrollView {
                    if let entry = log.entries.first(where: { $0.id == selected }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.outcome + (entry.milliseconds.map { " · \($0) ms" } ?? ""))
                            Text("发送的请求正文").font(.headline)
                            Text(entry.request).font(.system(.body, design: .monospaced))
                            Divider()
                            Text("服务返回正文").font(.headline)
                            Text(entry.response).font(.system(.body, design: .monospaced))
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } else {
                        Text(log.enabled ? "等待请求。回到输入框输入拼音，或在设置中测试模型。" : "开启调试模式后开始记录。")
                            .foregroundStyle(.secondary).padding()
                    }
                }.frame(minWidth: 350)
            }
        }.padding(16)
            .onReceive(log.$entries) { entries in
                if followLatest || !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
            }
    }
}
