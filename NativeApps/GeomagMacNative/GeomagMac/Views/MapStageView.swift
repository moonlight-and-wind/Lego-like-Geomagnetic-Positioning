import SwiftUI

struct MapStageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme
    @State private var showRemoveConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            mapList
                .frame(width: 260)
            Rectangle()
                .fill(theme.hairlineSoft)
                .frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
                    header
                    preflightPanel
                    if let entry = model.mapForCurrentSelection {
                        mapDetail(entry)
                    } else {
                        emptyDetail
                    }
                    buildPanel
                }
                .padding(ThemeMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.inspectorVisible {
                Rectangle()
                    .fill(theme.hairlineSoft)
                    .frame(width: 1)
                ScrollView {
                    mapInspector
                        .padding(14)
                }
                .frame(width: ThemeMetrics.inspectorWidth)
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .background(theme.canvas)
        .confirmationDialog(
            "移除所选磁图？",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("移除磁图", role: .destructive) {
                model.removeSelectedMagneticMap()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除用户磁图文件；内置磁图不可删除。此操作不可撤销。")
        }
    }

    private var mapList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "磁图库", trailing: "\(model.magneticMaps.count)")
                Button {
                    model.refreshMagneticMaps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .help("重新读取磁图目录")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)

            Text(
                model.runInputMode == .bundled
                    ? "内置留出数据自动使用同组磁图"
                    : "选择一张覆盖当前区域的磁图"
            )
            .font(ThemeFont.caption(9))
            .foregroundStyle(theme.faint)
            .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    let builtIn = model.magneticMaps.filter { $0.isBuiltIn }
                    let user = model.magneticMaps.filter { !$0.isBuiltIn }
                    if !builtIn.isEmpty {
                        listLabel("内置")
                        ForEach(builtIn) { entry in
                            mapRow(entry)
                        }
                    }
                    if !user.isEmpty {
                        listLabel("用户")
                        ForEach(user) { entry in
                            mapRow(entry)
                        }
                    }
                    if model.magneticMaps.isEmpty {
                        Text("还没有磁图。先在 01 导入第一次采集并建立磁图。")
                            .font(ThemeFont.caption(9.5))
                            .foregroundStyle(theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
        }
        .background(theme.surface)
    }

    private func listLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(ThemeFont.micro(8, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(theme.faint)
            .padding(.top, 5)
            .padding(.bottom, 2)
    }

    private func mapRow(_ entry: GenericMagneticMapStore.Entry) -> some View {
        let active = model.mapForCurrentSelection?.id == entry.id
        let selectable = model.runInputMode == .imported
        return Button {
            if selectable {
                model.selectedMagneticMapID = entry.id
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.document.name)
                        .font(ThemeFont.title(11, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.isBuiltIn {
                        Text("内置")
                            .font(ThemeFont.micro(7.5))
                            .foregroundStyle(theme.faint)
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.document.localizationMode == .routeCorridorValidation ? "路线" : "网格")
                        .font(ThemeFont.mono(8))
                        .foregroundStyle(theme.muted)
                    Text("\(entry.document.samples.count) 采样")
                        .font(ThemeFont.mono(8))
                        .foregroundStyle(theme.faint)
                    Spacer(minLength: 4)
                    Text(gradeText(entry))
                        .font(ThemeFont.caption(8))
                        .foregroundStyle(gradeColor(entry))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .fill(active ? theme.surfaceSecondary : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.signal)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
            .opacity(selectable || active ? 1 : 0.58)
        }
        .buttonStyle(.plain)
        .help(
            selectable
                ? entry.document.localizationMode.summary
                : "内置留出数据自动使用同组磁图"
        )
    }

    private func gradeText(_ entry: GenericMagneticMapStore.Entry) -> String {
        if let grade = entry.document.qualityReport?.grade {
            return grade.rawValue
        }
        return entry.document.localizationMode == .routeCorridorValidation
            ? "路线磁图" : "无质量数据"
    }

    private func gradeColor(_ entry: GenericMagneticMapStore.Entry) -> Color {
        guard let grade = entry.document.qualityReport?.grade else {
            return theme.faint
        }
        switch grade {
        case .excellent, .good: return theme.trace
        case .needsMoreData: return theme.warn
        case .poor: return theme.danger
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("02 · 磁图")
                    .font(ThemeFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(theme.signal)
                Text("坐标地磁图")
                    .font(ThemeFont.display(20))
                    .foregroundStyle(theme.ink)
                Text("第一次采集建立磁图；后续独立采集在同一张图上定位。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 12)
            if let map = model.mapForCurrentSelection {
                StatusPill(
                    text: map.document.localizationMode.title,
                    tint: map.document.localizationMode == .roomAreaKnownStart
                        ? theme.warn : theme.signal
                )
            }
        }
    }

    private func mapDetail(_ entry: GenericMagneticMapStore.Entry) -> some View {
        let document = entry.document
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(document.name)
                        .font(ThemeFont.title(16, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(
                        "参考采集 \(document.sourceLabel)"
                            + (document.coordinateFrame.map { " · \($0)" } ?? "")
                    )
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.muted)
                }
                Spacer()
                Text(
                    document.localizationMode == .routeCorridorValidation
                        ? "允许沿程、拐点和闭合约束"
                        : "PF 不读取真实路线形状"
                )
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.faint)
            }

            if let report = document.qualityReport {
                HStack(spacing: 8) {
                    qualityStat("综合质量", report.grade.rawValue, tint: gradeColor(entry))
                    qualityStat(
                        "有效覆盖",
                        "\(Int((report.coverageRatio * 100).rounded()))%",
                        tint: theme.ink
                    )
                    qualityStat(
                        "有效 / 总网格",
                        "\(report.coveredCellCount)/\(report.expectedCellCount)",
                        tint: theme.ink
                    )
                    qualityStat(
                        "每格样本中位数",
                        "\(report.medianObservationCount)",
                        tint: theme.ink
                    )
                }

                MagneticMapHeatmap(report: report)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius)
                            .stroke(theme.plotInk.opacity(0.12), lineWidth: 1)
                    }

                HStack(spacing: 16) {
                    legend("质量良好", theme.trace)
                    legend("单一方向", theme.signal)
                    legend("样本不足", theme.warn)
                    legend("高方差", theme.danger)
                    legend("缺失 / 障碍", theme.faint.opacity(0.45))
                    Spacer()
                }
                .font(ThemeFont.caption(9))

                ForEach(report.messages, id: \.self) { message in
                    Label(message, systemImage: "info.circle")
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.muted)
                }
            } else {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        RoutePreview(
                            points: document.referenceRoute,
                            bounds: document.bounds,
                            canvasHeight: 220
                        )
                        Label(
                            "路线磁图不生成房间覆盖热力图；定位只沿参考路线附近的窄带生效。",
                            systemImage: "info.circle"
                        )
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.muted)
                        Text(
                            "参考路线 \(document.referenceRoute.count) 个点 · "
                                + "支持半径 \(String(format: "%.2f m", document.supportRadiusM))"
                        )
                        .font(ThemeFont.mono(9))
                        .foregroundStyle(theme.faint)
                    }
                }
            }
        }
    }

    private var emptyDetail: some View {
        Panel {
            VStack(spacing: 9) {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(theme.muted)
                Text("还没有可用的磁图")
                    .font(ThemeFont.title(13))
                    .foregroundStyle(theme.ink)
                Text("先在 01 导入第一次采集，再用它建立磁图。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
                PlateButton(
                    title: "去 01 导入采集",
                    systemImage: "arrow.left",
                    kind: .secondary
                ) {
                    model.go(to: .data)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private var buildPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "用当前采集建立磁图", trailing: "0.25 m 网格")
                if let dataset = model.importedDataset {
                    Text(dataset.directoryURL.lastPathComponent)
                        .font(ThemeFont.mono(9))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    FieldSlot {
                        TextField(
                            "新磁图名称，例如 room_a",
                            text: $model.newMagneticMapName
                        )
                        .textFieldStyle(.plain)
                        .font(ThemeFont.label(11))
                        .foregroundStyle(theme.ink)
                    }
                    HStack(spacing: 8) {
                        PlateButton(
                            title: "用当前采集建立磁图",
                            systemImage: "map.badge.plus",
                            kind: .secondary,
                            isEnabled: model.canBuildMapFromImportedDataset
                                && !model.isMagneticMapBuilding
                                && !model.isBackendRunning
                        ) {
                            model.buildMagneticMapFromImportedDataset()
                        }
                        if model.isMagneticMapBuilding {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Spacer()
                    }
                    Text(
                        "同名用户磁图会按网格中位数合并；内置磁图不可覆盖；建图采集不能用于自我验证。"
                    )
                    .font(ThemeFont.caption(9))
                    .foregroundStyle(theme.faint)
                    Text(model.magneticMapStatus)
                        .font(ThemeFont.caption(9))
                        .foregroundStyle(theme.muted)
                } else {
                    HStack(spacing: 8) {
                        Text(
                            model.runInputMode == .bundled
                                ? "当前没有导入采集；内置留出数据使用预置磁图。"
                                : "当前没有导入采集；先在 01 导入第一次采集，才能建立或合并磁图。"
                        )
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.muted)
                        Spacer()
                        PlateButton(
                            title: "去 01 导入采集",
                            systemImage: "arrow.left",
                            kind: .ghost
                        ) {
                            model.go(to: .data)
                        }
                    }
                }
            }
        }
    }

    private var preflightPanel: some View {
        let readiness = model.pipelineReadiness
        let routeReady = readiness.routeReady
        let notSelf = !(model.runInputMode == .imported && model.selectedMapUsesCurrentDataset)
        let frameMatches = model.coordinateFrameMatchesSelectedMap
        let headingReady = readiness.headingReady
        return Panel {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeader(title: "运行前检查", trailing: "5 项")
                checkRow(
                    "磁图已选择",
                    detail: model.mapForCurrentSelection?.document.name ?? "尚未选择磁图",
                    passed: model.mapForCurrentSelection != nil,
                    issue: "先在左侧选择一张磁图。"
                )
                checkRow(
                    "覆盖当前路线",
                    detail: routeReady ? "路线在磁图范围内" : "路线有点超出磁图范围",
                    passed: routeReady,
                    issue: "回到 01 调整真实路线，或换一张覆盖范围更大的磁图。"
                )
                checkRow(
                    "参考采集不是当前采集",
                    detail: notSelf ? "未使用建图数据自我验证" : "当前采集就是建图数据",
                    passed: notSelf,
                    issue: "换一组独立采集；建图数据不能自我验证。"
                )
                checkRow(
                    "坐标系一致",
                    detail: frameMatches ? "采集与磁图坐标系一致" : "采集与磁图坐标系不一致",
                    passed: frameMatches,
                    issue: "选择另一张坐标系相同的磁图，或回到 01 检查 coordinate_frame。"
                )
                checkRow(
                    "房间模式已有初始航向",
                    detail: headingReady ? "航向已就绪" : "房间自由定位需要显式初始航向",
                    passed: headingReady,
                    issue: "回到 01 填写初始航向（数学角度）。"
                )
                HStack {
                    Spacer()
                    if readiness.dataReady
                        && readiness.mapReady
                        && routeReady
                        && headingReady {
                        Label("可以进入 03 运行", systemImage: "checkmark.seal.fill")
                            .font(ThemeFont.caption(9.5))
                            .foregroundStyle(theme.trace)
                    }
                }
            }
        }
    }

    private func checkRow(
        _ title: String,
        detail: String,
        passed: Bool,
        issue: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(passed ? theme.trace : theme.danger)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThemeFont.label(10.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                Text(passed ? detail : issue)
                    .font(ThemeFont.caption(9))
                    .foregroundStyle(passed ? theme.muted : theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !passed, title == "覆盖当前路线" || title == "房间模式已有初始航向" {
                PlateButton(title: "去 01", kind: .ghost) {
                    model.go(to: .data)
                }
            }
        }
    }

    private var mapInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "磁图信息")
            if let entry = model.mapForCurrentSelection {
                let document = entry.document
                VStack(spacing: 5) {
                    infoRow("名称", document.name)
                    infoRow("来源", document.sourceLabel)
                    infoRow("类型", entry.isBuiltIn ? "内置" : "用户")
                    infoRow("坐标系", document.coordinateFrame ?? "—")
                    infoRow(
                        "网格",
                        document.gridCellSizeM.map { String(format: "%.2f m", $0) } ?? "路线"
                    )
                    infoRow("采样", "\(document.samples.count)")
                    infoRow("参考路线", "\(document.referenceRoute.count) 点")
                    infoRow("建立时间", Self.dateFormatter.string(from: document.createdAt))
                    if let scale = document.pdrStepLengthScale {
                        infoRow("步长比例", String(format: "%.3f", scale))
                    }
                }

                if let divergence = document.sourceDivergence {
                    Hairline()
                    SectionHeader(title: "跨会话分歧")
                    Text(
                        "\(divergence.divergentCellCount)/\(divergence.comparedCellCount) 格超阈值 "
                            + String(format: "%.1f µT · 中位 %.1f · 峰值 %.1f",
                                     divergence.thresholdUT,
                                     divergence.medianDivergenceUT,
                                     divergence.maximumDivergenceUT)
                    )
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(divergence.hasDivergence ? theme.warn : theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Hairline()
                SectionHeader(title: "操作")
                VStack(spacing: 6) {
                    PlateButton(
                        title: "打开磁图目录",
                        systemImage: "folder",
                        kind: .ghost
                    ) {
                        model.openMagneticMapDirectory()
                    }
                    if !entry.isBuiltIn {
                        PlateButton(
                            title: "移除所选用户磁图",
                            systemImage: "trash",
                            kind: .danger
                        ) {
                            showRemoveConfirmation = true
                        }
                    }
                }
            } else {
                Text("尚未选择磁图。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
            }

            Hairline()
            SectionHeader(title: "状态")
            Text(model.selectedMapSummary)
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if model.isMagneticMapBuilding {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func qualityStat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(ThemeFont.caption(8.5))
                .foregroundStyle(theme.faint)
            Text(value)
                .font(ThemeFont.mono(14, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
                .foregroundStyle(theme.muted)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.muted)
            Spacer(minLength: 4)
            Text(value)
                .font(ThemeFont.mono(9))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct MagneticMapHeatmap: View {
    let report: MagneticMapQualityReport

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        Canvas { context, size in
            let columns = max(report.maximumGridX - report.minimumGridX + 1, 1)
            let rows = max(report.maximumGridY - report.minimumGridY + 1, 1)
            let padding = 14.0
            let availableWidth = max(size.width - 2 * padding, 1)
            let availableHeight = max(size.height - 2 * padding, 1)
            let cellSize = min(availableWidth / Double(columns), availableHeight / Double(rows))
            let gridWidth = cellSize * Double(columns)
            let gridHeight = cellSize * Double(rows)
            let originX = (size.width - gridWidth) / 2
            let originY = (size.height - gridHeight) / 2

            for cell in report.cells {
                let column = cell.gridX - report.minimumGridX
                let row = report.maximumGridY - cell.gridY
                let rect = CGRect(
                    x: originX + Double(column) * cellSize + 0.7,
                    y: originY + Double(row) * cellSize + 0.7,
                    width: max(cellSize - 1.4, 1),
                    height: max(cellSize - 1.4, 1)
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(cellSize * 0.15, 3)),
                    with: .color(color(for: cell.status))
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius)
                .fill(theme.plotBackground)
        )
        .accessibilityLabel("二维地磁图覆盖热力图")
    }

    private func color(for status: MagneticMapCellStatus) -> Color {
        switch status {
        case .missing: theme.faint.opacity(0.28)
        case .good: theme.trace.opacity(0.9)
        case .sparse: theme.warn.opacity(0.92)
        case .singleDirection: theme.signal.opacity(0.88)
        case .noisy: theme.danger.opacity(0.92)
        }
    }
}
