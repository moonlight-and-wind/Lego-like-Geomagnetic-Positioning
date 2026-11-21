import Foundation

struct XYPoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
    }
}

struct ErrorStatistics: Codable {
    let mean: Double
    let median: Double
    let p95: Double
    let final: Double
}

struct PFConfidenceSample: Codable, Hashable {
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

struct LocalizationHealthSample: Codable, Hashable {
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

struct ActiveWalkInterval: Codable, Hashable {
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

struct HeadingDiagnostics: Codable, Hashable, Sendable {
    let method: String
    let deviceMotionAvailable: Bool
    let deviceMotionAccepted: Bool
    let deviceMotionSampleCount: Int
    let coverageRatio: Double?
    let calibratedRatio: Double?
    let maximumGapSeconds: Double?
    let gyroAgreementRMSEDegrees: Double?
    let rejectionReason: String?

    enum CodingKeys: String, CodingKey {
        case method
        case deviceMotionAvailable = "device_motion_available"
        case deviceMotionAccepted = "device_motion_accepted"
        case deviceMotionSampleCount = "device_motion_sample_count"
        case coverageRatio = "coverage_ratio"
        case calibratedRatio = "calibrated_ratio"
        case maximumGapSeconds = "maximum_gap_seconds"
        case gyroAgreementRMSEDegrees = "gyro_agreement_rms_deg"
        case rejectionReason = "rejection_reason"
    }

    var localizedMethod: String {
        switch method {
        case "core_motion_relative_yaw": "Core Motion 相对航向"
        default: "陀螺仪积分"
        }
    }

    var localizedRejectionReason: String? {
        switch rejectionReason {
        case "missing_device_motion": "未提供 DeviceMotion.csv"
        case "insufficient_samples": "姿态样本不足"
        case "insufficient_coverage": "姿态数据未覆盖完整行走区间"
        case "magnetic_calibration_low": "磁场校准有效比例不足"
        case "timestamp_gap": "姿态数据存在过长断点"
        case "implausible_yaw_rate": "姿态航向变化速度异常"
        case "rotation_direction_mismatch": "姿态与陀螺旋转方向矛盾"
        default: rejectionReason
        }
    }
}

struct ControlledMotionDiagnostics: Codable, Hashable, Sendable {
    let releaseID: String
    let profile: String
    let deploymentStatus: String
    let calibrationSourceKey: String
    let turnRegionsDetected: Int
    let turnTranslationStepsRemoved: Int
    let postEndpointPeaksRemoved: Int
    let segmentStepCounts: [Int]
    let estimatedSegmentLengthsM: [Double]
    let effectiveDistancePrior: [Double]
    let segmentHeadingsDegrees: [Double]
    let turnPartitionMethod: String?
    let legacyParticleFilterExcluded: Bool
    let rejectionReason: String?

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case profile
        case deploymentStatus = "deployment_status"
        case calibrationSourceKey = "calibration_source_key"
        case turnRegionsDetected = "turn_regions_detected"
        case turnTranslationStepsRemoved = "turn_translation_steps_removed"
        case postEndpointPeaksRemoved = "post_endpoint_peaks_removed"
        case segmentStepCounts = "segment_step_counts"
        case estimatedSegmentLengthsM = "estimated_segment_lengths_m"
        case effectiveDistancePrior = "effective_distance_prior_by_segment"
        case segmentHeadingsDegrees = "segment_headings_deg"
        case turnPartitionMethod = "turn_partition_method"
        case legacyParticleFilterExcluded = "legacy_particle_filter_excluded"
        case rejectionReason = "rejection_reason"
    }

    var localizedStatus: String {
        rejectionReason == nil ? "封版受控路线配置" : "受控配置未采用"
    }

    var localizedRejectionReason: String? {
        switch rejectionReason {
        case "core_motion_heading_unavailable": "Core Motion 航向未通过质量门控"
        case "quarter_turns_not_detected": "没有可靠检测到四次直角转弯"
        case "empty_straight_segment": "至少一个直行段没有有效步态"
        default: rejectionReason
        }
    }
}

struct MagneticFusionDiagnostics: Codable, Hashable, Sendable {
    let profile: String
    let calibrationSourceKey: String
    let progressStatusBySegment: [String]
    let progressConfidenceBySegment: [Double]
    let progressGainBySegment: [Double]
    let progressCorrelationBySegment: [Double]
    let progressCostBySegment: [Double?]
    let progressShiftMeanBySegment: [Double]
    let progressMatchedSegments: Int
    let headingStatusBySegment: [String]
    let headingDeltaDegreesBySegment: [Double]
    let headingFitResidualBySegment: [Double?]
    let headingConfidenceBySegment: [Double]
    let headingGlobalAdjustmentDegrees: Double
    let headingGlobalGain: Double
    let headingMatchedSegments: Int
    let fallbackReason: String?

    enum CodingKeys: String, CodingKey {
        case profile
        case calibrationSourceKey = "calibration_source_key"
        case progressStatusBySegment = "magnetic_progress_status_by_segment"
        case progressConfidenceBySegment = "magnetic_progress_confidence_by_segment"
        case progressGainBySegment = "magnetic_progress_gain_by_segment"
        case progressCorrelationBySegment = "magnetic_progress_correlation_by_segment"
        case progressCostBySegment = "magnetic_progress_cost_by_segment"
        case progressShiftMeanBySegment = "magnetic_progress_shift_mean_by_segment"
        case progressMatchedSegments = "magnetic_progress_matched_segments"
        case headingStatusBySegment = "magnetic_heading_status_by_segment"
        case headingDeltaDegreesBySegment = "magnetic_heading_delta_deg_by_segment"
        case headingFitResidualBySegment = "magnetic_heading_fit_residual_by_segment"
        case headingConfidenceBySegment = "magnetic_heading_confidence_by_segment"
        case headingGlobalAdjustmentDegrees = "magnetic_heading_global_adjustment_deg"
        case headingGlobalGain = "magnetic_heading_global_gain"
        case headingMatchedSegments = "magnetic_heading_matched_segments"
        case fallbackReason = "fallback_reason"
    }

    var localizedFallbackReason: String? {
        switch fallbackReason {
        case "missing_template": "没有找到对应路线的磁模板"
        case "missing_attitude_aligned_field": "DeviceMotion 缺少可用的姿态对齐磁场"
        default: fallbackReason
        }
    }
}

struct PositioningResult: Codable {
    let branch: String
    let datasetKey: String
    let routeLabel: String
    let routeXY: [XYPoint]
    let pdrTrack: [XYPoint]
    let pfTrack: [XYPoint]
    let pdrErrorStats: ErrorStatistics?
    let pfErrorStats: ErrorStatistics?
    let controlledCrossTrackErrorStats: ErrorStatistics?
    let closureErrorM: Double?
    let pdrCrossTrackErrorStats: ErrorStatistics?
    let pfCrossTrackErrorStats: ErrorStatistics?
    let pdrAlongTrackErrorStats: ErrorStatistics?
    let pfAlongTrackErrorStats: ErrorStatistics?
    let pdrTurnAngleErrorStats: ErrorStatistics?
    let pfTurnAngleErrorStats: ErrorStatistics?
    let pdrPathLengthRatio: Double?
    let pfPathLengthRatio: Double?
    let pdrClosureErrorM: Double?
    let pfClosureErrorM: Double?
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
    let headingDiagnostics: HeadingDiagnostics?
    let controlledMotionDiagnostics: ControlledMotionDiagnostics?
    let magneticFusionDiagnostics: MagneticFusionDiagnostics?
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
        case controlledCrossTrackErrorStats = "controlled_cross_track_error_stats"
        case closureErrorM = "closure_error_m"
        case pdrCrossTrackErrorStats = "pdr_cross_track_error_stats"
        case pfCrossTrackErrorStats = "pf_cross_track_error_stats"
        case pdrAlongTrackErrorStats = "pdr_along_track_error_stats"
        case pfAlongTrackErrorStats = "pf_along_track_error_stats"
        case pdrTurnAngleErrorStats = "pdr_turn_angle_error_stats_deg"
        case pfTurnAngleErrorStats = "pf_turn_angle_error_stats_deg"
        case pdrPathLengthRatio = "pdr_path_length_ratio"
        case pfPathLengthRatio = "pf_path_length_ratio"
        case pdrClosureErrorM = "pdr_closure_error_m"
        case pfClosureErrorM = "pf_closure_error_m"
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
        case headingDiagnostics = "heading_diagnostics"
        case controlledMotionDiagnostics = "controlled_motion_diagnostics"
        case magneticFusionDiagnostics = "magnetic_fusion_diagnostics"
        case pfConfidenceHistory = "pf_confidence_history"
        case localizationHealthHistory = "localization_health_history"
        case localizationRecoveryEvents = "localization_recovery_events"
    }
}

extension PositioningResult {
    var displayName: String {
        datasetKey.replacingOccurrences(of: "_", with: " ")
    }

    var friendlyTitle: String {
        let parts = datasetKey.split(separator: "_")
        if parts.count == 3,
           parts[0] == "route",
           let index = Int(parts[2]) {
            return "Route \(parts[1]) · 第 \(index) 次（留出）"
        }
        return datasetKey
    }

    var finalPFConfidence: PFConfidenceSample? {
        pfConfidenceHistory?.last
    }

    var overallPFConfidenceScore: Double? {
        guard let history = pfConfidenceHistory, !history.isEmpty else { return nil }
        return history.reduce(0.0) { $0 + $1.score } / Double(history.count)
    }

    var overallPFConfidenceLevel: String? {
        overallPFConfidenceScore.map { score in
            score >= 0.75 ? "高" : score >= 0.45 ? "中" : "低"
        }
    }

    var meanPFGlobalAmbiguity: Double? {
        let values = pfConfidenceHistory?.compactMap(\.globalAmbiguity) ?? []
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var maximumPFGlobalAmbiguity: Double? {
        pfConfidenceHistory?.compactMap(\.globalAmbiguity).max()
    }

    var finalLocalizationHealth: LocalizationHealthSample? {
        localizationHealthHistory?.last
    }
}
