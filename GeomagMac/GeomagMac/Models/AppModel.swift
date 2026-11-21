import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    struct Sample: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static let samples = [
        Sample(id: "v7_final_route1_run2", title: "Route 1 · Run 2"),
        Sample(id: "v7_final_route2_run1", title: "Route 2 · Run 1"),
        Sample(id: "v7_final_route2_run2", title: "Route 2 · Run 2"),
    ]

    static let runnableDatasets = [
        Sample(id: "route1_run2", title: "Route 1 · Run 2"),
        Sample(id: "route2_run1", title: "Route 2 · Run 1"),
        Sample(id: "route2_run2", title: "Route 2 · Run 2"),
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
    @Published var customMapPath = ""
    @Published var projectDirectory: String
    @Published var isBackendRunning = false
    @Published var backendProgress = 0.0
    @Published var backendLog = ""
    @Published var backendStatus = "准备就绪"
    @Published var lastOutputPath = ""
    @Published var exportMessage: String?
    @Published private(set) var recentRuns: [RunRecord] = []
    @Published private(set) var selectedAlgorithmPreset: AlgorithmPreset
    @Published private(set) var algorithmSettings: AlgorithmSettings

    private var backendProcess: Process?
    private var backendPipe: Pipe?
    private var backendWasCancelled = false

    private struct BackendLaunch {
        let executableURL: URL
        let currentDirectoryURL: URL
        let arguments: [String]
        let logHeader: String
    }

    private struct RunRequest {
        let datasetKey: String
        let selectionArgument: String
        let additionalArguments: [String]
        let logDescription: String
    }

    private enum RunPreparationError: LocalizedError {
        case noImportedDataset
        case emptyDatasetName
        case invalidRoute
        case invalidInitialHeading
        case missingMap(String)
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
            case let .missingMap(path):
                "找不到自定义地磁地图：\(path)"
            case let .routeOutsideMap(description):
                description
            }
        }
    }

    var hasBundledBackend: Bool {
        bundledBackendExecutableURL != nil
    }

    var backendModeTitle: String {
        hasBundledBackend ? "内置算法后端" : "外部 Python（开发模式）"
    }

    var importedDatasetReady: Bool {
        guard importedDataset != nil,
              !customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              DatasetValidator.normalizedRouteText(customRouteText) != nil else {
            return false
        }
        if !customInitialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Double(customInitialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return false
        }
        guard customMapPath.isEmpty || FileManager.default.fileExists(atPath: customMapPath) else {
            return false
        }
        return routeMapValidation.isValid
    }

    var routeMapValidation: RouteMapValidation {
        DatasetValidator.validateRoute(customRouteText, against: selectedMapBounds)
    }

    var selectedMapBounds: CoordinateBounds? {
        customMapPath.isEmpty ? .builtInTileManifest : nil
    }

    var canRunSelectedDataset: Bool {
        guard !isBackendRunning else { return false }
        return runInputMode == .bundled || importedDatasetReady
    }

    var runButtonHelp: String {
        if isBackendRunning {
            return "定位计算正在运行"
        }
        if runInputMode == .imported, !importedDatasetReady {
            if !routeMapValidation.isValid {
                return "真实路线超出当前地磁地图范围"
            }
            return "请先选择有效的采集数据，并填写数据集名称和真实路线"
        }
        return "使用当前数据和下次运行参数开始定位计算"
    }

    var importedDatasetStatus: String {
        guard let importedDataset else { return "尚未选择采集文件夹" }
        if DatasetValidator.normalizedRouteText(customRouteText) == nil {
            return "传感器数据有效；还需要填写至少两个真实路线坐标点"
        }
        if !routeMapValidation.isValid {
            return "真实路线存在超出地磁地图范围的坐标点"
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
        projectDirectory = UserDefaults.standard.string(forKey: "pythonProjectDirectory")
            ?? Self.defaultProjectDirectory()
        let restored = Self.restoreAlgorithmConfiguration()
        selectedAlgorithmPreset = restored.preset
        algorithmSettings = restored.settings
        loadBundledSample(id: selectedSampleID)
        refreshRunHistory()
    }

    deinit {
        backendProcess?.terminate()
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

    func chooseCustomMapFile() {
        let panel = NSOpenPanel()
        panel.title = "选择地磁地图 NPZ"
        panel.prompt = "选择地图"
        panel.allowedContentTypes = [UTType(filenameExtension: "npz") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !customMapPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customMapPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customMapPath = url.path
    }

    func clearCustomMap() {
        customMapPath = ""
    }

    func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Python 地磁定位项目"
        panel.prompt = "选择项目"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: projectDirectory) {
            panel.directoryURL = URL(fileURLWithPath: projectDirectory)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let mainFile = url.appendingPathComponent("main.py")
        guard FileManager.default.fileExists(atPath: mainFile.path) else {
            errorMessage = "所选目录中没有 main.py，请选择 Lego-like-Geomagnetic-Positioning 项目根目录。"
            return
        }
        projectDirectory = url.path
        UserDefaults.standard.set(projectDirectory, forKey: "pythonProjectDirectory")
        backendStatus = "Python 项目已连接"
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
                reservedSuffixes: [".json", ".png", "_diagnostics.png"]
            )
            let jsonURL = runDirectory.appendingPathComponent(baseName).appendingPathExtension("json")
            let pngURL = runDirectory.appendingPathComponent(baseName).appendingPathExtension("png")

            guard let launch = resolveBackendLaunch(
                request: request,
                jsonURL: jsonURL,
                pngURL: pngURL
            ) else {
                return
            }

            let process = Process()
            let pipe = Pipe()
            process.executableURL = launch.executableURL
            process.currentDirectoryURL = launch.currentDirectoryURL
            process.arguments = launch.arguments
            process.standardOutput = pipe
            process.standardError = pipe

            var environment = ProcessInfo.processInfo.environment
            let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = standardPath + ":" + (environment["PATH"] ?? "")
            environment["MPLBACKEND"] = "Agg"
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment

            backendProcess = process
            backendPipe = pipe
            backendWasCancelled = false
            backendLog = launch.logHeader
                + "数据: \(request.datasetKey)\n"
                + request.logDescription
                + "预设: \(selectedAlgorithmPreset.title)\n"
                + "参数: \(algorithmSettings.logSummary)\n\n"
            backendProgress = 0
            backendStatus = "正在计算 \(request.datasetKey)…"
            isBackendRunning = true

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.consumeBackendOutput(text)
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.backendPipe?.fileHandleForReading.readabilityHandler = nil
                    self.isBackendRunning = false
                    self.backendProcess = nil
                    self.backendPipe = nil

                    if self.backendWasCancelled {
                        self.backendStatus = "计算已取消"
                    } else if finishedProcess.terminationStatus == 0,
                              FileManager.default.fileExists(atPath: jsonURL.path) {
                        self.backendProgress = 1
                        self.backendStatus = "计算完成，结果已加载"
                        self.lastOutputPath = jsonURL.path
                        self.load(url: jsonURL)
                        self.refreshRunHistory()
                    } else {
                        self.backendStatus = "计算失败（退出码 \(finishedProcess.terminationStatus)）"
                        self.errorMessage = self.backendFailureMessage(
                            exitCode: finishedProcess.terminationStatus
                        )
                    }
                }
            }

            try process.run()
        } catch {
            backendProcess = nil
            backendPipe = nil
            isBackendRunning = false
            if error is RunPreparationError {
                backendStatus = "等待完善数据配置"
                errorMessage = error.localizedDescription
            } else {
                backendStatus = "无法启动算法后端"
                errorMessage = "无法启动算法后端：\(error.localizedDescription)"
            }
        }
    }

    func cancelBackendRun() {
        guard let backendProcess, backendProcess.isRunning else { return }
        backendWasCancelled = true
        backendStatus = "正在取消…"
        backendProcess.terminate()
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
                customDatasetName = inspected.suggestedDatasetName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? inspected.directoryURL.lastPathComponent
                customRouteText = inspected.suggestedRouteText ?? ""
                customInitialHeadingText = inspected.suggestedInitialHeadingDegrees.map {
                    String(format: "%.3f", $0)
                } ?? ""
                customMapPath = inspected.suggestedMapURL?.path ?? ""
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

    private func currentRunRequest() throws -> RunRequest {
        if runInputMode == .bundled {
            return RunRequest(
                datasetKey: selectedRunDatasetID,
                selectionArgument: selectedRunDatasetID,
                additionalArguments: [],
                logDescription: "来源: App 内置测试数据\n"
            )
        }

        guard let importedDataset else {
            throw RunPreparationError.noImportedDataset
        }
        let datasetKey = customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !datasetKey.isEmpty else {
            throw RunPreparationError.emptyDatasetName
        }
        guard let route = DatasetValidator.normalizedRouteText(customRouteText) else {
            throw RunPreparationError.invalidRoute
        }
        let routeValidation = routeMapValidation
        if let point = routeValidation.invalidPoints.first,
           let bounds = routeValidation.bounds {
            throw RunPreparationError.routeOutsideMap(
                "路线第 \(point.index) 个坐标（\(Self.cliNumber(point.x)), \(Self.cliNumber(point.y))）"
                    + "超出地图范围 x=[\(Self.cliNumber(bounds.minX)), \(Self.cliNumber(bounds.maxX))]、"
                    + "y=[\(Self.cliNumber(bounds.minY)), \(Self.cliNumber(bounds.maxY))]。"
            )
        }

        var arguments = [
            "--own-profile", "package",
            "--own-data-source", "directory",
            "--own-dataset-key", datasetKey,
            "--own-data-dir", importedDataset.directoryURL.path,
            "--own-map-profile", "tile_manifest",
            "--own-route", route,
        ]
        let initialHeading = customInitialHeadingText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !initialHeading.isEmpty {
            guard let value = Double(initialHeading), value.isFinite else {
                throw RunPreparationError.invalidInitialHeading
            }
            arguments += ["--own-initial-heading-deg", Self.cliNumber(value)]
        }
        if !customMapPath.isEmpty {
            guard FileManager.default.fileExists(atPath: customMapPath) else {
                throw RunPreparationError.missingMap(customMapPath)
            }
            arguments += ["--own-map-npz-path", customMapPath]
        }
        let activeInterval = importedDataset.activeInterval
        if activeInterval.confidence != "低" {
            if activeInterval.trimHeadFrames > 0 {
                arguments += ["--own-trim-head", String(activeInterval.trimHeadFrames)]
            }
            if activeInterval.trimTailFrames > 0 {
                arguments += ["--own-trim-tail", String(activeInterval.trimTailFrames)]
            }
        }

        let mapDescription = customMapPath.isEmpty
            ? "内置砖块地磁地图（tile_manifest）"
            : customMapPath
        return RunRequest(
            datasetKey: datasetKey,
            selectionArgument: importedDataset.directoryURL.path,
            additionalArguments: arguments,
            logDescription: "来源: \(importedDataset.directoryURL.path)\n"
                + "有效帧: 约 \(importedDataset.estimatedFrameCount)，时间重叠: "
                + String(format: "%.2f 秒\n", importedDataset.overlapDuration)
                + "自动行走区间: "
                + String(
                    format: "%.2f–%.2f 秒（保留约 %d 帧，置信度 %@）\n",
                    activeInterval.startTime,
                    activeInterval.endTime,
                    importedDataset.activeFrameCount,
                    activeInterval.confidence
                )
                + "数据质量: \(importedDataset.quality.grade.title)\n"
                + "算法配置: package（当前优化参数）\n"
                + "路线: \(route)\n地图: \(mapDescription)\n"
        )
    }

    private func consumeBackendOutput(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        backendLog += normalized
        if backendLog.count > 40_000 {
            backendLog = String(backendLog.suffix(40_000))
        }

        let pattern = #"\(\s*([0-9]+(?:\.[0-9]+)?)%\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(normalized.startIndex..., in: normalized)
        let matches = expression.matches(in: normalized, range: range)
        guard let match = matches.last,
              let percentRange = Range(match.range(at: 1), in: normalized),
              let percent = Double(normalized[percentRange]) else { return }
        backendProgress = min(max(percent / 100, 0), 1)
    }

    private func resolvePythonExecutable(projectURL: URL) -> URL? {
        var candidates = [
            projectURL.appendingPathComponent(".venv/bin/python").path,
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                String($0) + "/python3"
            }
        }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private var bundledBackendExecutableURL: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let executableURL = resourceURL
            .appendingPathComponent("GeomagBackend", isDirectory: true)
            .appendingPathComponent("GeomagBackend", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        return executableURL
    }

    private func resolveBackendLaunch(
        request: RunRequest,
        jsonURL: URL,
        pngURL: URL
    ) -> BackendLaunch? {
        let algorithmArguments = [
            "--branch", "own",
            "--own", request.selectionArgument,
            "--no-show",
            "--output-json", jsonURL.path,
            "--output-png", pngURL.path,
        ] + request.additionalArguments + algorithmSettings.commandLineArguments

        if let executableURL = bundledBackendExecutableURL {
            return BackendLaunch(
                executableURL: executableURL,
                currentDirectoryURL: executableURL.deletingLastPathComponent(),
                arguments: algorithmArguments,
                logHeader: "后端: 内置 GeomagBackend\n算法: xuml-v7-optimization 修改版\n"
            )
        }

        let projectURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let mainURL = projectURL.appendingPathComponent("main.py")
        guard FileManager.default.fileExists(atPath: mainURL.path) else {
            errorMessage = "App 中没有内置算法后端，同时找不到 \(mainURL.path)。请先构建内置后端，或重新选择 Python 项目目录。"
            return nil
        }
        guard let pythonURL = resolvePythonExecutable(projectURL: projectURL) else {
            errorMessage = "App 中没有内置算法后端，也找不到可用的 Python 3。请先构建内置后端，或在原项目中创建 .venv。"
            return nil
        }

        return BackendLaunch(
            executableURL: pythonURL,
            currentDirectoryURL: projectURL,
            arguments: ["-u", mainURL.path] + algorithmArguments,
            logHeader: "后端: 外部 Python（开发模式）\nPython: \(pythonURL.path)\n项目: \(projectURL.path)\n"
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
            .appendingPathComponent("GeomagMac", isDirectory: true)
            .appendingPathComponent("Runs", isDirectory: true)
        if createIfNeeded {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private func backendFailureMessage(exitCode: Int32) -> String {
        let meaningfulLines = backendLog
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if let errorLine = meaningfulLines.last(where: Self.isBackendErrorLine) {
            let reason = Self.localizedBackendReason(from: errorLine)
            return "定位计算失败（退出码 \(exitCode)）：\n\(reason)\n\n完整技术信息仍保留在运行日志中。"
        }
        return "定位计算失败（退出码 \(exitCode)）。请打开运行日志查看完整技术信息。"
    }

    private static func isBackendErrorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return [
            "ValueError:",
            "FileNotFoundError:",
            "RuntimeError:",
            "PermissionError:",
            "KeyError:",
            "ImportError:",
            "ModuleNotFoundError:",
        ].contains { trimmed.hasPrefix($0) }
    }

    private static func localizedBackendReason(from line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let reason = trimmed.split(separator: ":", maxSplits: 1)
            .dropFirst()
            .first
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            ?? trimmed

        if reason.contains("Own route and magnetic map use incompatible coordinates"),
           let details = mapBoundsDetails(in: reason) {
            return "真实路线超出地磁地图范围：坐标 \(details.coordinate) 不在地图范围 \(details.bounds) 内。请检查路线坐标或选择正确的地图。"
        }
        if reason.localizedCaseInsensitiveContains("No such file or directory") {
            return "算法所需的文件不存在。请重新选择采集数据或地图文件。"
        }
        if trimmed.hasPrefix("ModuleNotFoundError:") || trimmed.hasPrefix("ImportError:") {
            return "算法运行环境缺少必要组件。请重新构建 App 内置后端。"
        }
        if trimmed.hasPrefix("PermissionError:") {
            return "没有权限读取输入文件或写入结果目录。请检查文件夹权限。"
        }
        return reason.isEmpty ? "算法后端返回了未知错误。" : reason
    }

    private static func mapBoundsDetails(in message: String) -> (
        coordinate: String,
        bounds: String
    )? {
        let pattern = #"point\s+\d+\s+\(([-+0-9.eE]+),\s*([-+0-9.eE]+)\)\s+is outside map bounds\s+x=\[([-+0-9.eE]+),\s*([-+0-9.eE]+)\],\s*y=\[([-+0-9.eE]+),\s*([-+0-9.eE]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)
              ),
              match.numberOfRanges == 7 else {
            return nil
        }

        func value(at index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: message) else { return nil }
            return String(message[range])
        }

        guard let x = value(at: 1),
              let y = value(at: 2),
              let minX = value(at: 3),
              let maxX = value(at: 4),
              let minY = value(at: 5),
              let maxY = value(at: 6) else {
            return nil
        }
        return (
            coordinate: "(\(x), \(y))",
            bounds: "x=[\(minX), \(maxX)]、y=[\(minY), \(maxY)]"
        )
    }

    private static func defaultProjectDirectory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("dachuang", isDirectory: true)
            .appendingPathComponent("Lego-like-Geomagnetic-Positioning", isDirectory: true)
            .path
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
