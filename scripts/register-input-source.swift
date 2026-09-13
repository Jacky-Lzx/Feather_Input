import Foundation
import Carbon

func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}
let args = CommandLine.arguments
 guard args.count == 2 else { fail("Usage: register-input-source /path/to/FeatherInput.app") }
let url = URL(fileURLWithPath: args[1]).standardizedFileURL
 guard Bundle(url: url)?.bundleIdentifier == "im.feather.inputmethod.FeatherInput" else { fail("Not a Feather Input bundle") }
let registration = TISRegisterInputSource(url as CFURL)
 guard registration == noErr else { fail("Input source registration failed: \(registration)") }
let filter = [kTISPropertyBundleID as String: "im.feather.inputmethod.FeatherInput"] as CFDictionary
func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}
guard let result = TISCreateInputSourceList(filter, true) else {
    fail("Registration returned success, but macOS cannot enumerate Feather Input. Log out and retry; installation is not yet verified.")
}
let sources = result.takeRetainedValue() as! [TISInputSource]
let selectable = sources.filter { property($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true }
guard !selectable.isEmpty else { fail("No selectable Feather Input mode registered") }
for source in selectable {
    let status = TISEnableInputSource(source)
    guard status == noErr else { fail("Unable to enable input source: \(status)") }
}
guard let enabled = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
      enabled.contains(where: { property($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true && property($0, kTISPropertyInputSourceIsEnabled) as? Bool == true }) else {
    fail("Input source enablement could not be verified")
}
print("Verified: Feather Input is registered, selectable and enabled.")
