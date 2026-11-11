import AppKit
import CoreGraphics

/// A dot on the screen to look at while calibrating.
final class AimMark {
    private let size = CGSize(width: 220, height: 220)
    private let window: NSWindow

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = AimDot(frame: NSRect(origin: .zero, size: size))
    }

    func show(at cgPoint: CGPoint) {
        window.setFrameOrigin(appKitOrigin(centering: cgPoint))
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    private func appKitOrigin(centering cgPoint: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let appY = primaryHeight - cgPoint.y
        return CGPoint(x: cgPoint.x - size.width / 2, y: appY - size.height / 2)
    }
}

final class AimDot: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 8, dy: 8)).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)).fill()
        let label = "LOOK" as NSString
        let font = NSFont.boldSystemFont(ofSize: 28)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: 28),
            withAttributes: attributes
        )
    }
}
