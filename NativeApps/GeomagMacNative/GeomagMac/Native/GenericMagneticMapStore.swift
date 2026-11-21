import Foundation

enum LocalizationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case routeCorridorValidation = "route_corridor_validation"
    case roomAreaKnownStart = "room_area_known_start"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .routeCorridorValidation: "已知路线验证"
        case .roomAreaKnownStart: "房间自由定位（已知起点）"
        }
    }

    var summary: String {
        switch self {
        case .routeCorridorValidation:
            "允许使用路线磁图的沿程、拐点和闭合约束，仅用于受控回归验证。"
        case .roomAreaKnownStart:
            "PF 不读取真实路线形状，只使用已知起点、显式初始航向、二维磁图和连续运动。"
        }
    }
}

struct MagneticDirectionalProfile: Codable, Hashable, Sendable {
    let directionBin: Int
    let magneticNormUT: Double
    let magneticXUT: Double?
    let magneticYUT: Double?
    let magneticZUT: Double?
    let observationCount: Int
}

struct GenericMagneticMapSample: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let magneticNormUT: Double
    var magneticXUT: Double? = nil
    var magneticYUT: Double? = nil
    var magneticZUT: Double? = nil
    var varianceUT2: Double? = nil
    /// 来源内方差（不含跨源分歧项）。合并时沿传；旧图没有该键，读侧退回 varianceUT2。
    /// 跨会话分歧判据必须用它当噪声底：varianceUT2 已被历次 disagreement 抬高，
    /// 拿它当底会让下一次分歧被判成正常（自我掩蔽，2026-10-28 二进制复现）。
    var sourceVarianceUT2: Double? = nil
    var observationCount: Int? = nil
    var directionCount: Int? = nil
    var headingRadians: Double? = nil
    var directionalProfiles: [MagneticDirectionalProfile]? = nil
    var gradientXUTPerM: Double? = nil
    var gradientYUTPerM: Double? = nil
}

enum MagneticMapCellStatus: String, Sendable {
    case missing
    case good
    case sparse
    case singleDirection
    case noisy
}

struct MagneticMapQualityCell: Identifiable, Sendable {
    let gridX: Int
    let gridY: Int
    let status: MagneticMapCellStatus
    let observationCount: Int
    let directionCount: Int
    let varianceUT2: Double

    var id: String { "\(gridX):\(gridY)" }
}

struct MagneticMapQualityReport: Sendable {
    enum Grade: String, Sendable {
        case excellent = "优秀"
        case good = "可用"
        case needsMoreData = "需要补采"
        case poor = "质量不足"
    }

    let grade: Grade
    let cells: [MagneticMapQualityCell]
    let minimumGridX: Int
    let maximumGridX: Int
    let minimumGridY: Int
    let maximumGridY: Int
    let coveredCellCount: Int
    let expectedCellCount: Int
    let sparseCellCount: Int
    let singleDirectionCellCount: Int
    let noisyCellCount: Int
    let medianObservationCount: Int
    let messages: [String]

    var coverageRatio: Double {
        guard expectedCellCount > 0 else { return 0 }
        return Double(coveredCellCount) / Double(expectedCellCount)
    }
}

/// 跨会话同格场强分歧（DESIGN ②「同格两来源幅值分歧」）：只记录，不改图、不阻断导入。
/// 单次会话内 B_房间 与 B_异常 不可分，跨次对比是唯一能看见静态畸变/物体被移动的地方。
struct SourceDivergenceSummary: Codable, Hashable, Sendable {
    /// 判定下限：8 µT ≈ 地磁场的 10%。低于它的差异更可能来自 PDR 定位误差与格内梯度，
    /// 而不是异常源；同时与既有「中位差 > 8 µT」警告同刻度。
    static let floorUT: Double = 8
    let comparedCellCount: Int
    let divergentCellCount: Int
    let medianDivergenceUT: Double
    let maximumDivergenceUT: Double
    let thresholdUT: Double
    var hasDivergence: Bool { divergentCellCount > 0 }
}

struct GenericMagneticMapDocument: Codable, Hashable, Identifiable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let id: String
    let name: String
    let createdAt: Date
    let sourceDatasetKeys: [String]
    let referenceRoute: [XYPoint]
    let samples: [GenericMagneticMapSample]
    let supportRadiusM: Double
    var coordinateFrame: String? = nil
    var gridCellSizeM: Double? = nil
    /// True only when adjacent samples are consecutive positions on one
    /// mapping trajectory. Grid maps leave this false.
    var samplesFollowPath: Bool? = nil
    /// Multiplier learned from known map anchors/route distance and the raw
    /// Core Motion step model. It is applied to later captures before PF.
    var pdrStepLengthScale: Double? = nil
    /// 合并时计算并持久化：跨会话同格分歧摘要（仅网格图；路径图为 nil）。
    var sourceDivergence: SourceDivergenceSummary? = nil

    var sourceLabel: String { sourceDatasetKeys.joined(separator: ", ") }

    var localizationMode: LocalizationMode {
        samplesFollowPath == true ? .routeCorridorValidation : .roomAreaKnownStart
    }

    var vectorSampleRatio: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.count { $0.magneticXUT != nil && $0.magneticYUT != nil && $0.magneticZUT != nil })
            / Double(samples.count)
    }

    var gridCoverageRatio: Double? {
        guard gridCellSizeM != nil else { return nil }
        return qualityReport?.coverageRatio
    }

    var qualityReport: MagneticMapQualityReport? {
        guard samplesFollowPath != true,
              let cell = gridCellSizeM,
              cell.isFinite,
              cell > 0,
              !samples.isEmpty else { return nil }

        struct Key: Hashable { let x: Int; let y: Int }
        var keyed: [Key: GenericMagneticMapSample] = [:]
        for sample in samples {
            let key = Key(x: Int(floor(sample.x / cell)), y: Int(floor(sample.y / cell)))
            if let existing = keyed[key],
               (existing.observationCount ?? 0) >= (sample.observationCount ?? 0) { continue }
            keyed[key] = sample
        }
        let referenceKeys = referenceRoute.map {
            Key(x: Int(floor($0.x / cell)), y: Int(floor($0.y / cell)))
        }
        let boundsKeys = Array(keyed.keys) + referenceKeys
        guard let minimumGridX = boundsKeys.map(\.x).min(),
              let maximumGridX = boundsKeys.map(\.x).max(),
              let minimumGridY = boundsKeys.map(\.y).min(),
              let maximumGridY = boundsKeys.map(\.y).max() else { return nil }
        let columns = maximumGridX - minimumGridX + 1
        let rows = maximumGridY - minimumGridY + 1
        let expected = columns * rows
        guard expected > 0, expected <= 20_000 else { return nil }

        var cells: [MagneticMapQualityCell] = []
        var sparse = 0
        var singleDirection = 0
        var noisy = 0
        for y in minimumGridY...maximumGridY {
            for x in minimumGridX...maximumGridX {
                guard let sample = keyed[Key(x: x, y: y)] else {
                    cells.append(MagneticMapQualityCell(
                        gridX: x, gridY: y, status: .missing,
                        observationCount: 0, directionCount: 0, varianceUT2: 0
                    ))
                    continue
                }
                let observations = sample.observationCount ?? 0
                let directions = sample.directionCount ?? 0
                let variance = sample.varianceUT2 ?? 0
                let status: MagneticMapCellStatus
                if variance > 25 {
                    status = .noisy
                    noisy += 1
                } else if observations < 12 {
                    status = .sparse
                    sparse += 1
                } else if directions < 2 {
                    status = .singleDirection
                    singleDirection += 1
                } else {
                    status = .good
                }
                cells.append(MagneticMapQualityCell(
                    gridX: x, gridY: y, status: status,
                    observationCount: observations,
                    directionCount: directions,
                    varianceUT2: variance
                ))
            }
        }

        let covered = keyed.count
        let coverage = Double(covered) / Double(expected)
        let observationCounts = samples.compactMap(\.observationCount).sorted()
        let medianObservations = observationCounts.isEmpty
            ? 0 : observationCounts[observationCounts.count / 2]
        let weakRatio = Double(sparse + noisy) / Double(max(covered, 1))
        var grade: MagneticMapQualityReport.Grade
        if coverage >= 0.80, weakRatio <= 0.10, medianObservations >= 20 {
            grade = .excellent
        } else if coverage >= 0.60, weakRatio <= 0.25, medianObservations >= 12 {
            grade = .good
        } else if coverage >= 0.35, weakRatio <= 0.45 {
            grade = .needsMoreData
        } else {
            grade = .poor
        }
        // 已记录的跨会话分歧是「有证据表明不可信」：覆盖与噪声再好也不再给「优秀」，
        // 否则徽章与复核提示互相矛盾。只封顶到「可用」——单格分歧可能只是物体临时移动，
        // 图通常仍可用于定位，缺的是人复核而不是补采。
        if grade == .excellent, sourceDivergence?.hasDivergence == true {
            grade = .good
        }
        var messages: [String] = []
        if coverage < 0.60 {
            messages.append("有效网格覆盖不足 60%，请补扫空白区域；固定障碍物内部可保持空白。")
        }
        if sparse > max(2, covered / 5) {
            messages.append("低样本网格较多，请在对应区域放慢速度或增加一次采集。")
        }
        if noisy > max(1, covered / 10) {
            messages.append("部分网格磁场方差较高，请检查移动金属、电器或手机姿态变化。")
        }
        if singleDirection > covered / 2 {
            messages.append("多数网格只有单一行走方向，建议增加与当前方向垂直的扫描。")
        }
        // 局部异常不会被中位差看见：一角落的金属被移动时，多数网格仍一致。
        if let divergence = sourceDivergence, divergence.hasDivergence {
            messages.append(String(
                format: "跨会话同格场强分歧：%d/%d 格超过正常散布（最大 %.1f µT）。"
                    + "同一点位两次采集读数明显不同，常见原因是金属物体被移动或异常源仍在，"
                    + "建议复核该区域后重新建图。",
                divergence.divergentCellCount,
                divergence.comparedCellCount,
                divergence.maximumDivergenceUT
            ))
        }
        if messages.isEmpty {
            messages.append("覆盖、样本量和磁场稳定性均达到当前建图要求。")
        }
        return MagneticMapQualityReport(
            grade: grade,
            cells: cells,
            minimumGridX: minimumGridX,
            maximumGridX: maximumGridX,
            minimumGridY: minimumGridY,
            maximumGridY: maximumGridY,
            coveredCellCount: covered,
            expectedCellCount: expected,
            sparseCellCount: sparse,
            singleDirectionCellCount: singleDirection,
            noisyCellCount: noisy,
            medianObservationCount: medianObservations,
            messages: messages
        )
    }

    var bounds: CoordinateBounds? {
        guard let first = samples.first else { return nil }
        let minX = samples.dropFirst().reduce(first.x) { min($0, $1.x) } - supportRadiusM
        let maxX = samples.dropFirst().reduce(first.x) { max($0, $1.x) } + supportRadiusM
        let minY = samples.dropFirst().reduce(first.y) { min($0, $1.y) } - supportRadiusM
        let maxY = samples.dropFirst().reduce(first.y) { max($0, $1.y) } + supportRadiusM
        return CoordinateBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    func validated() throws -> GenericMagneticMapDocument {
        guard schemaVersion == Self.schemaVersion,
              !id.isEmpty,
              !name.isEmpty,
              !sourceDatasetKeys.isEmpty,
              referenceRoute.count >= 2,
              samples.count >= 8,
              supportRadiusM.isFinite,
              supportRadiusM > 0,
              gridCellSizeM.map({ $0.isFinite && $0 > 0 }) ?? true,
              pdrStepLengthScale.map({ $0.isFinite && 0.2...2.0 ~= $0 }) ?? true,
              samples.allSatisfy({
                  $0.x.isFinite && $0.y.isFinite
                      && $0.magneticNormUT.isFinite
                      && 10 <= $0.magneticNormUT
                      && $0.magneticNormUT <= 100
                      && [$0.magneticXUT, $0.magneticYUT, $0.magneticZUT]
                          .compactMap { $0 }.allSatisfy(\.isFinite)
                      && ($0.varianceUT2.map { $0.isFinite && $0 >= 0 } ?? true)
                      && ($0.headingRadians?.isFinite ?? true)
                      && [$0.gradientXUTPerM, $0.gradientYUTPerM]
                          .compactMap { $0 }.allSatisfy(\.isFinite)
              }) else {
            throw GenericMagneticMapStore.StoreError.malformedMap(name)
        }
        return self
    }
}

enum GenericMagneticMapStore {
    enum StoreError: LocalizedError {
        case malformedMap(String)
        case invalidName
        case duplicateMap(String)
        case builtInMapCannotBeRemoved
        case incompatibleMaps
        case duplicateSourceDataset(String)

        var errorDescription: String? {
            switch self {
            case let .malformedMap(name): "磁图 \(name) 的格式或样本不完整。"
            case .invalidName: "请填写有效的磁图名称。"
            case let .duplicateMap(name): "已经存在名为 \(name) 的磁图，请先删除或改名。"
            case .builtInMapCannotBeRemoved: "内置示例磁图不能删除。"
            case .incompatibleMaps: "两次采集的磁图名称、坐标系或网格尺寸不一致，不能合并。"
            case let .duplicateSourceDataset(key): "采集 \(key) 已经加入该磁图，不能重复合并。"
            }
        }
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let document: GenericMagneticMapDocument
        let isBuiltIn: Bool

        var id: String { document.id }
    }

    static func loadAll() throws -> [Entry] {
        var entries = try loadBuiltIn().map { Entry(document: $0, isBuiltIn: true) }
        let builtInIDs = Set(entries.map(\.id))
        entries.append(contentsOf: try loadUser().filter { !builtInIDs.contains($0.id) }.map {
            Entry(document: $0, isBuiltIn: false)
        })
        return entries.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.document.name.localizedStandardCompare($1.document.name) == .orderedAscending
        }
    }

    static func save(_ document: GenericMagneticMapDocument, replacing: Bool = false) throws -> URL {
        let checked = try document.validated()
        let directory = try directoryURL(createIfNeeded: true)
        let url = directory.appendingPathComponent(checked.id).appendingPathExtension("json")
        if !replacing, FileManager.default.fileExists(atPath: url.path) {
            throw StoreError.duplicateMap(checked.name)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checked).write(to: url, options: .atomic)
        return url
    }

    static func remove(_ entry: Entry) throws {
        guard !entry.isBuiltIn else { throw StoreError.builtInMapCannotBeRemoved }
        let url = try directoryURL(createIfNeeded: true)
            .appendingPathComponent(entry.id)
            .appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func merging(
        _ existing: GenericMagneticMapDocument,
        with addition: GenericMagneticMapDocument
    ) throws -> GenericMagneticMapDocument {
        let lhs = try existing.validated()
        let rhs = try addition.validated()
        guard lhs.id == rhs.id,
              lhs.coordinateFrame == rhs.coordinateFrame,
              lhs.localizationMode == rhs.localizationMode,
              abs((lhs.gridCellSizeM ?? 0.4) - (rhs.gridCellSizeM ?? 0.4)) < 1e-6 else {
            throw StoreError.incompatibleMaps
        }
        if let duplicate = Set(lhs.sourceDatasetKeys).intersection(rhs.sourceDatasetKeys).first {
            throw StoreError.duplicateSourceDataset(duplicate)
        }
        let divergence = sourceDivergence(lhs, rhs)
        let cell = lhs.gridCellSizeM ?? rhs.gridCellSizeM ?? 0.4
        struct Key: Hashable { let x: Int; let y: Int }
        struct WeightedSample {
            let sample: GenericMagneticMapSample
            let sourceWeight: Double
        }
        var grouped: [Key: [WeightedSample]] = [:]
        func append(_ document: GenericMagneticMapDocument) {
            let sourceWeight = Double(max(document.sourceDatasetKeys.count, 1))
            for sample in document.samples {
                let key = Key(x: Int(floor(sample.x / cell)), y: Int(floor(sample.y / cell)))
                grouped[key, default: []].append(WeightedSample(
                    sample: sample,
                    sourceWeight: sourceWeight
                ))
            }
        }
        append(lhs)
        append(rhs)

        func weightedMean(_ values: [(value: Double, weight: Double)]) -> Double {
            let totalWeight = values.map(\.weight).reduce(0, +)
            guard totalWeight > 0 else { return values.first?.value ?? 0 }
            return values.map { $0.value * $0.weight }.reduce(0, +) / totalWeight
        }
        func optionalWeightedMean(
            _ values: [WeightedSample],
            _ value: (GenericMagneticMapSample) -> Double?
        ) -> Double? {
            let available = values.compactMap { item -> (value: Double, weight: Double)? in
                value(item.sample).map { ($0, item.sourceWeight) }
            }
            return available.isEmpty ? nil : weightedMean(available)
        }

        var mergedByKey: [Key: GenericMagneticMapSample] = [:]
        for (key, values) in grouped {
            let x = weightedMean(values.map { ($0.sample.x, $0.sourceWeight) })
            let y = weightedMean(values.map { ($0.sample.y, $0.sourceWeight) })
            let norm = weightedMean(values.map { ($0.sample.magneticNormUT, $0.sourceWeight) })
            let bx = optionalWeightedMean(values, { $0.magneticXUT })
            let by = optionalWeightedMean(values, { $0.magneticYUT })
            let bz = optionalWeightedMean(values, { $0.magneticZUT })
            let varianceValues = values.compactMap { item -> (value: Double, weight: Double)? in
                guard let sourceVariance = item.sample.varianceUT2 else { return nil }
                let disagreement = item.sample.magneticNormUT - norm
                return (sourceVariance + disagreement * disagreement, item.sourceWeight)
            }
            let variance = varianceValues.isEmpty ? nil : weightedMean(varianceValues)
            // 来源内方差：只平均各来源自己登记的格内方差，不掺 disagreement。
            let sourceVarianceValues = values.compactMap { item -> (value: Double, weight: Double)? in
                guard let sourceVariance = item.sample.sourceVarianceUT2 ?? item.sample.varianceUT2 else {
                    return nil
                }
                return (sourceVariance, item.sourceWeight)
            }
            let sourceVariance = sourceVarianceValues.isEmpty ? nil : weightedMean(sourceVarianceValues)
            let observations = values.compactMap(\.sample.observationCount).reduce(0, +)
            // Repeating the same heading in another capture adds evidence, not a new direction.
            let directions = values.compactMap(\.sample.directionCount).max()
            let headings = values.compactMap { item -> (heading: Double, weight: Double)? in
                item.sample.headingRadians.map { ($0, item.sourceWeight) }
            }
            let heading = headings.isEmpty ? nil : atan2(
                headings.map { sin($0.heading) * $0.weight }.reduce(0, +),
                headings.map { cos($0.heading) * $0.weight }.reduce(0, +)
            )
            let profileGroups = Dictionary(grouping: values.flatMap { item in
                (item.sample.directionalProfiles ?? []).map { profile in
                    (profile: profile, weight: item.sourceWeight)
                }
            }, by: { $0.profile.directionBin })
            let directionalProfiles = profileGroups.map { directionBin, profiles in
                func profileMean(_ value: (MagneticDirectionalProfile) -> Double?) -> Double? {
                    let available = profiles.compactMap { item in
                        value(item.profile).map { ($0, item.weight) }
                    }
                    return available.isEmpty ? nil : weightedMean(available)
                }
                return MagneticDirectionalProfile(
                    directionBin: directionBin,
                    magneticNormUT: weightedMean(profiles.map {
                        ($0.profile.magneticNormUT, $0.weight)
                    }),
                    magneticXUT: profileMean(\.magneticXUT),
                    magneticYUT: profileMean(\.magneticYUT),
                    magneticZUT: profileMean(\.magneticZUT),
                    observationCount: profiles.map(\.profile.observationCount).reduce(0, +)
                )
            }.sorted { $0.directionBin < $1.directionBin }
            var sample = GenericMagneticMapSample(x: x, y: y, magneticNormUT: norm)
            sample.magneticXUT = bx
            sample.magneticYUT = by
            sample.magneticZUT = bz
            sample.varianceUT2 = variance
            sample.sourceVarianceUT2 = sourceVariance
            sample.observationCount = observations
            sample.directionCount = directions
            sample.headingRadians = heading
            sample.directionalProfiles = directionalProfiles.isEmpty ? nil : directionalProfiles
            mergedByKey[key] = sample
        }
        // Gradients must be derived from the balanced merged field. Blending old
        // gradients recursively gives the most recently added capture too much weight.
        for (key, sample) in mergedByKey {
            var updated = sample
            if let left = mergedByKey[Key(x: key.x - 1, y: key.y)],
               let right = mergedByKey[Key(x: key.x + 1, y: key.y)] {
                updated.gradientXUTPerM = (right.magneticNormUT - left.magneticNormUT) / (2 * cell)
            }
            if let down = mergedByKey[Key(x: key.x, y: key.y - 1)],
               let up = mergedByKey[Key(x: key.x, y: key.y + 1)] {
                updated.gradientYUTPerM = (up.magneticNormUT - down.magneticNormUT) / (2 * cell)
            }
            mergedByKey[key] = updated
        }
        var mergedSamples = Array(mergedByKey.values)
        mergedSamples.sort { lhs, rhs in
            lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
        }
        let mergedStepScale: Double? = switch (lhs.pdrStepLengthScale, rhs.pdrStepLengthScale) {
        case (nil, nil): nil
        case let (value?, nil), let (nil, value?): value
        case let (left?, right?):
            if lhs.localizationMode == .roomAreaKnownStart,
               lhs.sourceDatasetKeys.count >= 2,
               (right <= 0.22 || right / left < 0.70 || right / left > 1.43) {
                // A dense stop-turn supplement often reaches the calibration clamp.
                // Do not let one such capture replace an established walk scale.
                left
            } else {
                weightedMean([
                    (left, Double(max(lhs.sourceDatasetKeys.count, 1))),
                    (right, Double(max(rhs.sourceDatasetKeys.count, 1))),
                ])
            }
        }
        return try GenericMagneticMapDocument(
            schemaVersion: GenericMagneticMapDocument.schemaVersion,
            id: lhs.id,
            name: lhs.name,
            createdAt: Date(),
            sourceDatasetKeys: Array(Set(lhs.sourceDatasetKeys + rhs.sourceDatasetKeys)).sorted(),
            referenceRoute: lhs.referenceRoute + rhs.referenceRoute,
            samples: mergedSamples,
            supportRadiusM: max(lhs.supportRadiusM, rhs.supportRadiusM),
            coordinateFrame: lhs.coordinateFrame,
            gridCellSizeM: cell,
            samplesFollowPath: lhs.samplesFollowPath == true,
            pdrStepLengthScale: mergedStepScale,
            sourceDivergence: divergence
        ).validated()
    }

    /// 跨会话同格分歧：逐格比较两次采集的场强，判定阈值取「3σ 与 8 µT 的较大者」。
    /// σ 来自两张图各自登记的**来源内**方差（sourceVarianceUT2）——「超出正常散布」而不是
    /// 固定绝对差，否则高噪声格会被误报、低噪声格的系统性偏移又会被放过。
    /// 不能用合并后的 varianceUT2：它已含历次分歧，会让后续分歧自我掩蔽。
    static func sourceDivergence(
        _ lhs: GenericMagneticMapDocument,
        _ rhs: GenericMagneticMapDocument
    ) -> SourceDivergenceSummary? {
        guard lhs.samplesFollowPath != true, rhs.samplesFollowPath != true else { return nil }
        let cell = lhs.gridCellSizeM ?? rhs.gridCellSizeM ?? 0.4
        guard cell.isFinite, cell > 0 else { return nil }
        struct Key: Hashable { let x: Int; let y: Int }
        func keyed(_ document: GenericMagneticMapDocument) -> [Key: GenericMagneticMapSample] {
            var result: [Key: GenericMagneticMapSample] = [:]
            for sample in document.samples {
                result[Key(x: Int(floor(sample.x / cell)), y: Int(floor(sample.y / cell)))] = sample
            }
            return result
        }
        let left = keyed(lhs)
        let right = keyed(rhs)
        var offsets: [Double] = []
        var maximum = 0.0
        var divergent = 0
        for (key, sample) in left {
            guard let other = right[key] else { continue }
            let offset = abs(sample.magneticNormUT - other.magneticNormUT)
            // 噪声底取**来源内**方差：合并后的 varianceUT2 已把历次分歧折进去，
            // 用它会让 A(50)+B(80) 之后的 C(95) 被判成正常（30 µT < 3√227≈45）。
            let variance = max(sample.sourceVarianceUT2 ?? sample.varianceUT2 ?? 0, 0)
                + max(other.sourceVarianceUT2 ?? other.varianceUT2 ?? 0, 0)
            let limit = max(SourceDivergenceSummary.floorUT, 3 * variance.squareRoot())
            offsets.append(offset)
            maximum = max(maximum, offset)
            if offset > limit { divergent += 1 }
        }
        guard !offsets.isEmpty else { return nil }
        let sorted = offsets.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return SourceDivergenceSummary(
            comparedCellCount: offsets.count,
            divergentCellCount: divergent,
            medianDivergenceUT: median,
            maximumDivergenceUT: maximum,
            thresholdUT: SourceDivergenceSummary.floorUT
        )
    }

    static func mergeQualityWarnings(
        _ existing: GenericMagneticMapDocument,
        with addition: GenericMagneticMapDocument
    ) -> [String] {
        let cell = existing.gridCellSizeM ?? addition.gridCellSizeM ?? 0.4
        struct Key: Hashable { let x: Int; let y: Int }
        func keyed(_ document: GenericMagneticMapDocument) -> [Key: GenericMagneticMapSample] {
            var result: [Key: GenericMagneticMapSample] = [:]
            for sample in document.samples {
                let key = Key(x: Int(floor(sample.x / cell)), y: Int(floor(sample.y / cell)))
                if let existing = result[key],
                   (existing.observationCount ?? 0) >= (sample.observationCount ?? 0) { continue }
                result[key] = sample
            }
            return result
        }
        let lhs = keyed(existing)
        let rhs = keyed(addition)
        let overlap = Set(lhs.keys).intersection(rhs.keys)
        var warnings: [String] = []
        let minimumUsefulOverlap = max(5, min(lhs.count, rhs.count) / 10)
        if overlap.count < minimumUsefulOverlap {
            warnings.append("两次建图只有 \(overlap.count) 个重叠网格，请确认坐标原点和扫描区域一致。")
        }
        let normDifferences = overlap.compactMap { key -> Double? in
            guard let left = lhs[key], let right = rhs[key] else { return nil }
            return abs(left.magneticNormUT - right.magneticNormUT)
        }.sorted()
        if let medianDifference = normDifferences.isEmpty
            ? nil : normDifferences[normDifferences.count / 2],
           medianDifference > 8 {
            warnings.append(String(
                format: "重叠网格磁场模长中位差 %.1f µT，可能存在姿态、设备或环境变化。",
                medianDifference
            ))
        }
        // 中位差看不见局部异常：补一条逐格计数（判据 = 3σ 与 8 µT 取大者）。
        if let divergence = sourceDivergence(existing, addition), divergence.hasDivergence {
            warnings.append(String(
                format: "有 %d/%d 个重叠网格的场强差异超过正常散布（最大 %.1f µT）："
                    + "同一点位两次读数明显不同，建议复核是否有金属物体被移动。",
                divergence.divergentCellCount,
                divergence.comparedCellCount,
                divergence.maximumDivergenceUT
            ))
        }
        return warnings
    }

    static func directoryURL(createIfNeeded: Bool) throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupport
            .appendingPathComponent("GeomagMacNative", isDirectory: true)
            .appendingPathComponent("MagneticMaps", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    static func identifier(from name: String) throws -> String {
        let normalized = name.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(String(scalar)) }
            return "_"
        }
        let value = String(normalized)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        guard !value.isEmpty else { throw StoreError.invalidName }
        return value
    }

    private static func loadUser() throws -> [GenericMagneticMapDocument] {
        let directory = try directoryURL(createIfNeeded: true)
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .compactMap { try? decode($0) }
    }

    private static func loadBuiltIn() throws -> [GenericMagneticMapDocument] {
        guard let root = Bundle.main.resourceURL else { return [] }
        let candidates = [
            root.appendingPathComponent("MagneticMaps", isDirectory: true),
            root,
        ]
        var urls: [URL] = []
        for directory in candidates where FileManager.default.fileExists(atPath: directory.path) {
            let found = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix("magnetic_map_") && $0.pathExtension == "json" }
            urls.append(contentsOf: found)
        }
        return try Array(Set(urls)).map(decode)
    }

    private static func decode(_ url: URL) throws -> GenericMagneticMapDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            GenericMagneticMapDocument.self,
            from: Data(contentsOf: url)
        ).validated()
    }
}
