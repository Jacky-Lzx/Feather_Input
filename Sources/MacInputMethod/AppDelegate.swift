import AppKit
import InputMethodKit
import InputCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var engine: Engine?
    private var server: IMKServer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let resources = Bundle.main.resourcePath else { return }
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        let smokeDefaults = UserDefaults.standard
        let smokeKeys = ["aiPinyinGenerationEnabled", "inputModeMemoryPolicy", "inputModeGlobalASCII", "inputModeByApplication"]
        let savedSmokeDefaults = smokeTest ? smokeKeys.map { ($0, smokeDefaults.object(forKey: $0)) } : []
        let restoreSmokeDefaults = {
            for (key, value) in savedSmokeDefaults {
                if let value { smokeDefaults.set(value, forKey: key) }
                else { smokeDefaults.removeObject(forKey: key) }
            }
        }
        let user = smokeTest ? NSTemporaryDirectory() + "FeatherInput-smoke-" + UUID().uuidString : FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FeatherInput").path
        do {
            Self.engine = try Engine(library: Bundle.main.bundlePath + "/Contents/Frameworks/librime.dylib",
                                     shared: resources + "/rime", user: user)
            let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
            server = IMKServer(name: connection, bundleIdentifier: Bundle.main.bundleIdentifier)
            guard server != nil, NSClassFromString("FeatherInputController") != nil else {
                throw Engine.Failure.schemaUnavailable
            }
            PersistentModeIndicator.shared.refresh()
            if smokeTest {
                smokeDefaults.set(false, forKey: "aiPinyinGenerationEnabled")
                smokeDefaults.set(InputModeMemoryPolicy.global.rawValue, forKey: "inputModeMemoryPolicy")
                smokeDefaults.set(false, forKey: "inputModeGlobalASCII")
                try PersistentModeIndicator.verify()
                try InputController.verifyMenuCommands(server: server!)
                try CandidatePanel.verifyPresentation()
                try CandidateDebugWindow.verify()
                try InputController.verifySecureInput(server: server!)
                try InputController.verifyRepeatedPaging(server: server!)
                try InputController.verifyKeyboardAndClick(server: server!)
                try InputController.verifyCapsLock(server: server!)
                try InputController.verifyRecommendationLifecycle(server: server!)
                try InputController.verifyContinuationLifecycle(server: server!)
                try InputController.verifyRankingLifecycle(server: server!)
                try InputController.verifyScoringLifecycle(server: server!)
                try InputController.verifyGenerationLifecycle(server: server!)
                try InputController.verifyCompositionFallback(server: server!)
                try InputController.verifyFocusIndicator(server: server!)
                try InputController.verifyNoTextField(server: server!)
                let session = try Self.engine!.session(.full)
                for key in "nihao".utf8 { session.process(Int32(key)) }
                guard session.candidates.texts.contains("你好") else { throw Engine.Failure.schemaUnavailable }
                let panel = CandidatePanel()
                panel.show(texts: session.candidates.texts, highlight: 0, caret: NSRect(x: 300, y: 300, width: 1, height: 20))
                panel.hide()
                print("PASS: app startup, IMKServer, controller class, bundled engine, native candidate panel")
                session.clear()
                try? FileManager.default.removeItem(atPath: user)
                restoreSmokeDefaults()
                NSApp.terminate(nil)
            }
        } catch {
            if smokeTest {
                restoreSmokeDefaults()
                fputs("FAIL: app smoke test: \(error)\n", stderr)
                exit(1)
            }
            let alert = NSAlert()
            alert.messageText = "Feather Input 无法启动"
            alert.informativeText = "引擎或词库加载失败：\(error)。请重新运行打包脚本。"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}
