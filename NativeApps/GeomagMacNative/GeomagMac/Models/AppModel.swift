import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    struct Sample: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static let samples = [
        Sample(id: "native_route_13_2", title: "Route 13 · 第 2 次（留出）"),
        Sample(id: "native_route_13_3", title: "Route 13 · 第 3 次（留出）"),
        Sample(id: "native_route_15_2", title: "Route 15 · 第 2 次（留出）"),
        Sample(id: "native_route_15_3", title: "Route 15 · 第 3 次（留出）"),
    ]

    static let runnableDatasets = [
        Sample(id: "route_13_2", title: "Route 13 · 第 2 次（留出）"),
        Sample(id: "route_13_3", title: "Route 13 · 第 3 次（留出）"),
        Sample(id: "route_15_2", title: "Route 15 · 第 2 次（留出）"),
        Sample(id: "route_15_3", title: "Route 15 · 第 3 次（留出）"),
    ]

    @Published var result: PositioningResult?
    @Published var selectedSampleID = samples[0].id
    @Published var loadedFileName = ""
    @Published var errorMessage: String?
    @Published var playbackProgress = 1.0
    @Published var showTrueRoute = true
    @Published var showPDR = true
    @Published var showPF = true
    @Published var showPFConfidence = true
    @Published var runInputMode: RunInputMode = .bundled
    @Published var selectedRunDatasetID = runnableDatasets[0].id
    @Published var importedDataset: ImportedDataset?
    @Published var customDatasetName = ""
    @Published var customRouteText = ""
    @Published var customInitialHeadingText = ""
    @Published var isBackendRunning = false
    @Published var backendProgress = 0.0
    @Published var backendLog = ""
    @Published var backendStatus = "准备就绪"
    @Published var lastOutputPath = ""
    @Published var exportMessage: String?
    @Published private(set) var recentRuns: [RunRecord] = []
    @Published private(set) var selectedAlgorithmPreset: AlgorithmPreset
    @Published private(set) var algorithmSettings: AlgorithmSettings
    @Published var selectedMagneticMapID = ""
    @Published var newMagneticMapName = ""
    @Published private(set) var magneticMaps: [GenericMagneticMapStore.Entry] = []
    @Published private(set) var isMagneticMapBuilding = false
    @Published private(set) var magneticMapStatus = "尚未加载坐标化地磁图"

    private var nativeTask: Task<Void, Never>?
    private var nativeEngineTask: Task<PositioningResult, Error>?

    private struct RunRequest {
        let datasetKey: String
        let datasetDirectory: URL
        let route: [XYPoint]
        let initialHeadingDegrees: Double?
        let activeStartTime: Double?
        let activeEndTime: Double?
        let magneticMap: GenericMagneticMapDocument
        let localizationMode: LocalizationMode
        let logDescription: String
    }

    private enum RunPreparationError: LocalizedError {
        case noImportedDataset
        case emptyDatasetName
        case invalidRoute
        case invalidInitialHeading
        case magneticMapRequired
        case mapSourceCannotLocateItself
        case coordinateFrameMismatch
        case routeOutsideMap(String)

        var errorDescription: String? {
            switch self {
            case .noImportedDataset:
                "请先选择并验证采集数据文件夹。"
            case .emptyDatasetName:
                "请填写数据集名称。"
            case .invalidRoute:
                "真实路线格式不正确。请至少输入两个坐标点，例如：1.44,0.55; 1.44,8.25。"
            case .invalidInitialHeading:
                "初始航向必须是有效数字；留空时会根据真实路线前两个点自动计算。"
            case .magneticMapRequired:
                "请先选择一张覆盖当前区域的地磁图；如果这是第一次采集，请先用它建立磁图。"
            case .mapSourceCannotLocateItself:
                "当前采集是所选磁图的建图数据，不能用它自我验证。请导入同一区域的第二次或后续独立采集。"
            case .coordinateFrameMismatch:
                "采集包与所选磁图的统一房间坐标系不一致。请检查 coordinate_frame。"
            case let .routeOutsideMap(description):
                description
            }
        }
    }

    var backendModeTitle: String {
        "纯原生 Swift 引擎"
    }

    var importedDatasetReady: Bool {
        guard importedDataset != nil,
              !customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              DatasetValidator.normalizedRouteText(customRouteText) != nil,
              DatasetValidator.routeGeometryIssue(customRouteText) == nil else {
            return false
        }
        if !customInitialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Double(customInitialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return false
        }
        return true
    }

    var canBuildMapFromImportedDataset: Bool {
        guard let importedDataset,
              !customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !newMagneticMapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return importedDataset.spatialAnchors.count >= 2
            || DatasetValidator.normalizedRouteText(customRouteText) != nil
    }

    var routeMapValidation: RouteMapValidation {
        DatasetValidator.validateRoute(customRouteText, against: selectedMapBounds)
    }

    var routeGeometryIssue: String? {
        DatasetValidator.routeGeometryIssue(customRouteText)
    }

    var selectedMapBounds: CoordinateBounds? {
        selectedMagneticMap?.document.bounds
    }

    var selectedMagneticMap: GenericMagneticMapStore.Entry? {
        magneticMaps.first { $0.id == selectedMagneticMapID }
    }

    var selectedMagneticMapQuality: MagneticMapQualityReport? {
        selectedMagneticMap?.document.qualityReport
    }

    var mapForCurrentSelection: GenericMagneticMapStore.Entry? {
        if runInputMode == .imported { return selectedMagneticMap }
        let group = Self.datasetGroup(selectedRunDatasetID)
        return magneticMaps.first { $0.document.id == group }
    }

    var currentLocalizationMode: LocalizationMode? {
        mapForCurrentSelection?.document.localizationMode
    }

    var roomModeHasExplicitInitialHeading: Bool {
        guard currentLocalizationMode == .roomAreaKnownStart else { return true }
        let text = customInitialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(text)?.isFinite == true
    }

    var selectedMapUsesCurrentDataset: Bool {
        guard let map = selectedMagneticMap, let importedDataset else { return false }
        return map.document.sourceDatasetKeys.contains(importedDataset.sourceDatasetKey)
    }

    var coordinateFrameMatchesSelectedMap: Bool {
        guard runInputMode == .imported, let mapFrame = selectedMagneticMap?.document.coordinateFrame else {
            return true
        }
        guard let datasetFrame = importedDataset?.coordinateFrame else {
            // Older route captures do not contain coordinate_frame. Their manually
            // entered route is already validated against the selected path map.
            return selectedMagneticMap?.document.samplesFollowPath == true
        }
        return datasetFrame == mapFrame
    }

    var canRunSelectedDataset: Bool {
        guard !isBackendRunning else { return false }
        guard mapForCurrentSelection != nil else { return false }
        if runInputMode == .imported {
            return importedDatasetReady
                && routeMapValidation.isValid
                && coordinateFrameMatchesSelectedMap
                && roomModeHasExplicitInitialHeading
                && !selectedMapUsesCurrentDataset
        }
        return true
    }

    var runButtonHelp: String {
        if isBackendRunning {
            return "定位计算正在运行"
        }
        if mapForCurrentSelection == nil {
            return "请先选择地磁图；第一次采集应先用于建图"
        }
        if runInputMode == .imported, selectedMapUsesCurrentDataset {
            return "建图数据不能自我验证，请导入另一组独立采集"
        }
        if runInputMode == .imported, !coordinateFrameMatchesSelectedMap {
            return "采集坐标系与所选房间磁图不一致"
        }
        if runInputMode == .imported, !roomModeHasExplicitInitialHeading {
            return "房间自由定位必须填写已知初始航向；真实路线只用于结果评估"
        }
        if runInputMode == .imported, !routeMapValidation.isValid {
            return "真实路线超出所选地磁图的覆盖范围；可以改选磁图或用当前采集建立新磁图"
        }
        if runInputMode == .imported, routeGeometryIssue != nil {
            return "真实路线存在重复点或原路折返，请先检查坐标顺序"
        }
        if runInputMode == .imported, !importedDatasetReady {
            return "请先选择有效的采集数据，并填写数据集名称和真实路线"
        }
        return "使用当前数据和下次运行参数开始定位计算"
    }

    var importedDatasetStatus: String {
        guard let importedDataset else { return "尚未选择采集文件夹" }
        if DatasetValidator.normalizedRouteText(customRouteText) == nil {
            return "传感器数据有效；还需要填写至少两个真实路线坐标点"
        }
        return "校验通过 · 约 \(importedDataset.estimatedFrameCount) 帧 · "
            + String(format: "重叠 %.1f 秒", importedDataset.overlapDuration)
    }

    var backendStatusDisplay: String {
        if backendStatus == "传感器校验通过，请填写真实路线", importedDatasetReady {
            return "采集数据校验通过，可以开始计算"
        }
        return backendStatus
    }

    init() {
        let restored = Self.restoreAlgorithmConfiguration()
        selectedAlgorithmPreset = restored.preset
        algorithmSettings = restored.settings
        loadBundledSample(id: selectedSampleID)
        refreshRunHistory()
        refreshMagneticMaps()
    }

    func loadBundledSample(id: String) {
        selectedSampleID = id
        guard let url = Bundle.main.url(
            forResource: id,
            withExtension: "json",
            subdirectory: "Samples"
        ) ?? Bundle.main.url(forResource: id, withExtension: "json") else {
            errorMessage = "找不到内置示例：\(id).json"
            return
        }
        load(url: url)
    }

    func selectMagneticMapForBundledDataset() {
        guard runInputMode == .bundled else { return }
        let group = Self.datasetGroup(selectedRunDatasetID)
        if magneticMaps.contains(where: { $0.id == group }) {
            selectedMagneticMapID = group
            magneticMapStatus = "内置留出数据自动使用 \(group) 的独立参考磁图"
        }
    }

    func openResultFile() {
        let panel = NSOpenPanel()
        panel.title = "打开地磁定位结果"
        panel.prompt = "打开"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func chooseImportedDatasetDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择手机传感器采集文件夹"
        panel.prompt = "选择并校验"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if let savedPath = UserDefaults.standard.string(forKey: "lastImportedDatasetDirectory"),
           FileManager.default.fileExists(atPath: savedPath) {
            panel.directoryURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDataset(at: url)
    }

    func revalidateImportedDataset() {
        guard let importedDataset else {
            errorMessage = RunPreparationError.noImportedDataset.localizedDescription
            return
        }
        importDataset(at: importedDataset.directoryURL, preserveConfiguration: true)
    }

    func applyAlgorithmPreset(_ preset: AlgorithmPreset) {
        selectedAlgorithmPreset = preset
        if let settings = preset.settings {
            algorithmSettings = settings
        }
        persistAlgorithmConfiguration()
    }

    func updateAlgorithmSetting<Value>(
        _ keyPath: WritableKeyPath<AlgorithmSettings, Value>,
        to value: Value
    ) {
        algorithmSettings[keyPath: keyPath] = value
        selectedAlgorithmPreset = .custom
        persistAlgorithmConfiguration()
    }

    func resetAlgorithmSettings() {
        applyAlgorithmPreset(.optimized)
    }

    func runSelectedDataset() {
        guard !isBackendRunning else { return }

        do {
            let request = try currentRunRequest()
            let runDirectory = try createRunDirectory()
            let stamp = Self.fileTimestamp()
            let proposedBaseName = "\(Self.safeFileComponent(request.datasetKey))-\(stamp)"
            let baseName = Self.availableBaseName(
                proposedBaseName,
                in: runDirectory,
                reservedSuffixes: [".json"]
            )
            let jsonURL = runDirectory.appendingPathComponent(baseName).appendingPathExtension("json")
            let engineRequest = NativePositioningEngine.Request(
                datasetKey: request.datasetKey,
                datasetDirectory: request.datasetDirectory,
                route: request.route,
                initialHeadingDegrees: request.initialHeadingDegrees,
                activeStartTime: request.activeStartTime,
                activeEndTime: request.activeEndTime,
                settings: algorithmSettings,
                magneticMap: request.magneticMap,
                localizationMode: request.localizationMode
            )

            backendLog = "引擎: 纯原生 Swift\n"
                + "算法: PDR + 标量地磁粒子滤波（运行时无 Python）\n"
                + "定位模式: \(request.localizationMode.title)\n"
                + "数据: \(request.datasetKey)\n"
                + request.logDescription
                + "预设: \(selectedAlgorithmPreset.title)\n"
                + "参数: \(algorithmSettings.logSummary)\n\n"
            backendProgress = 0
            backendStatus = "正在进行原生计算 \(request.datasetKey)…"
            isBackendRunning = true
            let engineTask = Task.detached(priority: .userInitiated) {
                try NativePositioningEngine.run(request: engineRequest) { progress, status in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isBackendRunning else { return }
                        self.backendProgress = progress
                        self.backendStatus = status
                        self.backendLog += "[\(Int((progress * 100).rounded()))%] \(status)\n"
                        if self.backendLog.count > 40_000 {
                            self.backendLog = String(self.backendLog.suffix(40_000))
                        }
                    }
                }
            }
            nativeEngineTask = engineTask
            nativeTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let nativeResult = try await engineTask.value
                    try Task.checkCancellation()
                    if let heading = nativeResult.headingDiagnostics {
                        self.backendLog += "航向: \(heading.localizedMethod)"
                        if let rms = heading.gyroAgreementRMSEDegrees {
                            self.backendLog += String(format: "，与陀螺相对变化 RMS %.1f°", rms)
                        }
                        if let reason = heading.localizedRejectionReason {
                            self.backendLog += "（回退原因：\(reason)）"
                        }
                        self.backendLog += "\n"
                    }
                    if let map = self.mapForCurrentSelection {
                        self.backendLog += "地磁图: \(map.document.name)"
                            + "（参考采集：\(map.document.sourceLabel)）\n"
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(nativeResult).write(to: jsonURL, options: .atomic)
                    self.isBackendRunning = false
                    self.nativeTask = nil
                    self.nativeEngineTask = nil
                    self.backendProgress = 1
                    self.backendStatus = "原生计算完成，结果已加载"
                    self.lastOutputPath = jsonURL.path
                    self.load(url: jsonURL)
                    self.refreshRunHistory()
                } catch is CancellationError {
                    self.isBackendRunning = false
                    self.nativeTask = nil
                    self.nativeEngineTask = nil
                    self.backendStatus = "计算已取消"
                } catch {
                    self.isBackendRunning = false
                    self.nativeTask = nil
                    self.nativeEngineTask = nil
                    self.backendStatus = "原生计算失败"
                    self.backendLog += "错误: \(error.localizedDescription)\n"
                    self.errorMessage = "原生定位计算失败：\(error.localizedDescription)"
                }
            }
        } catch {
            isBackendRunning = false
            if error is RunPreparationError {
                backendStatus = "等待完善数据配置"
                errorMessage = error.localizedDescription
            } else {
                backendStatus = "无法开始原生计算"
                errorMessage = "无法开始原生计算：\(error.localizedDescription)"
            }
        }
    }

    func cancelBackendRun() {
        guard isBackendRunning else { return }
        backendStatus = "正在取消…"
        nativeEngineTask?.cancel()
        nativeTask?.cancel()
    }

    func buildMagneticMapFromImportedDataset() {
        guard !isMagneticMapBuilding else { return }
        guard let importedDataset else {
            errorMessage = RunPreparationError.noImportedDataset.localizedDescription
            return
        }
        let datasetKey = customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !datasetKey.isEmpty else {
            errorMessage = RunPreparationError.emptyDatasetName.localizedDescription
            return
        }
        let normalized = DatasetValidator.normalizedRouteText(customRouteText)
        guard importedDataset.spatialAnchors.count >= 2 || normalized != nil else {
            errorMessage = "锚点建图至少需要两个已知坐标锚点；旧采集则必须填写真实路线。"
            return
        }
        let mapName = newMagneticMapName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mapName.isEmpty else {
            errorMessage = GenericMagneticMapStore.StoreError.invalidName.localizedDescription
            return
        }
        let route = normalized.map(Self.parseRoute) ?? importedDataset.spatialAnchors.map {
            XYPoint(x: $0.x, y: $0.y)
        }
        let requestedID = try? GenericMagneticMapStore.identifier(from: mapName)
        let existingEntry = requestedID.flatMap { id in magneticMaps.first { $0.id == id } }
        if existingEntry?.isBuiltIn == true {
            errorMessage = "内置示例磁图不能被覆盖；请使用新的房间磁图名称。"
            return
        }
        let initialHeading = Double(customInitialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines))
        let interval = importedDataset.activeInterval
        isMagneticMapBuilding = true
        magneticMapStatus = "正在把参考采集转换为坐标磁图…"
        let job = Task.detached(priority: .userInitiated) { [algorithmSettings] in
            let callback: @Sendable (Double, String) -> Void = { progress, status in
                DispatchQueue.main.async { [weak self] in
                    self?.magneticMapStatus = "\(Int((progress * 100).rounded()))% · \(status)"
                }
            }
            let document: GenericMagneticMapDocument
            if importedDataset.spatialAnchors.count >= 2 {
                document = try NativePositioningEngine.buildAnchoredGridMagneticMap(
                    name: mapName,
                    datasetKey: importedDataset.sourceDatasetKey,
                    datasetDirectory: importedDataset.directoryURL,
                    coordinateFrame: importedDataset.coordinateFrame ?? "local-room",
                    anchors: importedDataset.spatialAnchors,
                    excludedIntervals: importedDataset.mappingPauseIntervals + importedDataset.mappingDisturbIntervals,
                    cellSizeM: 0.25,
                    settings: algorithmSettings,
                    progress: callback
                )
            } else {
                document = try NativePositioningEngine.buildGenericMagneticMap(
                    name: mapName,
                    datasetKey: importedDataset.sourceDatasetKey,
                    datasetDirectory: importedDataset.directoryURL,
                    route: route,
                    initialHeadingDegrees: initialHeading,
                    activeStartTime: interval.confidence == "低" ? nil : interval.startTime,
                    activeEndTime: interval.confidence == "低" ? nil : interval.endTime,
                    excludedIntervals: importedDataset.mappingPauseIntervals
                        + importedDataset.mappingDisturbIntervals,
                    settings: algorithmSettings,
                    progress: callback
                )
            }
            let savedDocument: GenericMagneticMapDocument
            var mergeWarnings: [String] = []
            if let existingEntry {
                mergeWarnings = GenericMagneticMapStore.mergeQualityWarnings(
                    existingEntry.document,
                    with: document
                )
                savedDocument = try GenericMagneticMapStore.merging(
                    existingEntry.document,
                    with: document
                )
                _ = try GenericMagneticMapStore.save(savedDocument, replacing: true)
            } else {
                savedDocument = document
                _ = try GenericMagneticMapStore.save(savedDocument)
            }
            return (savedDocument, mergeWarnings)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let (document, mergeWarnings) = try await job.value
                self.isMagneticMapBuilding = false
                self.refreshMagneticMaps(selecting: document.id)
                if let quality = document.qualityReport {
                    let summary = "质量\(quality.grade.rawValue) · 覆盖约 "
                        + "\(Int((quality.coverageRatio * 100).rounded()))%"
                    self.magneticMapStatus = ([summary] + mergeWarnings + quality.messages.prefix(1))
                        .joined(separator: " · ")
                } else {
                    self.magneticMapStatus = "路线磁图已建立；请导入独立采集进行验证"
                }
            } catch {
                self.isMagneticMapBuilding = false
                self.magneticMapStatus = "磁图建立失败"
                self.errorMessage = "无法建立地磁图：\(error.localizedDescription)"
            }
        }
    }

    func removeSelectedMagneticMap() {
        guard let entry = selectedMagneticMap, !isMagneticMapBuilding else { return }
        do {
            try GenericMagneticMapStore.remove(entry)
            refreshMagneticMaps()
            magneticMapStatus = "用户地磁图已移除"
        } catch {
            errorMessage = "无法移除地磁图：\(error.localizedDescription)"
        }
    }

    func openMagneticMapDirectory() {
        do {
            NSWorkspace.shared.open(try GenericMagneticMapStore.directoryURL(createIfNeeded: true))
        } catch {
            errorMessage = "无法打开地磁图目录：\(error.localizedDescription)"
        }
    }

    func revealLastOutput() {
        guard !lastOutputPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastOutputPath)])
    }

    func openRunsDirectory() {
        do {
            NSWorkspace.shared.open(try runsDirectoryURL(createIfNeeded: true))
        } catch {
            errorMessage = "无法打开结果目录：\(error.localizedDescription)"
        }
    }

    func refreshRunHistory() {
        do {
            let directory = try runsDirectoryURL(createIfNeeded: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            recentRuns = urls
                .filter { $0.pathExtension.lowercased() == "json" }
                .map { url in
                    let date = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    return RunRecord(jsonURL: url, modifiedAt: date)
                }
                .sorted { $0.modifiedAt > $1.modifiedAt }
        } catch {
            recentRuns = []
        }
    }

    func loadRun(_ record: RunRecord) {
        load(url: record.jsonURL)
        lastOutputPath = record.jsonURL.path
        backendStatus = "已加载历史结果"
    }

    func revealRun(_ record: RunRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.jsonURL])
    }

    func copyBackendLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(backendLog, forType: .string)
    }

    func clearBackendLog() {
        guard !isBackendRunning else { return }
        backendLog = ""
        backendProgress = 0
        if backendStatus.hasPrefix("计算失败") || backendStatus == "计算已取消" {
            backendStatus = "准备就绪"
        }
    }

    func exportCurrentResult() {
        guard let result else {
            errorMessage = "当前没有可以导出的定位结果。"
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择 PNG 和 CSV 导出文件夹"
        panel.prompt = "导出到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let savedPath = UserDefaults.standard.string(forKey: "resultExportDirectory"),
           FileManager.default.fileExists(atPath: savedPath) {
            panel.directoryURL = URL(fileURLWithPath: savedPath, isDirectory: true)
        }

        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }

        do {
            let safeDatasetName = result.datasetKey
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let baseName = "\(safeDatasetName)-\(Self.fileTimestamp())"
            let files = try ResultExporter.export(
                result: result,
                to: directoryURL,
                baseName: baseName
            )
            UserDefaults.standard.set(directoryURL.path, forKey: "resultExportDirectory")
            exportMessage = "已导出：\n\(files.pngURL.lastPathComponent)\n\(files.csvURL.lastPathComponent)"
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func load(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PositioningResult.self, from: data)
            result = decoded
            loadedFileName = url.lastPathComponent
            playbackProgress = 1.0
            errorMessage = nil
        } catch {
            errorMessage = "无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"
        }
    }

    private func importDataset(at selectedURL: URL, preserveConfiguration: Bool = false) {
        do {
            let inspected = try DatasetValidator.inspect(selectedURL: selectedURL)
            importedDataset = inspected
            runInputMode = .imported
            if !preserveConfiguration {
                applyAlgorithmPreset(.optimized)
                let resolvedDatasetName = inspected.suggestedDatasetName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? inspected.directoryURL.lastPathComponent
                customDatasetName = resolvedDatasetName
                customRouteText = inspected.suggestedRouteText ?? ""
                customInitialHeadingText = inspected.suggestedInitialHeadingDegrees.map {
                    String(format: "%.3f", $0)
                } ?? ""
                newMagneticMapName = Self.datasetGroup(resolvedDatasetName)
            }
            UserDefaults.standard.set(
                inspected.directoryURL.path,
                forKey: "lastImportedDatasetDirectory"
            )
            backendStatus = DatasetValidator.normalizedRouteText(customRouteText) == nil
                ? "传感器校验通过，请填写真实路线"
                : "采集数据校验通过，可以开始计算"
            backendProgress = 0
            backendLog = ""
            errorMessage = nil
        } catch {
            importedDataset = nil
            backendStatus = "采集数据校验失败"
            errorMessage = "无法导入采集数据：\(error.localizedDescription)"
        }
    }

    private func refreshMagneticMaps(selecting preferredID: String? = nil) {
        do {
            magneticMaps = try GenericMagneticMapStore.loadAll()
            if let preferredID, magneticMaps.contains(where: { $0.id == preferredID }) {
                selectedMagneticMapID = preferredID
            } else if !magneticMaps.contains(where: { $0.id == selectedMagneticMapID }) {
                selectedMagneticMapID = magneticMaps.first?.id ?? ""
            }
            if let map = selectedMagneticMap {
                magneticMapStatus = "已选择 \(map.document.name) · 参考采集 \(map.document.sourceLabel)"
            } else {
                magneticMapStatus = "尚无地磁图；请导入第一次采集并建立磁图"
            }
        } catch {
            magneticMaps = []
            selectedMagneticMapID = ""
            magneticMapStatus = "地磁图读取失败"
        }
    }

    private func currentRunRequest() throws -> RunRequest {
        guard let selectedMap = mapForCurrentSelection else {
            throw RunPreparationError.magneticMapRequired
        }
        if runInputMode == .bundled {
            let route = Self.route(for: selectedRunDatasetID)
            let datasetDirectory = try NativePositioningEngine.bundledDatasetURL(
                key: selectedRunDatasetID
            )
            let inspected = try DatasetValidator.inspect(selectedURL: datasetDirectory)
            let activeInterval = inspected.activeInterval
            return RunRequest(
                datasetKey: selectedRunDatasetID,
                datasetDirectory: datasetDirectory,
                route: route,
                initialHeadingDegrees: nil,
                activeStartTime: activeInterval.confidence == "低" ? nil : activeInterval.startTime,
                activeEndTime: activeInterval.confidence == "低" ? nil : activeInterval.endTime,
                magneticMap: selectedMap.document,
                localizationMode: selectedMap.document.localizationMode,
                logDescription: "来源: App 内置原始传感器 CSV\n"
                    + "路线: \(Self.routeText(route))\n"
                    + "地磁图: \(selectedMap.document.name)\n"
            )
        }

        guard let importedDataset else {
            throw RunPreparationError.noImportedDataset
        }
        let datasetKey = customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !datasetKey.isEmpty else {
            throw RunPreparationError.emptyDatasetName
        }
        if selectedMap.document.sourceDatasetKeys.contains(importedDataset.sourceDatasetKey) {
            throw RunPreparationError.mapSourceCannotLocateItself
        }
        if let mapFrame = selectedMap.document.coordinateFrame {
            if let datasetFrame = importedDataset.coordinateFrame {
                guard datasetFrame == mapFrame else {
                    throw RunPreparationError.coordinateFrameMismatch
                }
            } else if selectedMap.document.samplesFollowPath != true {
                throw RunPreparationError.coordinateFrameMismatch
            }
        }
        guard let normalizedRoute = DatasetValidator.normalizedRouteText(customRouteText) else {
            throw RunPreparationError.invalidRoute
        }
        guard DatasetValidator.routeGeometryIssue(normalizedRoute) == nil else {
            throw RunPreparationError.invalidRoute
        }
        let route = Self.parseRoute(normalizedRoute)
        let routeValidation = routeMapValidation
        if let point = routeValidation.invalidPoints.first,
           let bounds = routeValidation.bounds {
            throw RunPreparationError.routeOutsideMap(
                "路线第 \(point.index) 个坐标（\(Self.cliNumber(point.x)), \(Self.cliNumber(point.y))）"
                    + "超出地图范围 x=[\(Self.cliNumber(bounds.minX)), \(Self.cliNumber(bounds.maxX))]、"
                    + "y=[\(Self.cliNumber(bounds.minY)), \(Self.cliNumber(bounds.maxY))]。"
            )
        }

        let initialHeading = customInitialHeadingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var initialHeadingDegrees: Double?
        if !initialHeading.isEmpty {
            guard let value = Double(initialHeading), value.isFinite else {
                throw RunPreparationError.invalidInitialHeading
            }
            initialHeadingDegrees = value
        }
        let activeInterval = importedDataset.activeInterval
        let activeStartTime = activeInterval.confidence == "低" ? nil : activeInterval.startTime
        let activeEndTime = activeInterval.confidence == "低" ? nil : activeInterval.endTime
        let intervalDescription = "自动行走区间: "
            + String(
                format: "%.2f–%.2f 秒（保留约 %d 帧，置信度 %@）\n",
                activeInterval.startTime,
                activeInterval.endTime,
                importedDataset.activeFrameCount,
                activeInterval.confidence
            )
        return RunRequest(
            datasetKey: datasetKey,
            datasetDirectory: importedDataset.directoryURL,
            route: route,
            initialHeadingDegrees: initialHeadingDegrees,
            activeStartTime: activeStartTime,
            activeEndTime: activeEndTime,
            magneticMap: selectedMap.document,
            localizationMode: selectedMap.document.localizationMode,
            logDescription: "来源: \(importedDataset.directoryURL.path)\n"
                + "有效帧: 约 \(importedDataset.estimatedFrameCount)，时间重叠: "
                + String(format: "%.2f 秒\n", importedDataset.overlapDuration)
                + intervalDescription
                + "数据质量: \(importedDataset.quality.grade.title)\n"
                + "算法配置: 纯 Swift 原生 PDR + PF\n"
                + "路线: \(normalizedRoute)\n"
                + "地磁图: \(selectedMap.document.name)"
                + "（参考采集 \(selectedMap.document.sourceLabel)）\n"
        )
    }

    private func createRunDirectory() throws -> URL {
        try runsDirectoryURL(createIfNeeded: true)
    }

    private func runsDirectoryURL(createIfNeeded: Bool) throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupport
            .appendingPathComponent("GeomagMacNative", isDirectory: true)
            .appendingPathComponent("Runs", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private static func route(for datasetKey: String) -> [XYPoint] {
        switch datasetGroup(datasetKey) {
        case "route_13":
            [
                XYPoint(x: 4.0, y: 3.0), XYPoint(x: 4.0, y: 4.8),
                XYPoint(x: 5.8, y: 4.8), XYPoint(x: 5.8, y: 3.0),
                XYPoint(x: 4.0, y: 3.0),
            ]
        case "route_15":
            [
                XYPoint(x: 12.5, y: 0.5), XYPoint(x: 0.5, y: 0.5),
                XYPoint(x: 0.5, y: 1.1), XYPoint(x: 12.5, y: 1.1),
                XYPoint(x: 12.5, y: 0.5),
            ]
        default: []
        }
    }

    private static func datasetGroup(_ datasetKey: String) -> String {
        datasetKey.replacingOccurrences(
            of: #"_\d+$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func parseRoute(_ text: String) -> [XYPoint] {
        text.split(separator: ";").compactMap { pair in
            let values = pair.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 2,
                  let x = Double(values[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(values[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return XYPoint(x: x, y: y)
        }
    }

    private static func routeText(_ route: [XYPoint]) -> String {
        route.map { "\(cliNumber($0.x)),\(cliNumber($0.y))" }
            .joined(separator: "; ")
    }

    private func persistAlgorithmConfiguration() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(algorithmSettings) {
            UserDefaults.standard.set(data, forKey: "algorithmSettings")
        }
        UserDefaults.standard.set(selectedAlgorithmPreset.rawValue, forKey: "algorithmPreset")
    }

    private static func restoreAlgorithmConfiguration() -> (
        preset: AlgorithmPreset,
        settings: AlgorithmSettings
    ) {
        let defaults = UserDefaults.standard
        let preset = defaults.string(forKey: "algorithmPreset")
            .flatMap(AlgorithmPreset.init(rawValue:)) ?? .optimized
        if preset != .custom, let settings = preset.settings {
            return (preset, settings)
        }
        if let data = defaults.data(forKey: "algorithmSettings"),
           let settings = try? JSONDecoder().decode(AlgorithmSettings.self, from: data) {
            return (preset, settings)
        }
        return (.optimized, .optimized)
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func availableBaseName(
        _ proposedBaseName: String,
        in directoryURL: URL,
        reservedSuffixes: [String]
    ) -> String {
        var candidate = proposedBaseName
        var suffix = 2
        let fileManager = FileManager.default
        while reservedSuffixes.contains(where: { reservedSuffix in
            fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent(candidate + reservedSuffix).path
            )
        }) {
            candidate = "\(proposedBaseName)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func safeFileComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = value.components(separatedBy: invalid)
        let cleaned = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "dataset" : cleaned
    }

    private static func cliNumber(_ value: Double) -> String {
        String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
