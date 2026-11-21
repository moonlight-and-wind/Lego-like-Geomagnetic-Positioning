import SwiftUI

struct RunStageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme
    @State private var showLogSheet = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
                    header
                    readinessBanner
                    connectionCard
                    modeCard
                    consoleCard
                }
                .padding(ThemeMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.inspectorVisible {
                Rectangle()
                    .fill(theme.hairlineSoft)
                    .frame(width: 1)
                ScrollView {
                    parameterInspector
                        .padding(14)
                }
                .frame(width: ThemeMetrics.inspectorWidth)
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .background(theme.canvas)
        .sheet(isPresented: $showLogSheet) {
            RunLogSheet(
                log: model.backendLog,
                status: model.backendStatusDisplay,
                isRunning: model.isBackendRunning
            )
            .geomagTheme(theme)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("03 · 运行")
                    .font(ThemeFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(theme.signal)
                Text("运行定位")
                    .font(ThemeFont.display(20))
                    .foregroundStyle(theme.ink)
                Text("确认数据与磁图配对，选择预设后开始计算；完成后自动进入分析。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 12)
            if let mode = model.currentLocalizationMode {
                StatusPill(
                    text: mode.title,
                    tint: mode == .roomAreaKnownStart ? theme.warn : theme.signal
                )
            }
        }
    }

    @ViewBuilder
    private var readinessBanner: some View {
        let readiness = model.pipelineReadiness
        if let issue = readiness.issues.first {
            NoticeBanner(
                severity: .warn,
                message: issue.message,
                actionTitle: issue.stage == .map ? "去 02" : "去 01"
            ) {
                model.go(to: issue.stage == .map ? .map : .data)
            }
        } else if readiness.canRun {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("数据、磁图与路线均已就绪，可以开始计算。")
                    .font(ThemeFont.caption(10))
                Spacer()
            }
            .foregroundStyle(theme.trace)
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 10) {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "数据", trailing: dataTag)
                    Text(dataTitle)
                        .font(ThemeFont.title(14))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(dataDetail)
                        .font(ThemeFont.mono(9))
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                }
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.faint)
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "磁图", trailing: mapTag)
                    Text(model.mapForCurrentSelection?.document.name ?? "尚未选择磁图")
                        .font(ThemeFont.title(14))
                        .foregroundStyle(
                            model.mapForCurrentSelection == nil ? theme.danger : theme.ink
                        )
                        .lineLimit(1)
                    Text(mapDetail)
                        .font(ThemeFont.mono(9))
                        .foregroundStyle(theme.muted)
                        .lineLimit(2)
                }
            }
        }
    }

    private var dataTag: String {
        model.runInputMode == .bundled ? "内置" : "导入"
    }

    private var dataTitle: String {
        if model.runInputMode == .bundled {
            return model.selectedRunDatasetID
        }
        return model.customDatasetName.isEmpty
            ? model.importedDataset?.directoryURL.lastPathComponent ?? "尚未导入采集"
            : model.customDatasetName
    }

    private var dataDetail: String {
        if model.runInputMode == .bundled {
            return "App 内置原始传感器 CSV · 留出验证"
        }
        guard let dataset = model.importedDataset else {
            return "回到 01 选择采集文件夹"
        }
        return String(
            format: "约 %d 帧 · 行走 %.1f–%.1f s · %@",
            dataset.activeFrameCount,
            dataset.activeInterval.startTime,
            dataset.activeInterval.endTime,
            dataset.quality.grade.title
        )
    }

    private var mapTag: String {
        guard let map = model.mapForCurrentSelection else { return "缺失" }
        return map.isBuiltIn ? "内置" : "用户"
    }

    private var mapDetail: String {
        guard let map = model.mapForCurrentSelection else {
            return "回到 02 选择或建立一张覆盖当前区域的磁图"
        }
        let document = map.document
        switch document.localizationMode {
        case .routeCorridorValidation:
            return "路线磁图 · \(document.samples.count) 采样 · \(document.referenceRoute.count) 个路线点"
        case .roomAreaKnownStart:
            let grade = document.qualityReport?.grade.rawValue ?? "无质量数据"
            let coverage = document.qualityReport.map {
                "\(Int(($0.coverageRatio * 100).rounded()))%"
            } ?? "—"
            return "网格 \(document.gridCellSizeM.map { String(format: "%.2f m", $0) } ?? "—") · 覆盖 \(coverage) · \(grade)"
        }
    }

    private var modeCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "运行模式与预设", trailing: model.selectedAlgorithmPreset.title)
                if let mode = model.currentLocalizationMode {
                    Text(mode.summary)
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    FieldSlot {
                        Picker(
                            "",
                            selection: Binding(
                                get: { model.selectedAlgorithmPreset },
                                set: { model.applyAlgorithmPreset($0) }
                            )
                        ) {
                            ForEach(AlgorithmPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 300)
                    Text(model.selectedAlgorithmPreset.detail)
                        .font(ThemeFont.caption(9))
                        .foregroundStyle(theme.faint)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
    }

    private var consoleCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "运行控制台")
                    Spacer()
                    if model.result != nil && !model.isBackendRunning {
                        PlateButton(
                            title: "查看当前结果",
                            systemImage: "chart.xyaxis.line",
                            kind: .ghost
                        ) {
                            model.go(to: .analysis)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Text(model.backendStatusDisplay)
                        .font(ThemeFont.caption(10))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Spacer()
                    if model.isBackendRunning {
                        Text("\(Int((model.backendProgress * 100).rounded()))%")
                            .font(ThemeFont.mono(10, weight: .medium))
                            .foregroundStyle(theme.signal)
                    } else {
                        PlateButton(
                            title: "开始计算",
                            systemImage: "play.fill",
                            kind: .secondary,
                            isEnabled: model.pipelineReadiness.canRun
                        ) {
                            model.runSelectedDataset()
                        }
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(theme.surfaceSecondary)
                        Capsule()
                            .fill(theme.signal)
                            .frame(
                                width: proxy.size.width
                                    * min(max(model.backendProgress, 0), 1)
                            )
                    }
                }
                .frame(height: 6)

                ScrollView {
                    Text(logPreview)
                        .font(ThemeFont.mono(9))
                        .foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 92, maxHeight: 130)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                        .fill(theme.surfaceSecondary)
                )

                HStack(spacing: 8) {
                    PlateButton(
                        title: "完整日志",
                        systemImage: "doc.text",
                        kind: .ghost
                    ) {
                        showLogSheet = true
                    }
                    PlateButton(
                        title: "复制",
                        systemImage: "doc.on.doc",
                        kind: .ghost
                    ) {
                        model.copyBackendLog()
                    }
                    PlateButton(
                        title: "清空",
                        systemImage: "trash",
                        kind: .ghost,
                        isEnabled: !model.isBackendRunning && !model.backendLog.isEmpty
                    ) {
                        model.clearBackendLog()
                    }
                    Spacer()
                    if model.isBackendRunning {
                        PlateButton(
                            title: "取消计算",
                            systemImage: "stop.fill",
                            kind: .danger
                        ) {
                            model.cancelBackendRun()
                        }
                    }
                }

                if !model.pipelineReadiness.canRun && !model.isBackendRunning {
                    Text(runBlockedReason)
                        .font(ThemeFont.caption(9))
                        .foregroundStyle(theme.warn)
                }
            }
        }
    }

    private var statusColor: Color {
        if model.isBackendRunning { return theme.signal }
        if model.backendStatus.contains("失败") || model.backendStatus.contains("无法") {
            return theme.danger
        }
        if model.backendStatus.contains("取消") { return theme.warn }
        return theme.muted
    }

    private var logPreview: String {
        guard !model.backendLog.isEmpty else {
            return "等待开始…"
        }
        let lines = model.backendLog.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(9).joined(separator: "\n")
    }

    private var runBlockedReason: String {
        if let issue = model.pipelineReadiness.issues.first {
            return "暂不能开始：\(issue.message)"
        }
        return "暂不能开始：请检查数据与磁图配置。"
    }

    private var parameterInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "高级参数", trailing: "只影响下一次")
            Text("这里的改动只作用于下一次计算；加载历史结果不会改动这些设置。")
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            parameterLabel(
                "PF 轨迹平滑",
                value: model.algorithmSettings.smoothingMode.title
            )
            FieldSlot {
                Picker(
                    "",
                    selection: algorithmBinding(\.smoothingMode)
                ) {
                    ForEach(AlgorithmSettings.SmoothingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.algorithmSettings.smoothingMode != .none {
                parameterLabel(
                    "平滑权重 α",
                    value: number(model.algorithmSettings.smoothingAlpha)
                )
                Slider(
                    value: algorithmBinding(\.smoothingAlpha),
                    in: 0...0.9,
                    step: 0.05
                )
                .tint(theme.signal)
            }

            parameterLabel(
                "航向吸附",
                value: model.algorithmSettings.headingSnapDegrees > 0
                    ? "\(number(model.algorithmSettings.headingSnapDegrees))°"
                    : "自适应直线"
            )
            Slider(
                value: algorithmBinding(\.headingSnapDegrees),
                in: 0...90,
                step: 5
            )
            .tint(theme.signal)

            parameterLabel(
                "步长比例",
                value: number(model.algorithmSettings.stepLengthScale)
            )
            Slider(
                value: algorithmBinding(\.stepLengthScale),
                in: 0.7...1.3,
                step: 0.01
            )
            .tint(theme.signal)

            Toggle(
                "PF 联合估计步长与航向偏差",
                isOn: algorithmBinding(\.jointCalibrationEnabled)
            )
            .font(ThemeFont.caption(10))
            .tint(theme.signal)

            Toggle(
                "实验性三轴矢量地图",
                isOn: algorithmBinding(\.vectorMapEnabled)
            )
            .font(ThemeFont.caption(10))
            .tint(theme.signal)
            .disabled(true)
            Text("原生版第一阶段使用稳定的标量地图；三轴矢量地图将在完成原生标定后启用。")
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Hairline()
            PlateButton(
                title: "恢复当前优化基线",
                systemImage: "arrow.counterclockwise",
                kind: .ghost
            ) {
                model.resetAlgorithmSettings()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parameterLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.muted)
            Spacer()
            Text(value)
                .font(ThemeFont.mono(9))
                .foregroundStyle(theme.ink)
        }
    }

    private func algorithmBinding<Value>(
        _ keyPath: WritableKeyPath<AlgorithmSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.algorithmSettings[keyPath: keyPath] },
            set: { model.updateAlgorithmSetting(keyPath, to: $0) }
        )
    }

    private func number(_ value: Double) -> String {
        String(format: value.rounded() == value ? "%.0f" : "%.2f", value)
    }
}

private struct RunLogSheet: View {
    let log: String
    let status: String
    let isRunning: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("定位算法运行日志")
                        .font(ThemeFont.display(20))
                        .foregroundStyle(theme.ink)
                    Text(status)
                        .font(ThemeFont.caption(10))
                        .foregroundStyle(theme.muted)
                }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                PlateButton(title: "完成", kind: .primary) {
                    dismiss()
                }
            }

            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(log.isEmpty ? "暂无日志" : log)
                        .font(ThemeFont.mono(11))
                        .foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("logEnd")
                }
                .background(
                    RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                        .fill(theme.surfaceSecondary)
                )
                .onAppear {
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
                .onChange(of: log) { _, _ in
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 500)
        .background(theme.canvas)
    }
}
