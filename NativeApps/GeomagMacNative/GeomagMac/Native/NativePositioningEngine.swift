import Foundation

/// Pure-Swift positioning pipeline. It deliberately has no Process, Python,
/// NumPy, or network dependency, so the same computation runs inside the app.
enum NativePositioningEngine {
    struct Request: Sendable {
        let datasetKey: String
        let datasetDirectory: URL
        let route: [XYPoint]
        let initialHeadingDegrees: Double?
        let activeStartTime: Double?
        let activeEndTime: Double?
        let settings: AlgorithmSettings
        let magneticMap: GenericMagneticMapDocument
        let localizationMode: LocalizationMode
    }

    enum EngineError: LocalizedError, Equatable {
        case missingResource(String)
        case malformedCSV(String)
        case insufficientSensorOverlap
        case noSteps
        case invalidMap
        case invalidReferenceRoute
        case insufficientMapSamples
        case insufficientMapSamplesAfterExclusions(excludedSegments: Int, remainingCells: Int)
        case insufficientStepsAfterExclusions(excludedSteps: Int)
        case mapSourceCannotLocateItself
        case localizationModeMismatch
        case initialHeadingRequired

        var errorDescription: String? {
            switch self {
            case let .missingResource(name): "缺少原生算法资源：\(name)"
            case let .malformedCSV(name): "无法解析传感器文件：\(name)"
            case .insufficientSensorOverlap: "三路传感器没有足够的重叠记录。"
            case .noSteps: "没有检测到有效步态，请检查采集数据或有效行走区间。"
            case .invalidMap: "内置地磁地图格式不正确。"
            case .invalidReferenceRoute: "建立磁图至少需要两个不同的真实路线坐标点。"
            case .insufficientMapSamples: "参考采集没有产生足够的有效步级磁场样本。"
            case let .insufficientMapSamplesAfterExclusions(excludedSegments, remainingCells):
                "受扰或暂停区间排除了 \(excludedSegments) 段路线（相邻锚点之间），"
                    + "剩余样本只形成 \(remainingCells) 个有效网格（至少需要 8 个）。请补采被排除的路段。"
            case let .insufficientStepsAfterExclusions(excludedSteps):
                "受扰或暂停区间排除了 \(excludedSteps) 个步级样本，剩余步态不足以建立路线磁图。"
                    + "请补采被排除的路段。"
            case .mapSourceCannotLocateItself: "建图采集不能用于自我定位验证。"
            case .localizationModeMismatch: "定位模式与所选磁图类型不一致。"
            case .initialHeadingRequired: "房间自由定位必须提供已知初始航向，不能从真实路线推断。"
            }
        }
    }

    private struct Vector3: Sendable {
        let x: Double
        let y: Double
        let z: Double
        var magnitude: Double { sqrt(x * x + y * y + z * z) }
    }

    private struct TimedVector: Sendable {
        let time: Double
        let value: Vector3
    }

    private struct TimedHeading: Sendable {
        let time: Double
        let yawRadians: Double
        let magneticAccuracy: Int
        let alignedMagneticVector: Vector3
    }

    private struct Frame: Sendable {
        let time: Double
        let acceleration: Vector3
        let userAcceleration: Vector3?
        let gyroscope: Vector3
        let magnetometer: Vector3
        let deviceHeading: DeviceHeadingFrame?
        let alignedMagneticVector: Vector3?
    }

    private struct Step: Sendable {
        let frameIndex: Int
        let time: Double
        let length: Double
        let heading: Double
        let sensorHeading: Double
        let magneticMagnitude: Double
        let alignedMagneticVector: Vector3?
        let segmentIndex: Int?
    }

    private struct TurnRegion: Sendable {
        let onsetIndex: Int
        let completionIndex: Int
        let onsetTime: Double
        let completionTime: Double
        let signedAngleDegrees: Double
    }

    private struct Particle {
        var x: Double
        var y: Double
        var headingBias: Double
        var stepScale: Double
        var magneticBias: Double
        var magneticBiasX: Double
        var magneticBiasY: Double
        var magneticBiasZ: Double
        var previousMapValue: Double
        var mapNormHistory: [Double]
        var mapVectorHistory: [Vector3]
        var stationaryHypothesis: Bool
        var distanceTravelled: Double
        var weight: Double
    }

    private struct GridKey: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    private struct MagneticMap: Sendable {
        let rows: Int
        let columns: Int
        let values: [Float]
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
        let flipY: Bool
        let scatteredSamples: [GenericMagneticMapSample]
        let supportRadiusM: Double
        let gridCellSizeM: Double?
        let occupiedGridCells: Set<GridKey>
        let samplesFollowPath: Bool
        let closedPathStart: XYPoint?
        let referencePathLength: Double

        private func interpolationDistanceLimit() -> Double {
            min(max(supportRadiusM * 1.9, 0.32), 0.45)
        }

        private func directionalProfile(
            for sample: GenericMagneticMapSample,
            heading: Double?
        ) -> MagneticDirectionalProfile? {
            guard let heading,
                  let profiles = sample.directionalProfiles,
                  (2...4).contains(profiles.count) else { return nil }
            let rawBin = Int(floor((wrap(heading) + .pi) / (2 * .pi) * 8))
            let targetBin = (rawBin % 8 + 8) % 8
            guard let closest = profiles.min(by: {
                min(abs($0.directionBin - targetBin), 8 - abs($0.directionBin - targetBin))
                    < min(abs($1.directionBin - targetBin), 8 - abs($1.directionBin - targetBin))
            }) else { return nil }
            let distance = min(
                abs(closest.directionBin - targetBin),
                8 - abs(closest.directionBin - targetBin)
            )
            return distance == 0 && closest.observationCount >= 12 ? closest : nil
        }

        func sample(x: Double, y: Double, heading: Double? = nil) -> Double {
            if !scatteredSamples.isEmpty {
                let nearest = scatteredSamples
                    .map { sample in
                        (sample, hypot(sample.x - x, sample.y - y))
                    }
                    .sorted { $0.1 < $1.1 }
                    .filter { $0.1 <= interpolationDistanceLimit() }
                    .prefix(4)
                guard !nearest.isEmpty else { return scatteredSamples[0].magneticNormUT }
                var weighted = 0.0
                var totalWeight = 0.0
                for (sample, distance) in nearest {
                    let scale = max(supportRadiusM * 0.45, 0.20)
                    let weight = exp(-0.5 * pow(distance / scale, 2)) + 1e-9
                    let profileValue = directionalProfile(for: sample, heading: heading)?.magneticNormUT
                    let value = profileValue.map {
                        sample.magneticNormUT + 0.15 * ($0 - sample.magneticNormUT)
                    } ?? sample.magneticNormUT
                    weighted += value * weight
                    totalWeight += weight
                }
                return totalWeight > 0
                    ? weighted / totalWeight
                    : scatteredSamples[0].magneticNormUT
            }
            let u = min(max((x - minX) / max(maxX - minX, 1e-9), 0), 1)
            var v = min(max((y - minY) / max(maxY - minY, 1e-9), 0), 1)
            if flipY { v = 1 - v }
            let gx = u * Double(columns - 1)
            let gy = v * Double(rows - 1)
            let x0 = min(max(Int(floor(gx)), 0), columns - 1)
            let y0 = min(max(Int(floor(gy)), 0), rows - 1)
            let x1 = min(x0 + 1, columns - 1)
            let y1 = min(y0 + 1, rows - 1)
            let tx = gx - Double(x0)
            let ty = gy - Double(y0)
            let q00 = Double(values[y0 * columns + x0])
            let q10 = Double(values[y0 * columns + x1])
            let q01 = Double(values[y1 * columns + x0])
            let q11 = Double(values[y1 * columns + x1])
            let top = q00 + (q10 - q00) * tx
            let bottom = q01 + (q11 - q01) * tx
            return top + (bottom - top) * ty
        }

        func sampleVector(x: Double, y: Double, heading: Double? = nil) -> Vector3? {
            let nearest = scatteredSamples.compactMap { sample -> (GenericMagneticMapSample, Double)? in
                guard sample.magneticXUT != nil, sample.magneticYUT != nil, sample.magneticZUT != nil else {
                    return nil
                }
                return (sample, hypot(sample.x - x, sample.y - y))
            }.sorted { $0.1 < $1.1 }
                .filter { $0.1 <= interpolationDistanceLimit() }
                .prefix(4)
            guard !nearest.isEmpty else { return nil }
            let scale = max(supportRadiusM * 0.45, 0.20)
            var xTotal = 0.0
            var yTotal = 0.0
            var zTotal = 0.0
            var weightTotal = 0.0
            for (sample, distance) in nearest {
                let weight = exp(-0.5 * pow(distance / scale, 2)) + 1e-9
                let profile = directionalProfile(for: sample, heading: heading)
                func blend(_ general: Double?, _ directional: Double?) -> Double {
                    let base = general ?? directional ?? 0
                    return directional.map { base + 0.15 * ($0 - base) } ?? base
                }
                xTotal += blend(sample.magneticXUT, profile?.magneticXUT) * weight
                yTotal += blend(sample.magneticYUT, profile?.magneticYUT) * weight
                zTotal += blend(sample.magneticZUT, profile?.magneticZUT) * weight
                weightTotal += weight
            }
            guard weightTotal > 0 else { return nil }
            return Vector3(x: xTotal / weightTotal, y: yTotal / weightTotal, z: zTotal / weightTotal)
        }

        func sampleHeading(x: Double, y: Double) -> Double? {
            let nearest = scatteredSamples.compactMap { sample -> (Double, Double)? in
                guard let heading = sample.headingRadians else { return nil }
                return (heading, hypot(sample.x - x, sample.y - y))
            }.sorted { $0.1 < $1.1 }
                .filter { $0.1 <= interpolationDistanceLimit() }
                .prefix(4)
            guard !nearest.isEmpty else { return nil }
            let scale = max(supportRadiusM * 0.45, 0.12)
            var sine = 0.0
            var cosine = 0.0
            for (heading, distance) in nearest {
                let weight = exp(-0.5 * pow(distance / scale, 2)) + 1e-9
                sine += sin(heading) * weight
                cosine += cos(heading) * weight
            }
            return atan2(sine, cosine)
        }

        func contains(x: Double, y: Double) -> Bool {
            guard minX <= x && x <= maxX && minY <= y && y <= maxY else { return false }
            guard !scatteredSamples.isEmpty else { return true }
            if !samplesFollowPath, let cell = gridCellSizeM, cell > 0 {
                let gridX = Int(floor(x / cell))
                let gridY = Int(floor(y / cell))
                return occupiedGridCells.contains(GridKey(x: gridX, y: gridY))
            }
            let sampleDistance = scatteredSamples.lazy.map {
                hypot($0.x - x, $0.y - y)
            }.min() ?? .infinity
            if sampleDistance <= supportRadiusM { return true }
            guard samplesFollowPath else { return false }
            return zip(scatteredSamples, scatteredSamples.dropFirst()).contains { first, second in
                distanceToSegment(
                    point: XYPoint(x: x, y: y),
                    start: XYPoint(x: first.x, y: first.y),
                    end: XYPoint(x: second.x, y: second.y)
                ).distance <= supportRadiusM
            }
        }

        func nearestSupport(x: Double, y: Double) -> (point: XYPoint, distance: Double)? {
            var nearest = scatteredSamples.map({ sample in
                (sample, hypot(sample.x - x, sample.y - y))
            }).min(by: { $0.1 < $1.1 }).map {
                (point: XYPoint(x: $0.0.x, y: $0.0.y), distance: $0.1)
            }
            if samplesFollowPath {
                for (first, second) in zip(scatteredSamples, scatteredSamples.dropFirst()) {
                    let candidate = distanceToSegment(
                        point: XYPoint(x: x, y: y),
                        start: XYPoint(x: first.x, y: first.y),
                        end: XYPoint(x: second.x, y: second.y)
                    )
                    if nearest == nil || candidate.distance < nearest!.distance {
                        nearest = candidate
                    }
                }
            }
            return nearest
        }

        func pathProgress(x: Double, y: Double, near expected: Double? = nil) -> Double? {
            guard samplesFollowPath, scatteredSamples.count >= 2 else { return nil }
            var cumulative = 0.0
            var best: (progress: Double, distance: Double, score: Double)?
            let total = max(referencePathLength, 1e-9)
            for (first, second) in zip(scatteredSamples, scatteredSamples.dropFirst()) {
                let dx = second.x - first.x
                let dy = second.y - first.y
                let length = hypot(dx, dy)
                guard length > 1e-9 else { continue }
                let fraction = min(max(
                    ((x - first.x) * dx + (y - first.y) * dy) / (length * length),
                    0
                ), 1)
                let px = first.x + fraction * dx
                let py = first.y + fraction * dy
                let distance = hypot(x - px, y - py)
                let progress = cumulative + fraction * length
                let progressTieBreak = expected.map {
                    0.002 * abs(progress - min(max($0, 0), total)) / total
                } ?? 0
                let score = distance + progressTieBreak
                if best == nil || score < best!.score {
                    best = (progress, distance, score)
                }
                cumulative += length
            }
            return best?.progress
        }

        func pathFingerprintUniqueness(x: Double, y: Double) -> Double {
            guard samplesFollowPath, scatteredSamples.count >= 6,
                  let target = scatteredSamples.indices.min(by: {
                    hypot(scatteredSamples[$0].x - x, scatteredSamples[$0].y - y)
                        < hypot(scatteredSamples[$1].x - x, scatteredSamples[$1].y - y)
                  }) else { return 1 }
            let targetHeading = scatteredSamples[target].headingRadians
            var strongestAlias = 0.0
            for candidate in scatteredSamples.indices where candidate != target {
                let separation = hypot(
                    scatteredSamples[candidate].x - scatteredSamples[target].x,
                    scatteredSamples[candidate].y - scatteredSamples[target].y
                )
                guard separation >= 1.0 else { continue }
                if let targetHeading,
                   let candidateHeading = scatteredSamples[candidate].headingRadians,
                   abs(wrap(targetHeading - candidateHeading)) > 35 * .pi / 180 {
                    continue
                }
                let window = min(5, target + 1, candidate + 1)
                guard window >= 3 else { continue }
                var cost = 0.0
                var terms = 0.0
                for offset in 1..<window {
                    let ta = scatteredSamples[target - window + offset + 1]
                    let tb = scatteredSamples[target - window + offset]
                    let ca = scatteredSamples[candidate - window + offset + 1]
                    let cb = scatteredSamples[candidate - window + offset]
                    let normDifference = (ta.magneticNormUT - tb.magneticNormUT)
                        - (ca.magneticNormUT - cb.magneticNormUT)
                    cost += pow(normDifference / 1.0, 2)
                    terms += 1
                    if let tax = ta.magneticXUT, let tay = ta.magneticYUT, let taz = ta.magneticZUT,
                       let tbx = tb.magneticXUT, let tby = tb.magneticYUT, let tbz = tb.magneticZUT,
                       let cax = ca.magneticXUT, let cay = ca.magneticYUT, let caz = ca.magneticZUT,
                       let cbx = cb.magneticXUT, let cby = cb.magneticYUT, let cbz = cb.magneticZUT {
                        cost += 0.25 * (
                            pow(((tax - tbx) - (cax - cbx)) / 3.5, 2)
                                + pow(((tay - tby) - (cay - cby)) / 3.5, 2)
                                + pow(((taz - tbz) - (caz - cbz)) / 3.5, 2)
                        )
                        terms += 0.75
                    }
                }
                guard terms > 0 else { continue }
                strongestAlias = max(strongestAlias, exp(-0.5 * cost / terms))
            }
            return min(max(1 - 0.70 * strongestAlias, 0.25), 1)
        }

        func turnJunction(
            previousHeading: Double,
            nextHeading: Double,
            around point: XYPoint
        ) -> XYPoint? {
            guard samplesFollowPath else { return nil }
            var best: (point: XYPoint, score: Double)?
            for (first, second) in zip(scatteredSamples, scatteredSamples.dropFirst()) {
                guard let incoming = first.headingRadians,
                      let outgoing = second.headingRadians,
                      abs(wrap(outgoing - incoming)) >= 30 * .pi / 180 else { continue }
                let junction = XYPoint(x: first.x, y: first.y)
                let distance = hypot(junction.x - point.x, junction.y - point.y)
                guard distance <= 3.5 else { continue }
                let angularCost = abs(wrap(previousHeading - incoming))
                    + abs(wrap(nextHeading - outgoing))
                guard angularCost <= 120 * .pi / 180 else { continue }
                let score = angularCost + 0.20 * distance
                if best == nil || score < best!.score { best = (junction, score) }
            }
            return best?.point
        }

        private func distanceToSegment(
            point: XYPoint,
            start: XYPoint,
            end: XYPoint
        ) -> (point: XYPoint, distance: Double) {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let denominator = dx * dx + dy * dy
            let fraction = denominator <= 1e-12 ? 0 : min(max(
                ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator,
                0
            ), 1)
            let projection = XYPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
            return (projection, hypot(point.x - projection.x, point.y - projection.y))
        }
    }

    private struct MapMetadata: Decodable {
        let rows: Int
        let columns: Int
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
        let flipY: Bool

        enum CodingKeys: String, CodingKey {
            case rows, columns
            case minX = "min_x_m"
            case maxX = "max_x_m"
            case minY = "min_y_m"
            case maxY = "max_y_m"
            case flipY = "flip_y"
        }
    }

    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func uniform() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }

        mutating func normal(mean: Double = 0, standardDeviation: Double = 1) -> Double {
            let u1 = max(uniform(), 1e-12)
            let u2 = uniform()
            return mean + standardDeviation * sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
    }

    static func bundledDatasetURL(key: String) throws -> URL {
        let url = try nativeResourceRoot()
            .appendingPathComponent("NativeData", isDirectory: true)
            .appendingPathComponent("Datasets", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.missingResource("NativeData/Datasets/\(key)")
        }
        return url
    }

    static func buildGenericMagneticMap(
        name: String,
        datasetKey: String,
        datasetDirectory: URL,
        route: [XYPoint],
        initialHeadingDegrees: Double?,
        activeStartTime: Double?,
        activeEndTime: Double?,
        excludedIntervals: [ClosedRange<Double>] = [],
        settings: AlgorithmSettings = .optimized,
        progress: @Sendable (Double, String) -> Void
    ) throws -> GenericMagneticMapDocument {
        guard route.count >= 2 else { throw EngineError.invalidReferenceRoute }
        let routeLength = zip(route, route.dropFirst()).reduce(0.0) {
            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }
        guard routeLength > 0.5 else { throw EngineError.invalidReferenceRoute }
        progress(0.05, "读取参考采集")
        let frames = try loadFrames(from: datasetDirectory)
        let startTime = max(activeStartTime ?? frames.first!.time, frames.first!.time)
        let endTime = min(activeEndTime ?? frames.last!.time, frames.last!.time)
        let activeFrames = frames.filter { startTime <= $0.time && $0.time <= endTime }
        guard activeFrames.count >= 20 else { throw EngineError.insufficientSensorOverlap }
        let initialHeading = initialHeadingDegrees.map { $0 * .pi / 180 }
            ?? headingOfFirstSegment(route)
        progress(0.35, "提取步级磁场样本")
        let detection = detectSteps(frames: activeFrames, initialHeading: initialHeading, settings: settings)
        // 路线建图同样要按时间排除受扰/暂停段（此前只有锚点建图支持）。
        let steps = detection.steps.filter { step in
            !excludedIntervals.contains { $0.contains(step.time) }
        }
        let excludedStepCount = detection.steps.count - steps.count
        let insufficientSamplesError: EngineError = excludedStepCount > 0
            ? .insufficientStepsAfterExclusions(excludedSteps: excludedStepCount)
            : .insufficientMapSamples
        guard steps.count >= 8 else { throw insufficientSamplesError }
        let segmentHeadings = zip(route, route.dropFirst()).map {
            atan2($1.y - $0.y, $1.x - $0.x)
        }
        var currentSegment = 0
        var acceptedInSegment = 0
        var segmentedSteps: [(step: Step, segment: Int)] = []
        for step in steps {
            let currentError = abs(wrap(step.heading - segmentHeadings[currentSegment]))
            if currentSegment + 1 < segmentHeadings.count {
                let nextError = abs(wrap(step.heading - segmentHeadings[currentSegment + 1]))
                if acceptedInSegment > 0,
                   nextError + 12 * .pi / 180 < currentError {
                    currentSegment += 1
                    acceptedInSegment = 0
                }
            } else if acceptedInSegment > 0, currentError > 75 * .pi / 180 {
                // The intended route is complete. A later turn back toward the
                // initial heading is phone handling after arrival, not mapping.
                break
            }
            segmentedSteps.append((step, currentSegment))
            if abs(wrap(step.heading - segmentHeadings[currentSegment])) < 55 * .pi / 180 {
                acceptedInSegment += 1
            }
        }
        guard Set(segmentedSteps.map(\.segment)).count == segmentHeadings.count else {
            throw insufficientSamplesError
        }
        let totalStepLength = segmentedSteps.map(\.step.length).reduce(0, +)
        guard totalStepLength > 0 else { throw insufficientSamplesError }
        let rawLearnedStepScale = routeLength / totalStepLength
        // A short calibration loop contains too few strides to transfer its
        // amplitude-derived scale reliably to another walk. Shrink short-map
        // calibration toward the physical default; long scans retain it.
        let scaleReliability = min(routeLength / 20.0, 1)
        let learnedStepScale = 1 + scaleReliability * (rawLearnedStepScale - 1)
        var samples: [GenericMagneticMapSample] = []
        samples.reserveCapacity(segmentedSteps.count + 1)
        func mapSample(
            step: Step,
            index: Int,
            position: XYPoint,
            routeHeading: Double
        ) -> GenericMagneticMapSample {
            let validSteps = segmentedSteps.map(\.step)
            let neighborhood = validSteps[max(0, index - 1)...min(validSteps.count - 1, index + 1)]
            let center = mean(neighborhood.map(\.magneticMagnitude))
            let variance = neighborhood.map { pow($0.magneticMagnitude - center, 2) }
                .reduce(0, +) / Double(neighborhood.count)
            var sample = GenericMagneticMapSample(
                x: position.x,
                y: position.y,
                magneticNormUT: step.magneticMagnitude
            )
            sample.magneticXUT = step.alignedMagneticVector?.x
            sample.magneticYUT = step.alignedMagneticVector?.y
            sample.magneticZUT = step.alignedMagneticVector?.z
            sample.varianceUT2 = variance
            sample.observationCount = neighborhood.count
            sample.directionCount = 1
            sample.headingRadians = routeHeading
            return sample
        }
        if let first = segmentedSteps.first {
            samples.append(mapSample(
                step: first.step,
                index: 0,
                position: route[0],
                routeHeading: segmentHeadings[0]
            ))
        }
        for segment in segmentHeadings.indices {
            let indexed = segmentedSteps.enumerated().filter { $0.element.segment == segment }
            let segmentTotal = indexed.map(\.element.step.length).reduce(0, +)
            var segmentProgress = 0.0
            for item in indexed {
                segmentProgress += item.element.step.length
                let fraction = segmentTotal > 0 ? min(max(segmentProgress / segmentTotal, 0), 1) : 1
                let start = route[segment]
                let end = route[segment + 1]
                let position = XYPoint(
                    x: start.x + (end.x - start.x) * fraction,
                    y: start.y + (end.y - start.y) * fraction
                )
                samples.append(mapSample(
                    step: item.element.step,
                    index: item.offset,
                    position: position,
                    routeHeading: segmentHeadings[segment]
                ))
            }
        }
        if samples.count >= 3 {
            for index in 1..<(samples.count - 1) {
                let before = samples[index - 1]
                let after = samples[index + 1]
                let dx = after.x - before.x
                let dy = after.y - before.y
                let distance = hypot(dx, dy)
                guard distance > 0.05 else { continue }
                let gradient = (after.magneticNormUT - before.magneticNormUT) / distance
                samples[index].gradientXUTPerM = gradient * dx / distance
                samples[index].gradientYUTPerM = gradient * dy / distance
            }
        }
        let identifier = try GenericMagneticMapStore.identifier(from: name)
        progress(1, "坐标化磁图建立完成")
        return try GenericMagneticMapDocument(
            schemaVersion: GenericMagneticMapDocument.schemaVersion,
            id: identifier,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            sourceDatasetKeys: [datasetKey],
            referenceRoute: route,
            samples: samples,
            supportRadiusM: 0.22,
            coordinateFrame: "\(identifier)_local",
            gridCellSizeM: 0.20,
            samplesFollowPath: true,
            pdrStepLengthScale: min(max(learnedStepScale, 0.2), 1.30)
        ).validated()
    }

    static func buildAnchoredGridMagneticMap(
        name: String,
        datasetKey: String,
        datasetDirectory: URL,
        coordinateFrame: String,
        anchors: [ImportedSpatialAnchor],
        excludedIntervals: [ClosedRange<Double>] = [],
        cellSizeM: Double = 0.4,
        settings: AlgorithmSettings = .optimized,
        progress: @Sendable (Double, String) -> Void
    ) throws -> GenericMagneticMapDocument {
        let anchors = anchors.sorted { $0.time < $1.time }
        guard anchors.count >= 2,
              zip(anchors, anchors.dropFirst()).contains(where: {
                  hypot($1.x - $0.x, $1.y - $0.y) > 0.2
              }),
              cellSizeM.isFinite, 0.2...1.0 ~= cellSizeM else {
            throw EngineError.invalidReferenceRoute
        }
        progress(0.05, "读取锚点建图采集")
        let frames = try loadFrames(from: datasetDirectory)
        let firstHeading = anchors.first?.headingDegrees.map { $0 * .pi / 180 } ?? 0
        let detection = detectSteps(
            frames: frames,
            initialHeading: firstHeading,
            settings: settings,
            activityGateEnabled: false
        )
        let steps = detection.steps
        let referenceYaw = anchors.first?.deviceYawDegrees.map { $0 * .pi / 180 }
            ?? frames.first(where: { $0.deviceHeading != nil })?.deviceHeading?.yawRadians
        let roomRotation = firstHeading - (referenceYaw ?? 0)

        struct Observation {
            let x: Double
            let y: Double
            let vector: Vector3
            let norm: Double
            let directionBin: Int
            let heading: Double
        }
        var buckets: [GridKey: [Observation]] = [:]
        var knownDistanceTotal = 0.0
        var rawStepDistanceTotal = 0.0
        var excludedSegmentCount = 0
        progress(0.25, "按相邻锚点分配传感器位置")
        for (start, end) in zip(anchors, anchors.dropFirst()) where end.time > start.time {
            if excludedIntervals.contains(where: {
                $0.lowerBound < end.time && start.time < $0.upperBound
            }) {
                excludedSegmentCount += 1
                continue
            }
            let segmentFrames = frames.filter { start.time <= $0.time && $0.time <= end.time }
            guard !segmentFrames.isEmpty else { continue }
            let segmentSteps = steps.filter { start.time <= $0.time && $0.time <= end.time }
            let totalStepDistance = segmentSteps.map(\.length).reduce(0, +)
            let knownDistance = hypot(end.x - start.x, end.y - start.y)
            if totalStepDistance > 0.1, knownDistance > 0.1 {
                knownDistanceTotal += knownDistance
                rawStepDistanceTotal += totalStepDistance
            }
            for frame in segmentFrames {
                guard let aligned = frame.alignedMagneticVector,
                      10...100 ~= aligned.magnitude else { continue }
                let distanceBefore = segmentSteps.lazy.filter { $0.time <= frame.time }.map(\.length).reduce(0, +)
                let timeProgress = (frame.time - start.time) / (end.time - start.time)
                let fraction = totalStepDistance > 0.1
                    ? distanceBefore / totalStepDistance
                    : timeProgress
                let progress = min(max(fraction, 0), 1)
                let x = start.x + (end.x - start.x) * progress
                let y = start.y + (end.y - start.y) * progress
                let roomVector = Vector3(
                    x: aligned.x * cos(roomRotation) - aligned.y * sin(roomRotation),
                    y: aligned.x * sin(roomRotation) + aligned.y * cos(roomRotation),
                    z: aligned.z
                )
                let roomHeading = frame.deviceHeading.map { wrap($0.yawRadians + roomRotation) }
                    ?? firstHeading
                let rawDirectionBin = Int(floor((roomHeading + .pi) / (2 * .pi) * 8))
                let directionBin = (rawDirectionBin % 8 + 8) % 8
                let key = GridKey(
                    x: Int(floor(x / cellSizeM)),
                    y: Int(floor(y / cellSizeM))
                )
                buckets[key, default: []].append(Observation(
                    x: x, y: y, vector: roomVector,
                    norm: roomVector.magnitude,
                    directionBin: directionBin,
                    heading: roomHeading
                ))
            }
        }
        progress(0.70, "稳健合并网格磁场")
        var samplesByKey: [GridKey: GenericMagneticMapSample] = [:]
        for (key, observations) in buckets where observations.count >= 5 {
            let center = median(observations.map(\.norm))
            let mad = median(observations.map { abs($0.norm - center) })
            let limit = max(3 * 1.4826 * mad, 5.0)
            let accepted = observations.filter { abs($0.norm - center) <= limit }
            guard accepted.count >= 4 else { continue }
            let norm = median(accepted.map(\.norm))
            let variance = accepted.map { pow($0.norm - norm, 2) }.reduce(0, +)
                / Double(accepted.count)
            samplesByKey[key] = GenericMagneticMapSample(
                x: accepted.map(\.x).reduce(0, +) / Double(accepted.count),
                y: accepted.map(\.y).reduce(0, +) / Double(accepted.count),
                magneticNormUT: norm,
                magneticXUT: median(accepted.map { $0.vector.x }),
                magneticYUT: median(accepted.map { $0.vector.y }),
                magneticZUT: median(accepted.map { $0.vector.z }),
                varianceUT2: variance,
                observationCount: accepted.count,
                directionCount: Set(accepted.map(\.directionBin)).count
            )
            let directionalProfiles = Dictionary(grouping: accepted, by: \.directionBin)
                .compactMap { directionBin, observations -> MagneticDirectionalProfile? in
                    guard observations.count >= 4 else { return nil }
                    return MagneticDirectionalProfile(
                        directionBin: directionBin,
                        magneticNormUT: median(observations.map(\.norm)),
                        magneticXUT: median(observations.map { $0.vector.x }),
                        magneticYUT: median(observations.map { $0.vector.y }),
                        magneticZUT: median(observations.map { $0.vector.z }),
                        observationCount: observations.count
                    )
                }
                .sorted { $0.directionBin < $1.directionBin }
            samplesByKey[key]?.directionalProfiles = directionalProfiles.isEmpty
                ? nil : directionalProfiles
            let sine = accepted.map { sin($0.heading) }.reduce(0, +)
            let cosine = accepted.map { cos($0.heading) }.reduce(0, +)
            samplesByKey[key]?.headingRadians = atan2(sine, cosine)
        }
        // 排除区间会把整条锚点腿拿掉：样本不足时要说清是排除造成的，
        // 否则用户只会看到「参考采集没有产生足够的有效步级磁场样本」而反复重采。
        guard samplesByKey.count >= 8 else {
            throw excludedSegmentCount > 0
                ? EngineError.insufficientMapSamplesAfterExclusions(
                    excludedSegments: excludedSegmentCount,
                    remainingCells: samplesByKey.count
                )
                : EngineError.insufficientMapSamples
        }
        for (key, sample) in samplesByKey {
            var updated = sample
            if let left = samplesByKey[GridKey(x: key.x - 1, y: key.y)],
               let right = samplesByKey[GridKey(x: key.x + 1, y: key.y)] {
                updated.gradientXUTPerM = (right.magneticNormUT - left.magneticNormUT) / (2 * cellSizeM)
            }
            if let down = samplesByKey[GridKey(x: key.x, y: key.y - 1)],
               let up = samplesByKey[GridKey(x: key.x, y: key.y + 1)] {
                updated.gradientYUTPerM = (up.magneticNormUT - down.magneticNormUT) / (2 * cellSizeM)
            }
            samplesByKey[key] = updated
        }
        let identifier = try GenericMagneticMapStore.identifier(from: name)
        progress(1, "二维锚点磁图建立完成")
        return try GenericMagneticMapDocument(
            schemaVersion: GenericMagneticMapDocument.schemaVersion,
            id: identifier,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            sourceDatasetKeys: [datasetKey],
            referenceRoute: anchors.map { XYPoint(x: $0.x, y: $0.y) },
            samples: samplesByKey.values.sorted { lhs, rhs in
                lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
            },
            supportRadiusM: max(cellSizeM * 1.6, 0.40),
            coordinateFrame: coordinateFrame,
            gridCellSizeM: cellSizeM,
            samplesFollowPath: false,
            pdrStepLengthScale: rawStepDistanceTotal > 0.1
                // Dense scan routes include many stop/turn impulses that make
                // the raw calibration about 20% short on continuous walks.
                ? min(max(1.28 * knownDistanceTotal / rawStepDistanceTotal, 0.2), 2.0)
                : nil
        ).validated()
    }

    static func run(
        request: Request,
        progress: @Sendable (Double, String) -> Void
    ) throws -> PositioningResult {
        if request.magneticMap.sourceDatasetKeys.contains(request.datasetKey) {
            throw EngineError.mapSourceCannotLocateItself
        }
        guard request.localizationMode == request.magneticMap.localizationMode else {
            throw EngineError.localizationModeMismatch
        }
        if request.localizationMode == .roomAreaKnownStart,
           request.initialHeadingDegrees == nil {
            throw EngineError.initialHeadingRequired
        }
        progress(0.02, "读取三路传感器 CSV")
        let frames = try loadFrames(from: request.datasetDirectory)
        try Task.checkCancellation()

        let startTime = max(request.activeStartTime ?? frames.first!.time, frames.first!.time)
        let endTime = min(request.activeEndTime ?? frames.last!.time, frames.last!.time)
        let activeFrames = frames.filter { startTime <= $0.time && $0.time <= endTime }
        guard activeFrames.count >= 20 else { throw EngineError.insufficientSensorOverlap }

        progress(0.20, "选择航向来源并检测步态")
        let initialHeading = request.initialHeadingDegrees.map { $0 * .pi / 180 }
            ?? headingOfFirstSegment(request.route)
        let stepDetection = detectSteps(
            frames: activeFrames,
            initialHeading: initialHeading,
            settings: request.settings,
            stabilizeFreeWalk: request.localizationMode == .roomAreaKnownStart
        )
        let steps = scaledSteps(
            stepDetection.steps,
            by: request.magneticMap.pdrStepLengthScale ?? 1
        )
        guard !steps.isEmpty else { throw EngineError.noSteps }
        try Task.checkCancellation()

        let pdr = buildPDR(start: request.route[0], steps: steps)
        var pfTrack: [XYPoint] = []
        var pfConfidence: [PFConfidenceSample]?
        var localizationHealth: [LocalizationHealthSample]?
        var recoveryEvents: [LocalizationHealthSample]?
        var mapBounds: [Double]?
        progress(0.30, "加载坐标化地磁图并执行原生粒子滤波")
        let map = magneticMap(from: request.magneticMap)
        let filter = try particleFilter(
            start: request.route[0],
            steps: steps,
            map: map,
            localizationMode: request.localizationMode,
            settings: request.settings,
            seed: stableSeed(request.datasetKey),
            progress: progress
        )
        pfTrack = filter.track
        pfConfidence = filter.confidence
        localizationHealth = filter.health
        recoveryEvents = filter.recoveries
        mapBounds = [map.minX, map.maxX, map.minY, map.maxY]

        progress(0.94, "计算误差与定位健康度")
        let pdrErrors = alignedErrors(track: pdr, route: request.route)
        let pdrCrossTrack = crossTrackErrors(track: pdr, route: request.route)
        let pfCrossTrack = pfTrack.isEmpty ? [] : crossTrackErrors(track: pfTrack, route: request.route)
        let pdrAlongTrack = alongTrackErrors(track: pdr, route: request.route)
        let pfAlongTrack = pfTrack.isEmpty ? [] : alongTrackErrors(track: pfTrack, route: request.route)
        let pdrTurnAngles = turnAngleErrors(track: pdr, route: request.route)
        let pfTurnAngles = pfTrack.isEmpty ? [] : turnAngleErrors(track: pfTrack, route: request.route)
        let routeLength = pathLength(request.route)
        let isClosed = request.route.first.map { first in
            request.route.last.map { hypot(first.x - $0.x, first.y - $0.y) <= 0.25 } ?? false
        } ?? false
        let pdrClosure = isClosed ? pdr.last.map { hypot($0.x - pdr[0].x, $0.y - pdr[0].y) } : nil
        let pfClosure = isClosed ? pfTrack.last.map { hypot($0.x - pfTrack[0].x, $0.y - pfTrack[0].y) } : nil
        let pfErrors = pfTrack.isEmpty ? nil : alignedErrors(track: pfTrack, route: request.route)
        let result = PositioningResult(
            branch: "generic_map_pf_native_swift",
            datasetKey: request.datasetKey,
            routeLabel: routeLabel(for: request.datasetKey),
            routeXY: request.route,
            pdrTrack: pdr,
            pfTrack: pfTrack,
            pdrErrorStats: statistics(pdrErrors),
            pfErrorStats: pfErrors.flatMap(statistics),
            controlledCrossTrackErrorStats: nil,
            closureErrorM: pfClosure,
            pdrCrossTrackErrorStats: statistics(pdrCrossTrack),
            pfCrossTrackErrorStats: statistics(pfCrossTrack),
            pdrAlongTrackErrorStats: statistics(pdrAlongTrack),
            pfAlongTrackErrorStats: statistics(pfAlongTrack),
            pdrTurnAngleErrorStats: statistics(pdrTurnAngles),
            pfTurnAngleErrorStats: statistics(pfTurnAngles),
            pdrPathLengthRatio: routeLength > 0 ? pathLength(pdr) / routeLength : nil,
            pfPathLengthRatio: routeLength > 0 ? pathLength(pfTrack) / routeLength : nil,
            pdrClosureErrorM: pdrClosure,
            pfClosureErrorM: pfClosure,
            stepsDetected: steps.count,
            sensorFramesUsed: activeFrames.count,
            fullSensorFrames: frames.count,
            pfSmoothingMode: request.settings.smoothingMode.rawValue,
            pfSmoothingAlpha: request.settings.smoothingAlpha,
            headingSnapDegrees: request.settings.headingSnapDegrees,
            stepLengthScale: request.settings.stepLengthScale,
            vectorMapEnabled: request.magneticMap.vectorSampleRatio >= 0.80,
            pfJointCalibration: request.settings.jointCalibrationEnabled,
            alignmentMode: request.localizationMode.rawValue,
            mapBounds: mapBounds,
            activeWalkInterval: ActiveWalkInterval(
                startTime: startTime,
                endTime: endTime,
                duration: max(endTime - startTime, 0),
                headExcluded: max(startTime - frames.first!.time, 0),
                tailExcluded: max(frames.last!.time - endTime, 0),
                confidence: "native_motion_window"
            ),
            headingDiagnostics: stepDetection.headingDiagnostics,
            controlledMotionDiagnostics: nil,
            magneticFusionDiagnostics: nil,
            pfConfidenceHistory: pfConfidence,
            localizationHealthHistory: localizationHealth,
            localizationRecoveryEvents: recoveryEvents
        )
        progress(1, "原生计算完成")
        return result
    }

    private static func loadFrames(from directory: URL) throws -> [Frame] {
        let acceleration = try loadCSV(directory.appendingPathComponent("Accelerometer.csv"))
        let gyroscope = try loadCSV(directory.appendingPathComponent("Gyroscope.csv"))
        let magnetometer = try loadAlgorithmMagnetometer(from: directory)
        let userAcceleration = try? loadCSV(
            directory.appendingPathComponent("DeviceMotion.csv"),
            valueIndices: (11, 12, 13)
        )
        let deviceHeadings = try? loadDeviceHeadings(
            directory.appendingPathComponent("DeviceMotion.csv")
        )
        guard let a0 = acceleration.first, let a1 = acceleration.last,
              let g0 = gyroscope.first, let g1 = gyroscope.last,
              let m0 = magnetometer.first, let m1 = magnetometer.last else {
            throw EngineError.insufficientSensorOverlap
        }
        let start = max(a0.time, g0.time, m0.time)
        let end = min(a1.time, g1.time, m1.time)
        guard end > start else { throw EngineError.insufficientSensorOverlap }
        var gyroCursor = 0
        var magCursor = 0
        var userAccelerationCursor = 0
        var headingCursor = 0
        return acceleration.compactMap { sample in
            guard start <= sample.time && sample.time <= end else { return nil }
            let gyro = interpolate(gyroscope, at: sample.time, cursor: &gyroCursor)
            let mag = interpolate(magnetometer, at: sample.time, cursor: &magCursor)
            return Frame(
                time: sample.time,
                acceleration: sample.value,
                userAcceleration: userAcceleration.map {
                    interpolate($0, at: sample.time, cursor: &userAccelerationCursor)
                },
                gyroscope: gyro,
                magnetometer: mag,
                deviceHeading: deviceHeadings.flatMap {
                    interpolateHeading($0, at: sample.time, cursor: &headingCursor)
                },
                alignedMagneticVector: deviceHeadings.flatMap {
                    interpolateAlignedMagnetic($0, at: sample.time, cursor: &headingCursor)
                }
            )
        }
    }

    private static func loadAlgorithmMagnetometer(from directory: URL) throws -> [TimedVector] {
        let deviceMotionURL = directory.appendingPathComponent("DeviceMotion.csv")
        if FileManager.default.fileExists(atPath: deviceMotionURL.path),
           let calibrated = try? loadCSV(
               deviceMotionURL,
               valueIndices: (17, 18, 19)
           ),
           calibrated.count >= 20 {
            return calibrated
        }
        return try loadCSV(directory.appendingPathComponent("Magnetometer.csv"))
    }

    private static func loadCSV(
        _ url: URL,
        valueIndices: (Int, Int, Int) = (1, 2, 3)
    ) throws -> [TimedVector] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EngineError.malformedCSV(url.lastPathComponent)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 20 else { throw EngineError.malformedCSV(url.lastPathComponent) }
        let requiredIndex = max(valueIndices.0, valueIndices.1, valueIndices.2)
        var samples: [TimedVector] = []
        samples.reserveCapacity(lines.count - 1)
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > requiredIndex,
                  let time = Double(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let x = Double(fields[valueIndices.0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(fields[valueIndices.1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let z = Double(fields[valueIndices.2].trimmingCharacters(in: .whitespacesAndNewlines)),
                  time.isFinite, x.isFinite, y.isFinite, z.isFinite else { continue }
            samples.append(TimedVector(time: time, value: Vector3(x: x, y: y, z: z)))
        }
        samples.sort { $0.time < $1.time }
        guard samples.count >= 20 else { throw EngineError.malformedCSV(url.lastPathComponent) }
        return samples
    }

    private static func loadDeviceHeadings(_ url: URL) throws -> [TimedHeading] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw EngineError.malformedCSV(url.lastPathComponent)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 20 else { throw EngineError.malformedCSV(url.lastPathComponent) }
        var samples: [TimedHeading] = []
        samples.reserveCapacity(lines.count - 1)
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 20,
                  let time = Double(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let quaternionX = Double(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let quaternionY = Double(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let quaternionZ = Double(fields[3].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let quaternionW = Double(fields[4].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let yaw = Double(fields[7].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let magneticX = Double(fields[17].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let magneticY = Double(fields[18].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let magneticZ = Double(fields[19].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let accuracyValue = Double(
                      fields[20].trimmingCharacters(in: .whitespacesAndNewlines)
                  ),
                  time.isFinite, yaw.isFinite, accuracyValue.isFinite,
                  quaternionX.isFinite, quaternionY.isFinite, quaternionZ.isFinite,
                  quaternionW.isFinite, magneticX.isFinite, magneticY.isFinite,
                  magneticZ.isFinite else { continue }
            let aligned = Vector3(
                x: (1 - 2 * (quaternionY * quaternionY + quaternionZ * quaternionZ)) * magneticX
                    + 2 * (quaternionX * quaternionY - quaternionZ * quaternionW) * magneticY
                    + 2 * (quaternionX * quaternionZ + quaternionY * quaternionW) * magneticZ,
                y: 2 * (quaternionX * quaternionY + quaternionZ * quaternionW) * magneticX
                    + (1 - 2 * (quaternionX * quaternionX + quaternionZ * quaternionZ)) * magneticY
                    + 2 * (quaternionY * quaternionZ - quaternionX * quaternionW) * magneticZ,
                z: 2 * (quaternionX * quaternionZ - quaternionY * quaternionW) * magneticX
                    + 2 * (quaternionY * quaternionZ + quaternionX * quaternionW) * magneticY
                    + (1 - 2 * (quaternionX * quaternionX + quaternionY * quaternionY)) * magneticZ
            )
            samples.append(TimedHeading(
                time: time,
                yawRadians: yaw,
                magneticAccuracy: Int(accuracyValue.rounded()),
                alignedMagneticVector: aligned
            ))
        }
        samples.sort { $0.time < $1.time }
        guard samples.count >= 20 else { throw EngineError.malformedCSV(url.lastPathComponent) }
        return samples
    }

    private static func interpolate(
        _ samples: [TimedVector],
        at time: Double,
        cursor: inout Int
    ) -> Vector3 {
        while cursor + 1 < samples.count && samples[cursor + 1].time < time { cursor += 1 }
        let next = min(cursor + 1, samples.count - 1)
        let a = samples[cursor]
        let b = samples[next]
        let ratio = a.time == b.time ? 0 : min(max((time - a.time) / (b.time - a.time), 0), 1)
        return Vector3(
            x: a.value.x + (b.value.x - a.value.x) * ratio,
            y: a.value.y + (b.value.y - a.value.y) * ratio,
            z: a.value.z + (b.value.z - a.value.z) * ratio
        )
    }

    private static func interpolateHeading(
        _ samples: [TimedHeading],
        at time: Double,
        cursor: inout Int
    ) -> DeviceHeadingFrame? {
        guard let first = samples.first, let last = samples.last,
              first.time <= time, time <= last.time else { return nil }
        while cursor + 1 < samples.count && samples[cursor + 1].time < time { cursor += 1 }
        let next = min(cursor + 1, samples.count - 1)
        let a = samples[cursor]
        let b = samples[next]
        let gap = b.time - a.time
        guard gap <= 0.25 else { return nil }
        let ratio = gap <= 1e-9 ? 0 : min(max((time - a.time) / gap, 0), 1)
        let delta = wrap(b.yawRadians - a.yawRadians)
        return DeviceHeadingFrame(
            yawRadians: wrap(a.yawRadians + delta * ratio),
            magneticAccuracy: min(a.magneticAccuracy, b.magneticAccuracy)
        )
    }

    private static func interpolateAlignedMagnetic(
        _ samples: [TimedHeading],
        at time: Double,
        cursor: inout Int
    ) -> Vector3? {
        guard let first = samples.first, let last = samples.last,
              first.time <= time, time <= last.time else { return nil }
        while cursor + 1 < samples.count && samples[cursor + 1].time < time { cursor += 1 }
        let next = min(cursor + 1, samples.count - 1)
        let a = samples[cursor]
        let b = samples[next]
        let gap = b.time - a.time
        guard gap <= 0.25 else { return nil }
        let ratio = gap <= 1e-9 ? 0 : min(max((time - a.time) / gap, 0), 1)
        return Vector3(
            x: a.alignedMagneticVector.x
                + (b.alignedMagneticVector.x - a.alignedMagneticVector.x) * ratio,
            y: a.alignedMagneticVector.y
                + (b.alignedMagneticVector.y - a.alignedMagneticVector.y) * ratio,
            z: a.alignedMagneticVector.z
                + (b.alignedMagneticVector.z - a.alignedMagneticVector.z) * ratio
        )
    }

    private static func loadBundledMap() throws -> MagneticMap {
        let base = try nativeResourceRoot().appendingPathComponent("NativeData/Map")
        guard let metadataData = try? Data(contentsOf: base.appendingPathComponent("metadata.json")),
              let metadata = try? JSONDecoder().decode(MapMetadata.self, from: metadataData),
              let binary = try? Data(contentsOf: base.appendingPathComponent("magnetic_map.f32")) else {
            throw EngineError.missingResource("NativeData/Map")
        }
        let count = metadata.rows * metadata.columns
        guard binary.count == count * MemoryLayout<Float>.size else { throw EngineError.invalidMap }
        var values = Array(repeating: Float.zero, count: count)
        _ = values.withUnsafeMutableBytes { binary.copyBytes(to: $0) }
        return MagneticMap(
            rows: metadata.rows,
            columns: metadata.columns,
            values: values,
            minX: metadata.minX,
            maxX: metadata.maxX,
            minY: metadata.minY,
            maxY: metadata.maxY,
            flipY: metadata.flipY,
            scatteredSamples: [],
            supportRadiusM: 0,
            gridCellSizeM: nil,
            occupiedGridCells: [],
            samplesFollowPath: false,
            closedPathStart: nil,
            referencePathLength: 0
        )
    }

    private static func magneticMap(from document: GenericMagneticMapDocument) -> MagneticMap {
        let bounds = document.bounds ?? CoordinateBounds(
            minX: 0,
            maxX: 1,
            minY: 0,
            maxY: 1
        )
        return MagneticMap(
            rows: 0,
            columns: 0,
            values: [],
            minX: bounds.minX,
            maxX: bounds.maxX,
            minY: bounds.minY,
            maxY: bounds.maxY,
            flipY: false,
            scatteredSamples: document.samples,
            supportRadiusM: document.supportRadiusM,
            gridCellSizeM: document.gridCellSizeM,
            occupiedGridCells: Set(document.samples.compactMap { sample in
                document.gridCellSizeM.map {
                    GridKey(x: Int(floor(sample.x / $0)), y: Int(floor(sample.y / $0)))
                }
            }),
            samplesFollowPath: document.samplesFollowPath == true,
            closedPathStart: document.samplesFollowPath == true
                ? document.referenceRoute.first.flatMap { first in
                    document.referenceRoute.last.flatMap {
                        hypot(first.x - $0.x, first.y - $0.y) <= document.supportRadiusM
                            ? first : nil
                    }
                }
                : nil,
            referencePathLength: zip(document.referenceRoute, document.referenceRoute.dropFirst())
                .reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        )
    }

    private static func nativeResourceRoot() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["GEOMAG_NATIVE_RESOURCE_ROOT"],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let resourceURL = Bundle.main.resourceURL else {
            throw EngineError.missingResource("NativeData")
        }
        return resourceURL
    }

    private static func detectSteps(
        frames: [Frame],
        initialHeading: Double,
        settings: AlgorithmSettings,
        activityGateEnabled: Bool = true,
        stabilizeFreeWalk: Bool = false
    ) -> (steps: [Step], headingDiagnostics: HeadingDiagnostics) {
        let magnitudes = frames.map { $0.acceleration.magnitude }
        let stationaryRates = frames.compactMap { frame -> Double? in
            let staticAcceleration = abs(frame.acceleration.magnitude - 9.80665) <= 0.30
            let staticRotation = frame.gyroscope.magnitude <= 0.12
            return staticAcceleration && staticRotation ? frame.gyroscope.z : nil
        }
        let gyroBias = stationaryRates.isEmpty ? 0 : mean(stationaryRates)
        var headings = Array(repeating: initialHeading, count: frames.count)
        if frames.count >= 2 {
            for index in 1..<frames.count {
                let dt = min(max(frames[index].time - frames[index - 1].time, 0), 0.1)
                let rate = ((frames[index - 1].gyroscope.z + frames[index].gyroscope.z) / 2) - gyroBias
                headings[index] = wrap(headings[index - 1] + rate * dt)
            }
        }
        let headingResolution = DeviceHeadingResolver.resolve(
            frameTimes: frames.map(\.time),
            gyroHeadings: headings,
            deviceFrames: frames.map(\.deviceHeading),
            initialHeading: initialHeading
        )
        headings = headingResolution.headings
        let referenceYaw = frames.first(where: { $0.deviceHeading != nil })?.deviceHeading?.yawRadians
        let roomRotation = initialHeading - (referenceYaw ?? initialHeading)
        let positiveIntervals = zip(frames, frames.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0 > 0 }
        let sampleRate = positiveIntervals.isEmpty ? 100 : 1 / median(positiveIntervals)
        let userAccelerationCoverage = Double(frames.count { $0.userAcceleration != nil })
            / Double(max(frames.count, 1))
        let rawStepSignal = userAccelerationCoverage >= 0.80
            ? frames.map { $0.userAcceleration?.z ?? 0 }
            : magnitudes.map { $0 - 9.80665 }
        let shortTerm = movingAverage(
            rawStepSignal,
            width: max(3, Int((0.08 * sampleRate).rounded()))
        )
        let baseline = movingAverage(
            rawStepSignal,
            width: max(5, Int((0.75 * sampleRate).rounded()))
        )
        let stepSignal = zip(shortTerm, baseline).map { $0.0 - $0.1 }
        let activityEnergy = movingAverage(
            stepSignal.map { $0 * $0 },
            width: max(5, Int((1.5 * sampleRate).rounded()))
        ).map { sqrt(max($0, 0)) }
        let activityUpperQuartile = percentile(activityEnergy.sorted(), 0.75)
        // Stop-heavy free walks contain long waits around manually marked points.
        // Sensor tremor during those waits can look cadence-like, so only accept
        // peaks inside sustained motion bursts when the whole capture is low-energy.
        let usesActivityGate = activityGateEnabled && activityUpperQuartile < 0.36
        let activityGate = max(
            0.18,
            (activityUpperQuartile < 0.30 ? 0.90 : 0.60) * activityUpperQuartile
        )
        let cadencePeriod = dominantStepPeriod(signal: stepSignal, sampleRate: sampleRate)
        let minimumInterval = min(max(0.84 * cadencePeriod, 0.46), 0.68)
        let signalCenter = median(stepSignal)
        let signalNoise = 1.4826 * median(stepSignal.map { abs($0 - signalCenter) })
        let historyWidth = max(10, Int((1.5 * sampleRate).rounded()))
        let prominenceWidth = max(3, Int((0.28 * sampleRate).rounded()))
        var steps: [Step] = []
        var previousPeak = 0
        var recentStableHeadings: [Double] = []
        var adaptiveHeadingAnchor: Double? = initialHeading
        guard frames.count > 17 else { return (steps, headingResolution.diagnostics) }
        for index in 15..<(frames.count - 1) {
            let historyStart = max(0, index - historyWidth)
            let history = Array(stepSignal[historyStart...index])
            let threshold = median(history) + 0.25 * standardDeviation(history)
            let prominenceStart = max(0, index - prominenceWidth)
            let recentMin = stepSignal[prominenceStart...index].min() ?? stepSignal[index]
            let prominence = stepSignal[index] - recentMin
            let isPeak = stepSignal[index] > stepSignal[index - 1]
                && stepSignal[index] >= stepSignal[index + 1]
                && stepSignal[index] > threshold
                && prominence > max(0.18, 0.85 * signalNoise)
                && (!usesActivityGate || activityEnergy[index] >= activityGate)
            guard isPeak else { continue }
            if let last = steps.last,
               frames[index].time - last.time < minimumInterval { continue }
            let accelerationSegment = magnitudes[previousPeak...min(index + 1, magnitudes.count - 1)]
            let delta = max((accelerationSegment.max() ?? 0) - (accelerationSegment.min() ?? 0), 1e-9)
            let turnWindow = max(1, Int((0.18 * sampleRate).rounded()))
            let turnStart = max(0, index - turnWindow)
            let turnEnd = min(frames.count - 1, index + turnWindow)
            let angularRate = frames[turnStart...turnEnd]
                .map { abs($0.gyroscope.z) }
                .max() ?? 0
            let translationGain: Double
            if angularRate <= 0.35 {
                translationGain = 1
            } else if angularRate >= 1.0 {
                translationGain = 0.03
            } else {
                translationGain = 1 - 0.97 * (angularRate - 0.35) / 0.65
            }
            let rawLength = min(max(
                0.31 * pow(delta, 0.25) * settings.stepLengthScale,
                0.15
            ), 1.20)
            let length = rawLength * translationGain
            let magneticWindow = frames[previousPeak...min(index + 1, frames.count - 1)]
                .map { $0.magnetometer.magnitude }
                .filter { 10 <= $0 && $0 <= 100 }
            let alignedVector = frames[index].alignedMagneticVector.map { vector in
                Vector3(
                    x: vector.x * cos(roomRotation) - vector.y * sin(roomRotation),
                    y: vector.x * sin(roomRotation) + vector.y * cos(roomRotation),
                    z: vector.z
                )
            }
            let sensorHeading = headings[index]
            let heading: Double
            if settings.headingSnapDegrees > 0 {
                let grid = settings.headingSnapDegrees * .pi / 180
                heading = (sensorHeading / grid).rounded() * grid
            } else if angularRate <= 0.12 {
                recentStableHeadings.append(sensorHeading)
                if recentStableHeadings.count > 6 { recentStableHeadings.removeFirst() }
                let center = atan2(
                    recentStableHeadings.map(sin).reduce(0, +),
                    recentStableHeadings.map(cos).reduce(0, +)
                )
                let spread = recentStableHeadings.map { abs(wrap($0 - center)) }.max() ?? 0
                if recentStableHeadings.count >= 3, spread <= 8 * .pi / 180 {
                    let anchor = adaptiveHeadingAnchor ?? center
                    let correction = min(max(wrap(anchor - sensorHeading), -12 * .pi / 180), 12 * .pi / 180)
                    heading = wrap(sensorHeading + 0.55 * correction)
                    adaptiveHeadingAnchor = wrap(anchor + 0.03 * wrap(center - anchor))
                } else {
                    heading = sensorHeading
                }
            } else {
                heading = sensorHeading
                recentStableHeadings.removeAll(keepingCapacity: true)
                adaptiveHeadingAnchor = nil
            }
            steps.append(Step(
                frameIndex: index,
                time: frames[index].time,
                length: length,
                heading: heading,
                sensorHeading: sensorHeading,
                magneticMagnitude: mean(magneticWindow),
                alignedMagneticVector: alignedVector,
                segmentIndex: nil
            ))
            previousPeak = index + 1
        }
        let stabilizedSteps = stabilizeFreeWalk && settings.headingSnapDegrees <= 0
            ? stabilizeFreeWalkHeadings(steps: steps, frames: frames)
            : steps
        return (stabilizedSteps, headingResolution.diagnostics)
    }

    /// Smooths quiet walking locally and models each automatically detected
    /// turn as one continuous heading transition. It does not assume 90° turns.
    private static func stabilizeFreeWalkHeadings(
        steps: [Step],
        frames: [Frame]
    ) -> [Step] {
        guard steps.count >= 3 else { return steps }
        let turns = detectQuarterTurnRegions(frames: frames)
        func circularMean(_ values: [Double]) -> Double {
            atan2(values.map(sin).reduce(0, +), values.map(cos).reduce(0, +))
        }
        func inTurn(_ time: Double) -> TurnRegion? {
            turns.first { $0.onsetTime <= time && time <= $0.completionTime }
        }
        return steps.indices.map { index in
            let step = steps[index]
            let stabilized: Double
            if let turn = inTurn(step.time) {
                let before = steps.filter { $0.time < turn.onsetTime }.suffix(3).map(\.heading)
                let after = steps.filter { $0.time > turn.completionTime }.prefix(3).map(\.heading)
                if !before.isEmpty, !after.isEmpty {
                    let incoming = circularMean(before)
                    let outgoing = circularMean(after)
                    let rawProgress = (step.time - turn.onsetTime)
                        / max(turn.completionTime - turn.onsetTime, 1e-6)
                    let progress = min(max(rawProgress, 0), 1)
                    let eased = progress * progress * (3 - 2 * progress)
                    stabilized = wrap(incoming + eased * wrap(outgoing - incoming))
                } else {
                    stabilized = step.heading
                }
            } else {
                let lower = max(0, index - 1)
                let upper = min(steps.count - 1, index + 1)
                let neighbors = (lower...upper)
                    .map { steps[$0] }
                    .filter { inTurn($0.time) == nil }
                    .map(\.heading)
                stabilized = neighbors.isEmpty ? step.heading : circularMean(neighbors)
            }
            return Step(
                frameIndex: step.frameIndex,
                time: step.time,
                length: step.length,
                heading: wrap(stabilized),
                sensorHeading: step.sensorHeading,
                magneticMagnitude: step.magneticMagnitude,
                alignedMagneticVector: step.alignedMagneticVector,
                segmentIndex: step.segmentIndex
            )
        }
    }

    private static func movingAverage(_ values: [Double], width: Int) -> [Double] {
        guard !values.isEmpty, width > 1 else { return values }
        let radius = width / 2
        var prefix = Array(repeating: 0.0, count: values.count + 1)
        for index in values.indices { prefix[index + 1] = prefix[index] + values[index] }
        return values.indices.map { index in
            let start = max(0, index - radius)
            let end = min(values.count, index + radius + 1)
            return (prefix[end] - prefix[start]) / Double(end - start)
        }
    }

    private static func dominantStepPeriod(signal: [Double], sampleRate: Double) -> Double {
        guard signal.count >= 30, sampleRate.isFinite, sampleRate > 1 else { return 0.65 }
        let centered = signal.map { $0 - mean(signal) }
        let minimumLag = max(1, Int((0.42 * sampleRate).rounded()))
        let maximumLag = min(signal.count / 2, Int((0.90 * sampleRate).rounded()))
        guard minimumLag <= maximumLag else { return 0.65 }
        var bestLag = minimumLag
        var bestCorrelation = -Double.infinity
        for lag in minimumLag...maximumLag {
            var correlation = 0.0
            for index in 0..<(centered.count - lag) {
                correlation += centered[index] * centered[index + lag]
            }
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        return Double(bestLag) / sampleRate
    }

    // Kept temporarily for decoding and comparing historical controlled-route
    // results. The app no longer exposes or calls this route-specific path.
    private static func legacyDetectSteps(
        datasetKey: String,
        frames: [Frame],
        initialHeading: Double,
        settings: AlgorithmSettings,
        route: [XYPoint],
        controlledProfile: ControlledMotionProfile?,
        magneticTemplate: ControlledMagneticTemplate?
    ) -> (
        steps: [Step],
        headingDiagnostics: HeadingDiagnostics,
        controlledMotionDiagnostics: ControlledMotionDiagnostics?,
        magneticFusionDiagnostics: MagneticFusionDiagnostics?,
        magneticTemplateSegments: [ControlledMagneticSegmentTemplate]?
    ) {
        let magnitudes = frames.map { $0.acceleration.magnitude }
        var smoothed = magnitudes
        if magnitudes.count >= 3 {
            for index in 1..<(magnitudes.count - 1) {
                smoothed[index] = (magnitudes[index - 1] + magnitudes[index] + magnitudes[index + 1]) / 3
            }
        }
        // Only truly stationary frames are valid for yaw-bias calibration.
        // Using arbitrary head/tail windows corrupts short captures when the
        // operator starts walking immediately or stops recording at arrival.
        let stationaryRates = frames.compactMap { frame -> Double? in
            let accelerationIsStatic = abs(frame.acceleration.magnitude - 9.80665) <= 0.30
            let gyroscopeIsStatic = frame.gyroscope.magnitude <= 0.12
            return accelerationIsStatic && gyroscopeIsStatic ? frame.gyroscope.z : nil
        }
        let gyroBias = stationaryRates.isEmpty ? 0 : mean(stationaryRates)
        var headings = Array(repeating: initialHeading, count: frames.count)
        if frames.count >= 2 {
            for index in 1..<frames.count {
                let dt = min(max(frames[index].time - frames[index - 1].time, 0), 0.1)
                let rate = ((frames[index - 1].gyroscope.z + frames[index].gyroscope.z) / 2) - gyroBias
                headings[index] = wrap(headings[index - 1] + rate * dt)
            }
        }
        let headingResolution = DeviceHeadingResolver.resolve(
            frameTimes: frames.map(\.time),
            gyroHeadings: headings,
            deviceFrames: frames.map(\.deviceHeading),
            initialHeading: initialHeading
        )
        headings = headingResolution.headings
        let turnRegions = controlledProfile == nil
            ? []
            : detectQuarterTurnRegions(frames: frames)
        let usesControlledCadence = controlledProfile != nil
        var steps: [Step] = []
        var previousPeak = 0
        var bufferStart = 0
        for index in 15..<(frames.count - 1) {
            let windowStart = usesControlledCadence ? bufferStart : max(0, index - 100)
            guard index - windowStart >= 14 else { continue }
            let history: [Double]
            let candidateIndex: Int
            if usesControlledCadence {
                let raw = Array(magnitudes[windowStart...index + 1])
                history = raw.indices.map { localIndex in
                    let previous = localIndex > 0 ? raw[localIndex - 1] : 0
                    let next = localIndex + 1 < raw.count ? raw[localIndex + 1] : 0
                    return (previous + raw[localIndex] + next) / 3
                }
                candidateIndex = history.count - 2
            } else {
                history = Array(smoothed[windowStart...index + 1])
                candidateIndex = history.count - 2
            }
            let threshold = mean(history) + 0.45 * standardDeviation(history)
            let recentMin = history[max(0, candidateIndex - 8)...candidateIndex].min()
                ?? history[candidateIndex]
            let isPeak = history[candidateIndex] > history[candidateIndex - 1]
                && history[candidateIndex] >= history[candidateIndex + 1]
                && history[candidateIndex] > threshold
                && history[candidateIndex] - recentMin > (usesControlledCadence ? 0.40 : 0.30)
            guard isPeak else { continue }
            let minimumInterval = usesControlledCadence ? 0.55 : 0.40
            if let last = steps.last, frames[index].time - last.time < minimumInterval { continue }
            let lengthStart = usesControlledCadence ? bufferStart : previousPeak
            let segment = magnitudes[lengthStart...min(index + 1, magnitudes.count - 1)]
            let delta = max((segment.max() ?? 0) - (segment.min() ?? 0), 1e-9)
            let length = 0.31 * pow(delta, 0.25) * settings.stepLengthScale
            let sensorHeading = headings[index]
            var heading = sensorHeading
            if settings.headingSnapDegrees > 0 {
                let grid = settings.headingSnapDegrees * .pi / 180
                heading = (heading / grid).rounded() * grid
            }
            let magneticWindow = frames[lengthStart...min(index + 1, frames.count - 1)]
                .map { $0.magnetometer.magnitude }
                .filter { 10 <= $0 && $0 <= 100 }
            steps.append(Step(
                frameIndex: index,
                time: frames[index].time,
                length: min(max(length, 0.15), 1.20),
                heading: heading,
                sensorHeading: sensorHeading,
                magneticMagnitude: usesControlledCadence
                    ? frames[index].magnetometer.magnitude
                    : mean(magneticWindow),
                alignedMagneticVector: frames[index].alignedMagneticVector,
                segmentIndex: nil
            ))
            previousPeak = index + 1
            if usesControlledCadence {
                bufferStart = min(index + 2, frames.count - 1)
            }
        }
        guard let profile = controlledProfile else {
            return (steps, headingResolution.diagnostics, nil, nil, nil)
        }
        guard headingResolution.diagnostics.deviceMotionAccepted else {
            return (
                steps,
                headingResolution.diagnostics,
                controlledDiagnostics(
                    profile: profile,
                    turns: turnRegions,
                    removed: 0,
                    postEndpoint: 0,
                    counts: [],
                    lengths: [],
                    priors: [],
                    headings: [],
                    rejectionReason: "core_motion_heading_unavailable"
                ),
                nil,
                nil
            )
        }
        guard turnRegions.count == 4 else {
            return (
                steps,
                headingResolution.diagnostics,
                controlledDiagnostics(
                    profile: profile,
                    turns: turnRegions,
                    removed: 0,
                    postEndpoint: 0,
                    counts: [],
                    lengths: [],
                    priors: [],
                    headings: [],
                    rejectionReason: "quarter_turns_not_detected"
                ),
                nil,
                nil
            )
        }

        var removed = 0
        let endpointStepCount = closedRouteEndpointStepCount(
            steps: steps,
            initialHeading: initialHeading
        )
        let postEndpoint = endpointStepCount.map { steps.count - $0 } ?? 0
        let endpointTrimmedSteps = endpointStepCount.map {
            Array(steps.prefix($0))
        } ?? steps
        var straightSteps: [Step] = []
        for step in endpointTrimmedSteps {
            if turnRegions.prefix(3).contains(where: {
                $0.onsetTime <= step.time && step.time <= $0.completionTime
            }) {
                removed += 1
                continue
            }
            let segmentIndex = turnRegions.prefix(3).reduce(into: 0) { segment, turn in
                if step.time > turn.completionTime { segment += 1 }
            }
            straightSteps.append(Step(
                frameIndex: step.frameIndex,
                time: step.time,
                length: step.length,
                heading: step.heading,
                sensorHeading: step.sensorHeading,
                magneticMagnitude: step.magneticMagnitude,
                alignedMagneticVector: step.alignedMagneticVector,
                segmentIndex: segmentIndex
            ))
        }
        var counts = (0..<4).map { segment in
            straightSteps.count { $0.segmentIndex == segment }
        }
        var partitionMethod = "sample_level"
        if !counts.allSatisfy({ $0 > 0 }),
           let fallback = stepLevelStraightPartition(
               steps: endpointTrimmedSteps,
               initialHeading: initialHeading
           ) {
            straightSteps = fallback.steps
            removed = fallback.removed
            counts = (0..<4).map { segment in
                straightSteps.count { $0.segmentIndex == segment }
            }
            partitionMethod = "step_level_fallback"
        }
        guard counts.allSatisfy({ $0 > 0 }) else {
            return (
                straightSteps,
                headingResolution.diagnostics,
                controlledDiagnostics(
                    profile: profile,
                    turns: turnRegions,
                    removed: removed,
                    postEndpoint: postEndpoint,
                    counts: counts,
                    lengths: [],
                    priors: [],
                    headings: [],
                    partitionMethod: partitionMethod,
                    rejectionReason: "empty_straight_segment"
                ),
                nil,
                nil
            )
        }
        let calibrated = calibrateControlledSteps(
            straightSteps,
            route: route,
            turns: turnRegions,
            profile: profile
        )
        let templateSegments = magneticTemplateSegments(from: straightSteps)
        let magnetic = ControlledMagneticFusion.apply(
            datasetKey: datasetKey,
            group: profile.group,
            calibrationSourceKey: profile.calibrationSourceKey,
            initialHeading: initialHeading,
            steps: calibrated.steps.map { step in
                ControlledMagneticStepInput(
                    length: step.length,
                    sensorHeading: step.sensorHeading,
                    fusedHeading: step.heading,
                    magneticNormUT: step.magneticMagnitude,
                    alignedMagneticVectorUT: step.alignedMagneticVector.map {
                        MagneticVector3(x: $0.x, y: $0.y, z: $0.z)
                    },
                    segmentIndex: step.segmentIndex ?? 0
                )
            },
            templateOverride: magneticTemplate
        )
        var fusedSteps: [Step] = []
        fusedSteps.reserveCapacity(calibrated.steps.count)
        for (index, step) in calibrated.steps.enumerated() {
            let segment = step.segmentIndex ?? 0
            fusedSteps.append(Step(
                frameIndex: step.frameIndex,
                time: step.time,
                length: magnetic.stepLengths[index],
                heading: magnetic.segmentHeadings[segment],
                sensorHeading: step.sensorHeading,
                magneticMagnitude: step.magneticMagnitude,
                alignedMagneticVector: step.alignedMagneticVector,
                segmentIndex: step.segmentIndex
            ))
        }
        return (
            fusedSteps,
            headingResolution.diagnostics,
            controlledDiagnostics(
                profile: profile,
                turns: turnRegions,
                removed: removed,
                postEndpoint: postEndpoint,
                counts: counts,
                lengths: calibrated.segmentLengths,
                priors: calibrated.distancePriors,
                headings: calibrated.segmentHeadingsDegrees,
                partitionMethod: partitionMethod,
                rejectionReason: nil
            ),
            magnetic.diagnostics,
            templateSegments
        )
    }

    private static func magneticTemplateSegments(
        from steps: [Step]
    ) -> [ControlledMagneticSegmentTemplate]? {
        var output: [ControlledMagneticSegmentTemplate] = []
        for segment in 0..<4 {
            let selected = steps.filter { $0.segmentIndex == segment }
            guard !selected.isEmpty,
                  selected.allSatisfy({ $0.alignedMagneticVector != nil }) else { return nil }
            let total = selected.map(\.length).reduce(0, +)
            var cumulative = 0.0
            let progress = selected.map { step in
                cumulative += step.length
                return cumulative / max(total, 1e-9)
            }
            output.append(ControlledMagneticSegmentTemplate(
                progress: progress,
                magneticNormUT: selected.map(\.magneticMagnitude),
                alignedVectorsUT: selected.compactMap { vector in
                    vector.alignedMagneticVector.map {
                        MagneticVector3(x: $0.x, y: $0.y, z: $0.z)
                    }
                }
            ))
        }
        return output
    }

    private static func detectQuarterTurnRegions(frames: [Frame]) -> [TurnRegion] {
        let yaws = frames.map { $0.deviceHeading?.yawRadians }
        guard let firstIndex = yaws.firstIndex(where: { $0 != nil }),
              let firstYaw = yaws[firstIndex] else { return [] }
        var continuous = firstYaw
        var previousRaw = firstYaw
        var unwrapped = Array(repeating: Double.nan, count: frames.count)
        for index in firstIndex..<frames.count {
            guard let raw = yaws[index] else { continue }
            continuous += wrap(raw - previousRaw)
            unwrapped[index] = continuous
            previousRaw = raw
        }
        let validIndices = unwrapped.indices.filter { unwrapped[$0].isFinite }
        guard validIndices.count >= 20,
              validIndices.count == frames.count else { return [] }
        let yawDegrees = unwrapped.map { $0 * 180 / .pi }
        let positiveIntervals = zip(frames, frames.dropFirst())
            .map { $1.time - $0.time }
            .filter { $0 > 0 }
        guard !positiveIntervals.isEmpty else { return [] }
        let sampleRate = 1 / median(positiveIntervals)
        let width = max(1, Int((0.12 * sampleRate).rounded()))
        var rate = Array(repeating: 0.0, count: frames.count)
        for index in frames.indices {
            let left = max(0, index - 1)
            let right = min(frames.count - 1, index + 1)
            let dt = frames[right].time - frames[left].time
            if dt > 1e-9 {
                rate[index] = abs((yawDegrees[right] - yawDegrees[left]) / dt)
            }
        }
        if width > 1 {
            // Match NumPy `convolve(..., mode: "same")`; even kernels are
            // aligned with one additional sample on the forward side.
            let radius = (width - 1) / 2
            rate = rate.indices.map { index in
                var total = 0.0
                for offset in 0..<width {
                    let source = index + offset - radius
                    if rate.indices.contains(source) { total += rate[source] }
                }
                return total / Double(width)
            }
        }
        let quietSamples = max(2, Int((0.18 * sampleRate).rounded()))
        let padding = max(1, Int((0.08 * sampleRate).rounded()))
        var regions: [TurnRegion] = []
        var index = firstIndex
        while index < rate.count {
            if rate[index] < 28 {
                index += 1
                continue
            }
            let onset = index
            var lastActive = index
            var cursor = index + 1
            while cursor < rate.count {
                if rate[cursor] >= 12 { lastActive = cursor }
                if cursor - lastActive >= quietSamples { break }
                cursor += 1
            }
            let paddedOnset = max(firstIndex, onset - padding)
            let completion = min(rate.count - 1, lastActive + padding)
            let signedAngle = yawDegrees[completion] - yawDegrees[paddedOnset]
            if abs(signedAngle) >= 30 {
                regions.append(TurnRegion(
                    onsetIndex: paddedOnset,
                    completionIndex: completion,
                    onsetTime: frames[paddedOnset].time,
                    completionTime: frames[completion].time,
                    signedAngleDegrees: signedAngle
                ))
            }
            index = max(cursor, onset + 1)
        }
        return regions
    }

    private static func closedRouteEndpointStepCount(
        steps: [Step],
        initialHeading: Double
    ) -> Int? {
        let turns = detectedStepTurns(steps: steps, initialHeading: initialHeading)
        guard turns.count >= 4 else { return nil }
        let count = turns[3].startIndex
        return 0 < count && count < steps.count ? count : nil
    }

    private static func detectedStepTurns(
        steps: [Step],
        initialHeading: Double
    ) -> [(stepIndex: Int, startIndex: Int, delta: Double)] {
        guard steps.count >= 2 else { return [] }
        let headings = [initialHeading] + steps.map(\.heading)
        let window = 3
        var turns: [(stepIndex: Int, startIndex: Int, delta: Double)] = []
        for index in 1..<headings.count {
            let start = max(0, index - window)
            let delta = wrap(headings[index] - headings[start])
            guard abs(delta) >= 25 * .pi / 180 else { continue }
            let candidate = (index, start, delta)
            if let last = turns.last,
               index - last.stepIndex <= window {
                if abs(delta) > abs(last.delta) {
                    turns[turns.count - 1] = candidate
                }
            } else {
                turns.append(candidate)
            }
        }
        return turns
    }

    private static func stepLevelStraightPartition(
        steps: [Step],
        initialHeading: Double
    ) -> (steps: [Step], removed: Int)? {
        let turns = detectedStepTurns(steps: steps, initialHeading: initialHeading)
        guard turns.count >= 3 else { return nil }
        var output: [Step] = []
        var removed = 0
        for (index, step) in steps.enumerated() {
            let isTurning = turns.prefix(3).contains { turn in
                turn.startIndex <= index && index < min(turn.stepIndex, steps.count)
            }
            if isTurning {
                removed += 1
                continue
            }
            let segment = turns.prefix(3).reduce(into: 0) { value, turn in
                if index >= min(turn.stepIndex, steps.count) { value += 1 }
            }
            output.append(Step(
                frameIndex: step.frameIndex,
                time: step.time,
                length: step.length,
                heading: step.heading,
                sensorHeading: step.sensorHeading,
                magneticMagnitude: step.magneticMagnitude,
                alignedMagneticVector: step.alignedMagneticVector,
                segmentIndex: segment
            ))
        }
        return (output, removed)
    }

    private static func calibrateControlledSteps(
        _ steps: [Step],
        route: [XYPoint],
        turns: [TurnRegion],
        profile: ControlledMotionProfile
    ) -> (
        steps: [Step],
        segmentLengths: [Double],
        distancePriors: [Double],
        segmentHeadingsDegrees: [Double]
    ) {
        var estimatedLengths: [Double] = []
        var distancePriors: [Double] = []
        var segmentHeadings: [Double] = []
        for segment in 0..<4 {
            let selected = steps.filter { $0.segmentIndex == segment }
            let scaled = selected.map { $0.length * profile.stepScaleBySegment[segment] }
            let sensorLength = scaled.reduce(0, +)
            let countRatio = min(
                Double(selected.count) / Double(max(profile.calibrationStepCounts[segment], 1)),
                Double(profile.calibrationStepCounts[segment]) / Double(max(selected.count, 1))
            )
            let average = mean(scaled)
            let coefficientOfVariation = average > 1e-9
                ? standardDeviation(scaled) / average
                : 0
            let reference = profile.referenceLengthsM[segment]
            let conflict = abs(sensorLength - reference) / max(reference, 0.15)
            let confidence = pow(countRatio, 2)
                * exp(-conflict / 0.35)
                * exp(-pow(coefficientOfVariation / 0.50, 2))
            let prior = 1 - 0.90 * confidence
            estimatedLengths.append(prior * reference + (1 - prior) * sensorLength)
            distancePriors.append(prior)

            let sine = selected.map { sin($0.heading) }.reduce(0, +) / Double(selected.count)
            let cosine = selected.map { cos($0.heading) }.reduce(0, +) / Double(selected.count)
            let measured = atan2(sine, cosine)
            let resultant = max(hypot(sine, cosine), 1e-9)
            let dispersionDegrees = sqrt(max(0, -2 * log(resultant))) * 180 / .pi
            let expected = atan2(
                route[segment + 1].y - route[segment].y,
                route[segment + 1].x - route[segment].x
            )
            let correction = wrap(expected - measured)
            let disagreementDegrees = abs(correction * 180 / .pi)
            let turnErrorDegrees = segment == 0
                ? 0
                : abs(abs(turns[segment - 1].signedAngleDegrees) - 90)
            let headingConfidence = exp(-pow(disagreementDegrees / 10, 2))
                * exp(-pow(dispersionDegrees / 8, 2))
                * exp(-pow(turnErrorDegrees / 20, 2))
            let headingPrior = 1 - 0.90 * headingConfidence
            segmentHeadings.append(wrap(measured + headingPrior * correction))
        }

        var result: [Step] = []
        for segment in 0..<4 {
            let selected = steps.filter { $0.segmentIndex == segment }
            let rawSum = selected.map(\.length).reduce(0, +)
            for step in selected {
                result.append(Step(
                    frameIndex: step.frameIndex,
                    time: step.time,
                    length: rawSum > 1e-9
                        ? step.length / rawSum * estimatedLengths[segment]
                        : 0,
                    heading: segmentHeadings[segment],
                    sensorHeading: step.sensorHeading,
                    magneticMagnitude: step.magneticMagnitude,
                    alignedMagneticVector: step.alignedMagneticVector,
                    segmentIndex: segment
                ))
            }
        }
        return (
            result,
            estimatedLengths,
            distancePriors,
            segmentHeadings.map { $0 * 180 / .pi }
        )
    }

    private static func controlledDiagnostics(
        profile: ControlledMotionProfile,
        turns: [TurnRegion],
        removed: Int,
        postEndpoint: Int,
        counts: [Int],
        lengths: [Double],
        priors: [Double],
        headings: [Double],
        partitionMethod: String? = nil,
        rejectionReason: String?
    ) -> ControlledMotionDiagnostics {
        ControlledMotionDiagnostics(
            releaseID: ControlledMotionProfile.releaseID,
            profile: ControlledMotionProfile.profileName,
            deploymentStatus: ControlledMotionProfile.deploymentStatus,
            calibrationSourceKey: profile.calibrationSourceKey,
            turnRegionsDetected: turns.count,
            turnTranslationStepsRemoved: removed,
            postEndpointPeaksRemoved: postEndpoint,
            segmentStepCounts: counts,
            estimatedSegmentLengthsM: lengths,
            effectiveDistancePrior: priors,
            segmentHeadingsDegrees: headings,
            turnPartitionMethod: partitionMethod,
            legacyParticleFilterExcluded: true,
            rejectionReason: rejectionReason
        )
    }

    private static func buildPDR(start: XYPoint, steps: [Step]) -> [XYPoint] {
        var track = [start]
        track.reserveCapacity(steps.count + 1)
        for step in steps {
            let last = track.last!
            track.append(XYPoint(
                x: last.x + step.length * cos(step.heading),
                y: last.y + step.length * sin(step.heading)
            ))
        }
        return track
    }

    private static func scaledSteps(_ steps: [Step], by scale: Double) -> [Step] {
        guard abs(scale - 1) > 1e-12 else { return steps }
        return steps.map { step in
            Step(
                frameIndex: step.frameIndex,
                time: step.time,
                length: step.length * scale,
                heading: step.heading,
                sensorHeading: step.sensorHeading,
                magneticMagnitude: step.magneticMagnitude,
                alignedMagneticVector: step.alignedMagneticVector,
                segmentIndex: step.segmentIndex
            )
        }
    }

    private static func particleFilter(
        start: XYPoint,
        steps: [Step],
        map: MagneticMap,
        localizationMode: LocalizationMode,
        settings: AlgorithmSettings,
        seed: UInt64,
        progress: @Sendable (Double, String) -> Void
    ) throws -> (
        track: [XYPoint],
        confidence: [PFConfidenceSample],
        health: [LocalizationHealthSample],
        recoveries: [LocalizationHealthSample]
    ) {
        let count = 2_000
        var rng = SeededGenerator(seed: seed)
        let startMap = map.sample(x: start.x, y: start.y)
        let initialObserved = steps.first?.magneticMagnitude ?? startMap
        let startVector = map.sampleVector(x: start.x, y: start.y)
        let initialObservedVector = steps.first?.alignedMagneticVector
        var particles = (0..<count).map { _ in
            Particle(
                x: start.x + rng.normal(standardDeviation: 0.20),
                y: start.y + rng.normal(standardDeviation: 0.20),
                headingBias: settings.jointCalibrationEnabled
                    ? rng.normal(standardDeviation: 0.06) : 0,
                stepScale: settings.jointCalibrationEnabled
                    ? min(max(1 + rng.normal(standardDeviation: 0.12), 0.45), 1.25) : 1,
                magneticBias: initialObserved - startMap,
                magneticBiasX: (initialObservedVector?.x ?? 0) - (startVector?.x ?? 0),
                magneticBiasY: (initialObservedVector?.y ?? 0) - (startVector?.y ?? 0),
                magneticBiasZ: (initialObservedVector?.z ?? 0) - (startVector?.z ?? 0),
                previousMapValue: startMap,
                mapNormHistory: [startMap],
                mapVectorHistory: startVector.map { [$0] } ?? [],
                stationaryHypothesis: false,
                distanceTravelled: 0,
                weight: 1 / Double(count)
            )
        }
        var track = [start]
        var confidence: [PFConfidenceSample] = []
        var health: [LocalizationHealthSample] = []
        var recoveries: [LocalizationHealthSample] = []
        var previousObserved = initialObserved
        var observedNormHistory = [initialObserved]
        var observedVectorHistory = initialObservedVector.map { [$0] } ?? []
        var lowStreak = 0
        var lostStreak = 0
        var turnSmoothingCooldown = 0
        var lastTurnTrackIndex = 0
        var closedEndpointLocked = false

        for (stepIndex, step) in steps.enumerated() {
            try Task.checkCancellation()
            observedNormHistory.append(step.magneticMagnitude)
            if let vector = step.alignedMagneticVector { observedVectorHistory.append(vector) }
            if observedNormHistory.count > 12 { observedNormHistory.removeFirst() }
            if observedVectorHistory.count > 12 { observedVectorHistory.removeFirst() }
            let stationarityWindow = Array(observedNormHistory.suffix(5))
            let endpointStabilityThreshold = map.referencePathLength < 10 ? 2.0 : 1.25
            let endpointMagneticStable = stationarityWindow.count >= 4
                && (stationarityWindow.max()! - stationarityWindow.min()!)
                    <= endpointStabilityThreshold
            let estimateAtClosedEndpoint = map.closedPathStart.map {
                hypot(track.last!.x - $0.x, track.last!.y - $0.y)
                    <= max(map.supportRadiusM * 3, 0.65)
            } ?? false
            let headingChange = stepIndex > 0
                ? abs(wrap(step.heading - steps[stepIndex - 1].heading)) : 0
            if headingChange > 25 * .pi / 180 {
                turnSmoothingCooldown = 2
            }
            let routeConstraintsEnabled = localizationMode == .routeCorridorValidation
            let activeTurnJunction = routeConstraintsEnabled && headingChange > 45 * .pi / 180
                ? map.turnJunction(
                    previousHeading: steps[stepIndex - 1].heading,
                    nextHeading: step.heading,
                    around: track.last!
                )
                : nil
            if let activeTurnJunction,
               !(endpointMagneticStable && estimateAtClosedEndpoint) {
                injectTurnParticles(
                    into: &particles,
                    junction: activeTurnJunction,
                    heading: step.heading,
                    observed: step.magneticMagnitude,
                    map: map,
                    rng: &rng,
                    ratio: 0.35
                )
            }
            let recentlyReachedClosedEndpoint = routeConstraintsEnabled
                ? map.closedPathStart.map { endpoint in
                pathLength(track) >= 0.70 * map.referencePathLength
                    && track.suffix(6).contains {
                        hypot($0.x - endpoint.x, $0.y - endpoint.y)
                            <= max(map.supportRadiusM * 1.6, 0.35)
                    }
            } ?? false : false
            let completedOrderedPath = routeConstraintsEnabled && map.samplesFollowPath
                && pathLength(track) >= 0.85 * map.referencePathLength
            if recentlyReachedClosedEndpoint
                && (endpointMagneticStable || completedOrderedPath) {
                closedEndpointLocked = true
            }
            if closedEndpointLocked, let endpoint = map.closedPathStart {
                injectEndpointParticles(
                    into: &particles,
                    endpoint: endpoint,
                    map: map,
                    rng: &rng,
                    ratio: 0.75
                )
            }
            var weightSum = 0.0
            for index in particles.indices {
                var particle = particles[index]
                if settings.jointCalibrationEnabled {
                    particle.stepScale = min(max(
                        particle.stepScale + 0.015 * (1 - particle.stepScale)
                            + rng.normal(standardDeviation: 0.003),
                        0.45
                    ), 1.25)
                    particle.headingBias = wrap(
                        particle.headingBias + rng.normal(standardDeviation: 0.003)
                    )
                }
                // Preserve heading continuity on straight/curved walking while
                // temporarily widening the hypothesis set at a genuine turn.
                let headingNoise = rng.normal(standardDeviation: 0.03)
                let stepNoise = rng.normal(standardDeviation: 0.025)
                // A peak detector inevitably sees an occasional phone-handling impulse.
                // Keep a small stationary hypothesis alive so the magnetic sequence can
                // reject those false steps instead of forcing every particle to move.
                let stationaryPrior: Double
                let completedClosedLoop = map.closedPathStart.map {
                    particle.distanceTravelled >= 0.75 * map.referencePathLength
                        && hypot(particle.x - $0.x, particle.y - $0.y)
                            <= max(map.supportRadiusM * 1.6, 0.35)
                } ?? false
                if localizationMode == .roomAreaKnownStart, step.length > 0.08 {
                    // In room-area localization the magnetic fingerprint can repeat
                    // several metres away. A tiny stationary particle subset can then
                    // win repeatedly and make the PF silently drop real walking steps.
                    // Keep normal detected steps translational; short handling impulses
                    // still use the false-step hypothesis below.
                    stationaryPrior = 0
                } else if closedEndpointLocked {
                    stationaryPrior = 0.995
                } else if completedClosedLoop && endpointMagneticStable {
                    stationaryPrior = particle.stationaryHypothesis ? 0.985 : 0.38
                } else if step.length <= 0.08 {
                    stationaryPrior = 0.72
                } else if particle.stationaryHypothesis {
                    let isAtClosedEndpoint = map.closedPathStart.map {
                        hypot(particle.x - $0.x, particle.y - $0.y)
                            <= max(map.supportRadiusM * 2.5, 0.50)
                    } ?? false
                    stationaryPrior = endpointMagneticStable && isAtClosedEndpoint ? 0.94 : 0.01
                } else {
                    stationaryPrior = 0.001
                }
                let acceptsTranslation = rng.uniform() >= stationaryPrior
                let distance = acceptsTranslation
                    ? max(0, step.length * particle.stepScale + stepNoise)
                    : 0
                particle.stationaryHypothesis = !acceptsTranslation
                particle.distanceTravelled += distance
                let particleHeading = wrap(step.heading + particle.headingBias + headingNoise)
                particle.x += distance * cos(particleHeading)
                particle.y += distance * sin(particleHeading)
                var supportPenalty = 1.0
                if !map.contains(x: particle.x, y: particle.y) {
                    guard let projection = map.nearestSupport(x: particle.x, y: particle.y),
                          projection.distance <= max(map.supportRadiusM * 0.25, 0.04) else {
                        particle.weight = 0
                        particles[index] = particle
                        continue
                    }
                    particle.x = projection.point.x
                    particle.y = projection.point.y
                    supportPenalty = exp(-0.5 * pow(
                        projection.distance / max(map.supportRadiusM * 0.20, 0.03), 2
                    ))
                }
                // Directional profiles are retained in the map, but only the
                // attitude-aligned aggregate is used until device-orientation
                // repeatability is independently validated.
                let mapValue = map.sample(x: particle.x, y: particle.y)
                let mapVector = map.sampleVector(x: particle.x, y: particle.y)
                particle.mapNormHistory.append(mapValue)
                if let mapVector { particle.mapVectorHistory.append(mapVector) }
                if particle.mapNormHistory.count > 12 { particle.mapNormHistory.removeFirst() }
                if particle.mapVectorHistory.count > 12 { particle.mapVectorHistory.removeFirst() }
                let absoluteError = mapValue + particle.magneticBias - step.magneticMagnitude
                let differentialError = (mapValue - particle.previousMapValue)
                    - (step.magneticMagnitude - previousObserved)
                var exponent = -0.5 * (
                    pow(absoluteError / 1.8, 2) + pow(differentialError / 0.65, 2)
                )
                exponent += -0.5 * 0.08 * pow((particle.stepScale - 1) / 0.18, 2)
                if routeConstraintsEnabled,
                   let mapHeading = map.sampleHeading(x: particle.x, y: particle.y) {
                    let headingError = wrap(step.heading + particle.headingBias - mapHeading)
                    exponent += -0.5 * 0.25 * pow(headingError / (30 * .pi / 180), 2)
                }
                if routeConstraintsEnabled,
                   let progress = map.pathProgress(
                    x: particle.x,
                    y: particle.y,
                    near: particle.distanceTravelled
                ) {
                    // Magnetic patterns can repeat several metres apart on a long edge.
                    // Keep those alternatives alive, but require each one to remain
                    // dynamically plausible for its own travelled-distance hypothesis.
                    let expected = min(particle.distanceTravelled, map.referencePathLength)
                    let progressError = abs(progress - expected)
                    exponent += -0.5 * 0.40 * pow(progressError / 0.85, 2)
                }
                let normWindow = min(particle.mapNormHistory.count, observedNormHistory.count, 10)
                if normWindow >= 3 {
                    var sequenceCost = 0.0
                    let mapStart = particle.mapNormHistory.count - normWindow
                    let observedStart = observedNormHistory.count - normWindow
                    for offset in 1..<normWindow {
                        let mapDelta = particle.mapNormHistory[mapStart + offset]
                            - particle.mapNormHistory[mapStart + offset - 1]
                        let observedDelta = observedNormHistory[observedStart + offset]
                            - observedNormHistory[observedStart + offset - 1]
                        sequenceCost += pow((mapDelta - observedDelta) / 0.9, 2)
                    }
                    exponent += -0.5 * 0.85 * sequenceCost / Double(normWindow - 1)
                }
                if let mapVector,
                   let observedVector = step.alignedMagneticVector {
                    let errorX = mapVector.x + particle.magneticBiasX - observedVector.x
                    let errorY = mapVector.y + particle.magneticBiasY - observedVector.y
                    let errorZ = mapVector.z + particle.magneticBiasZ - observedVector.z
                    exponent += -0.5 * 0.45 * (
                        pow(errorX / 6.0, 2) + pow(errorY / 6.0, 2) + pow(errorZ / 6.0, 2)
                    )
                    let vectorWindow = min(
                        particle.mapVectorHistory.count,
                        observedVectorHistory.count,
                        10
                    )
                    if vectorWindow >= 3 {
                        let mapStart = particle.mapVectorHistory.count - vectorWindow
                        let observedStart = observedVectorHistory.count - vectorWindow
                        var sequenceCost = 0.0
                        for offset in 1..<vectorWindow {
                            let a = particle.mapVectorHistory[mapStart + offset]
                            let b = particle.mapVectorHistory[mapStart + offset - 1]
                            let c = observedVectorHistory[observedStart + offset]
                            let d = observedVectorHistory[observedStart + offset - 1]
                            sequenceCost += pow(((a.x - b.x) - (c.x - d.x)) / 3.0, 2)
                                + pow(((a.y - b.y) - (c.y - d.y)) / 3.0, 2)
                                + pow(((a.z - b.z) - (c.z - d.z)) / 3.0, 2)
                        }
                        exponent += -0.5 * 0.50 * sequenceCost / Double(vectorWindow - 1)
                    }
                    particle.magneticBiasX += 0.003 * (observedVector.x - mapVector.x - particle.magneticBiasX)
                    particle.magneticBiasY += 0.003 * (observedVector.y - mapVector.y - particle.magneticBiasY)
                    particle.magneticBiasZ += 0.003 * (observedVector.z - mapVector.z - particle.magneticBiasZ)
                }
                let likelihood = max(exp(exponent), 1e-12) * supportPenalty
                particle.weight *= likelihood
                particle.magneticBias += 0.003 * (step.magneticMagnitude - mapValue - particle.magneticBias)
                particle.previousMapValue = mapValue
                particles[index] = particle
                weightSum += particle.weight
            }
            if !weightSum.isFinite || weightSum <= 1e-300 {
                injectParticles(
                    into: &particles,
                    around: track.last!,
                    map: map,
                    observed: step.magneticMagnitude,
                    rng: &rng,
                    ratio: 1
                )
            } else {
                for index in particles.indices { particles[index].weight /= weightSum }
            }

            let estimate = localModeMean(
                particles,
                radius: max(map.supportRadiusM * 2.2, 0.48),
                preferred: XYPoint(
                    x: track.last!.x + step.length * cos(step.heading),
                    y: track.last!.y + step.length * sin(step.heading)
                ),
                maximumMotion: max(step.length * 1.8, 0.55)
            )
            var rawPoint = XYPoint(x: estimate.x, y: estimate.y)
            if let activeTurnJunction {
                let available = max(track.count - 1 - lastTurnTrackIndex, 1)
                applyFixedLagTurnCorrection(
                    track: &track,
                    junction: activeTurnJunction,
                    lag: min(5, available)
                )
                lastTurnTrackIndex = track.count - 1
            }
            if localizationMode == .roomAreaKnownStart {
                rawPoint = constrainedRoomDeparture(
                    rawPoint,
                    previous: track.last!,
                    heading: step.heading,
                    stepLength: step.length
                )
            } else if turnSmoothingCooldown > 0, !closedEndpointLocked {
                rawPoint = constrainedTurnDeparture(
                    rawPoint,
                    previous: track.last!,
                    heading: step.heading,
                    stepLength: step.length
                )
            }
            let bypassEMA = turnSmoothingCooldown > 0
                || closedEndpointLocked
            let point = bypassEMA
                ? rawPoint
                : smooth(rawPoint, previous: track.last!, settings: settings)
            track.append(point)
            turnSmoothingCooldown = max(turnSmoothingCooldown - 1, 0)
            let ess = 1 / particles.reduce(0) { $0 + $1.weight * $1.weight }
            let sample = confidenceSample(
                particles: particles,
                essRatio: ess / Double(count),
                map: map,
                fingerprintUniqueness: map.pathFingerprintUniqueness(
                    x: rawPoint.x,
                    y: rawPoint.y
                )
            )
            confidence.append(sample)
            if sample.score < 0.38 { lowStreak += 1 } else { lowStreak = 0 }
            if sample.score < 0.20 { lostStreak += 1 } else { lostStreak = 0 }
            let status: String
            let action: String
            if lostStreak >= 5 {
                status = "lost"
                action = "reinitialize"
            } else if lowStreak >= 3 {
                status = "ambiguous"
                action = "expand_search"
            } else {
                status = "healthy"
                action = "none"
            }
            let event = LocalizationHealthSample(
                stepIndex: stepIndex + 1,
                status: status,
                score: sample.score,
                lowConfidenceStreak: lowStreak,
                lostStreak: lostStreak,
                action: action,
                reasonCodes: status == "healthy" ? [] : (
                    (sample.globalAmbiguity ?? 0) > 0.35
                        ? ["global_path_ambiguity"] : ["low_particle_concentration"]
                ),
                recoveryCount: recoveries.count
            )
            health.append(event)
            if lostStreak == 5 {
                recoveries.append(event)
                injectParticles(
                    into: &particles,
                    around: point,
                    map: map,
                    observed: step.magneticMagnitude,
                    rng: &rng,
                    ratio: 0.35
                )
                lowStreak = 0
                lostStreak = 0
            } else if ess < Double(count) * 0.55 {
                particles = modePreservingResample(particles, map: map, rng: &rng)
            }
            previousObserved = step.magneticMagnitude
            progress(
                0.30 + 0.62 * Double(stepIndex + 1) / Double(steps.count),
                "原生 PF：第 \(stepIndex + 1)/\(steps.count) 步"
            )
        }
        return (track, confidence, health, recoveries)
    }

    private static func weightedMean(_ particles: [Particle]) -> (x: Double, y: Double) {
        particles.reduce(into: (x: 0.0, y: 0.0)) { result, particle in
            result.x += particle.x * particle.weight
            result.y += particle.y * particle.weight
        }
    }

    private static func localModeMean(
        _ particles: [Particle],
        radius: Double,
        preferred: XYPoint,
        maximumMotion: Double
    ) -> (x: Double, y: Double) {
        guard !particles.isEmpty else { return (preferred.x, preferred.y) }
        let candidates = particles.sorted { $0.weight > $1.weight }.prefix(24)
        var selected = candidates.first!
        var selectedScore = -Double.infinity
        for candidate in candidates {
            let mass = particles.lazy.filter {
                hypot($0.x - candidate.x, $0.y - candidate.y) <= radius
            }.reduce(0.0) { $0 + $1.weight }
            let motion = hypot(candidate.x - preferred.x, candidate.y - preferred.y)
            let continuity = exp(-0.5 * pow(motion / max(maximumMotion, 0.1), 2))
            let score = mass * (0.25 + 0.75 * continuity)
            if score > selectedScore {
                selected = candidate
                selectedScore = score
            }
        }
        var x = 0.0
        var y = 0.0
        var total = 0.0
        for particle in particles
        where hypot(particle.x - selected.x, particle.y - selected.y) <= radius {
            x += particle.x * particle.weight
            y += particle.y * particle.weight
            total += particle.weight
        }
        return total > 1e-12 ? (x / total, y / total) : (selected.x, selected.y)
    }

    private static func smooth(
        _ current: XYPoint,
        previous: XYPoint,
        settings: AlgorithmSettings
    ) -> XYPoint {
        switch settings.smoothingMode {
        case .none:
            return current
        case .ema:
            return XYPoint(
                x: settings.smoothingAlpha * previous.x + (1 - settings.smoothingAlpha) * current.x,
                y: settings.smoothingAlpha * previous.y + (1 - settings.smoothingAlpha) * current.y
            )
        case .motionAdaptive:
            let displacement = hypot(current.x - previous.x, current.y - previous.y)
            let historyWeight = min(max(settings.smoothingAlpha * exp(-displacement), 0.05), 0.85)
            return XYPoint(
                x: historyWeight * previous.x + (1 - historyWeight) * current.x,
                y: historyWeight * previous.y + (1 - historyWeight) * current.y
            )
        }
    }

    /// Prevents a room-area PF mode from jumping sideways to a distant but
    /// magnetically similar cell in one step. Small lateral corrections remain
    /// available and can accumulate over subsequent steps.
    static func constrainedRoomDeparture(
        _ point: XYPoint,
        previous: XYPoint,
        heading: Double,
        stepLength: Double
    ) -> XYPoint {
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let ux = cos(heading)
        let uy = sin(heading)
        let forward = dx * ux + dy * uy
        let lateral = -dx * uy + dy * ux
        let forwardLimit = max(stepLength * 1.8, 0.20)
        let lateralLimit = max(stepLength * 0.50, 0.07)
        let correctedForward = min(max(forward, -0.02), forwardLimit)
        let correctedLateral = min(max(lateral, -lateralLimit), lateralLimit)
        return XYPoint(
            x: previous.x + correctedForward * ux - correctedLateral * uy,
            y: previous.y + correctedForward * uy + correctedLateral * ux
        )
    }


    /// A map-independent continuity guard for the first two estimates around a
    /// detected turn. It suppresses a sideways mode jump caused by a broad
    /// particle cloud without snapping the estimate to any reference corner.
    static func constrainedTurnDeparture(
        _ point: XYPoint,
        previous: XYPoint,
        heading: Double,
        stepLength: Double
    ) -> XYPoint {
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let distance = hypot(dx, dy)
        guard distance > 0.04 else { return point }
        let ux = cos(heading)
        let uy = sin(heading)
        let forward = dx * ux + dy * uy
        let lateral = -dx * uy + dy * ux
        let lateralLimit = max(0.10, min(stepLength * 0.45, 0.16))
        let backwardLimit = max(0.04, stepLength * 0.12)
        guard forward < -backwardLimit || abs(lateral) > lateralLimit else {
            return point
        }
        let maximumForward = max(stepLength * 1.5, 0.25)
        let correctedForward = min(max(forward, 0), maximumForward)
        return XYPoint(
            x: previous.x + correctedForward * ux,
            y: previous.y + correctedForward * uy
        )
    }

    private static func applyFixedLagTurnCorrection(
        track: inout [XYPoint],
        junction: XYPoint,
        lag: Int
    ) {
        guard track.count >= 2, lag > 0 else { return }
        let correctedCount = min(lag, track.count - 1)
        let anchorIndex = track.count - 1 - correctedCount
        let anchor = track[anchorIndex]
        for offset in 1...correctedCount {
            let fraction = Double(offset) / Double(correctedCount)
            track[anchorIndex + offset] = XYPoint(
                x: anchor.x + (junction.x - anchor.x) * fraction,
                y: anchor.y + (junction.y - anchor.y) * fraction
            )
        }
    }

    private static func confidenceSample(
        particles: [Particle],
        essRatio: Double,
        map: MagneticMap,
        fingerprintUniqueness: Double
    ) -> PFConfidenceSample {
        let center = weightedMean(particles)
        var xx = 0.0
        var yy = 0.0
        var xy = 0.0
        var distances: [(Double, Double)] = []
        distances.reserveCapacity(particles.count)
        for particle in particles {
            let dx = particle.x - center.x
            let dy = particle.y - center.y
            xx += particle.weight * dx * dx
            yy += particle.weight * dy * dy
            xy += particle.weight * dx * dy
            distances.append((hypot(dx, dy), particle.weight))
        }
        let trace = xx + yy
        let discriminant = sqrt(max(pow(xx - yy, 2) + 4 * xy * xy, 0))
        let major = sqrt(max((trace + discriminant) / 2, 0))
        let minor = sqrt(max((trace - discriminant) / 2, 0))
        distances.sort { $0.0 < $1.0 }
        func radius(_ quantile: Double) -> Double {
            var accumulated = 0.0
            for (distance, weight) in distances {
                accumulated += weight
                if accumulated >= quantile { return distance }
            }
            return distances.last?.0 ?? 0
        }
        let radius80 = radius(0.80)
        let radius95 = radius(0.95)
        let concentration = exp(-radius80 / 1.5)
        let dominantPathMass = dominantPathModeMass(particles: particles, map: map)
        let pathAmbiguity = map.samplesFollowPath ? 1 - dominantPathMass : 1 - concentration
        let ambiguity = max(pathAmbiguity, 1 - fingerprintUniqueness)
        let information = pow(
            max(concentration * dominantPathMass * fingerprintUniqueness, 0),
            1 / 3
        )
        let rawScore = 0.35 * concentration + 0.15 * essRatio
            + 0.25 * dominantPathMass + 0.25 * fingerprintUniqueness
        let ambiguityGate = 0.50 + 0.50 * (1 - ambiguity)
        let score = min(max(rawScore * ambiguityGate, 0), 1)
        let level = score >= 0.70 ? "high" : score >= 0.40 ? "medium" : "low"
        return PFConfidenceSample(
            radius95M: radius95,
            coreRadius80M: radius80,
            sigmaMajorM: major,
            sigmaMinorM: minor,
            essRatio: essRatio,
            measurementInformation: information,
            globalAmbiguity: ambiguity,
            score: score,
            level: level
        )
    }

    private static func dominantPathModeMass(
        particles: [Particle],
        map: MagneticMap
    ) -> Double {
        guard map.samplesFollowPath else { return 1 }
        let values = particles.compactMap { particle -> (progress: Double, weight: Double)? in
            map.pathProgress(
                x: particle.x,
                y: particle.y,
                near: particle.distanceTravelled
            ).map { ($0, particle.weight) }
        }
        guard !values.isEmpty else { return 0 }
        let radius = max(map.supportRadiusM * 4, 0.80)
        let candidates = values.sorted { $0.weight > $1.weight }.prefix(48)
        return min(candidates.reduce(0.0) { best, candidate in
            max(best, values.reduce(0.0) { mass, item in
                mass + (abs(item.progress - candidate.progress) <= radius ? item.weight : 0)
            })
        }, 1)
    }

    private static func modePreservingResample(
        _ particles: [Particle],
        map: MagneticMap,
        rng: inout SeededGenerator
    ) -> [Particle] {
        guard particles.count > 1 else { return particles }
        guard map.samplesFollowPath else {
            return spatialModePreservingResample(particles, map: map, rng: &rng)
        }
        let binWidth = max(map.supportRadiusM * 3, 0.70)
        var bins: [Int: (indices: [Int], mass: Double)] = [:]
        for index in particles.indices {
            guard particles[index].weight > 0,
                  let progress = map.pathProgress(
                    x: particles[index].x,
                    y: particles[index].y,
                    near: particles[index].distanceTravelled
                  ) else { continue }
            let key = Int(floor(progress / binWidth))
            bins[key, default: ([], 0)].indices.append(index)
            bins[key, default: ([], 0)].mass += particles[index].weight
        }
        let orderedKeys = bins.keys.sorted()
        let ranked = orderedKeys.sorted {
            let lhsMass = bins[$0]!.mass
            let rhsMass = bins[$1]!.mass
            return abs(lhsMass - rhsMass) > 1e-15 ? lhsMass > rhsMass : $0 < $1
        }
        var seeds: [Int] = []
        for key in ranked where bins[key]!.mass >= 0.01 {
            if seeds.allSatisfy({ abs($0 - key) >= 2 }) { seeds.append(key) }
            if seeds.count == 4 { break }
        }
        guard seeds.count >= 2 else { return systematicResample(particles, rng: &rng) }

        var clusters = Array(repeating: [Int](), count: seeds.count)
        for key in orderedKeys {
            let bin = bins[key]!
            let cluster = seeds.indices.min { abs(seeds[$0] - key) < abs(seeds[$1] - key) }!
            clusters[cluster].append(contentsOf: bin.indices)
        }
        let masses = clusters.map { indices in
            indices.reduce(0.0) { $0 + particles[$1].weight }
        }
        let totalMass = max(masses.reduce(0, +), 1e-12)
        let rawCounts = masses.map {
            Double(particles.count) * (0.82 * $0 / totalMass + 0.18 / Double(seeds.count))
        }
        var allocations = rawCounts.map { Int(floor($0)) }
        var remainder = particles.count - allocations.reduce(0, +)
        for index in rawCounts.indices.sorted(by: {
            let lhs = rawCounts[$0] - floor(rawCounts[$0])
            let rhs = rawCounts[$1] - floor(rawCounts[$1])
            return abs(lhs - rhs) > 1e-15 ? lhs > rhs : $0 < $1
        }) where remainder > 0 {
            allocations[index] += 1
            remainder -= 1
        }

        var result: [Particle] = []
        result.reserveCapacity(particles.count)
        for clusterIndex in clusters.indices {
            let indices = clusters[clusterIndex]
            let requested = allocations[clusterIndex]
            guard requested > 0, !indices.isEmpty else { continue }
            let mass = max(masses[clusterIndex], 1e-12)
            let start = rng.uniform() / Double(requested)
            var sourceOffset = 0
            var cumulative = particles[indices[0]].weight / mass
            for outputIndex in 0..<requested {
                let target = start + Double(outputIndex) / Double(requested)
                while target > cumulative && sourceOffset + 1 < indices.count {
                    sourceOffset += 1
                    cumulative += particles[indices[sourceOffset]].weight / mass
                }
                var particle = particles[indices[sourceOffset]]
                particle.weight = 1 / Double(particles.count)
                result.append(particle)
            }
        }
        while result.count < particles.count {
            var particle = particles[ranked.first.flatMap { bins[$0]?.indices.first } ?? 0]
            particle.weight = 1 / Double(particles.count)
            result.append(particle)
        }
        return Array(result.prefix(particles.count))
    }

    /// Grid maps often contain several similar magnetic locations along a long
    /// edge. Preserve a small particle share for separated spatial modes so a
    /// later magnetic sequence can select the correct one.
    private static func spatialModePreservingResample(
        _ particles: [Particle],
        map: MagneticMap,
        rng: inout SeededGenerator
    ) -> [Particle] {
        let binWidth = max(map.supportRadiusM * 1.5, 0.55)
        var bins: [GridKey: (indices: [Int], mass: Double)] = [:]
        for index in particles.indices where particles[index].weight > 0 {
            let key = GridKey(
                x: Int(floor(particles[index].x / binWidth)),
                y: Int(floor(particles[index].y / binWidth))
            )
            bins[key, default: ([], 0)].indices.append(index)
            bins[key, default: ([], 0)].mass += particles[index].weight
        }
        let orderedKeys = bins.keys.sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }
        let ranked = orderedKeys.sorted {
            let lhsMass = bins[$0]!.mass
            let rhsMass = bins[$1]!.mass
            if abs(lhsMass - rhsMass) > 1e-15 { return lhsMass > rhsMass }
            return $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }
        var seeds: [GridKey] = []
        for key in ranked where bins[key]!.mass >= 0.008 {
            if seeds.allSatisfy({ hypot(Double($0.x - key.x), Double($0.y - key.y)) >= 2 }) {
                seeds.append(key)
            }
            if seeds.count == 4 { break }
        }
        guard seeds.count >= 2 else { return systematicResample(particles, rng: &rng) }

        var clusters = Array(repeating: [Int](), count: seeds.count)
        for key in orderedKeys {
            let bin = bins[key]!
            let cluster = seeds.indices.min {
                hypot(Double(seeds[$0].x - key.x), Double(seeds[$0].y - key.y))
                    < hypot(Double(seeds[$1].x - key.x), Double(seeds[$1].y - key.y))
            }!
            clusters[cluster].append(contentsOf: bin.indices)
        }
        let masses = clusters.map { indices in
            indices.reduce(0.0) { $0 + particles[$1].weight }
        }
        let totalMass = max(masses.reduce(0, +), 1e-12)
        let rawCounts = masses.map {
            Double(particles.count) * (0.84 * $0 / totalMass + 0.16 / Double(seeds.count))
        }
        var allocations = rawCounts.map { Int(floor($0)) }
        var remainder = particles.count - allocations.reduce(0, +)
        for index in rawCounts.indices.sorted(by: {
            let lhs = rawCounts[$0] - floor(rawCounts[$0])
            let rhs = rawCounts[$1] - floor(rawCounts[$1])
            return abs(lhs - rhs) > 1e-15 ? lhs > rhs : $0 < $1
        }) where remainder > 0 {
            allocations[index] += 1
            remainder -= 1
        }

        var result: [Particle] = []
        result.reserveCapacity(particles.count)
        for clusterIndex in clusters.indices {
            let indices = clusters[clusterIndex]
            let requested = allocations[clusterIndex]
            guard requested > 0, !indices.isEmpty else { continue }
            let mass = max(masses[clusterIndex], 1e-12)
            let start = rng.uniform() / Double(requested)
            var sourceOffset = 0
            var cumulative = particles[indices[0]].weight / mass
            for outputIndex in 0..<requested {
                let target = start + Double(outputIndex) / Double(requested)
                while target > cumulative && sourceOffset + 1 < indices.count {
                    sourceOffset += 1
                    cumulative += particles[indices[sourceOffset]].weight / mass
                }
                var particle = particles[indices[sourceOffset]]
                particle.weight = 1 / Double(particles.count)
                result.append(particle)
            }
        }
        while result.count < particles.count {
            var particle = particles[ranked.first.flatMap { bins[$0]?.indices.first } ?? 0]
            particle.weight = 1 / Double(particles.count)
            result.append(particle)
        }
        return Array(result.prefix(particles.count))
    }

    private static func systematicResample(
        _ particles: [Particle],
        rng: inout SeededGenerator
    ) -> [Particle] {
        let count = particles.count
        let start = rng.uniform() / Double(count)
        var cumulative = particles[0].weight
        var source = 0
        var result: [Particle] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let target = start + Double(index) / Double(count)
            while target > cumulative && source + 1 < count {
                source += 1
                cumulative += particles[source].weight
            }
            var particle = particles[source]
            particle.weight = 1 / Double(count)
            result.append(particle)
        }
        return result
    }

    private static func injectParticles(
        into particles: inout [Particle],
        around point: XYPoint,
        map: MagneticMap,
        observed: Double,
        rng: inout SeededGenerator,
        ratio: Double
    ) {
        let count = min(Int(Double(particles.count) * ratio), particles.count)
        let meanTravelled = particles.reduce(0.0) { $0 + $1.distanceTravelled * $1.weight }
        let localSamples = Array(map.scatteredSamples.sorted {
            hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
        }.prefix(3))
        for index in 0..<count {
            let base: XYPoint
            if localSamples.isEmpty {
                base = point
            } else {
                let sampleIndex = min(
                    Int(rng.uniform() * Double(localSamples.count)),
                    localSamples.count - 1
                )
                let sample = localSamples[sampleIndex]
                base = XYPoint(x: sample.x, y: sample.y)
            }
            var x = min(max(base.x + rng.normal(standardDeviation: 0.08), map.minX), map.maxX)
            var y = min(max(base.y + rng.normal(standardDeviation: 0.08), map.minY), map.maxY)
            if !map.contains(x: x, y: y) { x = base.x; y = base.y }
            let value = map.sample(x: x, y: y)
            particles[index] = Particle(
                x: x,
                y: y,
                headingBias: rng.normal(standardDeviation: 0.15),
                stepScale: min(max(1 + rng.normal(standardDeviation: 0.12), 0.45), 1.25),
                magneticBias: observed - value,
                magneticBiasX: 0,
                magneticBiasY: 0,
                magneticBiasZ: 0,
                previousMapValue: value,
                mapNormHistory: [value],
                mapVectorHistory: map.sampleVector(x: x, y: y).map { [$0] } ?? [],
                stationaryHypothesis: false,
                distanceTravelled: meanTravelled,
                weight: 1 / Double(particles.count)
            )
        }
        let total = particles.reduce(0) { $0 + $1.weight }
        for index in particles.indices { particles[index].weight /= total }
    }

    private static func injectTurnParticles(
        into particles: inout [Particle],
        junction: XYPoint,
        heading: Double,
        observed: Double,
        map: MagneticMap,
        rng: inout SeededGenerator,
        ratio: Double
    ) {
        let candidates = map.scatteredSamples.filter { sample in
            guard let sampleHeading = sample.headingRadians else { return false }
            return hypot(sample.x - junction.x, sample.y - junction.y) <= 0.85
                && abs(wrap(sampleHeading - heading)) <= 55 * .pi / 180
        }.sorted { lhs, rhs in
            let lhsScore = hypot(lhs.x - junction.x, lhs.y - junction.y)
                + 0.12 * abs(lhs.magneticNormUT - observed)
            let rhsScore = hypot(rhs.x - junction.x, rhs.y - junction.y)
                + 0.12 * abs(rhs.magneticNormUT - observed)
            return lhsScore < rhsScore
        }
        guard !candidates.isEmpty else { return }
        let bases = Array(candidates.prefix(6))
        let count = min(Int(Double(particles.count) * ratio), particles.count)
        let meanBias = particles.reduce(0.0) { $0 + $1.magneticBias * $1.weight }
        let meanTravelled = particles.reduce(0.0) { $0 + $1.distanceTravelled * $1.weight }
        for index in 0..<count {
            let base = bases[min(Int(rng.uniform() * Double(bases.count)), bases.count - 1)]
            var x = base.x + rng.normal(standardDeviation: 0.05)
            var y = base.y + rng.normal(standardDeviation: 0.05)
            if !map.contains(x: x, y: y) { x = base.x; y = base.y }
            let value = map.sample(x: x, y: y)
            particles[index] = Particle(
                x: x,
                y: y,
                headingBias: rng.normal(standardDeviation: 0.08),
                stepScale: min(max(1 + rng.normal(standardDeviation: 0.10), 0.45), 1.25),
                magneticBias: meanBias,
                magneticBiasX: 0,
                magneticBiasY: 0,
                magneticBiasZ: 0,
                previousMapValue: value,
                mapNormHistory: [value],
                mapVectorHistory: map.sampleVector(x: x, y: y).map { [$0] } ?? [],
                stationaryHypothesis: false,
                distanceTravelled: meanTravelled,
                weight: 1 / Double(particles.count)
            )
        }
        let total = particles.reduce(0) { $0 + $1.weight }
        for index in particles.indices { particles[index].weight /= total }
    }

    private static func injectEndpointParticles(
        into particles: inout [Particle],
        endpoint: XYPoint,
        map: MagneticMap,
        rng: inout SeededGenerator,
        ratio: Double
    ) {
        let count = min(Int(Double(particles.count) * ratio), particles.count)
        guard count > 0 else { return }
        let meanBias = particles.reduce(0.0) { $0 + $1.magneticBias * $1.weight }
        let meanBiasX = particles.reduce(0.0) { $0 + $1.magneticBiasX * $1.weight }
        let meanBiasY = particles.reduce(0.0) { $0 + $1.magneticBiasY * $1.weight }
        let meanBiasZ = particles.reduce(0.0) { $0 + $1.magneticBiasZ * $1.weight }
        let meanTravelled = particles.reduce(0.0) { $0 + $1.distanceTravelled * $1.weight }
        for index in 0..<count {
            var x = endpoint.x + rng.normal(standardDeviation: 0.035)
            var y = endpoint.y + rng.normal(standardDeviation: 0.035)
            if !map.contains(x: x, y: y) { x = endpoint.x; y = endpoint.y }
            let value = map.sample(x: x, y: y)
            particles[index] = Particle(
                x: x,
                y: y,
                headingBias: particles[index].headingBias,
                stepScale: particles[index].stepScale,
                magneticBias: meanBias,
                magneticBiasX: meanBiasX,
                magneticBiasY: meanBiasY,
                magneticBiasZ: meanBiasZ,
                previousMapValue: value,
                mapNormHistory: [value],
                mapVectorHistory: map.sampleVector(x: x, y: y).map { [$0] } ?? [],
                stationaryHypothesis: true,
                distanceTravelled: meanTravelled,
                weight: 1 / Double(particles.count)
            )
        }
        let total = particles.reduce(0) { $0 + $1.weight }
        for index in particles.indices { particles[index].weight /= total }
    }

    private static func alignedErrors(track: [XYPoint], route: [XYPoint]) -> [Double] {
        guard track.count > 1 else { return [0] }
        return track.enumerated().map { index, trackPoint in
            let progress = Double(index) / Double(track.count - 1)
            let truth = point(on: route, progress: progress)
            return hypot(trackPoint.x - truth.x, trackPoint.y - truth.y)
        }
    }

    private static func crossTrackErrors(track: [XYPoint], route: [XYPoint]) -> [Double] {
        guard route.count >= 2 else { return track.map { _ in 0 } }
        return track.map { point in
            zip(route, route.dropFirst()).map { start, end in
                let dx = end.x - start.x
                let dy = end.y - start.y
                let squaredLength = dx * dx + dy * dy
                let ratio = squaredLength > 1e-12
                    ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength, 0), 1)
                    : 0
                let projectionX = start.x + ratio * dx
                let projectionY = start.y + ratio * dy
                return hypot(point.x - projectionX, point.y - projectionY)
            }.min() ?? 0
        }
    }

    private static func alongTrackErrors(track: [XYPoint], route: [XYPoint]) -> [Double] {
        guard track.count > 1, route.count >= 2 else { return [] }
        let lengths = zip(route, route.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 1e-9 else { return [] }
        var cumulative = Array(repeating: 0.0, count: route.count)
        for index in lengths.indices { cumulative[index + 1] = cumulative[index] + lengths[index] }
        return track.enumerated().map { index, point in
            let expected = Double(index) / Double(track.count - 1) * total
            var candidates: [(distance: Double, progress: Double)] = []
            for segment in lengths.indices {
                let start = route[segment]
                let end = route[segment + 1]
                let dx = end.x - start.x
                let dy = end.y - start.y
                let squaredLength = dx * dx + dy * dy
                let fraction = squaredLength > 1e-12
                    ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength, 0), 1)
                    : 0
                let projection = XYPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
                candidates.append((
                    hypot(point.x - projection.x, point.y - projection.y),
                    cumulative[segment] + fraction * lengths[segment]
                ))
            }
            let nearestDistance = candidates.map(\.distance).min() ?? 0
            let spatiallyEquivalent = candidates.filter { $0.distance <= nearestDistance + 1e-6 }
            let selected = spatiallyEquivalent.min {
                abs($0.progress - expected) < abs($1.progress - expected)
            }
            return abs((selected?.progress ?? expected) - expected)
        }
    }

    private static func turnAngleErrors(track: [XYPoint], route: [XYPoint]) -> [Double] {
        guard track.count >= 5, route.count >= 3 else { return [] }
        let lengths = zip(route, route.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 1e-9 else { return [] }
        var cumulative = Array(repeating: 0.0, count: route.count)
        for index in lengths.indices { cumulative[index + 1] = cumulative[index] + lengths[index] }
        func angularError(
            before: XYPoint,
            vertex: XYPoint,
            after: XYPoint,
            expectedIncoming: Double,
            expectedOutgoing: Double
        ) -> Double {
            let incoming = atan2(vertex.y - before.y, vertex.x - before.x)
            let outgoing = atan2(after.y - vertex.y, after.x - vertex.x)
            let measuredTurn = abs(wrap(outgoing - incoming))
            let expectedTurn = abs(wrap(expectedOutgoing - expectedIncoming))
            return abs(measuredTurn - expectedTurn) * 180 / .pi
        }
        var errors: [Double] = []
        for vertexIndex in 1..<(route.count - 1) {
            let expectedIndex = Int((cumulative[vertexIndex] / total * Double(track.count - 1)).rounded())
            let searchRadius = max(2, track.count / max(route.count * 2, 1))
            let lower = max(2, expectedIndex - searchRadius)
            let upper = min(track.count - 3, expectedIndex + searchRadius)
            guard lower <= upper else { continue }
            let centerIndex = (lower...upper).min {
                hypot(track[$0].x - route[vertexIndex].x, track[$0].y - route[vertexIndex].y)
                    < hypot(track[$1].x - route[vertexIndex].x, track[$1].y - route[vertexIndex].y)
            }!
            errors.append(angularError(
                before: track[centerIndex - 2],
                vertex: track[centerIndex],
                after: track[centerIndex + 2],
                expectedIncoming: atan2(
                    route[vertexIndex].y - route[vertexIndex - 1].y,
                    route[vertexIndex].x - route[vertexIndex - 1].x
                ),
                expectedOutgoing: atan2(
                    route[vertexIndex + 1].y - route[vertexIndex].y,
                    route[vertexIndex + 1].x - route[vertexIndex].x
                )
            ))
        }
        if let first = route.first, let last = route.last,
           hypot(first.x - last.x, first.y - last.y) <= 0.25 {
            errors.append(angularError(
                before: track[track.count - 3],
                vertex: track.last!,
                after: track[2],
                expectedIncoming: atan2(last.y - route[route.count - 2].y, last.x - route[route.count - 2].x),
                expectedOutgoing: atan2(route[1].y - first.y, route[1].x - first.x)
            ))
        }
        return errors
    }

    private static func pathLength(_ points: [XYPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
        }
    }

    private static func point(on route: [XYPoint], progress: Double) -> XYPoint {
        guard route.count > 1 else { return route.first ?? XYPoint(x: 0, y: 0) }
        let lengths = zip(route, route.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var target = min(max(progress, 0), 1) * total
        for index in lengths.indices {
            if target <= lengths[index] || index == lengths.count - 1 {
                let ratio = lengths[index] > 0 ? target / lengths[index] : 0
                return XYPoint(
                    x: route[index].x + (route[index + 1].x - route[index].x) * ratio,
                    y: route[index].y + (route[index + 1].y - route[index].y) * ratio
                )
            }
            target -= lengths[index]
        }
        return route.last!
    }

    private static func statistics(_ values: [Double]) -> ErrorStatistics? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return ErrorStatistics(
            mean: mean(values),
            median: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            final: values.last ?? 0
        )
    }

    private static func percentile(_ sorted: [Double], _ quantile: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = min(max(quantile, 0), 1) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        percentile(values.sorted(), 0.5)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = mean(values)
        return sqrt(values.reduce(0) { $0 + pow($1 - average, 2) } / Double(values.count))
    }

    private static func headingOfFirstSegment(_ route: [XYPoint]) -> Double {
        guard route.count >= 2 else { return 0 }
        return atan2(route[1].y - route[0].y, route[1].x - route[0].x)
    }

    private static func wrap(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    private static func routeLabel(for datasetKey: String) -> String {
        let normalized = datasetKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = normalized.replacingOccurrences(
            of: #"_\d+$"#,
            with: "",
            options: .regularExpression
        )
        return group.isEmpty ? "custom" : group
    }
}
