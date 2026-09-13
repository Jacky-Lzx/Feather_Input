import AppKit
import SwiftUI
import InputCore

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 310),
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
    var body: some View {
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
            Text("词库和学习记录保存在本机。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380)
    }
}
