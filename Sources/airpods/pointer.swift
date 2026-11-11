import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let relayPort: UInt16 = 9998
private let dotSettle = 0.5
private let dotSamplesNeeded = 12
private let dotTimeout = 2.6
/// US keyboard backslash, and the same key on layouts where it sits there.
private let backslashKeyCode: UInt16 = 42

func wrapAngle(_ angle: Double) -> Double {
    atan2(sin(angle), cos(angle))
}

struct Desktop {
    var bounds: [CGRect]

    static func current() -> Desktop {
        var count: UInt32 = 0
        if CGGetActiveDisplayList(0, nil, &count) != .success || count == 0 {
            return Desktop(bounds: [CGDisplayBounds(CGMainDisplayID())])
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if CGGetActiveDisplayList(count, &ids, &count) != .success || count == 0 {
            return Desktop(bounds: [CGDisplayBounds(CGMainDisplayID())])
        }
        return Desktop(bounds: ids.prefix(Int(count)).map { CGDisplayBounds($0) })
    }

    var union: CGRect {
        bounds.reduce(CGRect.null) { $0.union($1) }
    }

    func clamp(_ point: CGPoint) -> CGPoint {
        if bounds.contains(where: { $0.contains(point) }) {
            return point
        }
        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for rect in bounds {
            let clamped = CGPoint(
                x: min(max(point.x, rect.minX), max(rect.minX, rect.maxX - 1)),
                y: min(max(point.y, rect.minY), max(rect.minY, rect.maxY - 1))
            )
            let dx = clamped.x - point.x
            let dy = clamped.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = clamped
            }
        }
        return best
    }
}

/// Calibrated eye gaze moves the pointer. A jaw clench clicks.
final class Pointer {
    private let aim = AimMark()
    private var dots: [CGPoint] = []
    private var dotIndex = 0
    private var dotStarted = Date.distantPast
    private var dotCount = 0
    private var dotFrames: [[Double]] = []
    private var buckets: [(point: CGPoint, frames: [[Double]])] = []
    private var model: GazeModel?
    private var calibrated = false
    private var recent: [CGPoint] = []
    private let smoothX = OneEuroFilter(minCutoff: 2.4, beta: 0.9, derivativeCutoff: 1.0)
    private let smoothY = OneEuroFilter(minCutoff: 2.4, beta: 0.9, derivativeCutoff: 1.0)
    private var pointer: CGPoint?
    private var lastPosted: CGPoint?
    private var paused = false
    private var lastToggle = Date.distantPast
    private let pauseLock = NSLock()
    private var keyMonitors: [Any] = []
    private var relaySocket: Int32 = -1
    private var remoteOnly = false
    private var reportedBlock = false
    private var lastTrustCheck = Date.distantPast
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    func prepare() {
        fputs("Look at each yellow dot. Press \\ to turn the pointer off, and \\ again to turn it on. Clench your jaw to click. Press Control-C to quit.\n", stderr)
        if let eventSource {
            eventSource.localEventsSuppressionInterval = 0
        }
        promptForAccessibility()
        watchBackslash()
    }

    private func watchBackslash() {
        let onKey: (NSEvent) -> Void = { [weak self] event in
            guard !event.isARepeat else { return }
            let character = event.charactersIgnoringModifiers ?? ""
            guard event.keyCode == backslashKeyCode || character == "\\" else { return }
            self?.toggle()
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            onKey(event)
            return event
        }) {
            keyMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: onKey) {
            keyMonitors.append(monitor)
        }
    }

    func toggle() {
        let now = Date()
        pauseLock.lock()
        guard calibrated, now.timeIntervalSince(lastToggle) > 0.25 else {
            pauseLock.unlock()
            return
        }
        lastToggle = now
        paused.toggle()
        let paused = paused
        pauseLock.unlock()
        fputs(paused
            ? "Pointer off. Press \\ to turn it on.\n"
            : "Pointer on.\n", stderr)
    }

    private func isPaused() -> Bool {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        return paused
    }

    func update(yaw _: Double, pitch _: Double, roll _: Double) {}

    func update(gaze features: [Double]?) {
        if model == nil {
            collect(features)
            return
        }
        guard let features, !isPaused() else { return }
        let predicted = model?.predict(features) ?? .zero
        recent.append(predicted)
        if recent.count > 3 { recent.removeFirst() }
        let stable = CGPoint(
            x: medianNumber(recent.map(\.x)),
            y: medianNumber(recent.map(\.y))
        )
        let now = Date().timeIntervalSinceReferenceDate
        move(to: Desktop.current().clamp(CGPoint(
            x: smoothX.filter(stable.x, time: now),
            y: smoothY.filter(stable.y, time: now)
        )))
    }

    private func collect(_ features: [Double]?) {
        if dots.isEmpty {
            dots = calibrationDots(in: Desktop.current().union)
            dotIndex = 0
            showCurrentDot()
        }
        guard dotIndex < dots.count else { return }
        let elapsed = Date().timeIntervalSince(dotStarted)
        if elapsed > dotSettle, dotCount < dotSamplesNeeded, let features, features.count == gazeFeatureCount {
            dotFrames.append(features)
            dotCount += 1
        }
        let filled = dotCount >= dotSamplesNeeded && elapsed > dotSettle + 0.25
        if filled || elapsed > dotTimeout {
            buckets.append((dots[dotIndex], dotFrames))
            dotFrames.removeAll()
            dotIndex += 1
            if dotIndex < dots.count {
                showCurrentDot()
            } else {
                finishCalibration()
            }
        }
    }

    private func showCurrentDot() {
        dotStarted = Date()
        dotCount = 0
        aim.show(at: dots[dotIndex])
        fputs("Look at the dot (\(dotIndex + 1) of \(dots.count)).\n", stderr)
    }

    private func finishCalibration() {
        aim.hide()
        guard let fitted = GazeModel.fit(dots: buckets) else {
            fputs("Could not see your eyes on enough dots. Starting the dots again.\n", stderr)
            buckets.removeAll()
            dotFrames.removeAll()
            dotIndex = 0
            dots = calibrationDots(in: Desktop.current().union)
            showCurrentDot()
            return
        }
        model = fitted
        calibrated = true
        fputs("Pointer ready. Look where you want the pointer. Clench your jaw to click. Press \\ to turn it off.\n", stderr)
    }

    private func calibrationDots(in area: CGRect) -> [CGPoint] {
        let steps: [CGFloat] = [0.12, 0.31, 0.50, 0.69, 0.88]
        var spots: [(CGFloat, CGFloat)] = [(0.50, 0.50)]
        for y in steps {
            for x in steps where abs(x - 0.50) > 0.01 || abs(y - 0.50) > 0.01 {
                spots.append((x, y))
            }
        }
        return spots.map {
            CGPoint(x: area.minX + area.width * $0.0, y: area.minY + area.height * $0.1)
        }
    }

    private func move(to point: CGPoint) {
        let pixel = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        pointer = pixel
        if lastPosted == pixel { return }
        lastPosted = pixel
        placeCursor(at: pixel, click: false)
    }

    func clench() {
        guard calibrated, !isPaused() else { return }
        if pointer == nil {
            pointer = CGEvent(source: nil)?.location
        }
        click()
    }

    private func click() {
        guard let point = pointer else { return }
        placeCursor(at: point, click: true)
        fputs("click\n", stderr)
    }

    /// `mouseMoved` events do not move the cursor on current macOS. Warp it.
    /// If this app is blocked, ask the terminal process to warp instead.
    private func placeCursor(at point: CGPoint, click: Bool) {
        if !remoteOnly, canControlPointer() {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(point)
            post(.mouseMoved, at: point)
            if click {
                post(.leftMouseDown, at: point)
                post(.leftMouseUp, at: point)
            }
            if let location = CGEvent(source: nil)?.location,
               hypot(location.x - point.x, location.y - point.y) > 40 {
                remoteOnly = true
                reportBlocked()
            } else {
                return
            }
        }
        relay(click ? "c,\(point.x),\(point.y)" : "m,\(point.x),\(point.y)")
    }

    private func canControlPointer() -> Bool {
        if AXIsProcessTrusted() { return true }
        if Date().timeIntervalSince(lastTrustCheck) > 1 {
            lastTrustCheck = Date()
            reportBlocked()
        }
        return false
    }

    private func reportBlocked() {
        guard !reportedBlock else { return }
        reportedBlock = true
        fputs(
            "macOS is still blocking airpods from moving the pointer. In Accessibility, remove any old airpods entry, add airpods.app from this folder, and turn it on.\n",
            stderr
        )
    }

    private func relay(_ message: String) {
        if relaySocket < 0 {
            relaySocket = socket(AF_INET, SOCK_DGRAM, 0)
        }
        guard relaySocket >= 0 else { return }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = relayPort.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        _ = message.withCString { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    sendto(relaySocket, bytes, strlen(bytes), 0, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: eventSource,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            fputs("Accessibility authorized.\n", stderr)
        } else {
            fputs(
                "Allow airpods in System Settings → Privacy & Security → Accessibility, then run it again.\n",
                stderr
            )
        }
    }
}

private func medianNumber(_ values: [CGFloat]) -> CGFloat {
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2), mid > 0 {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}
