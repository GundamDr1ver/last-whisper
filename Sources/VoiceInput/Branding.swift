import AppKit

@MainActor
enum QingyuBrand {
    static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let wings = NSBezierPath()
            wings.lineWidth = 1.65
            wings.lineCapStyle = .round
            wings.lineJoinStyle = .round
            wings.move(to: NSPoint(x: 3, y: 11))
            wings.curve(to: NSPoint(x: 7, y: 18), controlPoint1: NSPoint(x: 0.5, y: 16), controlPoint2: NSPoint(x: 3.5, y: 19))
            wings.curve(to: NSPoint(x: 10, y: 10), controlPoint1: NSPoint(x: 13, y: 18), controlPoint2: NSPoint(x: 13, y: 13))
            wings.curve(to: NSPoint(x: 17, y: 7), controlPoint1: NSPoint(x: 14, y: 13), controlPoint2: NSPoint(x: 19, y: 12))
            wings.curve(to: NSPoint(x: 10, y: 2), controlPoint1: NSPoint(x: 19, y: 2), controlPoint2: NSPoint(x: 13, y: 0))
            wings.stroke()
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.65
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 3, y: 3))
            arrow.line(to: NSPoint(x: 17, y: 17))
            arrow.move(to: NSPoint(x: 12.5, y: 16.5))
            arrow.line(to: NSPoint(x: 17, y: 17))
            arrow.line(to: NSPoint(x: 16.5, y: 12.5))
            arrow.move(to: NSPoint(x: 3, y: 6))
            arrow.line(to: NSPoint(x: 3, y: 3))
            arrow.line(to: NSPoint(x: 6, y: 3))
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
