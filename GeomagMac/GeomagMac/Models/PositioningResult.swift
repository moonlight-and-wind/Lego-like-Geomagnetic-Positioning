import Foundation

struct XYPoint: Decodable, Hashable {
    let x: Double
    let y: Double

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
    }
}

struct ErrorStatistics: Decodable {
    let mean: Double
    let median: Double
    let p95: Double
    let final: Double
}

struct PFConfidenceSample: Decodable, Hashable {
    let radius95M: Double
    let coreRadius80M: Double?
    let sigmaMajorM: Double
    let sigmaMinorM: Double
    let essRatio: Double
    let measurementInformation: Double?
    let globalAmbiguity: Double?
    let score: Double
    let level: String

    enum CodingKeys: String, CodingKey {
        case radius95M = "radius95_m"
        case coreRadius80M = "core_radius80_m"
        case sigmaMajorM = "sigma_major_m"
        case sigmaMinorM = "sigma_minor_m"
        case essRatio = "ess_ratio"
        case measurementInformation = "measurement_information"
        case globalAmbiguity = "global_ambiguity"
        case score
        case level
    }

    var localizedLevel: String {
        switch level.lowercased() {
        case "high": "高"
        case "medium": "中"
        default: "低"
        }
    }
}

struct LocalizationHealthSample: Decodable, Hashable {
    let stepIndex: Int
    let status: String
    let score: Double
    let lowConfidenceStreak: Int
    let lostStreak: Int
    let action: String
    let reasonCodes: [String]
    let recoveryCount: Int

    enum CodingKeys: String, CodingKey {
        case stepIndex = "step_index"
        case status
        case score
        case lowConfidenceStreak = "low_confidence_streak"
        case lostStreak = "lost_streak"
        case action
        case reasonCodes = "reason_codes"
        case recoveryCount = "recovery_count"
    }

    var localizedStatus: String {
        switch status.lowercased() {
        case "healthy": "稳定"
        case "degraded": "传感器降级"
        case "ambiguous": "存在歧义"
        case "lost": "可能失效"
        case "recovering": "正在恢复"
        default: status
        }
    }

    var localizedAction: String? {
        switch action.lowercased() {
        case "expand_search": "已扩大粒子搜索范围"
        case "reinitialize": "已重新初始化粒子"
        case "reinitialize_anchor": "已按可信起点重新初始化"
        case "reinitialize_heading": "已隔离异常航向并重新定位"
        case "concentrate_heading": "航向恢复后已收紧粒子"
        default: nil
        }
    }
}

struct ActiveWalkInterval: Decodable, Hashable {
    let startTime: Double
    let endTime: Double
    let duration: Double
    let headExcluded: Double
    let tailExcluded: Double
    let confidence: String

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case headExcluded = "head_excluded"
        case tailExcluded = "tail_excluded"
        case confidence
    }
}

struct PositioningResult: Decodable {
    let branch: String
    let datasetKey: String
    let routeLabel: String
    let routeXY: [XYPoint]
    let pdrTrack: [XYPoint]
    let pfTrack: [XYPoint]
    let pdrErrorStats: ErrorStatistics?
    let pfErrorStats: ErrorStatistics?
    let stepsDetected: Int?
    let sensorFramesUsed: Int?
    let fullSensorFrames: Int?
    let pfSmoothingMode: String?
    let pfSmoothingAlpha: Double?
    let headingSnapDegrees: Double?
    let stepLengthScale: Double?
    let vectorMapEnabled: Bool?
    let pfJointCalibration: Bool?
    let alignmentMode: String?
    let mapBounds: [Double]?
    let activeWalkInterval: ActiveWalkInterval?
    let pfConfidenceHistory: [PFConfidenceSample]?
    let localizationHealthHistory: [LocalizationHealthSample]?
    let localizationRecoveryEvents: [LocalizationHealthSample]?

    enum CodingKeys: String, CodingKey {
        case branch
        case datasetKey = "dataset_key"
        case routeLabel = "route_label"
        case routeXY = "route_xy_m"
        case pdrTrack = "pdr_track"
        case pfTrack = "pf_track"
        case pdrErrorStats = "pdr_error_stats"
        case pfErrorStats = "pf_error_stats"
        case stepsDetected = "steps_detected"
        case sensorFramesUsed = "sensor_frames_used"
        case fullSensorFrames = "full_sensor_frames"
        case pfSmoothingMode = "pf_smoothing_mode"
        case pfSmoothingAlpha = "pf_smoothing_alpha"
        case headingSnapDegrees = "heading_snap_deg"
        case stepLengthScale = "step_length_scale"
        case vectorMapEnabled = "vector_map_enabled"
        case pfJointCalibration = "pf_joint_calibration"
        case alignmentMode = "alignment_mode"
        case mapBounds = "map_bounds"
        case activeWalkInterval = "active_walk_interval"
        case pfConfidenceHistory = "pf_confidence_history"
        case localizationHealthHistory = "localization_health_history"
        case localizationRecoveryEvents = "localization_recovery_events"
    }
}

extension PositioningResult {
    var displayName: String {
        datasetKey.replacingOccurrences(of: "_", with: " ")
    }

    var finalPFConfidence: PFConfidenceSample? {
        pfConfidenceHistory?.last
    }

    var finalLocalizationHealth: LocalizationHealthSample? {
        localizationHealthHistory?.last
    }
}
