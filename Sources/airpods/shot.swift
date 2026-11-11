import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

func prepareScreenCapture() {
    if CGPreflightScreenCaptureAccess() { return }
    if !CGRequestScreenCaptureAccess() {
        fputs(
            "Allow airpods in System Settings → Privacy & Security → Screen Recording, then run it again.\n",
            stderr
        )
    }
}

enum ScreenShot {
    static func captureAllDisplays() async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let displays = content.displays
        guard !displays.isEmpty else { throw ShotError.noDisplay }

        var parts: [(CGImage, CGRect)] = []
        for display in displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            parts.append((image, display.frame))
        }
        let image = try composite(parts)
        let url = destinationURL()
        try writePNG(image, to: url)
        NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)?.play()
        NSWorkspace.shared.open(url)
        return url
    }

    private static func composite(_ parts: [(CGImage, CGRect)]) throws -> CGImage {
        if parts.count == 1 { return parts[0].0 }
        let frames = parts.map(\.1)
        let minX = frames.map(\.minX).min() ?? 0
        let minY = frames.map(\.minY).min() ?? 0
        let maxX = frames.map(\.maxX).max() ?? 0
        let maxY = frames.map(\.maxY).max() ?? 0
        let scale = parts.map { CGFloat($0.0.width) / max($0.1.width, 1) }.max() ?? 1
        let width = max(Int(((maxX - minX) * scale).rounded(.up)), 1)
        let height = max(Int(((maxY - minY) * scale).rounded(.up)), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ShotError.writeFailed
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for (image, frame) in parts {
            context.draw(
                image,
                in: CGRect(
                    x: (frame.minX - minX) * scale,
                    y: (frame.minY - minY) * scale,
                    width: frame.width * scale,
                    height: frame.height * scale
                )
            )
        }
        guard let combined = context.makeImage() else { throw ShotError.writeFailed }
        return combined
    }

    private static func destinationURL() -> URL {
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let stamp = formatter.string(from: Date())
        var url = desktop.appendingPathComponent("Screenshot \(stamp).png")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("Screenshot \(stamp) \(copy).png")
            copy += 1
        }
        return url
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw ShotError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShotError.writeFailed }
    }
}

enum ShotError: LocalizedError {
    case noDisplay
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available to capture."
        case .writeFailed:
            return "The screenshot could not be saved."
        }
    }
}

/// Listens for a jaw clench and saves one screenshot per clench.
final class JawShots: @unchecked Sendable {
    private let detector = JawClenchDetector()
    private var busy = false

    func receive(
        t: Double,
        yaw: Double,
        pitch: Double,
        roll: Double,
        ax: Double,
        ay: Double,
        az: Double
    ) {
        guard detector.update(t: t, ax: ax, ay: ay, az: az, rx: 0, ry: 0, rz: 0) else {
            return
        }
        guard !busy else { return }
        busy = true
        fputs("clench\n", stderr)
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                let url = try await ScreenShot.captureAllDisplays()
                fputs("screenshot \(url.path)\n", stderr)
            } catch {
                if !CGPreflightScreenCaptureAccess() {
                    fputs(
                        "Allow airpods in System Settings → Privacy & Security → Screen Recording, then run it again.\n",
                        stderr
                    )
                }
                fputs("screenshot failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
