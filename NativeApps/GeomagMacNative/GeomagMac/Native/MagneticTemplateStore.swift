import Foundation

struct MagneticCalibrationCapture: Sendable {
    let sourceKey: String
    let group: String
    let segments: [ControlledMagneticSegmentTemplate]
}

enum MagneticTemplateBuilder {
    enum BuilderError: LocalizedError {
        case tooFewCaptures
        case mixedRouteGroups
        case malformedCapture(String)

        var errorDescription: String? {
            switch self {
            case .tooFewCaptures:
                "至少需要两组独立标定采集才能建立稳健磁模板。"
            case .mixedRouteGroups:
                "所选标定采集不属于同一条路线。"
            case let .malformedCapture(key):
                "标定采集 \(key) 没有形成四段有效磁指纹。"
            }
        }
    }

    static func aggregate(
        captures: [MagneticCalibrationCapture],
        group: String,
        createdAt: Date = Date()
    ) throws -> ControlledMagneticTemplate {
        guard captures.count >= 2 else { throw BuilderError.tooFewCaptures }
        guard captures.allSatisfy({ $0.group == group }) else { throw BuilderError.mixedRouteGroups }
        guard captures.allSatisfy({ capture in
            capture.segments.count == 4 && capture.segments.allSatisfy(isValid)
        }) else {
            throw BuilderError.malformedCapture(captures.first?.sourceKey ?? "unknown")
        }
        let segments = try (0..<4).map { segmentIndex in
            let candidates = captures.map { $0.segments[segmentIndex] }
            let eligible = candidates.filter { $0.progress.count >= 3 }
            guard !eligible.isEmpty else {
                guard let best = candidates.max(by: { $0.progress.count < $1.progress.count }) else {
                    throw BuilderError.malformedCapture(captures[0].sourceKey)
                }
                return best
            }
            if eligible.count == 1 { return eligible[0] }
            let counts = eligible.map { $0.progress.count }.sorted()
            let sampleCount = max(3, counts[counts.count / 2])
            let sharedProgress = (0..<sampleCount).map {
                Double($0) / Double(max(sampleCount - 1, 1))
            }
            let norms = sharedProgress.map { progress in
                median(eligible.map {
                    interpolate($0.magneticNormUT, axis: $0.progress, at: progress)
                })
            }
            let vectors = sharedProgress.map { progress in
                MagneticVector3(
                    x: median(eligible.map {
                        interpolate($0.alignedVectorsUT.map(\.x), axis: $0.progress, at: progress)
                    }),
                    y: median(eligible.map {
                        interpolate($0.alignedVectorsUT.map(\.y), axis: $0.progress, at: progress)
                    }),
                    z: median(eligible.map {
                        interpolate($0.alignedVectorsUT.map(\.z), axis: $0.progress, at: progress)
                    })
                )
            }
            return ControlledMagneticSegmentTemplate(
                progress: sharedProgress,
                magneticNormUT: norms,
                alignedVectorsUT: vectors
            )
        }
        return ControlledMagneticTemplate(
            schemaVersion: 1,
            group: group,
            sourceKeys: Array(Set(captures.map(\.sourceKey))).sorted(),
            createdAt: createdAt,
            segments: segments
        )
    }

    private static func isValid(_ segment: ControlledMagneticSegmentTemplate) -> Bool {
        let count = segment.progress.count
        guard count > 0,
              segment.magneticNormUT.count == count,
              segment.alignedVectorsUT.count == count,
              segment.progress.allSatisfy(\.isFinite),
              segment.magneticNormUT.allSatisfy(\.isFinite),
              segment.alignedVectorsUT.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
              }) else { return false }
        return zip(segment.progress, segment.progress.dropFirst()).allSatisfy { $0 <= $1 }
    }

    private static func interpolate(_ values: [Double], axis: [Double], at value: Double) -> Double {
        guard let first = values.first, let last = values.last else { return 0 }
        if value <= axis[0] { return first }
        if value >= axis[axis.count - 1] { return last }
        var upper = 1
        while upper < axis.count && axis[upper] < value { upper += 1 }
        let lower = upper - 1
        let span = axis[upper] - axis[lower]
        let ratio = span <= 1e-12 ? 0 : (value - axis[lower]) / span
        return values[lower] + (values[upper] - values[lower]) * ratio
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

enum MagneticTemplateStore {
    static let supportedGroups = ["route_13", "route_14", "route_15"]

    static func loadAll() throws -> [String: ControlledMagneticTemplate] {
        let directory = try directoryURL(createIfNeeded: true)
        var output: [String: ControlledMagneticTemplate] = [:]
        for group in supportedGroups {
            let url = directory.appendingPathComponent(group).appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let template = try decoder.decode(
                ControlledMagneticTemplate.self,
                from: Data(contentsOf: url)
            )
            guard template.schemaVersion == 1,
                  template.group == group,
                  template.segments.count == 4 else { continue }
            output[group] = template
        }
        return output
    }

    @discardableResult
    static func save(_ template: ControlledMagneticTemplate) throws -> URL {
        guard supportedGroups.contains(template.group) else {
            throw MagneticTemplateBuilder.BuilderError.mixedRouteGroups
        }
        let directory = try directoryURL(createIfNeeded: true)
        let url = directory.appendingPathComponent(template.group).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(template).write(to: url, options: .atomic)
        return url
    }

    static func remove(group: String) throws {
        let url = try directoryURL(createIfNeeded: true)
            .appendingPathComponent(group)
            .appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func directoryURL(createIfNeeded: Bool) throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupport
            .appendingPathComponent("GeomagMacNative", isDirectory: true)
            .appendingPathComponent("MagneticTemplates", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }
}
