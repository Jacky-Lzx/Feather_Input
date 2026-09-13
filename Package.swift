// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FeatherInput", platforms: [.macOS(.v13)], products: [
    .executable(name: "FeatherInput", targets: ["MacInputMethod"]),
    .executable(name: "EngineCheck", targets: ["EngineCheck"])
], targets: [
    .target(name: "CRime"),
    .target(name: "InputCore", dependencies: ["CRime"]),
    .executableTarget(name: "MacInputMethod", dependencies: ["InputCore"]),
    .executableTarget(name: "EngineCheck", dependencies: ["InputCore"]),
    .testTarget(name: "InputCoreTests", dependencies: ["InputCore"])
])
