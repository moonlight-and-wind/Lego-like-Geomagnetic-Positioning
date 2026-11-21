import Foundation

struct MagneticVector3: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

struct ControlledMagneticStepInput: Sendable {
    let length: Double
    let sensorHeading: Double
    let fusedHeading: Double
    let magneticNormUT: Double
    let alignedMagneticVectorUT: MagneticVector3?
    let segmentIndex: Int
}

struct ControlledMagneticFusionOutput: Sendable {
    let stepLengths: [Double]
    let segmentHeadings: [Double]
    let diagnostics: MagneticFusionDiagnostics
}

enum ControlledMagneticFusion {
    private struct Alignment {
        let progress: [Double]
        let reason: String
        let confidence: Double
        let gain: Double
        let correlation: Double
        let normalizedCost: Double?
    }

    static func apply(
        datasetKey: String,
        group: String,
        calibrationSourceKey: String,
        initialHeading: Double,
        steps: [ControlledMagneticStepInput],
        templateOverride: ControlledMagneticTemplate? = nil
    ) -> ControlledMagneticFusionOutput {
        guard let template = templateOverride ?? ControlledMagneticTemplates.template(for: group),
              template.group == group,
              template.segments.count == 4 else {
            return fallback(
                steps: steps,
                calibrationSourceKey: calibrationSourceKey,
                reason: "missing_template"
            )
        }
        let currentHeadings = (0..<4).map { segment in
            steps.first { $0.segmentIndex == segment }?.fusedHeading
                ?? initialHeading - Double(segment) * .pi / 2
        }
        let templateSourceLabel = template.sourceLabel
        if template.sourceKeys.map({ $0.lowercased() }).contains(datasetKey.lowercased()) {
            return ControlledMagneticFusionOutput(
                stepLengths: steps.map(\.length),
                segmentHeadings: currentHeadings,
                diagnostics: diagnostics(
                    calibrationSourceKey: templateSourceLabel,
                    progressStatuses: Array(repeating: "calibration_reference", count: 4),
                    progressConfidences: Array(repeating: 0, count: 4),
                    progressGains: Array(repeating: 0, count: 4),
                    progressCorrelations: Array(repeating: 1, count: 4),
                    progressCosts: Array(repeating: nil, count: 4),
                    progressShifts: Array(repeating: 0, count: 4),
                    headingStatuses: Array(repeating: "calibration_reference", count: 4),
                    headingDeltas: Array(repeating: 0, count: 4),
                    headingResiduals: Array(repeating: nil, count: 4),
                    headingConfidences: Array(repeating: 0, count: 4),
                    adjustment: 0,
                    globalGain: 0,
                    fallbackReason: nil
                )
            )
        }

        var correctedLengths: [Double] = []
        var correctedProgressBySegment: [[Double]] = []
        var progressStatuses: [String] = []
        var progressConfidences: [Double] = []
        var progressGains: [Double] = []
        var progressCorrelations: [Double] = []
        var progressCosts: [Double?] = []
        var progressShifts: [Double] = []
        for segment in 0..<4 {
            let selected = steps.filter { $0.segmentIndex == segment }
            let total = selected.map(\.length).reduce(0, +)
            let queryProgress = cumulativeProgress(selected.map(\.length))
            let alignment = alignProgress(
                referenceValues: template.segments[segment].magneticNormUT,
                referenceProgress: template.segments[segment].progress,
                queryValues: selected.map(\.magneticNormUT),
                queryProgress: queryProgress
            )
            let endpoints = [0.0] + alignment.progress
            var increments = zip(endpoints, endpoints.dropFirst()).map { max($1 - $0, 0) }
            let incrementTotal = increments.reduce(0, +)
            if incrementTotal > 1e-9 {
                increments = increments.map { $0 / incrementTotal * total }
            } else {
                increments = selected.map(\.length)
            }
            correctedLengths.append(contentsOf: increments)
            correctedProgressBySegment.append(alignment.progress)
            progressStatuses.append(alignment.reason)
            progressConfidences.append(alignment.confidence)
            progressGains.append(alignment.gain)
            progressCorrelations.append(alignment.correlation)
            progressCosts.append(alignment.normalizedCost)
            progressShifts.append(mean(zip(alignment.progress, queryProgress).map { abs($0 - $1) }))
        }

        var headingStatuses: [String] = []
        var headingDeltas: [Double] = []
        var headingResiduals: [Double?] = []
        var headingConfidences: [Double] = []
        var targetCorrections: [Double] = []
        var currentCorrections: [Double] = []
        var acceptedWeights: [Double] = []
        var missingAlignedField = false
        for segment in 0..<4 {
            let selected = steps.filter { $0.segmentIndex == segment }
            guard progressStatuses[segment] == "accepted" else {
                headingStatuses.append("progress_\(progressStatuses[segment])")
                headingDeltas.append(0)
                headingResiduals.append(nil)
                headingConfidences.append(0)
                continue
            }
            let queryVectors = selected.compactMap(\.alignedMagneticVectorUT)
            guard queryVectors.count == selected.count else {
                missingAlignedField = true
                headingStatuses.append("missing_attitude_aligned_field")
                headingDeltas.append(0)
                headingResiduals.append(nil)
                headingConfidences.append(0)
                continue
            }
            let segmentTemplate = template.segments[segment]
            let mapped = correctedProgressBySegment[segment].map { progress in
                MagneticVector3(
                    x: interpolate(segmentTemplate.alignedVectorsUT.map(\.x), axis: segmentTemplate.progress, at: progress),
                    y: interpolate(segmentTemplate.alignedVectorsUT.map(\.y), axis: segmentTemplate.progress, at: progress),
                    z: interpolate(segmentTemplate.alignedVectorsUT.map(\.z), axis: segmentTemplate.progress, at: progress)
                )
            }
            let horizontalStrength = mean(mapped.map { hypot($0.x, $0.y) })
            let dot = zip(queryVectors, mapped).map { $0.x * $1.x + $0.y * $1.y }.reduce(0, +)
            let cross = zip(queryVectors, mapped).map { $0.x * $1.y - $0.y * $1.x }.reduce(0, +)
            let magneticDelta = atan2(cross, dot)
            let cosine = cos(magneticDelta)
            let sine = sin(magneticDelta)
            let squaredError = zip(queryVectors, mapped).map { query, reference in
                let x = cosine * query.x - sine * query.y
                let y = sine * query.x + cosine * query.y
                return pow(x - reference.x, 2) + pow(y - reference.y, 2)
            }
            let fitResidual = sqrt(mean(squaredError)) / max(horizontalStrength, 1e-9)
            let measuredHeading = circularMean(selected.map(\.sensorHeading))
            let expectedHeading = initialHeading - Double(segment) * .pi / 2
            let pdrResidual = wrap(expectedHeading - measuredHeading)
            let agreementDegrees = abs(wrap(magneticDelta - pdrResidual) * 180 / .pi)
            var status = "accepted"
            if horizontalStrength < 10 {
                status = "weak_horizontal_field"
            } else if abs(pdrResidual * 180 / .pi) < 1 {
                status = "insufficient_pdr_residual"
            } else if magneticDelta * pdrResidual <= 0 {
                status = "direction_disagreement"
            } else if fitResidual > 0.20 {
                status = "high_fit_residual"
            }
            var confidence = 0.0
            if status == "accepted" {
                let fitConfidence = exp(-pow(fitResidual / 0.20, 2))
                let agreementConfidence = exp(-pow(agreementDegrees / 10, 2))
                confidence = progressConfidences[segment] * fitConfidence * agreementConfidence
                targetCorrections.append(magneticDelta)
                currentCorrections.append(wrap(currentHeadings[segment] - measuredHeading))
                acceptedWeights.append(confidence)
            }
            headingStatuses.append(status)
            headingDeltas.append(magneticDelta * 180 / .pi)
            headingResiduals.append(fitResidual)
            headingConfidences.append(confidence)
        }

        var globalGain = 0.0
        var adjustment = 0.0
        let weightTotal = acceptedWeights.reduce(0, +)
        if weightTotal > 1e-9 {
            let target = weightedCircularMean(targetCorrections, weights: acceptedWeights)
            let current = weightedCircularMean(currentCorrections, weights: acceptedWeights)
            globalGain = 0.35 * mean(acceptedWeights)
            adjustment = globalGain * wrap(target - current)
        }
        return ControlledMagneticFusionOutput(
            stepLengths: correctedLengths,
            segmentHeadings: currentHeadings.map { $0 + adjustment },
            diagnostics: diagnostics(
                calibrationSourceKey: templateSourceLabel,
                progressStatuses: progressStatuses,
                progressConfidences: progressConfidences,
                progressGains: progressGains,
                progressCorrelations: progressCorrelations,
                progressCosts: progressCosts,
                progressShifts: progressShifts,
                headingStatuses: headingStatuses,
                headingDeltas: headingDeltas,
                headingResiduals: headingResiduals,
                headingConfidences: headingConfidences,
                adjustment: adjustment,
                globalGain: globalGain,
                fallbackReason: missingAlignedField ? "missing_attitude_aligned_field" : nil
            )
        )
    }

    private static func fallback(
        steps: [ControlledMagneticStepInput],
        calibrationSourceKey: String,
        reason: String
    ) -> ControlledMagneticFusionOutput {
        let headings = (0..<4).map { segment in
            steps.first { $0.segmentIndex == segment }?.fusedHeading ?? 0
        }
        return ControlledMagneticFusionOutput(
            stepLengths: steps.map(\.length),
            segmentHeadings: headings,
            diagnostics: diagnostics(
                calibrationSourceKey: calibrationSourceKey,
                progressStatuses: Array(repeating: reason, count: 4),
                progressConfidences: Array(repeating: 0, count: 4),
                progressGains: Array(repeating: 0, count: 4),
                progressCorrelations: Array(repeating: 0, count: 4),
                progressCosts: Array(repeating: nil, count: 4),
                progressShifts: Array(repeating: 0, count: 4),
                headingStatuses: Array(repeating: reason, count: 4),
                headingDeltas: Array(repeating: 0, count: 4),
                headingResiduals: Array(repeating: nil, count: 4),
                headingConfidences: Array(repeating: 0, count: 4),
                adjustment: 0,
                globalGain: 0,
                fallbackReason: reason
            )
        )
    }

    private static func diagnostics(
        calibrationSourceKey: String,
        progressStatuses: [String],
        progressConfidences: [Double],
        progressGains: [Double],
        progressCorrelations: [Double],
        progressCosts: [Double?],
        progressShifts: [Double],
        headingStatuses: [String],
        headingDeltas: [Double],
        headingResiduals: [Double?],
        headingConfidences: [Double],
        adjustment: Double,
        globalGain: Double,
        fallbackReason: String?
    ) -> MagneticFusionDiagnostics {
        MagneticFusionDiagnostics(
            profile: "controlled_core_motion_magnetic_yaw_native_v1",
            calibrationSourceKey: calibrationSourceKey,
            progressStatusBySegment: progressStatuses,
            progressConfidenceBySegment: progressConfidences,
            progressGainBySegment: progressGains,
            progressCorrelationBySegment: progressCorrelations,
            progressCostBySegment: progressCosts,
            progressShiftMeanBySegment: progressShifts,
            progressMatchedSegments: progressStatuses.count { $0 == "accepted" },
            headingStatusBySegment: headingStatuses,
            headingDeltaDegreesBySegment: headingDeltas,
            headingFitResidualBySegment: headingResiduals,
            headingConfidenceBySegment: headingConfidences,
            headingGlobalAdjustmentDegrees: adjustment * 180 / .pi,
            headingGlobalGain: globalGain,
            headingMatchedSegments: headingStatuses.count { $0 == "accepted" },
            fallbackReason: fallbackReason
        )
    }

    private static func alignProgress(
        referenceValues: [Double],
        referenceProgress: [Double],
        queryValues: [Double],
        queryProgress: [Double]
    ) -> Alignment {
        let referenceSpan = (referenceValues.max() ?? 0) - (referenceValues.min() ?? 0)
        let querySpan = (queryValues.max() ?? 0) - (queryValues.min() ?? 0)
        var reason = "accepted"
        var correlation = 0.0
        var cost: Double?
        var matched = queryProgress
        if min(referenceValues.count, queryValues.count) < 5 {
            reason = "too_few_samples"
        } else if min(referenceSpan, querySpan) < 1 {
            reason = "insufficient_magnetic_variation"
        } else {
            correlation = profileCorrelation(
                referenceValues: referenceValues,
                referenceProgress: referenceProgress,
                queryValues: queryValues,
                queryProgress: queryProgress
            )
            let result = endpointConstrainedDTW(
                referenceValues: referenceValues,
                referenceProgress: referenceProgress,
                queryValues: queryValues,
                bandRatio: 0.35
            )
            matched = result.matched
            cost = result.cost
            if correlation < 0.75 {
                reason = "low_correlation"
            } else if result.cost > 0.75 {
                reason = "high_alignment_cost"
            }
        }
        var confidence = 0.0
        var gain = 0.0
        if reason == "accepted", let cost {
            let sampleConfidence = clamp((Double(min(referenceValues.count, queryValues.count)) - 3) / 7)
            let variationConfidence = clamp(min(referenceSpan, querySpan) / 2)
            let correlationConfidence = clamp((correlation - 0.75) / 0.25)
            let costConfidence = clamp(1 - cost / 0.75)
            confidence = sqrt(sampleConfidence * variationConfidence * correlationConfidence * costConfidence)
            gain = 0.30 * confidence
        }
        var corrected = zip(queryProgress, matched).map { (1 - gain) * $0 + gain * $1 }
        for index in 1..<corrected.count { corrected[index] = max(corrected[index], corrected[index - 1]) }
        if !corrected.isEmpty { corrected[corrected.count - 1] = 1 }
        return Alignment(
            progress: corrected,
            reason: reason,
            confidence: confidence,
            gain: gain,
            correlation: correlation,
            normalizedCost: cost
        )
    }

    private static func profileCorrelation(
        referenceValues: [Double],
        referenceProgress: [Double],
        queryValues: [Double],
        queryProgress: [Double]
    ) -> Double {
        let axis = (0..<64).map { Double($0) / 63 }
        let reference = axis.map { interpolate(referenceValues, axis: referenceProgress, at: $0) }
        let query = axis.map { interpolate(queryValues, axis: queryProgress, at: $0) }
        let referenceDeviation = standardDeviation(reference)
        let queryDeviation = standardDeviation(query)
        guard referenceDeviation >= 1e-9, queryDeviation >= 1e-9 else { return 0 }
        let referenceMean = mean(reference)
        let queryMean = mean(query)
        let covariance = zip(reference, query)
            .map { ($0 - referenceMean) * ($1 - queryMean) }
            .reduce(0, +) / Double(reference.count)
        return covariance / (referenceDeviation * queryDeviation)
    }

    private static func endpointConstrainedDTW(
        referenceValues: [Double],
        referenceProgress: [Double],
        queryValues: [Double],
        bandRatio: Double
    ) -> (matched: [Double], cost: Double) {
        let referenceMean = mean(referenceValues)
        let queryMean = mean(queryValues)
        let referenceScale = max(standardDeviation(referenceValues), 0.3)
        let queryScale = max(standardDeviation(queryValues), 0.3)
        let reference = referenceValues.map { ($0 - referenceMean) / referenceScale }
        let query = queryValues.map { ($0 - queryMean) / queryScale }
        let rows = query.count
        let columns = reference.count
        var costs = Array(repeating: Double.infinity, count: rows * columns)
        var previousRow = Array(repeating: -1, count: rows * columns)
        var previousColumn = Array(repeating: -1, count: rows * columns)
        func offset(_ row: Int, _ column: Int) -> Int { row * columns + column }
        for row in 0..<rows {
            let rowFraction = Double(row) / Double(max(rows - 1, 1))
            for column in 0..<columns {
                let columnFraction = Double(column) / Double(max(columns - 1, 1))
                guard abs(rowFraction - columnFraction) <= bandRatio else { continue }
                let emission = pow(query[row] - reference[column], 2)
                let current = offset(row, column)
                if row == 0 && column == 0 {
                    costs[current] = emission
                    continue
                }
                var candidates: [(Double, Int, Int)] = []
                if row > 0 { candidates.append((costs[offset(row - 1, column)] + 0.08, row - 1, column)) }
                if column > 0 { candidates.append((costs[offset(row, column - 1)] + 0.08, row, column - 1)) }
                if row > 0 && column > 0 { candidates.append((costs[offset(row - 1, column - 1)], row - 1, column - 1)) }
                guard let best = candidates.min(by: { $0.0 < $1.0 }) else { continue }
                costs[current] = best.0 + emission
                previousRow[current] = best.1
                previousColumn[current] = best.2
            }
        }
        var row = rows - 1
        var column = columns - 1
        var path: [(Int, Int)] = []
        while row >= 0 && column >= 0 {
            path.append((row, column))
            let current = offset(row, column)
            let nextRow = previousRow[current]
            let nextColumn = previousColumn[current]
            if nextRow < 0 { break }
            row = nextRow
            column = nextColumn
        }
        path.reverse()
        var matched = (0..<rows).map { queryIndex in
            mean(path.filter { $0.0 == queryIndex }.map { referenceProgress[$0.1] })
        }
        for index in 1..<matched.count { matched[index] = max(matched[index], matched[index - 1]) }
        matched[matched.count - 1] = 1
        return (matched, costs[offset(rows - 1, columns - 1)] / Double(max(path.count, 1)))
    }

    private static func cumulativeProgress(_ values: [Double]) -> [Double] {
        let total = values.reduce(0, +)
        var cumulative = 0.0
        return values.map {
            cumulative += $0
            return cumulative / max(total, 1e-9)
        }
    }

    private static func interpolate(_ values: [Double], axis: [Double], at value: Double) -> Double {
        guard let first = values.first, let last = values.last, !axis.isEmpty else { return 0 }
        if value <= axis[0] { return first }
        if value >= axis[axis.count - 1] { return last }
        var upper = 1
        while upper < axis.count && axis[upper] < value { upper += 1 }
        let lower = upper - 1
        let span = axis[upper] - axis[lower]
        let ratio = span <= 1e-12 ? 0 : (value - axis[lower]) / span
        return values[lower] + (values[upper] - values[lower]) * ratio
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let average = mean(values)
        return sqrt(values.map { pow($0 - average, 2) }.reduce(0, +) / Double(values.count))
    }

    private static func circularMean(_ values: [Double]) -> Double {
        atan2(mean(values.map(sin)), mean(values.map(cos)))
    }

    private static func weightedCircularMean(_ values: [Double], weights: [Double]) -> Double {
        atan2(
            zip(values, weights).map { sin($0) * $1 }.reduce(0, +),
            zip(values, weights).map { cos($0) * $1 }.reduce(0, +)
        )
    }

    private static func wrap(_ value: Double) -> Double {
        atan2(sin(value), cos(value))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
