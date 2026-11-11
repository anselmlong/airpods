import AVFoundation
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import Vision

let gazePatchColumns = 8
let gazePatchRows = 4
/// Two angled eye patches, then pupil position, eye center, and face pose.
let gazeFeatureCount = gazePatchColumns * gazePatchRows * 2 + 11

/// Features for one frame. The eye image is rotated so the corners are horizontal,
/// which is the angled-patch step from the webcam gaze pipelines that beat a raw pupil offset.
func gazeFeatures(
    from face: VNFaceObservation,
    sampleBuffer: CMSampleBuffer,
    orientation: CGImagePropertyOrientation
) -> [Double]? {
    guard let leftEye = face.landmarks?.leftEye, let rightEye = face.landmarks?.rightEye,
          eyeOpenness(leftEye) > 0.12, eyeOpenness(rightEye) > 0.12,
          let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return nil
    }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let pixels = EyePixels(
        base: base,
        width: CVPixelBufferGetWidth(buffer),
        height: CVPixelBufferGetHeight(buffer),
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        orientation: orientation
    )
    guard let left = eyePatch(pupil: face.landmarks?.leftPupil, eye: leftEye, box: face.boundingBox, pixels: pixels),
          let right = eyePatch(pupil: face.landmarks?.rightPupil, eye: rightEye, box: face.boundingBox, pixels: pixels),
          abs(left.along - right.along) < 0.35,
          abs(left.across - right.across) < 0.35 else {
        return nil
    }
    var features = left.patch
    features.append(contentsOf: right.patch)
    features.append(contentsOf: [
        left.along, left.across, right.along, right.across,
        left.centerX, left.centerY, right.centerX, right.centerY,
        face.yaw?.doubleValue ?? 0,
        face.pitch?.doubleValue ?? 0,
        face.roll?.doubleValue ?? 0,
    ])
    guard features.count == gazeFeatureCount else { return nil }
    return features
}

/// Lid opening. A blink collapses this and would yank the pupil estimate.
func eyeOpenness(_ eye: VNFaceLandmarkRegion2D) -> CGFloat {
    let points = eye.normalizedPoints
    guard points.count > 1,
          let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
          let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
        return 0
    }
    let width = maxX - minX
    guard width > 0.0001 else { return 0 }
    return (maxY - minY) / width
}

/// Pupil position inside the eye, in eye-widths. Positive y is up.
func pupilOffset(pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?) -> CGPoint? {
    guard let pupil, let eye, pupil.pointCount > 0, eye.pointCount > 1 else { return nil }
    let eyePoints = eye.normalizedPoints
    let pupilPoints = pupil.normalizedPoints
    guard eyePoints.count > 1, !pupilPoints.isEmpty else { return nil }

    let eyeCenter = centroid(eyePoints)
    let pupilCenter = centroid(pupilPoints)
    guard let minX = eyePoints.map(\.x).min(), let maxX = eyePoints.map(\.x).max() else { return nil }
    let width = maxX - minX
    guard width > 0.0001 else { return nil }
    return CGPoint(
        x: (pupilCenter.x - eyeCenter.x) / width,
        y: (pupilCenter.y - eyeCenter.y) / width
    )
}

private struct EyePatch {
    var patch: [Double]
    var along: Double
    var across: Double
    var centerX: Double
    var centerY: Double
}

/// Grayscale patch rotated onto the eye's long axis, plus the pupil in that frame.
private func eyePatch(
    pupil: VNFaceLandmarkRegion2D?,
    eye: VNFaceLandmarkRegion2D,
    box: CGRect,
    pixels: EyePixels
) -> EyePatch? {
    let contour = eye.normalizedPoints.map { imagePoint($0, in: box) }
    guard contour.count > 2, let pupil, pupil.pointCount > 0 else { return nil }
    let pupilPoint = imagePoint(centroid(pupil.normalizedPoints), in: box)
    let center = centroid(contour)
    var cxx = 0.0
    var cyy = 0.0
    var cxy = 0.0
    for point in contour {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        cxx += dx * dx
        cyy += dy * dy
        cxy += dx * dy
    }
    let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
    let axis = CGPoint(x: cos(angle), y: sin(angle))
    let perp = CGPoint(x: -axis.y, y: axis.x)
    var low = Double.greatestFiniteMagnitude
    var high = -Double.greatestFiniteMagnitude
    for point in contour {
        let projected = Double((point.x - center.x) * axis.x + (point.y - center.y) * axis.y)
        low = min(low, projected)
        high = max(high, projected)
    }
    let width = high - low
    guard width > 0.004 else { return nil }
    let along = Double((pupilPoint.x - center.x) * axis.x + (pupilPoint.y - center.y) * axis.y) / width
    let across = Double((pupilPoint.x - center.x) * perp.x + (pupilPoint.y - center.y) * perp.y) / width
    var patch: [Double] = []
    patch.reserveCapacity(gazePatchColumns * gazePatchRows)
    let halfAlong = width * 0.75
    let halfAcross = width * 0.40
    for row in 0..<gazePatchRows {
        for column in 0..<gazePatchColumns {
            let tu = (Double(column) + 0.5) / Double(gazePatchColumns) - 0.5
            let tv = (Double(row) + 0.5) / Double(gazePatchRows) - 0.5
            let x = Double(center.x) + Double(axis.x) * tu * 2 * halfAlong + Double(perp.x) * tv * 2 * halfAcross
            let y = Double(center.y) + Double(axis.y) * tu * 2 * halfAlong + Double(perp.y) * tv * 2 * halfAcross
            patch.append(pixels.gray(nx: x, ny: y))
        }
    }
    let mean = patch.reduce(0, +) / Double(patch.count)
    let variance = patch.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(patch.count)
    let spread = max(sqrt(variance), 1e-3)
    return EyePatch(
        patch: patch.map { ($0 - mean) / spread },
        along: along,
        across: across,
        centerX: Double(center.x),
        centerY: Double(center.y)
    )
}

private func imagePoint(_ point: CGPoint, in box: CGRect) -> CGPoint {
    CGPoint(x: box.minX + point.x * box.width, y: box.minY + point.y * box.height)
}

/// Reads one upright pixel. Vision's coordinates are the oriented image, origin at the bottom left.
private struct EyePixels {
    let base: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let orientation: CGImagePropertyOrientation

    func gray(nx: Double, ny: Double) -> Double {
        let uprightWidth = orientation == .left || orientation == .right ? height : width
        let uprightHeight = orientation == .left || orientation == .right ? width : height
        let x = min(max(nx, 0), 0.999) * Double(uprightWidth - 1)
        let yFromBottom = min(max(ny, 0), 0.999) * Double(uprightHeight - 1)
        let source = bufferPoint(x: x, yFromBottom: yFromBottom)
        let px = min(max(source.x, 0), width - 1)
        let py = min(max(source.y, 0), height - 1)
        let pixel = base.advanced(by: py * bytesPerRow + px * 4).assumingMemoryBound(to: UInt8.self)
        let blue = Double(pixel[0])
        let green = Double(pixel[1])
        let red = Double(pixel[2])
        return (0.114 * blue + 0.587 * green + 0.299 * red) / 255
    }

    private func bufferPoint(x: Double, yFromBottom: Double) -> (x: Int, y: Int) {
        switch orientation {
        case .down:
            return (width - 1 - Int(x), Int(yFromBottom))
        case .left:
            return (Int(yFromBottom), Int(x))
        case .right:
            return (width - 1 - Int(yFromBottom), height - 1 - Int(x))
        default:
            return (Int(x), height - 1 - Int(yFromBottom))
        }
    }
}

func centroid(_ points: [CGPoint]) -> CGPoint {
    var x: CGFloat = 0
    var y: CGFloat = 0
    for point in points {
        x += point.x
        y += point.y
    }
    let count = CGFloat(points.count)
    return CGPoint(x: x / count, y: y / count)
}

func largestFace(_ faces: [VNFaceObservation]?) -> VNFaceObservation? {
    faces?.max { lhs, rhs in
        lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
    }
}

func visionOrientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
    switch Int(connection.videoRotationAngle.rounded()) {
    case 90:
        return .right
    case 180:
        return .down
    case 270, -90:
        return .left
    default:
        return .up
    }
}

/// Built-in camera. Reports a pupil offset, or nil when no face is visible.
final class GazeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onGaze: (([Double]?) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "airpods.camera.session")
    private let framesQueue = DispatchQueue(label: "airpods.camera.frames")
    private let landmarks: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.preferBackgroundProcessing = false
        let revision = VNDetectFaceLandmarksRequestRevision3
        if VNDetectFaceLandmarksRequest.supportedRevisions.contains(revision) {
            request.revision = revision
        }
        return request
    }()
    /// Last face, grown so the next frame searches the eyes instead of the whole image.
    private var searchRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureAndStart() }
                } else {
                    self.reportCameraDenied()
                }
            }
        case .denied, .restricted:
            reportCameraDenied()
        @unknown default:
            break
        }
    }

    private func configureAndStart() {
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else {
            session.commitConfiguration()
            fputs("No camera is available.\n", stderr)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                fputs("The camera could not be opened.\n", stderr)
                return
            }
            session.addInput(input)
            if (try? device.lockForConfiguration()) != nil {
                let frame = CMTime(value: 1, timescale: 30)
                device.activeVideoMinFrameDuration = frame
                device.activeVideoMaxFrameDuration = frame
                device.unlockForConfiguration()
            }
        } catch {
            session.commitConfiguration()
            fputs("The camera could not be opened: \(error.localizedDescription)\n", stderr)
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: framesQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            fputs("The camera could not be opened.\n", stderr)
            return
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()
        session.startRunning()
        fputs("camera started\n", stderr)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        landmarks.regionOfInterest = searchRect
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: visionOrientation(for: connection),
            options: [:]
        )
        let features: [Double]?
        do {
            try handler.perform([landmarks])
            if let face = largestFace(landmarks.results) {
                searchRect = expandedFace(face.boundingBox)
                features = gazeFeatures(from: face, sampleBuffer: sampleBuffer, orientation: visionOrientation(for: connection))
            } else {
                searchRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                features = nil
            }
        } catch {
            searchRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            features = nil
        }
        let onGaze = self.onGaze
        DispatchQueue.main.async {
            onGaze?(features)
        }
    }

    private func expandedFace(_ box: CGRect) -> CGRect {
        let grown = box.insetBy(dx: -box.width * 0.6, dy: -box.height * 0.6)
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = grown.intersection(bounds)
        guard clipped.width > 0.08, clipped.height > 0.08 else { return bounds }
        return clipped
    }

}

/// One Euro filter. It stays still when the eyes are still, and catches up when they move.
final class OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let derivativeCutoff: Double
    private var filtered: Double?
    private var derivative = 0.0
    private var lastTime: Double?

    init(minCutoff: Double, beta: Double, derivativeCutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    func reset() {
        filtered = nil
        derivative = 0
        lastTime = nil
    }

    func filter(_ value: Double, time: Double) -> Double {
        guard let filtered, let lastTime else {
            self.filtered = value
            self.lastTime = time
            return value
        }
        let dt = max(time - lastTime, 1.0 / 120.0)
        let rawDerivative = (value - filtered) / dt
        let derivativeAlpha = smoothingAlpha(cutoff: derivativeCutoff, dt: dt)
        derivative += derivativeAlpha * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let alpha = smoothingAlpha(cutoff: cutoff, dt: dt)
        let next = filtered + alpha * (value - filtered)
        self.filtered = next
        self.lastTime = time
        return next
    }

    private func smoothingAlpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * max(cutoff, 0.01))
        return 1.0 / (1.0 + tau / dt)
    }
}

private extension GazeCamera {
    func reportCameraDenied() {
        fputs(
            "Camera access denied. Enable airpods in System Settings → Privacy & Security → Camera.\n",
            stderr
        )
    }
}
