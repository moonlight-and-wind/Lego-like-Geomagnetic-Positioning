import Combine
import SwiftUI

struct AnalysisStageView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewport = PlotViewport()
    @State private var isPlaying = false
    @State private var speed = 1.0
    @FocusState private var isFocused: Bool

    private let timer = Timer.publish(
        every: 1.0 / 30.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            if !model.isFocusMode && model.runsRailVisible {
                RunsRailView()
                    .frame(width: ThemeMetrics.railWidth)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .leading)
                                .combined(with: .opacity)
                    )
                verticalDivider
            }

            VStack(alignment: .leading, spacing: 10) {
                if model.comparisonActive {
                    ComparisonStageView()
                } else {
                    singleResultContent
                }
            }
            .padding(16)

            if !model.isFocusMode && model.inspectorVisible {
                verticalDivider
                inspectorPane
                    .frame(width: ThemeMetrics.inspectorWidth)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing)
                                .combined(with: .opacity)
                    )
            }
        }
        .background(theme.canvas)
        .onReceive(timer) { _ in tick() }
        .onChange(of: model.loadedFileName) { _, _ in
            isPlaying = false
            viewport.reset()
        }
        .onChange(of: model.comparisonActive) { _, active in
            if active {
                isPlaying = false
            }
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .simultaneousGesture(
            TapGesture().onEnded {
                isFocused = true
            }
        )
        .onKeyPress(.space) {
            guard !model.comparisonActive, model.result != nil else {
                return .ignored
            }
            togglePlay()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard !model.comparisonActive else { return .ignored }
            moveSelection(-1)
            return model.result == nil ? .ignored : .handled
        }
        .onKeyPress(.rightArrow) {
            guard !model.comparisonActive else { return .ignored }
            moveSelection(1)
            return model.result == nil ? .ignored : .handled
        }
        .onKeyPress(.escape) {
            if model.isFocusMode {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.isFocusMode = false
                }
            } else if model.comparisonActive {
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.endComparison()
                }
            } else {
                model.selectedStepIndex = nil
            }
            return .handled
        }
        .onKeyPress(KeyEquivalent("f")) {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.isFocusMode.toggle()
            }
            return .handled
        }
    }

    @ViewBuilder
    private var singleResultContent: some View {
        header
        if model.resultSource == .history {
            historyBanner
        }
        if let result = model.result {
            insight(result)
            TrajectoryPlot(
                result: result,
                layers: plotLayers,
                progress: model.playbackProgress,
                selectedStep: model.selectedStepIndex,
                gridCellSize: model.mapForCurrentSelection?.document.gridCellSizeM,
                viewport: $viewport,
                onSelectStep: selectStep
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            StepErrorStrip(
                result: result,
                progress: model.playbackProgress,
                selectedStep: model.selectedStepIndex,
                onSelect: { selectStep($0) }
            )

            playbackBar(result)
            metrics(result)
            foot(result)
        } else {
            emptyState
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.hairlineSoft)
            .frame(width: 1)
    }

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("检查器")
                    .font(ThemeFont.micro(9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.muted)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.inspectorVisible = false
                    }
                    model.inspectorScrollTarget = nil
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("收起检查器")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(theme.surface)
            .overlay(alignment: .bottom) {
                Hairline()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if model.comparisonActive {
                        ComparisonInspectorView()
                            .padding(14)
                    } else {
                        InspectorView()
                            .padding(14)
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        scrollInspector(proxy)
                    }
                }
                .onChange(of: model.inspectorScrollToken) { _, _ in
                    scrollInspector(proxy)
                }
            }
        }
        .background(theme.canvas)
    }

    private func scrollInspector(_ proxy: ScrollViewProxy) {
        guard let target = model.inspectorScrollTarget else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("04 · 分析 / 结果")
                    .font(ThemeFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(theme.signal)
                Text(model.result?.friendlyTitle ?? "分析")
                    .font(ThemeFont.display(20))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(resultSubtitle)
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if let result = model.result {
                if !compactCrowded {
                    statusPill(result)
                }
                PlateButton(
                    title: model.showPDR ? "隐藏 PDR" : "显示 PDR",
                    systemImage: model.showPDR ? "eye.slash" : "eye",
                    kind: .ghost
                ) {
                    model.showPDR.toggle()
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
    }

    private var compactCrowded: Bool {
        model.isCompact && model.inspectorVisible
    }

    private var resultSubtitle: String {
        guard let result = model.result else {
            return "尚未加载结果"
        }
        let mapName = model.mapForCurrentSelection?.document.name ?? "—"
        let steps = result.stepsDetected.map { "\($0) 步" } ?? "—"
        let duration = result.activeWalkInterval.map {
            String(format: "%.1f s", $0.duration)
        } ?? "—"
        return "\(resultSourceLabel) · \(result.routeLabel) · \(mapName) · "
            + "\(steps) / \(duration) · \(model.loadedFileName)"
    }

    private var resultSourceLabel: String {
        switch model.resultSource {
        case .liveRun: "本次运行"
        case .history: "历史结果"
        case .openedFile: "打开的结果"
        case .bundledSample: "内置示例"
        }
    }

    private func statusPill(_ result: PositioningResult) -> some View {
        if let health = result.finalLocalizationHealth,
           health.status.lowercased() != "healthy" {
            return StatusPill(
                text: health.localizedStatus,
                tint: health.status.lowercased() == "lost" ? theme.danger : theme.warn
            )
        }
        if let confidence = result.finalPFConfidence {
            return StatusPill(
                text: "终点可靠度\(confidence.localizedLevel) · "
                    + "\(Int((confidence.score * 100).rounded()))%",
                tint: confidence.level.lowercased() == "high"
                    ? theme.trace : theme.warn
            )
        }
        return StatusPill(text: "仅 PDR", tint: theme.faint)
    }

    private var historyBanner: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.warn)
                .frame(width: 2)
                .clipShape(Capsule())
            Text("历史结果 · 只读；打开它不会改动当前数据、磁图或参数。")
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.muted)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private func insight(_ result: PositioningResult) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(theme.trace)
                .frame(width: 2)
                .clipShape(Capsule())
            insightText(result)
                .font(ThemeFont.caption(10))
                .foregroundStyle(theme.muted)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("查看诊断") {
                if model.isFocusMode {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.isFocusMode = false
                    }
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    model.inspectorVisible = true
                }
                model.inspectorScrollTarget = "diagnostics"
                model.inspectorScrollToken = UUID()
            }
            .buttonStyle(.plain)
            .font(ThemeFont.caption(9.5))
            .foregroundStyle(theme.signal)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
    }

    private func insightText(_ result: PositioningResult) -> Text {
        let pfFinal = result.pfErrorStats?.final
        let pdrFinal = result.pdrErrorStats?.final
        let score = result.overallPFConfidenceScore
        let recoveryCount = result.localizationRecoveryEvents?.count ?? 0

        var sentence = ""
        if let pfFinal, let pdrFinal {
            sentence += "PF 将终点误差从 \(meters(pdrFinal)) 降到 \(meters(pfFinal))；"
        } else if let pfFinal {
            sentence += "PF 终点误差 \(meters(pfFinal))；"
        }
        if let score {
            sentence += "平均可靠度 \(Int((score * 100).rounded()))%；"
        }
        sentence += recoveryCount == 0
            ? "全程无自动恢复。"
            : "自动恢复 \(recoveryCount) 次。"
        return Text(sentence)
    }

    private var emptyState: some View {
        Panel {
            VStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(theme.muted)
                Text("尚未加载结果")
                    .font(ThemeFont.title(14))
                    .foregroundStyle(theme.ink)
                Text("运行一次定位，或打开已有的结果 JSON。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
                HStack(spacing: 8) {
                    PlateButton(
                        title: "打开结果 JSON…",
                        systemImage: "folder",
                        kind: .secondary
                    ) {
                        model.openResultFile()
                    }
                    PlateButton(
                        title: "载入内置示例",
                        systemImage: "play.rectangle",
                        kind: .ghost
                    ) {
                        model.loadBundledSample(id: AppModel.samples[0].id)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private func playbackBar(_ result: PositioningResult) -> some View {
        HStack(spacing: 10) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.surface))
                    .overlay(Circle().stroke(theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "暂停" : "播放")

            PlaybackTimeline(
                cornerFractions: TrajectoryAnalysis.routeCorners(result.routeXY).map(\.fraction),
                recoveryFractions: (result.localizationRecoveryEvents ?? []).compactMap { event in
                    guard result.pfTrack.indices.contains(event.stepIndex) else { return nil }
                    return TrajectoryAnalysis.progress(
                        forStep: event.stepIndex,
                        pointCount: result.pfTrack.count
                    )
                },
                progress: model.playbackProgress,
                onSeek: seek
            )
            .frame(height: 22)

            Text(timeText(result))
                .font(ThemeFont.mono(9))
                .foregroundStyle(theme.muted)
                .frame(minWidth: 58, alignment: .trailing)

            Button(speedLabel) {
                speed = speed >= 4 ? 1 : speed * 2
            }
            .buttonStyle(.plain)
            .font(ThemeFont.mono(9))
            .foregroundStyle(theme.muted)
            .frame(width: 28, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(theme.hairline, lineWidth: 1)
            }

            PlateButton(title: "显示全部", kind: .ghost) {
                isPlaying = false
                model.playbackProgress = 1
            }
        }
    }

    private var speedLabel: String {
        "\(Int(speed))×"
    }

    private func timeText(_ result: PositioningResult) -> String {
        let duration = result.activeWalkInterval?.duration ?? 0
        let seconds = duration * min(max(model.playbackProgress, 0), 1)
        return String(
            format: "%d:%02d / %d:%02d",
            Int(seconds) / 60,
            Int(seconds) % 60,
            Int(duration) / 60,
            Int(duration) % 60
        )
    }

    private func metrics(_ result: PositioningResult) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 116), spacing: 8)],
            spacing: 8
        ) {
            MetricTile(
                title: "PF 终点误差",
                value: meters(result.pfErrorStats?.final),
                unit: "m",
                compare: "PDR \(meters(result.pdrErrorStats?.final))",
                delta: improvement(
                    pf: result.pfErrorStats?.final,
                    pdr: result.pdrErrorStats?.final
                ),
                tint: theme.trace
            )
            MetricTile(
                title: "PF 横向误差",
                value: meters(result.pfCrossTrackErrorStats?.mean),
                unit: "m",
                compare: "PDR \(meters(result.pdrCrossTrackErrorStats?.mean))",
                delta: improvement(
                    pf: result.pfCrossTrackErrorStats?.mean,
                    pdr: result.pdrCrossTrackErrorStats?.mean
                ),
                tint: theme.signal
            )
            MetricTile(
                title: "PF 沿程误差",
                value: meters(result.pfAlongTrackErrorStats?.mean),
                unit: "m",
                compare: "PDR \(meters(result.pdrAlongTrackErrorStats?.mean))",
                delta: improvement(
                    pf: result.pfAlongTrackErrorStats?.mean,
                    pdr: result.pdrAlongTrackErrorStats?.mean
                ),
                tint: theme.trace
            )
            MetricTile(
                title: "PF 转角误差",
                value: degrees(result.pfTurnAngleErrorStats?.mean),
                unit: "°",
                compare: "PDR \(degrees(result.pdrTurnAngleErrorStats?.mean))",
                delta: improvement(
                    pf: result.pfTurnAngleErrorStats?.mean,
                    pdr: result.pdrTurnAngleErrorStats?.mean
                ),
                tint: theme.warn
            )
            MetricTile(
                title: "PF 路程比例",
                value: percent(result.pfPathLengthRatio),
                unit: "%",
                compare: "PDR \(percent(result.pdrPathLengthRatio)) · 目标 100%",
                delta: pathDelta(
                    pf: result.pfPathLengthRatio,
                    pdr: result.pdrPathLengthRatio
                ),
                tint: theme.signal
            )
            MetricTile(
                title: "PF 闭合误差",
                value: meters(result.pfClosureErrorM),
                unit: "m",
                compare: "PDR \(meters(result.pdrClosureErrorM))",
                delta: improvement(
                    pf: result.pfClosureErrorM,
                    pdr: result.pdrClosureErrorM
                ),
                tint: theme.trace
            )
        }
    }

    private func foot(_ result: PositioningResult) -> some View {
        HStack(spacing: 10) {
            Text(algorithmFoot(result))
                .font(ThemeFont.mono(8))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
            Spacer()
            if let steps = result.stepsDetected {
                Text("\(steps) 步 · \(model.loadedFileName)")
                    .font(ThemeFont.mono(8))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
        }
    }

    private func algorithmFoot(_ result: PositioningResult) -> String {
        var pieces: [String] = [result.branch]
        if let mode = result.pfSmoothingMode {
            pieces.append("平滑 \(mode)")
        }
        if let alpha = result.pfSmoothingAlpha {
            pieces.append(String(format: "α %.2f", alpha))
        }
        if let joint = result.pfJointCalibration {
            pieces.append("联合校准 \(joint ? "开" : "关")")
        }
        return pieces.joined(separator: " · ")
    }

    private var plotLayers: PlotLayers {
        PlotLayers(
            trueRoute: model.showTrueRoute,
            pdr: model.showPDR,
            pf: model.showPF,
            confidence: model.showPFConfidence
        )
    }

    private func togglePlay() {
        guard model.result != nil else { return }
        if model.playbackProgress >= 1 {
            model.playbackProgress = 0
        }
        isPlaying.toggle()
        if isPlaying {
            isFocused = true
        }
    }

    private func tick() {
        guard isPlaying, model.result != nil else { return }
        let delta = (1.0 / 30.0) * speed / 8.0
        let next = min(1, model.playbackProgress + delta)
        model.playbackProgress = next
        if next >= 1 {
            isPlaying = false
        }
    }

    private func seek(_ fraction: Double) {
        isPlaying = false
        model.playbackProgress = min(max(fraction, 0), 1)
    }

    private func selectStep(_ step: Int?) {
        guard let result = model.result else { return }
        guard let step else {
            model.selectedStepIndex = nil
            return
        }
        let lowerBound = result.pfTrack.count > 1 ? 1 : 0
        let clamped = min(
            max(step, lowerBound),
            max(result.pfTrack.count - 1, 0)
        )
        model.selectedStepIndex = clamped
        model.playbackProgress = TrajectoryAnalysis.progress(
            forStep: clamped,
            pointCount: result.pfTrack.count
        )
        isPlaying = false
    }

    private func moveSelection(_ delta: Int) {
        guard let result = model.result else { return }
        let current = model.selectedStepIndex
            ?? TrajectoryAnalysis.stepIndex(
                forProgress: model.playbackProgress,
                pointCount: result.pfTrack.count
            )
        selectStep(current + delta)
    }

    private func meters(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }

    private func degrees(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value * 100)
    }

    private func improvement(pf: Double?, pdr: Double?) -> String? {
        guard let pf, let pdr, pdr > 1e-9 else { return nil }
        let value = max(0, (pdr - pf) / pdr * 100)
        return String(format: "↓ %.0f%%", value)
    }

    private func pathDelta(pf: Double?, pdr: Double?) -> String? {
        guard let pf, let pdr else { return nil }
        return String(format: "%+.0f pp", (pf - pdr) * 100)
    }
}

private struct PlaybackTimeline: View {
    let cornerFractions: [Double]
    let recoveryFractions: [Double]
    let progress: Double
    var onSeek: (Double) -> Void

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let y = size.height / 2
                let trackRect = CGRect(
                    x: 0,
                    y: y - 2,
                    width: size.width,
                    height: 4
                )
                context.fill(
                    Path(roundedRect: trackRect, cornerRadius: 2),
                    with: .color(theme.surfaceSecondary)
                )
                let filled = CGRect(
                    x: 0,
                    y: y - 2,
                    width: size.width * min(max(progress, 0), 1),
                    height: 4
                )
                context.fill(
                    Path(roundedRect: filled, cornerRadius: 2),
                    with: .color(theme.signal)
                )

                for fraction in cornerFractions {
                    let x = size.width * CGFloat(fraction)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: y - 5))
                    tick.addLine(to: CGPoint(x: x, y: y + 5))
                    context.stroke(
                        tick,
                        with: .color(theme.faint.opacity(0.65)),
                        lineWidth: 1
                    )
                }
                for fraction in recoveryFractions {
                    let x = size.width * CGFloat(fraction)
                    let dot = CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(theme.signal)
                    )
                }

                let thumbX = size.width * CGFloat(min(max(progress, 0), 1))
                let thumb = CGRect(
                    x: thumbX - 5,
                    y: y - 5,
                    width: 10,
                    height: 10
                )
                context.fill(
                    Path(ellipseIn: thumb),
                    with: .color(theme.surface)
                )
                context.stroke(
                    Path(ellipseIn: thumb),
                    with: .color(theme.signal),
                    lineWidth: 2
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(
                            min(
                                max(value.location.x / max(proxy.size.width, 1), 0),
                                1
                            )
                        )
                    }
            )
        }
    }
}
