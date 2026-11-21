import SwiftUI

struct DataStageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: ThemeMetrics.sectionGap) {
                    header
                    sourceSection
                    if model.runInputMode == .bundled {
                        bundledSection
                        nextStepsCard
                    } else {
                        importedSection
                    }
                    readinessFooter
                }
                .padding(ThemeMetrics.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.inspectorVisible {
                Rectangle()
                    .fill(theme.hairlineSoft)
                    .frame(width: 1)
                ScrollView {
                    DataInspectorView()
                        .padding(14)
                }
                .frame(width: ThemeMetrics.inspectorWidth)
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .background(theme.canvas)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("01 · 数据")
                    .font(ThemeFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(theme.signal)
                Text("采集数据")
                    .font(ThemeFont.display(20))
                    .foregroundStyle(theme.ink)
                Text("确认采集包、真实路线和起点；任何一项不完整都会在阶段条上标红。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
            }
            Spacer(minLength: 12)
            PlateButton(
                title: "打开结果 JSON…",
                systemImage: "folder",
                kind: .ghost
            ) {
                model.openResultFile()
            }
        }
    }

    private var sourceSection: some View {
        HStack(spacing: 12) {
            SegmentedRail(
                items: RunInputMode.allCases,
                title: { $0 == .bundled ? "内置留出数据" : "导入采集" },
                selection: $model.runInputMode
            )
            .frame(maxWidth: 360)
            Text(sourceHint)
                .font(ThemeFont.caption(10))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .onChange(of: model.runInputMode) { _, mode in
            if mode == .bundled {
                model.selectMagneticMapForBundledDataset()
            }
        }
    }

    private var sourceHint: String {
        switch model.runInputMode {
        case .bundled:
            "内置原始传感器 CSV，路线与磁图已预设；也可以打开预计算示例直接看分析。"
        case .imported:
            "支持 iPhone / HarmonyOS 采集文件夹；拖进窗口任意位置即可导入。"
        }
    }

    private var bundledSection: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "内置留出数据", trailing: "无需导入")
                FieldSlot {
                    Picker("", selection: $model.selectedRunDatasetID) {
                        ForEach(AppModel.runnableDatasets) { sample in
                            Text(sample.title).tag(sample.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.selectedRunDatasetID) { _, _ in
                    model.selectMagneticMapForBundledDataset()
                }
                Text("第一次采集已用于建立坐标磁图；这里的第 2/3 次采集是独立留出验证。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
                HStack(spacing: 28) {
                    readout("数据组", datasetGroup(model.selectedRunDatasetID))
                    readout("磁图", model.mapForCurrentSelection?.document.name ?? "—")
                    readout("模式", model.currentLocalizationMode?.title ?? "—")
                    readout("磁图网格", model.mapForCurrentSelection.map { "\($0.document.samples.count)" } ?? "—")
                }
                if model.mapForCurrentSelection == nil {
                    NoticeBanner(
                        severity: .warn,
                        message: "缺少这个数据组的内置磁图；请先在 02 建立磁图或导入自己的采集。"
                    )
                }
            }
        }
    }

    private var nextStepsCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "接下来三步", trailing: "内置示例")
                nextStepRow(
                    "02",
                    "磁图",
                    "确认 \(model.mapForCurrentSelection?.document.name ?? "磁图") 覆盖这次留出路线",
                    tint: theme.signal
                )
                nextStepRow(
                    "03",
                    "运行",
                    "用 \(model.selectedAlgorithmPreset.title) 运行 PDR + PF，完成后自动进入分析",
                    tint: theme.trace
                )
                nextStepRow(
                    "04",
                    "分析",
                    "在画布上播放、逐步核对，再导出 PNG / PDF",
                    tint: theme.warn
                )
            }
        }
    }

    private func nextStepRow(
        _ number: String,
        _ title: String,
        _ detail: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(ThemeFont.mono(9, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(tint.opacity(0.10)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThemeFont.label(11, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Text(detail)
                    .font(ThemeFont.caption(9.5))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var importedSection: some View {
        if let dataset = model.importedDataset {
            datasetCard(dataset)
            routeEditor
            importedActions
        } else {
            importDropZone
        }
    }

    private var importDropZone: some View {
        Panel {
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(theme.signal)
                Text("把采集文件夹拖进来")
                    .font(ThemeFont.title(14))
                    .foregroundStyle(theme.ink)
                Text("或点击选择 iPhone / HarmonyOS 导出的采集文件夹")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
                PlateButton(
                    title: "选择采集文件夹…",
                    systemImage: "folder.badge.plus",
                    kind: .primary
                ) {
                    model.chooseImportedDatasetDirectory()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private func datasetCard(_ dataset: ImportedDataset) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(dataset.directoryURL.lastPathComponent)
                        .font(ThemeFont.title(14))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    StatusPill(
                        text: dataset.quality.grade.title,
                        tint: qualityColor(dataset.quality.grade)
                    )
                }
                Text(dataset.directoryURL.path)
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .textSelection(.enabled)

                HStack(spacing: 28) {
                    readout(
                        "有效帧",
                        "\(dataset.activeFrameCount)/\(dataset.estimatedFrameCount)"
                    )
                    readout("行走区间", String(format: "%.1f–%.1f s", dataset.activeInterval.startTime, dataset.activeInterval.endTime))
                    readout(
                        "时间重叠",
                        String(format: "%.1f s", dataset.overlapDuration)
                    )
                    readout("坐标锚点", "\(dataset.spatialAnchors.count)")
                    readout("坐标系", dataset.coordinateFrame ?? "—")
                }

                Hairline()
                HStack(spacing: 18) {
                    ForEach(dataset.streams) { stream in
                        HStack(spacing: 5) {
                            Text(stream.kind.title)
                                .foregroundStyle(theme.muted)
                            Text(
                                "\(stream.validRowCount) 行 · "
                                    + String(format: "%.1f Hz", stream.sampleRateHz)
                            )
                            .foregroundStyle(theme.ink)
                        }
                        .font(ThemeFont.mono(9))
                    }
                    Spacer()
                }

                ForEach(dataset.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.warn)
                }
            }
        }
    }

    private var routeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "真实路线", trailing: "\(routeRows.count) 个点")
            Text("白线按这里的坐标顺序连线，不是传感器自动还原的轨迹；请确认点序与实际行走一致。")
                .font(ThemeFont.caption(10))
                .foregroundStyle(theme.muted)

            FieldSlot {
                TextField(
                    "例如 1.44,0.55; 1.44,8.25; 5.28,8.25",
                    text: $model.customRouteText,
                    axis: .vertical
                )
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(ThemeFont.mono(11))
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 10) {
                RoutePointList(rows: routeRows)
                    .frame(maxWidth: .infinity)
                RoutePreview(points: routePoints, bounds: model.selectedMapBounds)
                    .frame(maxWidth: .infinity)
            }

            HStack(alignment: .top, spacing: 12) {
                labeledField(
                    title: "数据集名称",
                    hint: "例如 route3_run1",
                    text: $model.customDatasetName
                )
                labeledField(
                    title: "初始航向（可选，数学角度）",
                    hint: "留空则由路线前两个点计算",
                    text: $model.customInitialHeadingText
                )
            }

            validationSummary
        }
    }

    @ViewBuilder
    private var validationSummary: some View {
        if let issue = model.routeGeometryIssue {
            NoticeBanner(severity: .error, message: issue)
        } else if !model.routeMapValidation.isValid {
            let points = model.routeMapValidation.invalidPoints.prefix(3)
            let message = points.map {
                String(
                    format: "路线第 %d 点 (%.2f, %.2f) 超出磁图范围",
                    $0.index,
                    $0.x,
                    $0.y
                )
            }.joined(separator: "；")
            NoticeBanner(severity: .error, message: message)
        } else if model.routeMapValidation.wasChecked {
            Label("路线已通过地图范围检查", systemImage: "checkmark.shield.fill")
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.trace)
        }
    }

    private var importedActions: some View {
        HStack(spacing: 8) {
            PlateButton(
                title: "重新校验",
                systemImage: "arrow.clockwise",
                kind: .secondary
            ) {
                model.revalidateImportedDataset()
            }
            PlateButton(
                title: "更换文件夹…",
                systemImage: "folder",
                kind: .ghost
            ) {
                model.chooseImportedDatasetDirectory()
            }
            Spacer()
            Text("路线坐标单位：米")
                .font(ThemeFont.mono(8.5))
                .foregroundStyle(theme.faint)
        }
    }

    @ViewBuilder
    private var readinessFooter: some View {
        if let issue = model.pipelineReadiness.issues.first {
            NoticeBanner(severity: .warn, message: issue.message)
        } else {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("数据就绪，可以进入磁图。")
                    .font(ThemeFont.caption(10))
                Spacer()
                PlateButton(
                    title: "下一步：磁图",
                    systemImage: "arrow.right",
                    kind: .secondary
                ) {
                    model.advanceFromCurrentStage()
                }
            }
            .foregroundStyle(theme.trace)
        }
    }

    private var routeRows: [EditableRoutePoint] {
        RouteTextParser.points(
            from: model.customRouteText,
            mapBounds: model.selectedMapBounds
        )
    }

    private var routePoints: [XYPoint] {
        routeRows.compactMap(\.point)
    }

    private func labeledField(
        title: String,
        hint: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(ThemeFont.caption(9, weight: .semibold))
                .foregroundStyle(theme.muted)
            FieldSlot {
                TextField(hint, text: text)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.label(11))
                    .foregroundStyle(theme.ink)
            }
        }
    }

    private func readout(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(ThemeFont.caption(8.5))
                .foregroundStyle(theme.faint)
            Text(value)
                .font(ThemeFont.mono(11, weight: .medium))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
    }

    private func datasetGroup(_ key: String) -> String {
        key.replacingOccurrences(
            of: #"_\d+$"#,
            with: "",
            options: .regularExpression
        )
    }

    private func qualityColor(_ grade: CaptureQualityGrade) -> Color {
        switch grade {
        case .usable: theme.trace
        case .attention: theme.warn
        case .notRecommended: theme.danger
        }
    }
}

private struct RoutePointList: View {
    let rows: [EditableRoutePoint]

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "解析点序")
            if rows.isEmpty {
                Text("还没有路线点")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.faint)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", row.id + 1))
                                    .font(ThemeFont.mono(8.5))
                                    .foregroundStyle(theme.faint)
                                    .frame(width: 18, alignment: .trailing)
                                Text(pointText(row))
                                    .font(ThemeFont.mono(9.5))
                                    .foregroundStyle(row.point == nil ? theme.danger : theme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(statusText(row))
                                    .font(ThemeFont.caption(8.5))
                                    .foregroundStyle(statusColor(row))
                            }
                            .frame(height: 22)
                            if row.id != rows.last?.id {
                                Hairline()
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private func pointText(_ row: EditableRoutePoint) -> String {
        guard let point = row.point else {
            return row.raw.isEmpty ? "空点" : row.raw
        }
        return String(format: "x %.2f   y %.2f", point.x, point.y)
    }

    private func statusText(_ row: EditableRoutePoint) -> String {
        if row.point == nil { return "格式错误" }
        if row.isDuplicate { return "重复点" }
        if row.isOutsideMap { return "越界" }
        return "OK"
    }

    private func statusColor(_ row: EditableRoutePoint) -> Color {
        if row.point == nil || row.isDuplicate || row.isOutsideMap {
            return theme.danger
        }
        return theme.trace
    }
}

struct RoutePreview: View {
    let points: [XYPoint]
    let bounds: CoordinateBounds?
    var canvasHeight: CGFloat = 124

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "路线预览")
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.surfaceSecondary)
                if points.count >= 2 {
                    Canvas { context, size in
                        let rect = CGRect(origin: .zero, size: size)
                            .insetBy(dx: 12, dy: 12)
                        let projection = PreviewProjection(
                            bounds: bounds ?? Self.bounds(for: points),
                            rect: rect
                        )
                        if let bounds {
                            let corners = [
                                XYPoint(x: bounds.minX, y: bounds.minY),
                                XYPoint(x: bounds.maxX, y: bounds.minY),
                                XYPoint(x: bounds.maxX, y: bounds.maxY),
                                XYPoint(x: bounds.minX, y: bounds.maxY),
                            ]
                            var frame = Path()
                            frame.move(to: projection.screen(corners[0]))
                            for corner in corners.dropFirst() {
                                frame.addLine(to: projection.screen(corner))
                            }
                            frame.closeSubpath()
                            context.stroke(
                                frame,
                                with: .color(theme.hairline),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                        }

                        var route = Path()
                        route.move(to: projection.screen(points[0]))
                        for point in points.dropFirst() {
                            route.addLine(to: projection.screen(point))
                        }
                        context.stroke(
                            route,
                            with: .color(theme.signal),
                            style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        let start = projection.screen(points[0])
                        context.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: start.x - 3,
                                    y: start.y - 3,
                                    width: 6,
                                    height: 6
                                )
                            ),
                            with: .color(theme.trace)
                        )
                    }
                } else {
                    Text("至少 2 个点")
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.faint)
                }
            }
            .frame(height: canvasHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.hairlineSoft, lineWidth: 1)
            }
        }
    }

    private static func bounds(for points: [XYPoint]) -> CoordinateBounds {
        var minX = points.first?.x ?? 0
        var maxX = minX
        var minY = points.first?.y ?? 0
        var maxY = minY
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let pad = 0.35
        return CoordinateBounds(
            minX: minX - pad,
            maxX: maxX + pad,
            minY: minY - pad,
            maxY: maxY + pad
        )
    }
}

private struct PreviewProjection {
    let bounds: CoordinateBounds
    let rect: CGRect

    func screen(_ point: XYPoint) -> CGPoint {
        let width = max(bounds.maxX - bounds.minX, 0.001)
        let height = max(bounds.maxY - bounds.minY, 0.001)
        let scale = min(rect.width / width, rect.height / height)
        let plotWidth = width * scale
        let plotHeight = height * scale
        let originX = rect.minX + (rect.width - plotWidth) / 2
        let originY = rect.minY + (rect.height - plotHeight) / 2
        return CGPoint(
            x: originX + (point.x - bounds.minX) * scale,
            y: originY + (bounds.maxY - point.y) * scale
        )
    }
}

private struct DataInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "数据集")
            if let dataset = model.importedDataset {
                VStack(alignment: .leading, spacing: 5) {
                    Text(dataset.directoryURL.lastPathComponent)
                        .font(ThemeFont.title(12))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(
                        "\(dataset.quality.grade.title) · 磁场中位数 "
                            + String(format: "%.1f µT", dataset.quality.magneticMedianUT)
                    )
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.muted)
                    Text(
                        "范围 "
                            + String(
                                format: "%.1f–%.1f µT",
                                dataset.quality.magneticRangeUT.lowerBound,
                                dataset.quality.magneticRangeUT.upperBound
                            )
                            + " · 突变 \(dataset.quality.magneticSpikeCount) 次"
                    )
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.muted)
                    if dataset.spatialAnchors.count > 0 {
                        Text("锚点 \(dataset.spatialAnchors.count) 个 · \(dataset.coordinateFrame ?? "未命名坐标系")")
                            .font(ThemeFont.mono(9))
                            .foregroundStyle(
                                dataset.spatialAnchors.count >= 2 ? theme.trace : theme.warn
                            )
                    }
                }
            } else {
                Text(model.runInputMode == .bundled ? "使用内置留出数据。" : "尚未选择采集文件夹。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
            }

            Hairline()

            SectionHeader(title: "内置结果预览")
            FieldSlot {
                Picker("", selection: $model.selectedSampleID) {
                    ForEach(AppModel.samples) { sample in
                        Text(sample.title).tag(sample.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.selectedSampleID) { _, id in
                model.loadBundledSample(id: id)
            }
            Text("打开预计算示例会进入 04 分析，不会改动当前导入管线。")
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.faint)

            Hairline()

            SectionHeader(title: "路线与起点")
            VStack(spacing: 5) {
                infoRow(
                    "路线点数",
                    model.runInputMode == .bundled
                        ? "内置 \(model.result?.routeXY.count ?? 5) 点"
                        : "\(RouteTextParser.points(from: model.customRouteText).count)"
                )
                infoRow(
                    "地图范围",
                    model.selectedMapBounds.map {
                        String(
                            format: "x %.2f–%.2f · y %.2f–%.2f",
                            $0.minX,
                            $0.maxX,
                            $0.minY,
                            $0.maxY
                        )
                    } ?? "未选磁图"
                )
                infoRow(
                    "初始航向",
                    model.customInitialHeadingText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty ? "自动" : model.customInitialHeadingText
                )
                infoRow(
                    "点序状态",
                    model.routeGeometryIssue == nil ? "通过" : "需检查"
                )
            }

            if !model.importedDatasetReady && model.runInputMode == .imported {
                Hairline()
                SectionHeader(title: "还缺什么")
                ForEach(
                    model.pipelineReadiness.issues.filter { $0.stage == .data },
                    id: \.self
                ) { issue in
                    Label(issue.message, systemImage: "exclamationmark.circle")
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.warn)
                }
            }

            Hairline()

            SectionHeader(title: "操作")
            VStack(spacing: 6) {
                PlateButton(
                    title: "重新校验",
                    systemImage: "arrow.clockwise",
                    kind: .secondary
                ) {
                    model.revalidateImportedDataset()
                }
                PlateButton(
                    title: "打开结果 JSON…",
                    systemImage: "folder",
                    kind: .ghost
                ) {
                    model.openResultFile()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
