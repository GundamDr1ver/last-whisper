import AppKit

@MainActor
enum SpeakeasyBrand {
    static let menuIcon: NSImage = {
        let image = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "svg", subdirectory: "Resources")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "bubble", accessibilityDescription: "speakeasy")!
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true
        return image
    }()
}
