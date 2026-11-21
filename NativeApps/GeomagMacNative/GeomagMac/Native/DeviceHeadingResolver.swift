import Foundation

struct DeviceHeadingFrame: Sendable {
    let yawRadians: Double
    let magneticAccuracy: Int
}

struct HeadingResolution: Sendable {
    let headings: [Double]
    let diagnostics: HeadingDiagnostics
}

/// Selects a trustworthy heading source without treating Core Motion yaw as
/// an absolute building direction. Accepted yaw is registered to the known
/// route heading at the beginning of the active walking interval.
enum DeviceHeadingResolver {
    static func resolve(
        frameTimes: [Double],
        gyroHeadings: [Double],
        deviceFrames: [DeviceHeadingFrame?],
        initialHeading: Double
    ) -> HeadingResolution {
        precondition(frameTimes.count == gyroHeadings.count)
        precondition(frameTimes.count == deviceFrames.count)

        let validIndices = deviceFrames.indices.filter { deviceFrames[$0] != nil }
        let sampleCount = validIndices.count
        let coverage = frameTimes.isEmpty ? 0 : Double(sampleCount) / Double(frameTimes.count)
        let calibratedCount = validIndices.reduce(into: 0) { count, index in
            if (deviceFrames[index]?.magneticAccuracy ?? -1) >= 0 { count += 1 }
        }
        let calibratedRatio = sampleCount == 0
            ? 0
            : Double(calibratedCount) / Double(sampleCount)
        let maximumGap = zip(validIndices, validIndices.dropFirst()).map { previous, current in
            frameTimes[current] - frameTimes[previous]
        }.max() ?? 0

        func fallback(_ reason: String) -> HeadingResolution {
            HeadingResolution(
                headings: gyroHeadings,
                diagnostics: HeadingDiagnostics(
                    method: "gyro_z_integration",
                    deviceMotionAvailable: sampleCount > 0,
                    deviceMotionAccepted: false,
                    deviceMotionSampleCount: sampleCount,
                    coverageRatio: sampleCount > 0 ? coverage : nil,
                    calibratedRatio: sampleCount > 0 ? calibratedRatio : nil,
                    maximumGapSeconds: sampleCount > 1 ? maximumGap : nil,
                    gyroAgreementRMSEDegrees: nil,
                    rejectionReason: reason
                )
            )
        }

        guard sampleCount > 0 else { return fallback("missing_device_motion") }
        guard sampleCount >= 20 else { return fallback("insufficient_samples") }
        guard coverage >= 0.90 else { return fallback("insufficient_coverage") }
        guard calibratedRatio >= 0.80 else { return fallback("magnetic_calibration_low") }
        guard maximumGap <= 0.25 else { return fallback("timestamp_gap") }

        var unwrappedYaw = Array(repeating: Double.nan, count: deviceFrames.count)
        var previousRaw: Double?
        var previousIndex: Int?
        var continuous = 0.0
        var repairedOutlierCount = 0
        for index in deviceFrames.indices {
            guard let raw = deviceFrames[index]?.yawRadians else { continue }
            if let previousRaw, let previousIndex {
                let rawDelta = wrapped(raw - previousRaw)
                let dt = frameTimes[index] - frameTimes[previousIndex]
                let gyroDelta = wrapped(gyroHeadings[index] - gyroHeadings[previousIndex])
                if dt > 1e-6,
                   abs(rawDelta) / dt > 6.0,
                   abs(wrapped(rawDelta - gyroDelta)) > 0.08 {
                    continuous += gyroDelta
                    repairedOutlierCount += 1
                } else {
                    continuous += rawDelta
                }
            } else {
                continuous = raw
            }
            unwrappedYaw[index] = continuous
            previousRaw = raw
            previousIndex = index
        }
        guard let anchorIndex = validIndices.first else { return fallback("insufficient_samples") }
        let anchorYaw = unwrappedYaw[anchorIndex]
        let allowedOutliers = max(5, Int(ceil(Double(sampleCount) * 0.005)))
        guard repairedOutlierCount <= allowedOutliers else {
            return fallback("implausible_yaw_rate")
        }

        let deviceRelative = validIndices.map { unwrappedYaw[$0] - anchorYaw }
        let gyroUnwrapped = unwrap(gyroHeadings)
        let gyroAnchor = gyroUnwrapped[anchorIndex]
        let gyroRelative = validIndices.map { gyroUnwrapped[$0] - gyroAnchor }
        let residuals = zip(deviceRelative, gyroRelative).map { device, gyro in
            wrapped(device - gyro)
        }
        let agreementRMS = sqrt(
            residuals.reduce(0) { $0 + $1 * $1 } / Double(max(residuals.count, 1))
        ) * 180 / .pi

        if let deviceTurn = deviceRelative.last,
           let gyroTurn = gyroRelative.last,
           abs(deviceTurn) >= 30 * .pi / 180,
           abs(gyroTurn) >= 30 * .pi / 180,
           deviceTurn * gyroTurn < 0 {
            return fallback("rotation_direction_mismatch")
        }

        var resolved = gyroHeadings
        for index in validIndices {
            resolved[index] = wrapped(initialHeading + unwrappedYaw[index] - anchorYaw)
        }
        // A valid series should normally cover every active frame. Fill any
        // isolated holes from the last Core Motion heading plus gyro delta.
        for index in resolved.indices where deviceFrames[index] == nil {
            guard index > 0 else { continue }
            resolved[index] = wrapped(
                resolved[index - 1] + wrapped(gyroHeadings[index] - gyroHeadings[index - 1])
            )
        }
        return HeadingResolution(
            headings: resolved,
            diagnostics: HeadingDiagnostics(
                method: "core_motion_relative_yaw",
                deviceMotionAvailable: true,
                deviceMotionAccepted: true,
                deviceMotionSampleCount: sampleCount,
                coverageRatio: coverage,
                calibratedRatio: calibratedRatio,
                maximumGapSeconds: maximumGap,
                gyroAgreementRMSEDegrees: agreementRMS,
                rejectionReason: nil
            )
        )
    }

    private static func unwrap(_ angles: [Double]) -> [Double] {
        guard let first = angles.first else { return [] }
        var result = [first]
        result.reserveCapacity(angles.count)
        for index in 1..<angles.count {
            result.append(result[index - 1] + wrapped(angles[index] - angles[index - 1]))
        }
        return result
    }

    private static func wrapped(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }
}
