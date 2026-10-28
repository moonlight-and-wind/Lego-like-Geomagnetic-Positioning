import Foundation

@main
struct AnchoredRoomValidation {
    static func main() throws {
        guard CommandLine.arguments.count == 6 else { throw UsageError() }

        let firstURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let secondURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let testURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let mapName = CommandLine.arguments[4]
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[5])
        var settings = AlgorithmSettings.optimized
        if let value = ProcessInfo.processInfo.environment["GEOMAG_HEADING_SNAP"].flatMap(Double.init) {
            settings.headingSnapDegrees = value
        }
        if ProcessInfo.processInfo.environment["GEOMAG_VECTOR_MAP"] == "1" {
            settings.vectorMapEnabled = true
        }
        var runSettings = settings
        if let value = ProcessInfo.processInfo.environment["GEOMAG_RUN_STEP_SCALE"].flatMap(Double.init) {
            runSettings.stepLengthScale = value
        }
        if ProcessInfo.processInfo.environment["GEOMAG_SMOOTHING"] == "none" {
            runSettings.smoothingMode = .none
            runSettings.smoothingAlpha = 0
        }

        let first = try DatasetValidator.inspect(selectedURL: firstURL)
        let second = try DatasetValidator.inspect(selectedURL: secondURL)
        let test = try DatasetValidator.inspect(selectedURL: testURL)

        let firstMap = try buildMap(from: first, name: mapName, settings: settings)
        let secondMap = try buildMap(from: second, name: mapName, settings: settings)
        let warnings = GenericMagneticMapStore.mergeQualityWarnings(firstMap, with: secondMap)
        let merged = try GenericMagneticMapStore.merging(firstMap, with: secondMap)
        let mapURL = try GenericMagneticMapStore.save(merged, replacing: true)

        let route = test.spatialAnchors.map { XYPoint(x: $0.x, y: $0.y) }
        guard route.count >= 2 else { throw UsageError() }
        let initialHeading = test.suggestedInitialHeadingDegrees ?? inferredHeading(route)
        let interval = test.activeInterval
        let result = try NativePositioningEngine.run(
            request: .init(
                datasetKey: test.suggestedDatasetName ?? "localization_test",
                datasetDirectory: test.directoryURL,
                route: route,
                initialHeadingDegrees: initialHeading,
                activeStartTime: interval.confidence == "低" ? nil : interval.startTime,
                activeEndTime: interval.confidence == "低" ? nil : interval.endTime,
                settings: runSettings,
                magneticMap: merged,
                localizationMode: merged.localizationMode
            ),
            progress: { _, _ in }
        )

        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: resultURL, options: .atomic)
        let pngURL = resultURL.deletingPathExtension().appendingPathExtension("png")
        try ResultExporter.renderPNG(result: result).write(to: pngURL, options: .atomic)

        let quality = merged.qualityReport
        print("map=\(mapURL.path)")
        print("sources=\(merged.sourceDatasetKeys.joined(separator: ",")) samples=\(merged.samples.count)")
        if let quality {
            print(String(format: "quality=%@ coverage=%.1f%% median_observations=%d",
                         quality.grade.rawValue, quality.coverageRatio * 100,
                         quality.medianObservationCount))
        }
        for warning in warnings { print("warning=\(warning)") }
        print("result=\(resultURL.path)")
        print("png=\(pngURL.path)")
        print("steps=\(result.stepsDetected ?? 0) heading=\(initialHeading)")
        print("heading_snap=\(runSettings.headingSnapDegrees) step_scale=\(runSettings.stepLengthScale)")
        printMetrics("pdr", result.pdrErrorStats, result.pdrCrossTrackErrorStats,
                     result.pdrAlongTrackErrorStats, result.pdrTurnAngleErrorStats,
                     result.pdrClosureErrorM)
        printMetrics("pf", result.pfErrorStats, result.pfCrossTrackErrorStats,
                     result.pfAlongTrackErrorStats, result.pfTurnAngleErrorStats,
                     result.pfClosureErrorM)
        if let confidence = result.overallPFConfidenceScore {
            print(String(format: "pf_confidence=%.3f", confidence))
        }
    }

    private static func buildMap(
        from dataset: ImportedDataset,
        name: String,
        settings: AlgorithmSettings
    ) throws -> GenericMagneticMapDocument {
        try NativePositioningEngine.buildAnchoredGridMagneticMap(
            name: name,
            datasetKey: dataset.suggestedDatasetName ?? name,
            datasetDirectory: dataset.directoryURL,
            coordinateFrame: dataset.coordinateFrame ?? "local-room",
            anchors: dataset.spatialAnchors,
            excludedIntervals: dataset.mappingPauseIntervals + dataset.mappingDisturbIntervals,
            cellSizeM: 0.25,
            settings: settings,
            progress: { _, _ in }
        )
    }

    private static func inferredHeading(_ route: [XYPoint]) -> Double {
        guard let first = route.first else { return 0 }
        for point in route.dropFirst() where hypot(point.x - first.x, point.y - first.y) > 1e-6 {
            return atan2(point.y - first.y, point.x - first.x) * 180 / .pi
        }
        return 0
    }

    private static func printMetrics(
        _ label: String,
        _ overall: ErrorStatistics?,
        _ cross: ErrorStatistics?,
        _ along: ErrorStatistics?,
        _ turn: ErrorStatistics?,
        _ closure: Double?
    ) {
        print(String(
            format: "%@ mean=%.3f final=%.3f cross=%.3f along=%.3f turn=%.1f closure=%.3f",
            label, overall?.mean ?? -1, overall?.final ?? -1, cross?.mean ?? -1,
            along?.mean ?? -1, turn?.mean ?? -1, closure ?? -1
        ))
    }

    private struct UsageError: LocalizedError {
        var errorDescription: String? {
            "用法：AnchoredRoomValidation <正向包> <反向包> <测试包> <磁图名> <结果JSON>"
        }
    }
}
