import Foundation

/// A jaw clench is a brief jerk, not a head turn.
/// Head turns keep the acceleration high across the whole window.
/// A clench is one sharp peak above that level.
final class JawClenchDetector {
    private let windowSeconds = 0.12
    private let refractorySeconds = 0.4
    private let accelImpulse = 0.008
    private let gyroImpulse = 0.45

    private struct Sample {
        var t: Double
        var accel: Double
        var gyro: Double
    }

    private var window: [Sample] = []
    private var armed = false
    private var lastFire = -1e9

    func update(
        t: Double,
        ax: Double,
        ay: Double,
        az: Double,
        rx: Double,
        ry: Double,
        rz: Double
    ) -> Bool {
        let sample = Sample(
            t: t,
            accel: (ax * ax + ay * ay + az * az).squareRoot(),
            gyro: (rx * rx + ry * ry + rz * rz).squareRoot()
        )
        window.append(sample)
        let cutoff = t - windowSeconds
        while let first = window.first, first.t < cutoff {
            window.removeFirst()
        }
        guard window.count >= 4 else { return false }

        let accelHit = impulse(window.map(\.accel)) >= accelImpulse
        let gyroHit = impulse(window.map(\.gyro)) >= gyroImpulse
        let hit = accelHit || gyroHit
        let clench = hit && !armed && (t - lastFire) >= refractorySeconds
        if clench {
            lastFire = t
        }
        armed = hit
        return clench
    }

    /// Peak minus the typical value in the window. A smooth head turn scores near zero.
    private func impulse(_ values: [Double]) -> Double {
        guard let peak = values.max() else { return 0 }
        let sorted = values.sorted()
        let middle = sorted[sorted.count / 2]
        return peak - middle
    }
}
