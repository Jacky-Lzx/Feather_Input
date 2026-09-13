import AppKit
import InputMethodKit
import InputCore

if CommandLine.arguments.contains("--smoke-test") { setbuf(stdout, nil) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
