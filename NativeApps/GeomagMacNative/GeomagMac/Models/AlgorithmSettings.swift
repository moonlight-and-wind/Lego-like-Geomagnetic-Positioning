import Foundation

struct AlgorithmSettings: Codable, Equatable, Sendable {
    enum SmoothingMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case none
        case ema
        case motionAdaptive = "motion_adaptive"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "不平滑"
            case .ema: "EMA"
            case .motionAdaptive: "运动自适应"
            }
        }
    }

    var smoothingMode: SmoothingMode
    var smoothingAlpha: Double
    var headingSnapDegrees: Double
    var stepLengthScale: Double
    var jointCalibrationEnabled: Bool
    var vectorMapEnabled: Bool

    static let optimized = AlgorithmSettings(
        smoothingMode: .ema,
        smoothingAlpha: 0.30,
        headingSnapDegrees: 0,
        stepLengthScale: 1.0,
        jointCalibrationEnabled: true,
        vectorMapEnabled: false
    )

    static let rawParticleFilter = AlgorithmSettings(
        smoothingMode: .none,
        smoothingAlpha: 0,
        headingSnapDegrees: 0,
        stepLengthScale: 1.0,
        jointCalibrationEnabled: true,
        vectorMapEnabled: false
    )

    var logSummary: String {
        "平滑=\(smoothingMode.rawValue), α=\(Self.cliNumber(smoothingAlpha)), "
            + "步长比例=\(Self.cliNumber(stepLengthScale)), "
            + "联合校准=\(jointCalibrationEnabled ? "开" : "关"), "
            + "矢量地图=\(vectorMapEnabled ? "开" : "关")"
    }

    private static func cliNumber(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

enum AlgorithmPreset: String, CaseIterable, Identifiable, Codable {
    case optimized
    case rawParticleFilter
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimized: "当前优化基线"
        case .rawParticleFilter: "原始 PF（不平滑）"
        case .custom: "自定义"
        }
    }

    var detail: String {
        switch self {
        case .optimized:
            "纯 Swift 原生算法的稳定默认参数，适合一般测试。"
        case .rawParticleFilter:
            "关闭显示轨迹平滑，用于观察粒子滤波原始抖动。"
        case .custom:
            "使用下方手动调整的参数。"
        }
    }

    var settings: AlgorithmSettings? {
        switch self {
        case .optimized: .optimized
        case .rawParticleFilter: .rawParticleFilter
        case .custom: nil
        }
    }
}
