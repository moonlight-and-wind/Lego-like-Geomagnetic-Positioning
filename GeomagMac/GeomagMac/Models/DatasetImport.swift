import Foundation

enum RunInputMode: String, CaseIterable, Identifiable {
    case bundled
    case imported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundled: "内置测试数据"
        case .imported: "导入采集文件夹"
        }
    }
}

struct SensorStreamSummary: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case accelerometer
        case gyroscope
        case magnetometer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accelerometer: "加速度计"
            case .gyroscope: "陀螺仪"
            case .magnetometer: "磁力计"
            }
        }

        var fileName: String {
            switch self {
            case .accelerometer: "Accelerometer.csv"
            case .gyroscope: "Gyroscope.csv"
            case .magnetometer: "Magnetometer.csv"
            }
        }

        fileprivate var axisCandidates: [[String]] {
            switch self {
            case .accelerometer:
                [
                    ["X (m/s^2)", "X", "ax"],
                    ["Y (m/s^2)", "Y", "ay"],
                    ["Z (m/s^2)", "Z", "az"],
                ]
            case .gyroscope:
                [
                    ["X (rad/s)", "X", "gx"],
                    ["Y (rad/s)", "Y", "gy"],
                    ["Z (rad/s)", "Z", "gz"],
                ]
            case .magnetometer:
                [
                    ["X (µT)", "X", "mx"],
                    ["Y (µT)", "Y", "my"],
                    ["Z (µT)", "Z", "mz"],
                ]
            }
        }
    }

    let kind: Kind
    let fileURL: URL
    let validRowCount: Int
    let invalidRowCount: Int
    let startTime: Double
    let endTime: Double
    let sampleRateHz: Double
    let medianSampleInterval: Double
    let maxGapSeconds: Double
    let gapCount: Int
    let maxMagnitude: Double

    var id: String { kind.id }
    var duration: Double { max(endTime - startTime, 0) }
}

enum CaptureQualityGrade: String, Hashable {
    case usable
    case attention
    case notRecommended

    var title: String {
        switch self {
        case .usable: "可用"
        case .attention: "需要注意"
        case .notRecommended: "不建议使用"
        }
    }
}

struct MotionIntervalSummary: Hashable {
    let startTime: Double
    let endTime: Double
    let headExcludedSeconds: Double
    let tailExcludedSeconds: Double
    let trimHeadFrames: Int
    let trimTailFrames: Int
    let confidence: String

    var duration: Double { max(endTime - startTime, 0) }
    var excludedSeconds: Double { headExcludedSeconds + tailExcludedSeconds }
}

struct CaptureQualityAssessment: Hashable {
    let grade: CaptureQualityGrade
    let messages: [String]
    let magneticMedianUT: Double
    let magneticRangeUT: ClosedRange<Double>
    let magneticAbnormalRatio: Double
    let magneticSpikeCount: Int
}

struct CoordinateBounds: Hashable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    static let builtInTileManifest = CoordinateBounds(
        minX: 0,
        maxX: 11.52,
        minY: 0,
        maxY: 8.80
    )

    func contains(x: Double, y: Double) -> Bool {
        minX <= x && x <= maxX && minY <= y && y <= maxY
    }
}

struct RouteMapValidation: Hashable {
    struct InvalidPoint: Identifiable, Hashable {
        let index: Int
        let x: Double
        let y: Double

        var id: Int { index }
    }

    let bounds: CoordinateBounds?
    let invalidPoints: [InvalidPoint]

    var isValid: Bool { invalidPoints.isEmpty }
    var wasChecked: Bool { bounds != nil }
}

struct ImportedDataset: Hashable {
    let directoryURL: URL
    let streams: [SensorStreamSummary]
    let locationFileURL: URL?
    let overlapStart: Double
    let overlapEnd: Double
    let metadataURL: URL?
    let suggestedDatasetName: String?
    let suggestedRouteText: String?
    let suggestedInitialHeadingDegrees: Double?
    let suggestedMapURL: URL?
    let activeInterval: MotionIntervalSummary
    let quality: CaptureQualityAssessment
    let warnings: [String]

    var overlapDuration: Double { max(overlapEnd - overlapStart, 0) }

    var estimatedFrameCount: Int {
        streams.first(where: { $0.kind == .accelerometer })?.validRowCount ?? 0
    }

    var activeFrameCount: Int {
        max(0, estimatedFrameCount - activeInterval.trimHeadFrames - activeInterval.trimTailFrames)
    }
}

struct RunRecord: Identifiable, Hashable {
    let jsonURL: URL
    let modifiedAt: Date

    var id: String { jsonURL.path }
    var fileName: String { jsonURL.lastPathComponent }

    var displayName: String {
        jsonURL.deletingPathExtension().lastPathComponent
    }
}

enum DatasetImportError: LocalizedError {
    case noSensorFolder
    case multipleSensorFolders([String])
    case missingFile(String)
    case unreadableFile(String)
    case invalidHeader(file: String, missing: String)
    case insufficientRows(file: String, count: Int)
    case noTimeOverlap

    var errorDescription: String? {
        switch self {
        case .noSensorFolder:
            "没有找到同时包含 Accelerometer.csv、Gyroscope.csv 和 Magnetometer.csv 的文件夹。"
        case let .multipleSensorFolders(names):
            "所选目录包含多组采集数据（\(names.joined(separator: "、"))），请直接选择其中一组采集文件夹。"
        case let .missingFile(name):
            "缺少必需文件：\(name)。"
        case let .unreadableFile(name):
            "无法读取 \(name)，请检查文件编码和访问权限。"
        case let .invalidHeader(file, missing):
            "\(file) 缺少算法需要的 \(missing) 列。"
        case let .insufficientRows(file, count):
            "\(file) 只有 \(count) 行有效数据，无法用于定位。"
        case .noTimeOverlap:
            "三种传感器记录的时间范围没有重叠，无法对齐为同一条传感器序列。"
        }
    }
}

enum DatasetValidator {
    private static let requiredKinds = SensorStreamSummary.Kind.allCases
    private static let timeCandidates = ["Time (s)", "time", "timestamp"]

    private struct SensorSample {
        let time: Double
        let x: Double
        let y: Double
        let z: Double

        var magnitude: Double { sqrt(x * x + y * y + z * z) }
    }

    private struct InspectedStream {
        let summary: SensorStreamSummary
        let samples: [SensorSample]
    }

    static func inspect(selectedURL: URL) throws -> ImportedDataset {
        let directoryURL = try locateDatasetDirectory(from: selectedURL)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var filesByName: [String: URL] = [:]
        for url in contents {
            filesByName[url.lastPathComponent.lowercased()] = url
        }

        var inspectedStreams: [InspectedStream] = []
        for kind in requiredKinds {
            guard let fileURL = filesByName[kind.fileName.lowercased()] else {
                throw DatasetImportError.missingFile(kind.fileName)
            }
            inspectedStreams.append(try inspectStream(kind: kind, fileURL: fileURL))
        }
        let streams = inspectedStreams.map(\.summary)

        let overlapStart = streams.map(\.startTime).max() ?? 0
        let overlapEnd = streams.map(\.endTime).min() ?? 0
        guard overlapEnd > overlapStart else {
            throw DatasetImportError.noTimeOverlap
        }

        let locationURL = filesByName["location.csv"]
        let metadataURL = filesByName["geomag_dataset.json"]
            ?? filesByName["capture_metadata.json"]
        let metadata = metadataURL.flatMap(readMetadata)
        var warnings: [String] = []
        if locationURL == nil {
            warnings.append("未找到 Location.csv；当前算法不依赖 GPS，可以继续运行。")
        }
        if metadata?.routeText == nil {
            warnings.append("未从元数据读取到 route_xy_m，运行前必须填写真实路线坐标。")
        }

        let counts = streams.map(\.validRowCount)
        if let minimum = counts.min(), let maximum = counts.max(), minimum > 0,
           Double(maximum) / Double(minimum) > 1.20 {
            warnings.append("三种传感器有效行数差异超过 20%，请确认采集是否同时开始和结束。")
        }

        let accelerometer = inspectedStreams.first {
            $0.summary.kind == .accelerometer
        }?.samples ?? []
        let gyroscope = inspectedStreams.first {
            $0.summary.kind == .gyroscope
        }?.samples ?? []
        let magnetometer = inspectedStreams.first {
            $0.summary.kind == .magnetometer
        }?.samples ?? []
        let activeInterval = inferMotionInterval(
            accelerometer: accelerometer,
            gyroscope: gyroscope,
            overlapStart: overlapStart,
            overlapEnd: overlapEnd
        )
        let quality = assessQuality(
            streams: streams,
            magnetometer: magnetometer,
            overlapStart: overlapStart,
            overlapEnd: overlapEnd,
            activeInterval: activeInterval
        )

        return ImportedDataset(
            directoryURL: directoryURL,
            streams: streams,
            locationFileURL: locationURL,
            overlapStart: overlapStart,
            overlapEnd: overlapEnd,
            metadataURL: metadataURL,
            suggestedDatasetName: metadata?.datasetName,
            suggestedRouteText: metadata?.routeText,
            suggestedInitialHeadingDegrees: metadata?.initialHeadingDegrees,
            suggestedMapURL: metadata?.mapURL(relativeTo: directoryURL),
            activeInterval: activeInterval,
            quality: quality,
            warnings: warnings
        )
    }

    static func normalizedRouteText(_ text: String) -> String? {
        let pointTokens = text.split(separator: ";", omittingEmptySubsequences: true)
        var points: [(Double, Double)] = []
        for token in pointTokens {
            let coordinates = token.split(separator: ",", omittingEmptySubsequences: false)
            guard coordinates.count == 2,
                  let x = Double(coordinates[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(coordinates[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  x.isFinite,
                  y.isFinite else {
                return nil
            }
            points.append((x, y))
        }
        guard points.count >= 2 else { return nil }
        return points.map { "\(number($0.0)),\(number($0.1))" }.joined(separator: "; ")
    }

    static func validateRoute(
        _ text: String,
        against bounds: CoordinateBounds?
    ) -> RouteMapValidation {
        guard normalizedRouteText(text) != nil else {
            return RouteMapValidation(bounds: nil, invalidPoints: [])
        }
        guard let bounds else {
            return RouteMapValidation(bounds: nil, invalidPoints: [])
        }
        let points = routePoints(text)
        let invalid = points.enumerated().compactMap { index, point in
            bounds.contains(x: point.0, y: point.1)
                ? nil
                : RouteMapValidation.InvalidPoint(
                    index: index + 1,
                    x: point.0,
                    y: point.1
                )
        }
        return RouteMapValidation(bounds: bounds, invalidPoints: invalid)
    }

    private static func routePoints(_ text: String) -> [(Double, Double)] {
        text.split(separator: ";", omittingEmptySubsequences: true).compactMap { token in
            let coordinates = token.split(separator: ",", omittingEmptySubsequences: false)
            guard coordinates.count == 2,
                  let x = Double(coordinates[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(coordinates[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  x.isFinite,
                  y.isFinite else {
                return nil
            }
            return (x, y)
        }
    }

    private static func locateDatasetDirectory(from selectedURL: URL) throws -> URL {
        if containsRequiredFiles(selectedURL) {
            return selectedURL
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: selectedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && containsRequiredFiles(url)
        }
        if candidates.count == 1, let candidate = candidates.first {
            return candidate
        }
        if candidates.count > 1 {
            throw DatasetImportError.multipleSensorFolders(
                candidates.map(\.lastPathComponent).sorted()
            )
        }
        throw DatasetImportError.noSensorFolder
    }

    private static func containsRequiredFiles(_ directoryURL: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return false
        }
        let normalizedNames = Set(names.map { $0.lowercased() })
        return requiredKinds.allSatisfy { normalizedNames.contains($0.fileName.lowercased()) }
    }

    private static func inspectStream(
        kind: SensorStreamSummary.Kind,
        fileURL: URL
    ) throws -> InspectedStream {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw DatasetImportError.unreadableFile(fileURL.lastPathComponent)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let firstLine = lines.first else {
            throw DatasetImportError.insufficientRows(file: fileURL.lastPathComponent, count: 0)
        }
        let headers = parseCSVLine(String(firstLine)).map(normalizeHeader)
        guard let timeIndex = columnIndex(in: headers, candidates: timeCandidates) else {
            throw DatasetImportError.invalidHeader(
                file: fileURL.lastPathComponent,
                missing: "Time (s)"
            )
        }
        let axisIndices = try kind.axisCandidates.enumerated().map { axis, candidates in
            guard let index = columnIndex(in: headers, candidates: candidates) else {
                throw DatasetImportError.invalidHeader(
                    file: fileURL.lastPathComponent,
                    missing: ["X", "Y", "Z"][axis]
                )
            }
            return index
        }
        let requiredIndex = ([timeIndex] + axisIndices).max() ?? 0
        var validRows = 0
        var invalidRows = 0
        var startTime = Double.greatestFiniteMagnitude
        var endTime = -Double.greatestFiniteMagnitude
        var samples: [SensorSample] = []

        for line in lines.dropFirst() {
            let values = parseCSVLine(String(line))
            guard values.count > requiredIndex,
                  let time = numeric(values[timeIndex]),
                  let x = numeric(values[axisIndices[0]]),
                  let y = numeric(values[axisIndices[1]]),
                  let z = numeric(values[axisIndices[2]]) else {
                invalidRows += 1
                continue
            }
            validRows += 1
            startTime = min(startTime, time)
            endTime = max(endTime, time)
            samples.append(SensorSample(time: time, x: x, y: y, z: z))
        }
        guard validRows >= 20 else {
            throw DatasetImportError.insufficientRows(
                file: fileURL.lastPathComponent,
                count: validRows
            )
        }
        samples.sort { $0.time < $1.time }
        let intervals = zip(samples, samples.dropFirst()).compactMap { first, second -> Double? in
            let interval = second.time - first.time
            return interval > 0 ? interval : nil
        }
        let medianInterval = median(intervals)
        let gapThreshold = max(0.08, medianInterval * 3.5)
        let gaps = intervals.filter { $0 > gapThreshold }
        return InspectedStream(
            summary: SensorStreamSummary(
                kind: kind,
                fileURL: fileURL,
                validRowCount: validRows,
                invalidRowCount: invalidRows,
                startTime: startTime,
                endTime: endTime,
                sampleRateHz: medianInterval > 0 ? 1 / medianInterval : 0,
                medianSampleInterval: medianInterval,
                maxGapSeconds: intervals.max() ?? 0,
                gapCount: gaps.count,
                maxMagnitude: samples.map(\.magnitude).max() ?? 0
            ),
            samples: samples
        )
    }

    private static func inferMotionInterval(
        accelerometer: [SensorSample],
        gyroscope: [SensorSample],
        overlapStart: Double,
        overlapEnd: Double
    ) -> MotionIntervalSummary {
        let acceleration = accelerometer.filter {
            overlapStart <= $0.time && $0.time <= overlapEnd
        }
        guard acceleration.count >= 20 else {
            return MotionIntervalSummary(
                startTime: overlapStart,
                endTime: overlapEnd,
                headExcludedSeconds: 0,
                tailExcludedSeconds: 0,
                trimHeadFrames: 0,
                trimTailFrames: 0,
                confidence: "低"
            )
        }

        let gravity = median(acceleration.map(\.magnitude))
        let accelerationDeviation = acceleration.map { abs($0.magnitude - gravity) }
        let gyroMagnitude = acceleration.map { sample in
            nearestMagnitude(at: sample.time, samples: gyroscope)
        }
        let accelerationThreshold = max(0.45, percentile(accelerationDeviation, 0.35) * 2.5)
        let gyroThreshold = max(0.12, percentile(gyroMagnitude, 0.35) * 2.5)
        let rawActivity = zip(accelerationDeviation, gyroMagnitude).map {
            $0 > accelerationThreshold || $1 > gyroThreshold
        }
        let sampleInterval = max(median(zip(acceleration, acceleration.dropFirst()).map {
            max(0, $1.time - $0.time)
        }), 0.01)
        let window = max(5, Int((0.5 / sampleInterval).rounded()))
        var smoothed = Array(repeating: false, count: rawActivity.count)
        var activeCount = 0
        for index in rawActivity.indices {
            if rawActivity[index] { activeCount += 1 }
            if index >= window, rawActivity[index - window] { activeCount -= 1 }
            let available = min(index + 1, window)
            smoothed[index] = Double(activeCount) / Double(available) >= 0.22
        }

        let minimumRun = max(1, Int((0.65 / sampleInterval).rounded()))
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for index in smoothed.indices {
            if smoothed[index], runStart == nil { runStart = index }
            if !smoothed[index], let start = runStart {
                if index - start >= minimumRun { runs.append(start...(index - 1)) }
                runStart = nil
            }
        }
        if let start = runStart, smoothed.count - start >= minimumRun {
            runs.append(start...(smoothed.count - 1))
        }
        guard let firstRun = runs.first, let lastRun = runs.last else {
            return MotionIntervalSummary(
                startTime: overlapStart,
                endTime: overlapEnd,
                headExcludedSeconds: 0,
                tailExcludedSeconds: 0,
                trimHeadFrames: 0,
                trimTailFrames: 0,
                confidence: "低"
            )
        }

        let activeStart = max(overlapStart, acceleration[firstRun.lowerBound].time - 0.75)
        let activeEnd = min(overlapEnd, acceleration[lastRun.upperBound].time + 0.50)
        let headFrames = acceleration.prefix { $0.time < activeStart }.count
        let tailFrames = acceleration.reversed().prefix { $0.time > activeEnd }.count
        let duration = activeEnd - activeStart
        let confidence = runs.count >= 1 && duration >= 4 ? "高" : "中"
        return MotionIntervalSummary(
            startTime: activeStart,
            endTime: activeEnd,
            headExcludedSeconds: max(0, activeStart - overlapStart),
            tailExcludedSeconds: max(0, overlapEnd - activeEnd),
            trimHeadFrames: headFrames,
            trimTailFrames: tailFrames,
            confidence: confidence
        )
    }

    private static func assessQuality(
        streams: [SensorStreamSummary],
        magnetometer: [SensorSample],
        overlapStart: Double,
        overlapEnd: Double,
        activeInterval: MotionIntervalSummary
    ) -> CaptureQualityAssessment {
        var warnings: [String] = []
        var severe: [String] = []
        let overlapDuration = overlapEnd - overlapStart
        if overlapDuration < 3 {
            severe.append("三种传感器的共同记录不足 3 秒。")
        }
        for stream in streams {
            if stream.sampleRateHz < 20 {
                severe.append("\(stream.kind.title)采样率只有 \(format(stream.sampleRateHz)) Hz。")
            } else if stream.sampleRateHz < 50 {
                warnings.append("\(stream.kind.title)采样率偏低（\(format(stream.sampleRateHz)) Hz）。")
            }
            if stream.maxGapSeconds > 0.5 {
                severe.append("\(stream.kind.title)存在 \(format(stream.maxGapSeconds)) 秒的数据中断。")
            } else if stream.maxGapSeconds > 0.10 {
                warnings.append("\(stream.kind.title)检测到 \(stream.gapCount) 处采样间断。")
            }
            if stream.invalidRowCount > max(3, stream.validRowCount / 100) {
                warnings.append("\(stream.kind.title)包含较多无效数据行。")
            }
            let saturationThreshold: Double = switch stream.kind {
            case .accelerometer: 50
            case .gyroscope: 20
            case .magnetometer: 200
            }
            if stream.maxMagnitude > saturationThreshold {
                severe.append("\(stream.kind.title)出现疑似饱和或极端异常值。")
            }
        }

        let magnetic = magnetometer.filter {
            overlapStart <= $0.time && $0.time <= overlapEnd
        }.map(\.magnitude)
        let magneticMedian = median(magnetic)
        let magneticMin = magnetic.min() ?? 0
        let magneticMax = magnetic.max() ?? 0
        let abnormalCount = magnetic.filter { $0 < 20 || $0 > 100 }.count
        let abnormalRatio = magnetic.isEmpty ? 1 : Double(abnormalCount) / Double(magnetic.count)
        let spikeCount = zip(magnetic, magnetic.dropFirst()).filter { abs($1 - $0) > 12 }.count
        let spikeRatio = magnetic.count < 2 ? 0 : Double(spikeCount) / Double(magnetic.count - 1)
        if abnormalRatio > 0.25 {
            severe.append("超过 25% 的磁场强度超出常见室内范围，可能存在强磁干扰。")
        } else if abnormalRatio > 0.05 {
            warnings.append("部分磁场读数超出常见室内范围，请留意附近金属或电器。")
        }
        if spikeRatio > 0.05 {
            severe.append("磁场信号频繁突变，当前采集不适合可靠匹配。")
        } else if spikeRatio > 0.01 {
            warnings.append("磁场信号存在少量突变。")
        }
        if activeInterval.confidence == "低" {
            warnings.append("无法可靠识别行走起止时间，将保留完整采集区间。")
        }

        let grade: CaptureQualityGrade
        let messages: [String]
        if !severe.isEmpty {
            grade = .notRecommended
            messages = severe + warnings
        } else if !warnings.isEmpty {
            grade = .attention
            messages = warnings
        } else {
            grade = .usable
            messages = ["采样连续、三轴数据完整，磁场范围未发现明显异常。"]
        }
        return CaptureQualityAssessment(
            grade: grade,
            messages: messages,
            magneticMedianUT: magneticMedian,
            magneticRangeUT: magneticMin...magneticMax,
            magneticAbnormalRatio: abnormalRatio,
            magneticSpikeCount: spikeCount
        )
    }

    private static func nearestMagnitude(at time: Double, samples: [SensorSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time < time { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return samples[0].magnitude }
        if low >= samples.count { return samples[samples.count - 1].magnitude }
        let before = samples[low - 1]
        let after = samples[low]
        return abs(before.time - time) <= abs(after.time - time)
            ? before.magnitude
            : after.magnitude
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        values.append(current)
        return values
    }

    private static func columnIndex(in headers: [String], candidates: [String]) -> Int? {
        let normalizedCandidates = Set(candidates.map(normalizeHeader))
        return headers.firstIndex(where: normalizedCandidates.contains)
    }

    private static func normalizeHeader(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "μ", with: "µ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func numeric(_ value: String) -> Double? {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.lowercased() != "nan", let number = Double(token),
              number.isFinite else {
            return nil
        }
        return number
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct Metadata {
        let datasetName: String?
        let routeText: String?
        let initialHeadingDegrees: Double?
        let mapPath: String?

        func mapURL(relativeTo directoryURL: URL) -> URL? {
            guard let mapPath, !mapPath.isEmpty else { return nil }
            let expanded = NSString(string: mapPath).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded)
            }
            return directoryURL.appendingPathComponent(expanded)
        }
    }

    private static func readMetadata(_ url: URL) -> Metadata? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let routeText: String?
        if let route = object["route_xy_m"] as? [[Any]] {
            let points = route.compactMap { values -> String? in
                guard values.count >= 2,
                      let x = values[0] as? NSNumber,
                      let y = values[1] as? NSNumber else { return nil }
                return "\(number(x.doubleValue)),\(number(y.doubleValue))"
            }
            routeText = points.count >= 2 ? points.joined(separator: "; ") : nil
        } else {
            routeText = nil
        }
        return Metadata(
            datasetName: object["dataset_key"] as? String,
            routeText: routeText,
            initialHeadingDegrees: (object["initial_heading_deg"] as? NSNumber)?.doubleValue,
            mapPath: object["map_npz_path"] as? String
        )
    }
}
