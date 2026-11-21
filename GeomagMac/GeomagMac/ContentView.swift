import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPlaying = false
    @State private var showFullLog = false

    private let timer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 330)
        } detail: {
            detail
        }
        .alert(
            "出现问题",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .alert(
            "导出完成",
            isPresented: Binding(
                get: { model.exportMessage != nil },
                set: { if !$0 { model.exportMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.exportMessage ?? "")
        }
        .sheet(isPresented: $showFullLog) {
            BackendLogView(
                log: model.backendLog,
                status: model.backendStatus,
                isRunning: model.isBackendRunning,
                copyAction: model.copyBackendLog,
                clearAction: model.clearBackendLog
            )
        }
        .onReceive(timer) { _ in
            guard isPlaying else { return }
            if model.playbackProgress >= 1.0 {
                isPlaying = false
            } else {
                model.playbackProgress = min(1.0, model.playbackProgress + 0.008)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("GeomagMac", systemImage: "location.viewfinder")
                        .font(.title2.weight(.bold))
                    Text("地磁定位路径查看器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                sidebarSection("示例数据") {
                    Picker("示例", selection: $model.selectedSampleID) {
                        ForEach(AppModel.samples) { sample in
                            Text(sample.title).tag(sample.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: model.selectedSampleID) { id in
                        isPlaying = false
                        model.loadBundledSample(id: id)
                    }

                    Button(action: model.openResultFile) {
                        Label("打开其他 JSON…", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                sidebarSection("运行定位算法") {
                    HStack(spacing: 7) {
                        Image(systemName: model.hasBundledBackend ? "shippingbox.fill" : "wrench.and.screwdriver.fill")
                        Text(model.backendModeTitle)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.hasBundledBackend ? .green : .orange)

                    Picker("数据来源", selection: $model.runInputMode) {
                        ForEach(RunInputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(model.isBackendRunning)

                    if model.runInputMode == .bundled {
                        Picker("采集数据", selection: $model.selectedRunDatasetID) {
                            ForEach(AppModel.runnableDatasets) { sample in
                                Text(sample.title).tag(sample.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isBackendRunning)
                    } else {
                        importedDatasetPanel
                    }

                    if model.hasBundledBackend {
                        Text("使用 App 内置的修改版算法、运行环境与采集数据，无需配置 Python。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PYTHON 项目")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text(model.projectDirectory)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }

                        Button(action: model.chooseProjectDirectory) {
                            Label("选择项目目录…", systemImage: "folder.badge.gearshape")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(model.isBackendRunning)
                    }

                    algorithmParameterPanel

                    if model.isBackendRunning || model.backendProgress > 0 {
                        ProgressView(value: model.backendProgress)
                        Text("\(Int(model.backendProgress * 100))% · \(model.backendStatusDisplay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.backendStatusDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button(action: model.runSelectedDataset) {
                            Label("开始计算", systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRunSelectedDataset)
                        .help(model.runButtonHelp)

                        if model.isBackendRunning {
                            Button("取消", role: .destructive, action: model.cancelBackendRun)
                        }
                    }

                    if !model.backendLog.isEmpty {
                        DisclosureGroup("运行日志") {
                            ScrollView {
                                Text(model.backendLog)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 110)
                            HStack {
                                Button("查看完整日志") { showFullLog = true }
                                Button("复制", action: model.copyBackendLog)
                                Spacer()
                                Button("清空", action: model.clearBackendLog)
                                    .disabled(model.isBackendRunning)
                            }
                            .font(.caption)
                        }
                        .font(.caption)
                    }
                }

                sidebarSection("结果管理") {
                    HStack {
                        Button(action: model.openRunsDirectory) {
                            Label("打开结果目录", systemImage: "folder")
                        }
                        Spacer()
                        Button(action: model.refreshRunHistory) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新历史结果")
                    }

                    if model.recentRuns.isEmpty {
                        Text("还没有算法运行结果")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.recentRuns.prefix(5))) { record in
                            HStack(spacing: 7) {
                                Button {
                                    isPlaying = false
                                    model.loadRun(record)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.displayName)
                                            .lineLimit(1)
                                        Text(runDate(record.modifiedAt))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.revealRun(record)
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                                .help("在 Finder 中显示")
                            }
                        }
                    }
                }

                sidebarSection("显示内容") {
                    routeToggle("真实路线", color: .white, isOn: $model.showTrueRoute)
                    routeToggle(
                        "PDR 路线",
                        color: Color(red: 0.10, green: 0.84, blue: 0.92),
                        isOn: $model.showPDR
                    )
                    routeToggle(
                        "PF 地磁匹配",
                        color: Color(red: 1.0, green: 0.78, blue: 0.16),
                        isOn: $model.showPF
                    )
                    routeToggle(
                        "PF 置信范围",
                        color: .green,
                        isOn: $model.showPFConfidence
                    )
                    .disabled(model.result?.pfConfidenceHistory?.isEmpty != false)
                }

                sidebarSection("路径播放") {
                    Slider(value: $model.playbackProgress, in: 0...1)
                    HStack {
                        Button {
                            if model.playbackProgress >= 1.0 {
                                model.playbackProgress = 0
                            }
                            isPlaying.toggle()
                        } label: {
                            Label(isPlaying ? "暂停" : "播放", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("显示全部") {
                            isPlaying = false
                            model.playbackProgress = 1.0
                        }
                    }
                    Text("进度 \(Int(model.playbackProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let result = model.result {
                    sidebarSection("当前数据") {
                        infoRow("数据集", result.datasetKey)
                        infoRow("路线", result.routeLabel)
                        infoRow("检测步数", value(result.stepsDetected))
                        infoRow("使用帧数", value(result.sensorFramesUsed))
                        if let smoothingMode = result.pfSmoothingMode {
                            infoRow("PF 平滑", smoothingMode)
                        }
                        if let headingSnap = result.headingSnapDegrees {
                            infoRow("航向约束", headingSnap == 0 ? "关闭" : "\(number(headingSnap))°")
                        }
                        if let stepScale = result.stepLengthScale {
                            infoRow("步长比例", number(stepScale))
                        }
                        if let confidence = result.finalPFConfidence {
                            infoRow(
                                "PF 可靠度",
                                "\(confidence.localizedLevel) · \(Int((confidence.score * 100).rounded()))%"
                            )
                            infoRow(
                                "核心粒子范围",
                                "r80 \(meters(confidence.coreRadius80M ?? confidence.radius95M))"
                            )
                        }
                        if let health = result.finalLocalizationHealth {
                            infoRow("定位状态", health.localizedStatus)
                        }
                        if let events = result.localizationRecoveryEvents, !events.isEmpty {
                            infoRow("自动恢复", "\(events.count) 次")
                        }
                        if let interval = result.activeWalkInterval {
                            infoRow(
                                "有效行走",
                                String(format: "%.1f 秒", interval.duration)
                            )
                        }
                    }
                }

                Spacer(minLength: 10)
            }
            .padding(20)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var detail: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.displayName)
                            .font(.title2.weight(.semibold))
                        Text(model.loadedFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: model.exportCurrentResult) {
                        Label("导出 PNG/CSV…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBackendRunning)

                    Text("\(result.pfTrack.count) 个定位点")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }

                if let health = result.finalLocalizationHealth,
                   health.status.lowercased() != "healthy" {
                    localizationHealthBanner(health, recoveryEvents: result.localizationRecoveryEvents ?? [])
                } else if let events = result.localizationRecoveryEvents, !events.isEmpty {
                    Label(
                        "本次运行已自动恢复 \(events.count) 次，当前定位状态稳定",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }

                TrajectoryCanvas(
                    result: result,
                    showTrueRoute: model.showTrueRoute,
                    showPDR: model.showPDR,
                    showPF: model.showPF,
                    showPFConfidence: model.showPFConfidence,
                    playbackProgress: model.playbackProgress
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                metrics(for: result)
            }
            .padding(18)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            VStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("尚未加载路径")
                    .font(.title3.weight(.semibold))
                Button("打开结果 JSON…", action: model.openResultFile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metrics(for result: PositioningResult) -> some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "PF 平均误差",
                value: meters(result.pfErrorStats?.mean),
                detail: "P95 \(meters(result.pfErrorStats?.p95))",
                color: Color(red: 1.0, green: 0.78, blue: 0.16)
            )
            MetricCard(
                title: "PF 终点误差",
                value: meters(result.pfErrorStats?.final),
                detail: "中位数 \(meters(result.pfErrorStats?.median))",
                color: Color(red: 1.0, green: 0.78, blue: 0.16)
            )
            MetricCard(
                title: "PDR 平均误差",
                value: meters(result.pdrErrorStats?.mean),
                detail: "P95 \(meters(result.pdrErrorStats?.p95))",
                color: Color(red: 0.10, green: 0.84, blue: 0.92)
            )
            MetricCard(
                title: "检测步数",
                value: value(result.stepsDetected),
                detail: "\(result.sensorFramesUsed ?? 0) 个传感器帧",
                color: .green
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var importedDatasetPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(action: model.chooseImportedDatasetDirectory) {
                Label(
                    model.importedDataset == nil ? "选择采集文件夹…" : "更换采集文件夹…",
                    systemImage: "folder.badge.plus"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(model.isBackendRunning)

            if let dataset = model.importedDataset {
                Label(dataset.directoryURL.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text(dataset.directoryURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                ForEach(dataset.streams) { stream in
                    HStack {
                        Text(stream.kind.title)
                        Spacer()
                        Text(
                            "\(stream.validRowCount) 行 · "
                                + String(format: "%.1f Hz", stream.sampleRateHz)
                        )
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                }

                DisclosureGroup("数据质量 · \(dataset.quality.grade.title)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            String(
                                format: "自动行走区间 %.2f–%.2f 秒，保留约 %d/%d 帧",
                                dataset.activeInterval.startTime,
                                dataset.activeInterval.endTime,
                                dataset.activeFrameCount,
                                dataset.estimatedFrameCount
                            ),
                            systemImage: "figure.walk.motion"
                        )
                        Text(
                            String(
                                format: "磁场中位数 %.1f µT · 范围 %.1f–%.1f µT · 突变 %d 次",
                                dataset.quality.magneticMedianUT,
                                dataset.quality.magneticRangeUT.lowerBound,
                                dataset.quality.magneticRangeUT.upperBound,
                                dataset.quality.magneticSpikeCount
                            )
                        )
                        ForEach(dataset.quality.messages, id: \.self) { message in
                            Label(message, systemImage: "info.circle")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(qualityColor(dataset.quality.grade))

                Divider()
                Text("数据集名称")
                    .font(.caption2.weight(.semibold))
                TextField("例如 route3_run1", text: $model.customDatasetName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBackendRunning)

                Text("真实路线坐标（米）")
                    .font(.caption2.weight(.semibold))
                TextField(
                    "例如 1.44,0.55; 1.44,8.25; 5.28,8.25",
                    text: $model.customRouteText,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBackendRunning)
                Text("坐标必须与所选地磁地图处于同一坐标系；分号分隔路径拐点。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text("初始航向（可选，数学角度）")
                    .font(.caption2.weight(.semibold))
                TextField("留空则由路线前两个点计算", text: $model.customInitialHeadingText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBackendRunning)

                Text("地磁地图")
                    .font(.caption2.weight(.semibold))
                Text(model.customMapPath.isEmpty ? "使用 App 内置砖块地磁地图" : model.customMapPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack {
                    Button("选择 NPZ…", action: model.chooseCustomMapFile)
                    if !model.customMapPath.isEmpty {
                        Button("恢复内置", action: model.clearCustomMap)
                    }
                    Button("重新校验", action: model.revalidateImportedDataset)
                }
                .font(.caption)
                .disabled(model.isBackendRunning)

                let routeValidation = model.routeMapValidation
                if routeValidation.wasChecked {
                    if routeValidation.isValid, let bounds = routeValidation.bounds {
                        Label(
                            String(
                                format: "路线已通过地图范围检查 · x %.2f–%.2f，y %.2f–%.2f",
                                bounds.minX,
                                bounds.maxX,
                                bounds.minY,
                                bounds.maxY
                            ),
                            systemImage: "checkmark.shield.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.green)
                    } else {
                        ForEach(routeValidation.invalidPoints) { point in
                            Label(
                                String(
                                    format: "路线第 %d 点 (%.3f, %.3f) 超出地图范围",
                                    point.index,
                                    point.x,
                                    point.y
                                ),
                                systemImage: "exclamationmark.octagon.fill"
                            )
                            .font(.caption2)
                            .foregroundStyle(.red)
                        }
                    }
                } else if !model.customMapPath.isEmpty {
                    Label("自定义 NPZ 地图将在计算开始前由后端校验范围", systemImage: "shield.lefthalf.filled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ForEach(dataset.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Label(
                model.importedDatasetStatus,
                systemImage: model.importedDatasetReady
                    ? "checkmark.seal.fill"
                    : "info.circle.fill"
            )
            .font(.caption2)
            .foregroundStyle(model.importedDatasetReady ? .green : .secondary)
        }
    }

    private var algorithmParameterPanel: some View {
        DisclosureGroup("下次运行的算法参数") {
            VStack(alignment: .leading, spacing: 11) {
                Text("这里只影响下一次计算；加载历史结果不会改动这些设置。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Picker(
                    "预设",
                    selection: Binding(
                        get: { model.selectedAlgorithmPreset },
                        set: model.applyAlgorithmPreset
                    )
                ) {
                    ForEach(AlgorithmPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .disabled(model.isBackendRunning)

                Text(model.selectedAlgorithmPreset.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                parameterLabel("PF 轨迹平滑", value: model.algorithmSettings.smoothingMode.title)
                Picker(
                    "PF 轨迹平滑",
                    selection: algorithmBinding(\.smoothingMode)
                ) {
                    ForEach(AlgorithmSettings.SmoothingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .disabled(model.isBackendRunning)

                if model.algorithmSettings.smoothingMode != .none {
                    parameterLabel("平滑权重 α", value: number(model.algorithmSettings.smoothingAlpha))
                    Slider(
                        value: algorithmBinding(\.smoothingAlpha),
                        in: 0...0.9,
                        step: 0.05
                    )
                    .disabled(model.isBackendRunning)
                }

                parameterLabel(
                    "航向网格约束",
                    value: model.algorithmSettings.headingSnapDegrees == 0
                        ? "关闭"
                        : "\(number(model.algorithmSettings.headingSnapDegrees))°"
                )
                Picker(
                    "航向网格约束",
                    selection: algorithmBinding(\.headingSnapDegrees)
                ) {
                    Text("关闭（实际场景）").tag(0.0)
                    Text("45° 网格").tag(45.0)
                    Text("90° 网格").tag(90.0)
                }
                .labelsHidden()
                .disabled(model.isBackendRunning)

                parameterLabel("步长比例", value: number(model.algorithmSettings.stepLengthScale))
                Slider(
                    value: algorithmBinding(\.stepLengthScale),
                    in: 0.7...1.3,
                    step: 0.01
                )
                .disabled(model.isBackendRunning)

                Toggle(
                    "PF 联合估计步长与航向偏差",
                    isOn: algorithmBinding(\.jointCalibrationEnabled)
                )
                .font(.caption)
                .disabled(model.isBackendRunning)

                Toggle(
                    "实验性三轴矢量地图",
                    isOn: algorithmBinding(\.vectorMapEnabled)
                )
                .font(.caption)
                .disabled(model.isBackendRunning)

                Button("恢复当前优化基线", action: model.resetAlgorithmSettings)
                    .font(.caption)
                    .disabled(model.isBackendRunning)
            }
            .padding(.top, 7)
        }
        .font(.caption)
    }

    private func algorithmBinding<Value>(
        _ keyPath: WritableKeyPath<AlgorithmSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.algorithmSettings[keyPath: keyPath] },
            set: { model.updateAlgorithmSetting(keyPath, to: $0) }
        )
    }

    private func parameterLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
    }

    private func qualityColor(_ grade: CaptureQualityGrade) -> Color {
        switch grade {
        case .usable: .green
        case .attention: .orange
        case .notRecommended: .red
        }
    }

    private func localizationHealthColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "healthy": .green
        case "degraded": .orange
        case "ambiguous": .orange
        case "recovering": .blue
        default: .red
        }
    }

    private func localizationHealthBanner(
        _ health: LocalizationHealthSample,
        recoveryEvents: [LocalizationHealthSample]
    ) -> some View {
        let color = localizationHealthColor(health.status)
        let title = health.localizedAction ?? "定位\(health.localizedStatus)"
        let detail = "可靠度 \(Int((health.score * 100).rounded()))%"
            + " · 连续低可靠 \(health.lowConfidenceStreak) 步"
            + (recoveryEvents.isEmpty ? "" : " · 已恢复 \(recoveryEvents.count) 次")
        return HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: health.status == "lost"
                    ? "location.slash.fill"
                    : health.status == "degraded"
                        ? "sensor.tag.radiowaves.forward.fill"
                        : "exclamationmark.triangle.fill"
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private func routeToggle(_ title: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(color)
                    .frame(width: 22, height: 4)
                    .overlay(Capsule().stroke(.black.opacity(0.18), lineWidth: 0.5))
                Text(title)
            }
        }
        .toggleStyle(.switch)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1)
        }
        .font(.caption)
    }

    private func meters(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f m", value)
    }

    private func number(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }

    private func value(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    private func runDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct BackendLogView: View {
    let log: String
    let status: String
    let isRunning: Bool
    let copyAction: () -> Void
    let clearAction: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("定位算法运行日志")
                        .font(.title2.weight(.semibold))
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("复制", action: copyAction)
                Button("清空", action: clearAction)
                    .disabled(isRunning)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView([.horizontal, .vertical]) {
                Text(log.isEmpty ? "暂无日志" : log)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 500)
    }
}
