import Foundation

@main
struct BuildBundledMagneticMaps {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw ToolError.usage
        }
        let route13URL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let route15URL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        try build(
            name: "route_13",
            key: "route_13_1",
            directory: route13URL,
            route: [
                XYPoint(x: 4.0, y: 3.0), XYPoint(x: 4.0, y: 4.8),
                XYPoint(x: 5.8, y: 4.8), XYPoint(x: 5.8, y: 3.0),
                XYPoint(x: 4.0, y: 3.0),
            ],
            outputURL: outputURL
        )
        try build(
            name: "route_15",
            key: "route_15_1",
            directory: route15URL,
            route: [
                XYPoint(x: 12.5, y: 0.5), XYPoint(x: 0.5, y: 0.5),
                XYPoint(x: 0.5, y: 1.1), XYPoint(x: 12.5, y: 1.1),
                XYPoint(x: 12.5, y: 0.5),
            ],
            outputURL: outputURL
        )
    }

    private static func build(
        name: String,
        key: String,
        directory: URL,
        route: [XYPoint],
        outputURL: URL
    ) throws {
        let inspection = try DatasetValidator.inspect(selectedURL: directory)
        let interval = inspection.activeInterval
        let document = try NativePositioningEngine.buildGenericMagneticMap(
            name: name,
            datasetKey: key,
            datasetDirectory: inspection.directoryURL,
            route: route,
            initialHeadingDegrees: nil,
            activeStartTime: interval.confidence == "低" ? nil : interval.startTime,
            activeEndTime: interval.confidence == "低" ? nil : interval.endTime,
            progress: { _, _ in }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = outputURL.appendingPathComponent("magnetic_map_\(name).json")
        try encoder.encode(document).write(to: url, options: .atomic)
        print("\(key): \(document.samples.count) samples -> \(url.path)")
    }

    private enum ToolError: LocalizedError {
        case usage

        var errorDescription: String? {
            "用法：build-maps <route_13_1采集包> <route_15_1采集包> <输出目录>"
        }
    }
}
