import SwiftUI

struct ComparisonStageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme
    @State private var viewport = PlotViewport()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !model.comparisonRoutesMatch && model.comparisonRuns.count > 1 {
                routeWarning
            }

            if !model.comparisonLoadFailures.isEmpty {
                loadFailureBanner
            }

            if model.comparisonIsLoading && model.comparisonRuns.isEmpty {
                loadingState
            } else if model.comparisonRuns.isEmpty {
                emptyState
            } else {
                if model.comparisonRuns.count == 1 {
                    singleRunHint
                }

                ComparisonPlot(
                    runs: model.comparisonRuns,
                    baselineID: model.comparisonBaselineID,
                    onSelectBaseline: { model.setComparisonBaseline(id: $0) },
                    viewport: $viewport
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                ComparisonMetricsTable(
                    runs: model.comparisonRuns,
                    baselineID: model.comparisonBaselineID,
                    routesComparable: model.comparisonRoutesMatch,
                    onSelectBaseline: { model.setComparisonBaseline(id: $0) }
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("04 · 多运行对比")
                    .font(ThemeFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(theme.signal)
                Text(model.comparisonTitle)
                    .font(ThemeFont.display(20))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(comparisonSubtitle)
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !compactCrowded,
               model.comparisonIsLoading || !model.comparisonRuns.isEmpty {
                StatusPill(
                    text: comparisonStatusText,
                    tint: theme.signal
                )
            }

            PlateButton(
                title: parameterButtonTitle,
                systemImage: "slider.horizontal.3",
                kind: .ghost
            ) {
                showParameters()
            }

            PlateButton(
                title: model.isFocusMode ? "退出专注" : "专注",
                systemImage: "arrow.up.left.and.arrow.down.right",
                kind: .ghost
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isFocusMode.toggle()
                }
            }
        }
    }

    private var compactCrowded: Bool {
        model.isCompact && model.inspectorVisible
    }

    private var comparisonStatusText: String {
        if model.comparisonIsLoading && model.comparisonRuns.isEmpty {
            return "读取中 · \(model.comparisonSelection.count) 个结果"
        }
        return "\(model.comparisonRuns.count) 次 · 基准 \(model.comparisonBaselineLetter)"
    }

    private var comparisonSubtitle: String {
        if model.comparisonRuns.isEmpty {
            return model.comparisonIsLoading
                ? "正在读取 \(model.comparisonSelection.count) 个结果…"
                : "尚未读取到结果"
        }
        let base = model.comparisonBaseline.map {
            "\($0.letter) \($0.result.datasetKey)"
        } ?? "—"
        let differences = model.comparisonParameterDifferenceCount
        let differenceText = differences == 0 ? "参数一致" : "参数差异 \(differences) 项"
        let loading = model.comparisonIsLoading
            ? "已读取 \(model.comparisonRuns.count)/\(model.comparisonSelection.count) · "
            : ""
        return "\(loading)基准 \(base) · \(differenceText)"
    }

    private var parameterButtonTitle: String {
        let differences = model.comparisonParameterDifferenceCount
        return differences == 0 ? "参数对照" : "参数差异 \(differences)"
    }

    private var routeWarning: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.warn)
                .frame(width: 2)
                .clipShape(Capsule())
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.warn)
            Text("所选运行的路线不同，轨迹叠加和误差指标只能作为参考，不能直接横向比较。")
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.warn.opacity(0.35), lineWidth: 1)
        }
    }

    private var loadFailureBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.warn)
            Text("读取失败：\(model.comparisonLoadFailures.joined(separator: "、"))")
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                model.retryComparisonLoad()
            }
            .buttonStyle(.plain)
            .font(ThemeFont.caption(9.5))
            .foregroundStyle(theme.signal)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private var loadingState: some View {
        Panel {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取 \(model.comparisonSelection.count) 个结果…")
                    .font(ThemeFont.title(13))
                    .foregroundStyle(theme.ink)
                Text("大型结果在后台解码，不影响运行记录栏继续勾选。")
                    .font(ThemeFont.caption(9.5))
                    .foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 260)
        }
    }

    private var emptyState: some View {
        Panel {
            VStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.muted)
                Text("还没有可对比的结果")
                    .font(ThemeFont.title(14))
                    .foregroundStyle(theme.ink)
                Text(
                    model.comparisonSelection.count < 2
                        ? "在左侧运行记录里至少勾选 2 条运行。"
                        : "所选结果全部读取失败，请在检查器中查看原因。"
                )
                .font(ThemeFont.caption(10))
                .foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private var singleRunHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.signal)
            Text("再勾选 1 条运行即可显示横向对比。")
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.muted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private func showParameters() {
        if model.isFocusMode {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.isFocusMode = false
            }
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            model.inspectorVisible = true
        }
    }
}

private struct ComparisonMetricsTable: View {
    let runs: [ComparisonRun]
    let baselineID: String?
    let routesComparable: Bool
    var onSelectBaseline: (String) -> Void

    @Environment(\.geomagTheme) private var theme

    private var contentHeight: CGFloat {
        50 + CGFloat(ComparisonMetric.allCases.count) * 24
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("指标对照 · PF")
                    .font(ThemeFont.micro(8, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(theme.muted)
                Spacer()
                Text(
                    routesComparable
                        ? "粗体 = 本组最优 · 点列头切换基准"
                        : "路线不同 · 不做最优标记"
                )
                .font(ThemeFont.mono(7.5))
                .foregroundStyle(theme.faint)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)

            Hairline()

            GeometryReader { proxy in
                let available = max(proxy.size.width - 24, 0)
                let labelWidth = max(84, min(112, available * 0.22))
                let columnWidth = max(
                    78,
                    min(180, (available - labelWidth) / CGFloat(max(runs.count, 1)))
                )
                VStack(spacing: 0) {
                    headerRow(labelWidth: labelWidth, columnWidth: columnWidth)
                    ForEach(ComparisonMetric.allCases) { metric in
                        metricRow(
                            metric,
                            labelWidth: labelWidth,
                            columnWidth: columnWidth
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: contentHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private func headerRow(
        labelWidth: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("指标")
                    .font(ThemeFont.caption(9, weight: .medium))
                    .foregroundStyle(theme.muted)
                Text("数值")
                    .font(ThemeFont.mono(7.5))
                    .foregroundStyle(theme.faint)
            }
            .frame(width: labelWidth, alignment: .leading)

            ForEach(runs) { run in
                let baseline = run.id == baselineID
                Button {
                    onSelectBaseline(run.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(theme.comparisonColor(run.colorIndex))
                                .frame(width: 5, height: 5)
                            Text(run.letter)
                                .font(ThemeFont.mono(8, weight: .bold))
                                .foregroundStyle(theme.comparisonColor(run.colorIndex))
                            if baseline {
                                Text("基准")
                                    .font(ThemeFont.micro(7))
                                    .foregroundStyle(theme.signal)
                            }
                        }
                        Text(run.result.datasetKey)
                            .font(
                                ThemeFont.title(
                                    columnWidth < 100 ? 8.5 : 9.5,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text(runMeta(run, compact: columnWidth < 100))
                            .font(ThemeFont.mono(7.5))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(width: columnWidth, alignment: .leading)
                    .background(
                        baseline
                            ? theme.surfaceSecondary.opacity(0.65)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("将 \(run.result.datasetKey) 设为基准")
            }
        }
        .frame(height: 50)
        .overlay(alignment: .bottom) {
            Hairline()
        }
    }

    private func metricRow(
        _ metric: ComparisonMetric,
        labelWidth: CGFloat,
        columnWidth: CGFloat
    ) -> some View {
        let values = runs.map { metric.value(from: $0.result) }
        let hasVariation = Set(values.compactMap { $0 }).count > 1
        let best = routesComparable && hasVariation
            ? metric.bestIndices(in: values)
            : []

        return HStack(spacing: 0) {
            Text(metric.title)
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)

            ForEach(Array(runs.indices), id: \.self) { index in
                let run = runs[index]
                let baseline = run.id == baselineID
                let isBest = best.contains(index)
                Text(metric.display(values[index]))
                    .font(ThemeFont.mono(10, weight: isBest ? .bold : .regular))
                    .foregroundStyle(
                        isBest
                            ? theme.trace
                            : values[index] == nil ? theme.faint : theme.ink
                    )
                    .lineLimit(1)
                    .padding(.leading, 9)
                    .frame(width: columnWidth, alignment: .leading)
                    .background(
                        baseline
                            ? theme.surfaceSecondary.opacity(0.45)
                            : Color.clear
                    )
            }
        }
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Hairline()
        }
    }

    private func runMeta(_ run: ComparisonRun, compact: Bool) -> String {
        if compact {
            return run.result.stepsDetected.map { "\($0) 步" } ?? "—"
        }
        let time = Self.timeFormatter.string(from: run.record.modifiedAt)
        if let steps = run.result.stepsDetected {
            return "\(time) · \(steps) 步"
        }
        return time
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

struct ComparisonInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme
    @State private var showOnlyDifferences = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.comparisonRuns.isEmpty {
                Text("还没有加载可对比的结果。")
                    .font(ThemeFont.caption(9.5))
                    .foregroundStyle(theme.muted)
            } else {
                runsSection
                parametersSection
            }

            if !model.comparisonLoadFailures.isEmpty {
                failureSection
            }
        }
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "运行",
                trailing: "\(model.comparisonRuns.count)"
            )

            ForEach(model.comparisonRuns) { run in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(theme.comparisonColor(run.colorIndex))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(run.letter)
                                .font(ThemeFont.mono(8, weight: .bold))
                                .foregroundStyle(theme.comparisonColor(run.colorIndex))
                            Text(run.result.datasetKey)
                                .font(ThemeFont.title(10, weight: .semibold))
                                .foregroundStyle(theme.ink)
                                .lineLimit(1)
                            if run.id == model.comparisonBaselineID {
                                Text("基准")
                                    .font(ThemeFont.micro(7))
                                    .foregroundStyle(theme.signal)
                            }
                            Spacer(minLength: 2)
                        }
                        Text(run.record.displayName)
                            .font(ThemeFont.mono(8))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .help(run.record.jsonURL.path)
                        Text(runMeta(run))
                            .font(ThemeFont.mono(8))
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var parametersSection: some View {
        let rows = model.comparisonParameterRows
        let differences = rows.filter(\.isDifferent)
        let displayed = showOnlyDifferences ? differences : rows

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionHeader(
                    title: "参数对照",
                    trailing: differences.isEmpty ? "一致" : "\(differences.count) 项不同"
                )
                Button(showOnlyDifferences ? "显示全部" : "仅看差异") {
                    showOnlyDifferences.toggle()
                }
                .buttonStyle(.plain)
                .font(ThemeFont.caption(8.5))
                .foregroundStyle(theme.signal)
            }

            if displayed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.trace)
                        Text("所有可记录参数一致")
                            .font(ThemeFont.caption(9.5, weight: .semibold))
                            .foregroundStyle(theme.ink)
                    }
                    Text("本次对比的差异来自采集、路线或运行版本本身。")
                        .font(ThemeFont.caption(9))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ThemeMetrics.badgeRadius)
                        .fill(theme.traceSoft.opacity(0.55))
                )
            } else {
                ForEach(displayed) { row in
                    parameterRow(row, runs: model.comparisonRuns)
                }
            }
        }
    }

    private func parameterRow(
        _ row: ComparisonParameter,
        runs: [ComparisonRun]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(row.label)
                    .font(ThemeFont.caption(9, weight: .semibold))
                    .foregroundStyle(row.isDifferent ? theme.ink : theme.muted)
                if row.isDifferent {
                    Circle()
                        .fill(theme.warn)
                        .frame(width: 4, height: 4)
                }
                Spacer()
            }

            ForEach(Array(runs.indices), id: \.self) { index in
                let run = runs[index]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.letter)
                        .font(ThemeFont.mono(8, weight: .bold))
                        .foregroundStyle(theme.comparisonColor(run.colorIndex))
                        .frame(width: 10, alignment: .leading)
                    Text(
                        row.values.indices.contains(index)
                            ? row.values[index]
                            : "—"
                    )
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(row.isDifferent ? theme.ink : theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.badgeRadius)
                .fill(theme.surface)
        )
        .overlay(alignment: .leading) {
            if row.isDifferent {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.warn)
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.badgeRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(
                title: "读取失败",
                trailing: "\(model.comparisonLoadFailures.count)"
            )
            ForEach(model.comparisonLoadFailures, id: \.self) { name in
                Text(name)
                    .font(ThemeFont.mono(8.5))
                    .foregroundStyle(theme.warn)
                    .lineLimit(1)
            }
        }
    }

    private func runMeta(_ run: ComparisonRun) -> String {
        var pieces = [Self.timeFormatter.string(from: run.record.modifiedAt)]
        if let steps = run.result.stepsDetected {
            pieces.append("\(steps) 步")
        }
        if let duration = run.result.activeWalkInterval?.duration {
            pieces.append(String(format: "%.1f s", duration))
        }
        return pieces.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
