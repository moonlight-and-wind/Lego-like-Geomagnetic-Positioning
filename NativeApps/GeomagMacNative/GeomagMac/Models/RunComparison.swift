import Foundation

struct ComparisonRun: Identifiable {
    let record: RunRecord
    let result: PositioningResult
    let colorIndex: Int

    var id: String { record.id }
    var letter: String { RunComparison.letter(for: colorIndex) }
}

struct ComparisonParameter: Identifiable, Equatable {
    let id: String
    let label: String
    let values: [String]
    let isDifferent: Bool
}

enum ComparisonMetric: String, CaseIterable, Identifiable {
    case finalError
    case crossTrack
    case alongTrack
    case turnAngle
    case pathRatio
    case closure
    case confidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .finalError: "PF 终点误差"
        case .crossTrack: "PF 横向误差"
        case .alongTrack: "PF 沿程误差"
        case .turnAngle: "PF 转角误差"
        case .pathRatio: "PF 路程比例"
        case .closure: "PF 闭合误差"
        case .confidence: "平均可靠度"
        }
    }

    func value(from result: PositioningResult) -> Double? {
        switch self {
        case .finalError: result.pfErrorStats?.final
        case .crossTrack: result.pfCrossTrackErrorStats?.mean
        case .alongTrack: result.pfAlongTrackErrorStats?.mean
        case .turnAngle: result.pfTurnAngleErrorStats?.mean
        case .pathRatio: result.pfPathLengthRatio
        case .closure: result.pfClosureErrorM
        case .confidence: result.overallPFConfidenceScore
        }
    }

    func display(_ value: Double?) -> String {
        guard let value else { return "—" }
        let locale = Locale(identifier: "en_US_POSIX")
        switch self {
        case .finalError, .crossTrack, .alongTrack, .closure:
            return String(format: "%.2f m", locale: locale, value)
        case .turnAngle:
            return String(format: "%.1f°", locale: locale, value)
        case .pathRatio, .confidence:
            return String(format: "%.0f%%", locale: locale, value * 100)
        }
    }

    func bestIndices(in values: [Double?]) -> Set<Int> {
        let present = values.enumerated().compactMap { index, value in
            value.map { (index, $0) }
        }
        guard !present.isEmpty else { return [] }

        switch self {
        case .finalError, .crossTrack, .alongTrack, .turnAngle, .closure:
            guard let best = present.map({ $0.1 }).min() else { return [] }
            return Set(present.filter { abs($0.1 - best) <= 1e-9 }.map { $0.0 })
        case .confidence:
            guard let best = present.map({ $0.1 }).max() else { return [] }
            return Set(present.filter { abs($0.1 - best) <= 1e-9 }.map { $0.0 })
        case .pathRatio:
            guard let best = present.map({ abs($0.1 - 1) }).min() else { return [] }
            return Set(
                present.filter { abs(abs($0.1 - 1) - best) <= 1e-9 }.map { $0.0 }
            )
        }
    }
}

enum RunComparison {
    static let maximumRunCount = 4
    static let letters = ["A", "B", "C", "D"]

    static func letter(for colorIndex: Int) -> String {
        guard letters.indices.contains(colorIndex) else { return "—" }
        return letters[colorIndex]
    }

    static func displayRouteLabel(_ label: String) -> String {
        let parts = label.split(separator: "_", omittingEmptySubsequences: false)
        if parts.count == 2,
           parts[0].lowercased() == "route",
           let number = Int(parts[1]) {
            return "Route \(number)"
        }
        let spaced = label.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return spaced.isEmpty ? "未命名路线" : spaced
    }

    static func title(for results: [PositioningResult]) -> String {
        guard let first = results.first, results.count > 1 else {
            return "多运行对比"
        }
        let labels = Set(results.map(\.routeLabel).filter { !$0.isEmpty })
        if labels.count == 1 {
            return "\(displayRouteLabel(first.routeLabel)) · \(results.count) 次运行对比"
        }
        return "\(results.count) 次运行对比"
    }

    static func routesMatch(
        _ results: [PositioningResult],
        tolerance: Double = 0.01
    ) -> Bool {
        guard let first = results.first else { return true }
        return results.dropFirst().allSatisfy { result in
            guard result.routeXY.count == first.routeXY.count else { return false }
            return zip(first.routeXY, result.routeXY).allSatisfy { lhs, rhs in
                hypot(lhs.x - rhs.x, lhs.y - rhs.y) <= tolerance
            }
        }
    }

    static func parameterRows(
        for results: [PositioningResult]
    ) -> [ComparisonParameter] {
        let rows: [(id: String, label: String, values: [ParameterValue])] = [
            (
                "smoothing_mode",
                "平滑模式",
                results.map { smoothing($0.pfSmoothingMode) }
            ),
            (
                "smoothing_alpha",
                "平滑系数 α",
                results.map { number($0.pfSmoothingAlpha, format: "%.2f") }
            ),
            (
                "heading_snap_deg",
                "航向吸附",
                results.map { number($0.headingSnapDegrees, format: "%.1f", suffix: "°") }
            ),
            (
                "step_length_scale",
                "步长比例",
                results.map { number($0.stepLengthScale, format: "%.2f", suffix: "×") }
            ),
            (
                "joint_calibration",
                "联合校准",
                results.map { boolean($0.pfJointCalibration) }
            ),
            (
                "vector_map",
                "矢量地图",
                results.map { boolean($0.vectorMapEnabled) }
            ),
            (
                "alignment_mode",
                "对齐模式",
                results.map { alignment($0.alignmentMode) }
            ),
        ]

        return rows.map { row in
            ComparisonParameter(
                id: row.id,
                label: row.label,
                values: row.values.map(\.display),
                isDifferent: Set(row.values.map(\.key)).count > 1
            )
        }
    }

    private struct ParameterValue {
        let display: String
        let key: String

        static let missing = ParameterValue(display: "未记录", key: "missing")
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static func smoothing(_ raw: String?) -> ParameterValue {
        guard let raw, !raw.isEmpty else { return .missing }
        let display = switch raw {
        case "none": "不平滑"
        case "ema": "EMA"
        case "motion_adaptive": "运动自适应"
        default: raw
        }
        return ParameterValue(display: display, key: raw)
    }

    private static func number(
        _ value: Double?,
        format: String,
        suffix: String = ""
    ) -> ParameterValue {
        guard let value else { return .missing }
        return ParameterValue(
            display: String(format: format, locale: locale, value) + suffix,
            key: String(format: "%.6f", locale: locale, value)
        )
    }

    private static func boolean(_ value: Bool?) -> ParameterValue {
        guard let value else { return .missing }
        return ParameterValue(
            display: value ? "开" : "关",
            key: value ? "true" : "false"
        )
    }

    private static func alignment(_ raw: String?) -> ParameterValue {
        guard let raw, !raw.isEmpty else { return .missing }
        let display = switch raw {
        case "cross_track_endpoint_closure": "横切 + 终点闭合"
        case "route_corridor_validation": "路线走廊验证"
        case "room_area_known_start": "房间自由（已知起点）"
        default: raw
        }
        return ParameterValue(display: display, key: raw)
    }
}
