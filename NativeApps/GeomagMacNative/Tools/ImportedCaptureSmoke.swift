import Foundation

@main
struct ImportedCaptureSmoke {
    static func main() throws {
        guard CommandLine.arguments.count >= 5 else { throw UsageError() }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let key = CommandLine.arguments[2]
        let route = try parseRoute(CommandLine.arguments[3])
        let mapURL = URL(fileURLWithPath: CommandLine.arguments[4])
        let initialHeading = CommandLine.arguments.count >= 6 ? Double(CommandLine.arguments[5]) : nil
        let inspection = try DatasetValidator.inspect(selectedURL: directory)
        let interval = inspection.activeInterval
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let map = try decoder.decode(
            GenericMagneticMapDocument.self,
            from: Data(contentsOf: mapURL)
        ).validated()
        let result = try NativePositioningEngine.run(
            request: .init(
                datasetKey: key,
                datasetDirectory: inspection.directoryURL,
                route: route,
                initialHeadingDegrees: initialHeading,
                activeStartTime: interval.confidence == "低" ? nil : interval.startTime,
                activeEndTime: interval.confidence == "低" ? nil : interval.endTime,
                settings: .optimized,
                magneticMap: map,
                localizationMode: map.localizationMode
            ),
            progress: { _, _ in }
        )
        print("dataset=\(key)")
        print("steps=\(result.stepsDetected ?? 0)")
        print(String(
            format: "pdr_mean_m=%.3f pf_mean_m=%.3f",
            result.pdrErrorStats?.mean ?? -1,
            result.pfErrorStats?.mean ?? -1
        ))
        print("pf_points=\(result.pfTrack.count)")
        print("confidence_points=\(result.pfConfidenceHistory?.count ?? 0)")
        print("heading_method=\(result.headingDiagnostics?.method ?? "unknown")")
    }

    private static func parseRoute(_ text: String) throws -> [XYPoint] {
        let points = text.split(separator: ";").compactMap { token -> XYPoint? in
            let values = token.split(separator: ",")
            guard values.count == 2,
                  let x = Double(values[0]),
                  let y = Double(values[1]) else { return nil }
            return XYPoint(x: x, y: y)
        }
        guard points.count >= 2 else { throw UsageError() }
        return points
    }

    private struct UsageError: LocalizedError {
        var errorDescription: String? {
            "用法：ImportedCaptureSmoke <采集目录> <数据集名称> <x,y;x,y...> <磁图JSON> [初始航向]"
        }
    }
}
