// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "VoiceInput", targets: ["VoiceInput"])],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1")],
    targets: [
        .executableTarget(name: "VoiceInput", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")], resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "VoiceInputTests", dependencies: ["VoiceInput"])
    ]
)
