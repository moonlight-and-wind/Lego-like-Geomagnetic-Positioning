import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    var body: some View {
        let theme = Theme.resolve(colorScheme)
        VStack(spacing: 0) {
            AppTopBar()
                .frame(height: ThemeMetrics.topBarHeight)
            Group {
                switch model.stage {
                case .data:
                    DataStageView()
                case .map:
                    MapStageView()
                case .run:
                    RunStageView()
                case .analysis:
                    AnalysisStageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(model.stage)
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: 8))
            )
            StatusBarView()
                .frame(height: ThemeMetrics.statusHeight)
        }
        .background(theme.canvas)
        .geomagTheme(theme)
        .frame(minWidth: 1100, minHeight: 720)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.signal, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if let message = model.errorMessage {
                    NoticeBanner(
                        severity: .error,
                        message: message,
                        actionTitle: "关闭"
                    ) {
                        model.errorMessage = nil
                    }
                }
                if let message = model.exportMessage {
                    NoticeBanner(
                        severity: .info,
                        message: message,
                        actionTitle: "关闭"
                    ) {
                        model.exportMessage = nil
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, ThemeMetrics.topBarHeight + 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(10)
        }
        .animation(.easeOut(duration: 0.2), value: model.stage)
        .background(WindowAccessor())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateCompact(width: proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        updateCompact(width: width)
                    }
            }
        }
    }

    private func updateCompact(width: CGFloat) {
        let compact = width < 1240
        guard compact != model.isCompact else { return }
        model.isCompact = compact
        #if DEBUG
        if ProcessInfo.processInfo.environment["GEOMAG_INSPECTOR"] == "1" {
            model.inspectorVisible = true
        } else {
            model.inspectorVisible = !compact
        }
        #else
        model.inspectorVisible = !compact
        #endif
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                model.importDroppedItem(at: url)
            }
        }
        return true
    }
}

private struct AppTopBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            titleStrip
            stageStrip
        }
        .background(theme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }

    private var titleStrip: some View {
        ZStack {
            WindowDragHandle()
            Text("GeomagMac Native")
                .font(ThemeFont.caption(10))
                .foregroundStyle(theme.faint)
                .allowsHitTesting(false)
            HStack(spacing: 5) {
                Spacer()
                KeyCap(text: "⌘O")
                Text("打开结果")
                    .font(ThemeFont.caption(9))
                    .foregroundStyle(theme.faint)
            }
            .padding(.horizontal, 18)
            .allowsHitTesting(false)
        }
        .frame(height: 30)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Hairline()
        }
    }

    private var stageStrip: some View {
        HStack(spacing: 10) {
            brand
            Rectangle()
                .fill(theme.hairlineSoft)
                .frame(width: 1, height: 26)
            Spacer(minLength: 16)
            HStack(spacing: 4) {
                ForEach(Stage.allCases) { stage in
                    stageTab(stage)
                    if stage != Stage.allCases.last {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.faint)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.stage)
            Spacer(minLength: 16)

            HStack(spacing: 8) {
                TopIconButton(
                    systemImage: "plus",
                    help: "新建运行（回到 01 数据）"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.go(to: .data)
                    }
                }
                TopIconButton(
                    systemImage: "folder",
                    help: "打开结果 JSON（⌘O）"
                ) {
                    model.openResultFile()
                }
                if model.stage == .analysis {
                    TopIconButton(
                        systemImage: "sidebar.left",
                        help: model.runsRailVisible
                            ? "收起运行记录"
                            : "打开运行记录",
                        isOn: model.runsRailVisible,
                        isEnabled: !model.isFocusMode
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.runsRailVisible.toggle()
                        }
                    }
                }
                TopIconButton(
                    systemImage: "sidebar.right",
                    help: model.inspectorVisible
                        ? "收起检查器"
                        : "打开检查器",
                    isOn: model.inspectorVisible,
                    isEnabled: !model.isFocusMode
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.inspectorVisible.toggle()
                    }
                    if !model.inspectorVisible {
                        model.inspectorScrollTarget = nil
                    }
                }
                primaryAction
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(theme.canvas)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            BrandMark(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("GEOMAG")
                    .font(ThemeFont.title(10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink)
                Text("位置分析台")
                    .font(ThemeFont.caption(8))
                    .tracking(0.8)
                    .foregroundStyle(theme.muted)
            }
        }
        .frame(width: model.isCompact ? 146 : 166, alignment: .leading)
    }

    private func stageTab(_ stage: Stage) -> some View {
        let active = model.stage == stage
        let state = stageState(stage)
        let issue = model.pipelineReadiness.issues.first { $0.stage == stage }
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                model.go(to: stage)
            }
        } label: {
            HStack(spacing: 7) {
                Text(String(format: "%02d", stage.rawValue + 1))
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(stageNumberColor(state))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(stage.title)
                            .font(
                                ThemeFont.title(
                                    11,
                                    weight: active ? .bold : .semibold
                                )
                            )
                            .foregroundStyle(stageNameColor(state))
                        if state == .done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(theme.trace)
                        }
                    }
                    if !model.isCompact {
                        Text(stageSubtitle(stage))
                            .font(ThemeFont.mono(8))
                            .foregroundStyle(stageSubtitleColor(state))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                active ? theme.surface : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(alignment: .bottom) {
                if active {
                    Rectangle()
                        .fill(theme.signal)
                        .frame(height: 2)
                        .padding(.horizontal, 10)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        active ? theme.hairline : Color.clear,
                        lineWidth: 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(issue?.message ?? "进入\(stage.title)")
        .accessibilityLabel("\(stage.title)阶段")
        .accessibilityValue(accessibilityValue(for: stage))
    }

    private func stageNumberColor(_ state: StageBadgeState) -> Color {
        switch state {
        case .active: theme.signal
        case .done: theme.trace
        case .blocked: theme.danger
        case .attention: theme.warn
        case .ready, .running: theme.faint
        }
    }

    private func stageNameColor(_ state: StageBadgeState) -> Color {
        switch state {
        case .active, .done: theme.ink
        case .blocked: theme.danger
        case .ready, .attention, .running: theme.muted
        }
    }

    private func stageSubtitleColor(_ state: StageBadgeState) -> Color {
        switch state {
        case .active: theme.signal
        case .blocked: theme.danger
        case .attention: theme.warn
        case .done: theme.muted
        case .ready, .running: theme.faint
        }
    }

    private func stageState(_ stage: Stage) -> StageBadgeState {
        if stage == .run, model.isBackendRunning {
            return model.stage == .run ? .active : .running
        }
        if model.stage == stage {
            return .active
        }
        let readiness = model.pipelineReadiness
        switch stage {
        case .data:
            return readiness.dataReady ? .done : .ready
        case .map:
            guard readiness.dataReady else { return .ready }
            if readiness.mapReady { return .done }
            return readiness.issues.contains { $0.stage == .map } ? .blocked : .ready
        case .run:
            if model.result != nil { return .done }
            guard readiness.dataReady, readiness.mapReady else { return .ready }
            return readiness.canRun ? .ready : .blocked
        case .analysis:
            return model.result != nil ? .done : .ready
        }
    }

    private func stageSubtitle(_ stage: Stage) -> String {
        switch stage {
        case .data:
            if model.runInputMode == .bundled {
                return "内置留出数据 · \(model.selectedRunDatasetID)"
            }
            if let dataset = model.importedDataset {
                let suffix = model.importedDatasetReady ? "已校验" : "待完善"
                return "\(dataset.directoryURL.lastPathComponent) · \(suffix)"
            }
            return "尚未选择采集"
        case .map:
            if let map = model.mapForCurrentSelection {
                return "\(map.document.name) · \(map.document.samples.count) 网格"
            }
            return "尚无磁图"
        case .run:
            if model.isBackendRunning {
                return "\(Int((model.backendProgress * 100).rounded()))% · 计算中"
            }
            if model.stage == .run {
                return model.pipelineReadiness.canRun ? "就绪 · 可开始计算" : "等待前置"
            }
            if model.result != nil {
                return "PF + PDR · 已完成"
            }
            return model.pipelineReadiness.canRun ? "就绪" : "等待前置"
        case .analysis:
            if model.comparisonActive {
                return "\(model.comparisonRuns.count) 次运行 · 基准 \(model.comparisonBaselineLetter)"
            }
            if let final = model.result?.pfErrorStats?.final {
                return "终点 \(String(format: "%.2f", final)) m"
            }
            return "尚无结果"
        }
    }

    private func accessibilityValue(for stage: Stage) -> String {
        switch stageState(stage) {
        case .done: "已完成"
        case .active: "当前阶段"
        case .blocked: "缺少前置条件"
        case .attention: "需要检查"
        case .running: "正在运行"
        case .ready: "待进行"
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch model.stage {
        case .data:
            PlateButton(
                title: "校验并继续",
                kind: .primary,
                isEnabled: model.pipelineReadiness.dataReady
            ) {
                model.advanceFromCurrentStage()
            }
        case .map:
            let readiness = model.pipelineReadiness
            PlateButton(
                title: "下一步：运行",
                kind: .primary,
                isEnabled: readiness.dataReady
                    && readiness.mapReady
                    && readiness.routeReady
                    && readiness.headingReady
            ) {
                model.advanceFromCurrentStage()
            }
        case .run:
            if model.isBackendRunning {
                PlateButton(title: "取消", systemImage: "stop.fill", kind: .danger) {
                    model.cancelBackendRun()
                }
            } else {
                PlateButton(
                    title: "开始计算",
                    systemImage: "play.fill",
                    kind: .primary,
                    isEnabled: model.pipelineReadiness.canRun
                ) {
                    model.runSelectedDataset()
                }
            }
        case .analysis:
            if model.comparisonActive {
                PlateButton(
                    title: "退出对比",
                    systemImage: "xmark",
                    kind: .secondary
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.endComparison()
                    }
                }
            } else {
                ExportMenu()
            }
        }
    }
}

private struct TopIconButton: View {
    let systemImage: String
    let help: String
    var isOn: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @Environment(\.geomagTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? theme.signal : theme.muted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                        .fill(
                            isOn
                                ? theme.signalSoft
                                : (isHovered
                                    ? theme.surfaceSecondary
                                    : theme.surface)
                        )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                        .stroke(
                            isOn
                                ? theme.signal.opacity(0.35)
                                : theme.hairline,
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

private struct ExportMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        Menu {
            Button("当前视图 PNG…") {
                model.exportCurrentViewPNG()
            }
            Button("报告 PDF…") {
                model.exportReportPDF()
            }
            Button("CSV 轨迹…") {
                model.exportCSV()
            }
            Divider()
            Button("复制结论与指标") {
                model.copyConclusion()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
                Text("导出")
                    .font(ThemeFont.label(11, weight: .semibold))
            }
            .foregroundStyle(theme.signalOn)
            .padding(.horizontal, 13)
            .frame(height: ThemeMetrics.primaryHeight)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .fill(theme.signal)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.result == nil)
        .opacity(model.result == nil ? 0.42 : 1)
    }
}

private struct StatusBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 5, height: 5)
                Text(statusText)
                    .foregroundStyle(theme.trace)
            }
            Spacer(minLength: 12)
            Text(centerText)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("v\(model.appVersion) · 纯 Swift 引擎")
                .foregroundStyle(theme.faint)
        }
        .font(ThemeFont.mono(8.5))
        .padding(.horizontal, 14)
        .background(theme.canvas)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairlineSoft)
                .frame(height: 1)
        }
    }

    private var statusTint: Color {
        if model.isBackendRunning { return theme.signal }
        if model.isMagneticMapBuilding { return theme.warn }
        return theme.trace
    }

    private var statusText: String {
        if model.isBackendRunning {
            return "计算中 \(Int((model.backendProgress * 100).rounded()))%"
        }
        if model.isMagneticMapBuilding {
            return "建图中"
        }
        return "就绪"
    }

    private var centerText: String {
        guard let result = model.result else {
            return "尚未加载结果"
        }
        let mapName = model.mapForCurrentSelection?.document.name ?? "—"
        let steps = result.stepsDetected.map(String.init) ?? "—"
        let final = result.pfErrorStats.map { String(format: "%.2f m", $0.final) } ?? "—"
        return "\(result.datasetKey) → \(mapName) · \(steps) 步 · PF \(final)"
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.zoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.setFrameAutosaveName("GeomagMacMainWindow")
        window.minSize = NSSize(width: 1100, height: 720)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
    }
}
