// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "VoiceInput", targets: ["VoiceInput"])],
    targets: [
        .systemLibrary(name: "NativeAudio", path: "NativeAudio"),
        .executableTarget(name: "VoiceInput", dependencies: ["NativeAudio"], resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.unsafeFlags(["-L", root + "/.native", "-Xlinker", "-rpath", "-Xlinker", root + "/.native"])]),
        .testTarget(name: "VoiceInputTests", dependencies: ["VoiceInput"])
    ]
)
