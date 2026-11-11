import CoreGraphics
import Foundation

/// Ridge regression from eye features to a screen point.
/// This is the mapping used by WebGazer and the individualized webcam trackers
/// that beat an uncalibrated pupil offset.
final class GazeRidge {
    private let mean: [Double]
    private let scale: [Double]
    private let weightsX: [Double]
    private let weightsY: [Double]

    private init(mean: [Double], scale: [Double], weightsX: [Double], weightsY: [Double]) {
        self.mean = mean
        self.scale = scale
        self.weightsX = weightsX
        self.weightsY = weightsY
    }

    static func fit(samples: [(features: [Double], point: CGPoint)], lambda: Double = 18) -> GazeRidge? {
        guard let width = samples.first?.features.count, width > 0 else { return nil }
        let rows = samples.filter { $0.features.count == width }
        guard rows.count >= width / 2 else { return nil }

        var mean = [Double](repeating: 0, count: width)
        for sample in rows {
            for index in 0..<width {
                mean[index] += sample.features[index]
            }
        }
        let count = Double(rows.count)
        for index in 0..<width {
            mean[index] /= count
        }
        var scale = [Double](repeating: 0, count: width)
        for sample in rows {
            for index in 0..<width {
                let delta = sample.features[index] - mean[index]
                scale[index] += delta * delta
            }
        }
        for index in 0..<width {
            scale[index] = sqrt(scale[index] / count)
            if scale[index] < 1e-6 { scale[index] = 1 }
        }

        let size = width + 1
        var gram = Array(repeating: Array(repeating: 0.0, count: size), count: size)
        var targetX = [Double](repeating: 0, count: size)
        var targetY = [Double](repeating: 0, count: size)
        var columns = Array(repeating: Array(repeating: 0.0, count: size), count: rows.count)
        for (row, sample) in rows.enumerated() {
            columns[row][0] = 1
            for index in 0..<width {
                columns[row][index + 1] = (sample.features[index] - mean[index]) / scale[index]
            }
            for left in 0..<size {
                targetX[left] += columns[row][left] * sample.point.x
                targetY[left] += columns[row][left] * sample.point.y
                for right in 0..<size {
                    gram[left][right] += columns[row][left] * columns[row][right]
                }
            }
        }
        for index in 1..<size {
            gram[index][index] += lambda
        }
        guard let weightsX = solveLinear(gram, targetX), let weightsY = solveLinear(gram, targetY) else {
            return nil
        }
        return GazeRidge(mean: mean, scale: scale, weightsX: weightsX, weightsY: weightsY)
    }

    func predict(_ features: [Double]) -> CGPoint {
        guard features.count == mean.count else { return .zero }
        var x = weightsX[0]
        var y = weightsY[0]
        for index in 0..<mean.count {
            let value = (features[index] - mean[index]) / scale[index]
            x += weightsX[index + 1] * value
            y += weightsY[index + 1] * value
        }
        return CGPoint(x: x, y: y)
    }
}

/// Quadratic binocular fit, then a correction learned at each calibration dot.
/// The correction removes the leftover error a single polynomial cannot fit.
final class GazeModel {
    private let ridge: GazeRidge
    private let anchors: [(at: CGPoint, residual: CGPoint)]

    private init(ridge: GazeRidge, anchors: [(at: CGPoint, residual: CGPoint)]) {
        self.ridge = ridge
        self.anchors = anchors
    }

    static func fit(dots: [(point: CGPoint, frames: [[Double]])]) -> GazeModel? {
        var rows: [(features: [Double], point: CGPoint)] = []
        var centers: [(features: [Double], point: CGPoint)] = []
        for dot in dots {
            let kept = inlierFrames(dot.frames)
            guard kept.count >= 3, let middle = medianFrame(kept) else { continue }
            let center = polynomialGaze(middle)
            centers.append((center, dot.point))
            for frame in kept {
                rows.append((polynomialGaze(frame), dot.point))
            }
        }
        guard centers.count >= 12, let ridge = GazeRidge.fit(samples: rows, lambda: 1.2) else {
            return nil
        }
        let anchors = centers.map { item in
            let predicted = ridge.predict(item.features)
            return (
                at: predicted,
                residual: CGPoint(x: item.point.x - predicted.x, y: item.point.y - predicted.y)
            )
        }
        return GazeModel(ridge: ridge, anchors: anchors)
    }

    func predict(_ raw: [Double]) -> CGPoint {
        let base = ridge.predict(polynomialGaze(raw))
        var weightSum = 0.0
        var offsetX = 0.0
        var offsetY = 0.0
        for anchor in anchors {
            let dx = base.x - anchor.at.x
            let dy = base.y - anchor.at.y
            let weight = exp(-(dx * dx + dy * dy) / (2 * 130 * 130))
            weightSum += weight
            offsetX += weight * anchor.residual.x
            offsetY += weight * anchor.residual.y
        }
        guard weightSum > 0 else { return base }
        return CGPoint(x: base.x + offsetX / weightSum, y: base.y + offsetY / weightSum)
    }
}

/// Pupil position in each eye, its square terms, and the face pose.
private func polynomialGaze(_ raw: [Double]) -> [Double] {
    guard raw.count >= 11 else { return [] }
    let base = raw.count - 11
    let leftAlong = raw[base]
    let leftAcross = raw[base + 1]
    let rightAlong = raw[base + 2]
    let rightAcross = raw[base + 3]
    let along = (leftAlong + rightAlong) / 2
    let across = (leftAcross + rightAcross) / 2
    let faceX = (raw[base + 4] + raw[base + 6]) / 2
    let faceY = (raw[base + 5] + raw[base + 7]) / 2
    let yaw = raw[base + 8]
    let pitch = raw[base + 9]
    let roll = raw[base + 10]
    return [
        leftAlong, leftAcross, rightAlong, rightAcross,
        along, across,
        along * along, across * across, along * across,
        leftAlong * leftAlong, leftAcross * leftAcross,
        rightAlong * rightAlong, rightAcross * rightAcross,
        leftAlong - rightAlong, leftAcross - rightAcross,
        faceX, faceY, yaw, pitch, roll,
        yaw * along, pitch * across,
    ]
}

private func inlierFrames(_ frames: [[Double]]) -> [[Double]] {
    let usable = frames.filter { $0.count >= 11 }
    guard usable.count >= 3 else { return usable }
    let along = usable.map { pupilAverage($0).along }
    let across = usable.map { pupilAverage($0).across }
    let alongLimit = max(2.8 * medianAbsoluteDeviation(along), 0.015)
    let acrossLimit = max(2.8 * medianAbsoluteDeviation(across), 0.015)
    let alongCenter = medianValue(along)
    let acrossCenter = medianValue(across)
    return usable.filter {
        let pupil = pupilAverage($0)
        return abs(pupil.along - alongCenter) <= alongLimit
            && abs(pupil.across - acrossCenter) <= acrossLimit
    }
}

private func pupilAverage(_ features: [Double]) -> (along: Double, across: Double) {
    let base = features.count - 11
    return (
        along: (features[base] + features[base + 2]) / 2,
        across: (features[base + 1] + features[base + 3]) / 2
    )
}

private func medianFrame(_ frames: [[Double]]) -> [Double]? {
    guard let width = frames.first?.count, frames.allSatisfy({ $0.count == width }) else { return nil }
    var median = [Double](repeating: 0, count: width)
    for index in 0..<width {
        median[index] = medianValue(frames.map { $0[index] })
    }
    return median
}

private func medianValue(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

private func medianAbsoluteDeviation(_ values: [Double]) -> Double {
    let center = medianValue(values)
    return medianValue(values.map { abs($0 - center) })
}

private func solveLinear(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
    let count = vector.count
    var rows = matrix
    var result = vector
    for column in 0..<count {
        var pivot = column
        for row in (column + 1)..<count where abs(rows[row][column]) > abs(rows[pivot][column]) {
            pivot = row
        }
        if abs(rows[pivot][column]) < 1e-8 { return nil }
        if pivot != column {
            rows.swapAt(pivot, column)
            result.swapAt(pivot, column)
        }
        let divisor = rows[column][column]
        for index in column..<count {
            rows[column][index] /= divisor
        }
        result[column] /= divisor
        for row in 0..<count where row != column {
            let factor = rows[row][column]
            if factor == 0 { continue }
            for index in column..<count {
                rows[row][index] -= factor * rows[column][index]
            }
            result[row] -= factor * result[column]
        }
    }
    return result
}
