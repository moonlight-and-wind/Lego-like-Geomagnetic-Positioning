import Foundation

enum Stage: Int, CaseIterable, Identifiable, Codable {
    case data = 0
    case map
    case run
    case analysis

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .data: "数据"
        case .map: "磁图"
        case .run: "运行"
        case .analysis: "分析"
        }
    }

    var shortTitle: String { title }
}

enum StageIssue: String, CaseIterable, Equatable {
    case noDataset
    case emptyDatasetName
    case invalidRoute
    case routeGeometry
    case invalidHeading
    case noMap
    case mapBuiltFromCurrentDataset
    case coordinateFrameMismatch
    case routeOutsideMap
    case roomModeNeedsHeading

    var stage: Stage {
        switch self {
        case .noDataset, .emptyDatasetName, .invalidRoute, .routeGeometry, .invalidHeading:
            .data
        case .noMap, .mapBuiltFromCurrentDataset, .coordinateFrameMismatch,
             .routeOutsideMap, .roomModeNeedsHeading:
            .map
        }
    }

    var message: String {
        switch self {
        case .noDataset:
            "先选择采集文件夹或内置留出数据。"
        case .emptyDatasetName:
            "数据集名称不能为空。"
        case .invalidRoute:
            "真实路线至少需要两个有效坐标点。"
        case .routeGeometry:
            "真实路线存在重复点或近 180° 原路折返，请检查点序。"
        case .invalidHeading:
            "初始航向必须是有效数字；留空时由路线前两点推算。"
        case .noMap:
            "还没有覆盖当前区域的地磁图。"
        case .mapBuiltFromCurrentDataset:
            "建图采集不能用于自我验证，请换一组独立采集。"
        case .coordinateFrameMismatch:
            "采集包与所选磁图的坐标系不一致。"
        case .routeOutsideMap:
            "真实路线超出所选磁图的覆盖范围。"
        case .roomModeNeedsHeading:
            "房间自由定位必须填写已知初始航向。"
        }
    }
}

struct PipelineInputs: Equatable {
    var hasDataset: Bool
    var usesBundledDataset: Bool
    var datasetNameIsEmpty: Bool
    var routeIsValid: Bool
    var routeGeometryIsValid: Bool
    var headingIsValid: Bool
    var routeIsInsideMap: Bool
    var hasMap: Bool
    var mapBuiltFromCurrentDataset: Bool
    var coordinateFrameMatches: Bool
    var localizationModeNeedsHeading: Bool
    var hasExplicitHeading: Bool
    var isRunning: Bool
    var hasResult: Bool
}

struct PipelineReadiness: Equatable {
    let issues: [StageIssue]
    let dataReady: Bool
    let mapReady: Bool
    let routeReady: Bool
    let headingReady: Bool
    let canRun: Bool
    let nextStage: Stage

    static func evaluate(_ input: PipelineInputs) -> PipelineReadiness {
        var issues: [StageIssue] = []
        let dataReady: Bool
        let routeReady: Bool
        let headingReady: Bool

        if input.usesBundledDataset {
            dataReady = input.hasDataset
            routeReady = true
            headingReady = true
            if !input.hasDataset { issues.append(.noDataset) }
        } else {
            dataReady = input.hasDataset
                && !input.datasetNameIsEmpty
                && input.routeIsValid
                && input.routeGeometryIsValid
                && input.headingIsValid
            routeReady = input.routeIsInsideMap
                && input.routeIsValid
                && input.routeGeometryIsValid
            headingReady = !input.localizationModeNeedsHeading || input.hasExplicitHeading

            if !input.hasDataset { issues.append(.noDataset) }
            if input.datasetNameIsEmpty { issues.append(.emptyDatasetName) }
            if !input.routeIsValid { issues.append(.invalidRoute) }
            if !input.routeGeometryIsValid { issues.append(.routeGeometry) }
            if !input.headingIsValid { issues.append(.invalidHeading) }
            if !input.routeIsInsideMap { issues.append(.routeOutsideMap) }
            if input.localizationModeNeedsHeading && !input.hasExplicitHeading {
                issues.append(.roomModeNeedsHeading)
            }
        }

        let mapReady = input.hasMap
            && !input.mapBuiltFromCurrentDataset
            && input.coordinateFrameMatches
        if !input.hasMap { issues.append(.noMap) }
        if input.mapBuiltFromCurrentDataset { issues.append(.mapBuiltFromCurrentDataset) }
        if !input.coordinateFrameMatches { issues.append(.coordinateFrameMismatch) }

        let canRun = dataReady && mapReady && routeReady && headingReady && !input.isRunning
        let nextStage: Stage
        if !dataReady {
            nextStage = .data
        } else if !mapReady || !routeReady || !headingReady {
            nextStage = .map
        } else if input.hasResult {
            nextStage = .analysis
        } else {
            nextStage = .run
        }

        return PipelineReadiness(
            issues: issues,
            dataReady: dataReady,
            mapReady: mapReady,
            routeReady: routeReady,
            headingReady: headingReady,
            canRun: canRun,
            nextStage: nextStage
        )
    }
}
