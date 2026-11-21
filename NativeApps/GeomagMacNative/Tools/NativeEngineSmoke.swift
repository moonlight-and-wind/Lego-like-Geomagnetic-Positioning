import Foundation

@main
struct NativeEngineSmoke {
    static func main() throws {
        let keys = ["route_13_2", "route_13_3", "route_15_2", "route_15_3"]
        let outputDirectory: URL?
        if let marker = CommandLine.arguments.firstIndex(of: "--write-samples"),
           marker + 1 < CommandLine.arguments.count {
            outputDirectory = URL(fileURLWithPath: CommandLine.arguments[marker + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: outputDirectory!, withIntermediateDirectories: true)
        } else {
            outputDirectory = nil
        }

        for key in keys {
            let group = key.replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
            let route = route(for: group)
            let map = try loadMap(group: group)
            let datasetDirectory = try NativePositioningEngine.bundledDatasetURL(key: key)
            let inspection = try DatasetValidator.inspect(selectedURL: datasetDirectory)
            let interval = inspection.activeInterval
            let result = try NativePositioningEngine.run(
                request: .init(
                    datasetKey: key,
                    datasetDirectory: datasetDirectory,
                    route: route,
                    initialHeadingDegrees: nil,
                    activeStartTime: interval.confidence == "低" ? nil : interval.startTime,
                    activeEndTime: interval.confidence == "低" ? nil : interval.endTime,
                    settings: .optimized,
                    magneticMap: map,
                    localizationMode: map.localizationMode
                ),
                progress: { _, _ in }
            )
            guard result.pfTrack.count == (result.stepsDetected ?? 0) + 1,
                  result.pfConfidenceHistory?.count == result.stepsDetected else {
                throw SmokeError.missingParticleFilter(key)
            }
            print(
                key,
                "steps=\(result.stepsDetected ?? 0)",
                String(
                    format: "cross=%.3f/%.3f ratio=%.2f/%.2f close=%.3f/%.3f",
                    result.pdrCrossTrackErrorStats?.mean ?? -1,
                    result.pfCrossTrackErrorStats?.mean ?? -1,
                    result.pdrPathLengthRatio ?? -1,
                    result.pfPathLengthRatio ?? -1,
                    result.pdrClosureErrorM ?? -1,
                    result.pfClosureErrorM ?? -1
                ),
                "confidence=\(result.finalPFConfidence?.localizedLevel ?? "-")"
            )
            if let outputDirectory {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let outputURL = outputDirectory.appendingPathComponent("native_\(key).json")
                try encoder.encode(result).write(to: outputURL, options: .atomic)
            }
        }
    }

    private static func loadMap(group: String) throws -> GenericMagneticMapDocument {
        guard let root = ProcessInfo.processInfo.environment["GEOMAG_NATIVE_RESOURCE_ROOT"] else {
            throw SmokeError.missingResourceRoot
        }
        let url = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("MagneticMaps", isDirectory: true)
            .appendingPathComponent("magnetic_map_\(group).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GenericMagneticMapDocument.self, from: Data(contentsOf: url)).validated()
    }

    private static func route(for group: String) -> [XYPoint] {
        if group == "route_13" {
            return [
                XYPoint(x: 4, y: 3), XYPoint(x: 4, y: 4.8),
                XYPoint(x: 5.8, y: 4.8), XYPoint(x: 5.8, y: 3), XYPoint(x: 4, y: 3),
            ]
        }
        return [
            XYPoint(x: 12.5, y: 0.5), XYPoint(x: 0.5, y: 0.5),
            XYPoint(x: 0.5, y: 1.1), XYPoint(x: 12.5, y: 1.1), XYPoint(x: 12.5, y: 0.5),
        ]
    }

    private enum SmokeError: LocalizedError {
        case missingParticleFilter(String)
        case missingResourceRoot

        var errorDescription: String? {
            switch self {
            case let .missingParticleFilter(key): "\(key) 没有生成完整 PF 路线或置信范围。"
            case .missingResourceRoot: "缺少 GEOMAG_NATIVE_RESOURCE_ROOT。"
            }
        }
    }
}
