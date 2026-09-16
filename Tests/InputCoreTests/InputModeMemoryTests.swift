import XCTest
@testable import InputCore

final class InputModeMemoryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "InputModeMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testGlobalModeIsSharedAcrossApplications() {
        let defaults = defaults()
        defaults.set(InputModeMemoryPolicy.global.rawValue, forKey: "inputModeMemoryPolicy")
        let memory = InputModeMemory(defaults: defaults)
        XCTAssertFalse(memory.activate(application: "app.a"))
        memory.update(ascii: true, application: "app.a")
        XCTAssertTrue(memory.activate(application: "app.b"))
    }

    func testPerApplicationModeIsRememberedSeparately() {
        let defaults = defaults()
        defaults.set(InputModeMemoryPolicy.perApplication.rawValue, forKey: "inputModeMemoryPolicy")
        let memory = InputModeMemory(defaults: defaults)
        memory.update(ascii: true, application: "app.a")
        XCTAssertFalse(memory.activate(application: "app.b"))
        XCTAssertTrue(memory.activate(application: "app.a"))
    }

    func testResetPoliciesOnlyResetWhenApplicationChanges() {
        let defaults = defaults()
        defaults.set(InputModeMemoryPolicy.resetToChinese.rawValue, forKey: "inputModeMemoryPolicy")
        let memory = InputModeMemory(defaults: defaults)
        XCTAssertFalse(memory.activate(application: "app.a"))
        memory.update(ascii: true, application: "app.a")
        XCTAssertTrue(memory.activate(application: "app.a"))
        XCTAssertFalse(memory.activate(application: "app.b"))

        defaults.set(InputModeMemoryPolicy.resetToEnglish.rawValue, forKey: "inputModeMemoryPolicy")
        XCTAssertTrue(memory.activate(application: "app.c"))
        memory.update(ascii: false, application: "app.c")
        XCTAssertFalse(memory.activate(application: "app.c"))
        XCTAssertTrue(memory.activate(application: "app.d"))
    }
}
