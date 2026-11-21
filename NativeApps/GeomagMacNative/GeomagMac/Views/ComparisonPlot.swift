import SwiftUI

struct ComparisonPlot: View {
    let runs: [ComparisonRun]
    let baselineID: String?
    var onSelectBaseline: (String) -> Void
    @Binding var viewport: PlotViewport

    @Environment(\.geomagTheme) private var theme
    @State private var hiddenIDs: Set<String> = []
    @State private var hoverLocation: CGPoint?
    @State private var panStart: CGSize?
    @State private var magnificationStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    draw(context: &context, size: canvasSize)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(magnificationGesture)
                .onTapGesture(count: 2) {
                    viewport.reset()
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        hoverLocation = location
                    case .ended:
                        hoverLocation = nil
                    }
                }
                .background {
                    ScrollWheelMonitor { delta, point in
                        let plot = layout(for: size)
                        let factor = min(max(exp(Double(delta) * 0.05), 0.8), 1.25)
                        viewport.applyZoom(
                            factor: factor,
                            anchor: point,
                            layout: plot,
                            canvasSize: size
                        )
                    }
                }

                legendOverlay
                toolsOverlay
                readoutOverlay(size: size)
            }
        }
        .background(theme.plotBackground)
        .clipShape(RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius)
                .stroke(theme.hairline, lineWidth: 1)
        }
        .onChange(of: runs.map(\.id)) { _, ids in
            hiddenIDs.formIntersection(Set(ids))
            viewport.reset()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("多运行轨迹对比画布")
        .accessibilityValue(
            "\(runs.count) 次运行 · "
                + (runs.first.map { RunComparison.displayRouteLabel($0.result.routeLabel) } ?? "—")
        )
    }

    private var baselineRun: ComparisonRun? {
        runs.first { $0.id == baselineID }
    }

    private var visibleRuns: [ComparisonRun] {
        runs.filter { !hiddenIDs.contains($0.id) }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil {
                    panStart = viewport.pan
                }
                let start = panStart ?? .zero
                viewport.pan = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in
                panStart = nil
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnificationStart == nil {
                    magnificationStart = viewport.zoom
                }
                let start = magnificationStart ?? 1
                viewport.zoom = min(
                    max(start * value, PlotViewport.minZoom),
                    PlotViewport.maxZoom
                )
            }
            .onEnded { _ in
                magnificationStart = nil
            }
    }

    private var legendOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("运行轨迹")
                    .font(ThemeFont.mono(8, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(theme.plotMuted)
                Text("点行设基准")
                    .font(ThemeFont.mono(7.5))
                    .foregroundStyle(theme.plotMuted.opacity(0.7))
            }
            .padding(.bottom, 1)

            ForEach(runs) { run in
                runLegendRow(run)
            }
        }
        .padding(9)
        .frame(width: 256, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.plotBackground.opacity(0.74))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.plotBoundary.opacity(0.55), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    private func runLegendRow(_ run: ComparisonRun) -> some View {
        let hidden = hiddenIDs.contains(run.id)
        let color = theme.comparisonColor(run.colorIndex)
        let baseline = run.id == baselineRun?.id
        return HStack(spacing: 3) {
            Button {
                onSelectBaseline(run.id)
            } label: {
                HStack(spacing: 6) {
                    Text(run.letter)
                        .font(ThemeFont.mono(8, weight: .bold))
                        .foregroundStyle(color)
                        .frame(width: 10)
                    Rectangle()
                        .fill(color)
                        .frame(width: 16, height: baseline ? 3 : 2)
                    Text(run.result.datasetKey)
                        .font(ThemeFont.caption(9))
                        .foregroundStyle(theme.plotInk)
                        .lineLimit(1)
                    if baseline {
                        Text("基准")
                            .font(ThemeFont.micro(7))
                            .foregroundStyle(theme.plotInk)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.plotInk.opacity(0.12)))
                    }
                    Spacer(minLength: 2)
                    Text(Self.shortTimeFormatter.string(from: run.record.modifiedAt))
                        .font(ThemeFont.mono(7.5))
                        .foregroundStyle(theme.plotMuted)
                }
                .padding(.leading, 4)
                .padding(.vertical, 3)
                .opacity(hidden ? 0.35 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("将 \(run.result.datasetKey) 设为基准")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if hidden {
                        hiddenIDs.remove(run.id)
                    } else {
                        hiddenIDs.insert(run.id)
                    }
                }
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(theme.plotMuted)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hidden ? "显示 \(run.result.datasetKey)" : "隐藏 \(run.result.datasetKey)")
        }
    }

    private var toolsOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    viewport.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.plotInk)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                                .fill(theme.plotBackground.opacity(0.72))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                                .stroke(theme.plotBoundary, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("复位缩放与位置（也可以双击画布）")
            }
            Spacer()
        }
        .padding(12)
    }

    private func readoutOverlay(size: CGSize) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                if let hoverLocation {
                    let point = viewport.world(
                        hoverLocation,
                        layout: layout(for: size),
                        canvasSize: size
                    )
                    Text(String(format: "x %.2f m", point.x))
                    readoutDivider
                    Text(String(format: "y %.2f m", point.y))
                    readoutDivider
                    Text("滚轮缩放 · 拖动平移")
                } else {
                    Text("悬停读取坐标 · 双击复位")
                }
            }
            .font(ThemeFont.mono(9))
            .foregroundStyle(theme.plotMuted)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.plotBackground.opacity(0.82))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(theme.plotBoundary, lineWidth: 1)
            }
            .padding(.bottom, 10)
        }
        .allowsHitTesting(false)
    }

    private var readoutDivider: some View {
        Rectangle()
            .fill(theme.plotBoundary)
            .frame(width: 1, height: 11)
    }

    private func layout(for size: CGSize) -> PlotLayout {
        PlotLayout(bounds: plotBounds, rect: CGRect(origin: .zero, size: size))
    }

    private var plotBounds: CoordinateBounds {
        var points: [XYPoint] = []
        for run in runs {
            points.append(contentsOf: run.result.routeXY)
            points.append(contentsOf: run.result.pfTrack)
        }
        guard let first = points.first else {
            return CoordinateBounds(minX: 0, maxX: 1, minY: 0, maxY: 1)
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
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

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let plot = layout(for: size)
        drawGrid(context: &context, plot: plot, size: size)

        if let baseline = baselineRun {
            drawPolyline(
                baseline.result.routeXY,
                color: theme.trueRoute,
                width: 1.3,
                dash: [2, 4],
                opacity: 0.58,
                context: &context,
                plot: plot,
                size: size
            )
            drawStartMarker(
                at: baseline.result.routeXY.first,
                context: &context,
                plot: plot,
                size: size
            )
        }

        let ordered = visibleRuns.sorted { lhs, rhs in
            let lhsBaseline = lhs.id == baselineRun?.id
            let rhsBaseline = rhs.id == baselineRun?.id
            if lhsBaseline != rhsBaseline { return !lhsBaseline }
            return lhs.colorIndex < rhs.colorIndex
        }
        for run in ordered {
            let color = theme.comparisonColor(run.colorIndex)
            let isBaseline = run.id == baselineRun?.id
            drawPolyline(
                run.result.pfTrack,
                color: theme.plotBackground,
                width: isBaseline ? 6.5 : 5,
                dash: [],
                opacity: 0.5,
                context: &context,
                plot: plot,
                size: size
            )
            drawPolyline(
                run.result.pfTrack,
                color: color,
                width: isBaseline ? 3.2 : 2.2,
                dash: [],
                opacity: 1,
                context: &context,
                plot: plot,
                size: size
            )
            drawEndpoint(
                run,
                baseline: isBaseline,
                color: color,
                context: &context,
                plot: plot,
                size: size
            )
        }

        drawScaleBar(context: &context, plot: plot, size: size)
    }

    private func drawGrid(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        let bounds = plotBounds
        let step = 0.5
        var x = ceil(bounds.minX / step) * step
        while x <= bounds.maxX + 1e-9 {
            let major = abs(x - x.rounded()) < 1e-6
            let top = viewport.screen(
                XYPoint(x: x, y: bounds.maxY),
                layout: plot,
                canvasSize: size
            )
            let bottom = viewport.screen(
                XYPoint(x: x, y: bounds.minY),
                layout: plot,
                canvasSize: size
            )
            var path = Path()
            path.move(to: top)
            path.addLine(to: bottom)
            context.stroke(
                path,
                with: .color(major ? theme.plotGridMajor : theme.plotGrid),
                lineWidth: 1
            )
            x += step
        }

        var y = ceil(bounds.minY / step) * step
        while y <= bounds.maxY + 1e-9 {
            let major = abs(y - y.rounded()) < 1e-6
            let left = viewport.screen(
                XYPoint(x: bounds.minX, y: y),
                layout: plot,
                canvasSize: size
            )
            let right = viewport.screen(
                XYPoint(x: bounds.maxX, y: y),
                layout: plot,
                canvasSize: size
            )
            var path = Path()
            path.move(to: left)
            path.addLine(to: right)
            context.stroke(
                path,
                with: .color(major ? theme.plotGridMajor : theme.plotGrid),
                lineWidth: 1
            )
            y += step
        }
    }

    private func drawPolyline(
        _ points: [XYPoint],
        color: Color,
        width: CGFloat,
        dash: [CGFloat],
        opacity: Double,
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        guard points.count > 1 else { return }
        var path = Path()
        path.move(to: viewport.screen(points[0], layout: plot, canvasSize: size))
        for point in points.dropFirst() {
            path.addLine(to: viewport.screen(point, layout: plot, canvasSize: size))
        }
        context.stroke(
            path,
            with: .color(color.opacity(opacity)),
            style: StrokeStyle(
                lineWidth: width,
                lineCap: .round,
                lineJoin: .round,
                dash: dash
            )
        )
    }

    private func drawEndpoint(
        _ run: ComparisonRun,
        baseline: Bool,
        color: Color,
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        guard let endpoint = run.result.pfTrack.last else { return }
        let center = viewport.screen(endpoint, layout: plot, canvasSize: size)
        let radius: CGFloat = baseline ? 5.5 : 4.5
        let marker = markerPath(
            shape: run.colorIndex,
            center: center,
            radius: radius
        )
        context.fill(marker, with: .color(color))
        context.stroke(
            marker,
            with: .color(theme.plotBackground.opacity(0.85)),
            lineWidth: 1
        )
        if baseline {
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - radius - 3,
                        y: center.y - radius - 3,
                        width: (radius + 3) * 2,
                        height: (radius + 3) * 2
                    )
                ),
                with: .color(theme.plotInk.opacity(0.9)),
                lineWidth: 1.2
            )
        }
        context.draw(
            Text(run.letter)
                .font(ThemeFont.mono(8, weight: .bold))
                .foregroundColor(color),
            at: CGPoint(x: center.x + 8, y: center.y - 9),
            anchor: .leading
        )
    }

    private func markerPath(shape: Int, center: CGPoint, radius: CGFloat) -> Path {
        switch shape % 4 {
        case 0:
            return Path(
                ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        case 1:
            return Path(
                CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        case 2:
            var path = Path()
            path.move(to: CGPoint(x: center.x, y: center.y - radius * 1.25))
            path.addLine(to: CGPoint(x: center.x + radius * 1.25, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.25))
            path.addLine(to: CGPoint(x: center.x - radius * 1.25, y: center.y))
            path.closeSubpath()
            return path
        default:
            var path = Path()
            path.move(to: CGPoint(x: center.x, y: center.y - radius * 1.2))
            path.addLine(to: CGPoint(x: center.x + radius * 1.15, y: center.y + radius))
            path.addLine(to: CGPoint(x: center.x - radius * 1.15, y: center.y + radius))
            path.closeSubpath()
            return path
        }
    }

    private func drawStartMarker(
        at point: XYPoint?,
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        guard let point else { return }
        let center = viewport.screen(point, layout: plot, canvasSize: size)
        let rect = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        context.stroke(
            Path(rect),
            with: .color(theme.trueRoute),
            lineWidth: 1.2
        )
    }

    private func drawScaleBar(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        let meterPixels = plot.scale * viewport.zoom
        let candidates: [Double] = [0.25, 0.5, 1, 2, 5, 10]
        let length = candidates.last(where: { CGFloat($0) * meterPixels <= 100 })
            ?? candidates[0]
        let pixels = CGFloat(length) * meterPixels
        let origin = CGPoint(x: 14, y: size.height - 20)
        var path = Path()
        path.move(to: origin)
        path.addLine(to: CGPoint(x: origin.x + pixels, y: origin.y))
        context.stroke(path, with: .color(theme.plotInk), lineWidth: 1.2)
        for x in [origin.x, origin.x + pixels] {
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: origin.y - 3))
            tick.addLine(to: CGPoint(x: x, y: origin.y + 3))
            context.stroke(tick, with: .color(theme.plotInk), lineWidth: 1.2)
        }
        context.draw(
            Text(String(format: length < 1 ? "%.2f m" : "%.1f m", length))
                .font(ThemeFont.mono(8))
                .foregroundColor(theme.plotMuted),
            at: CGPoint(x: origin.x + pixels / 2, y: origin.y - 8),
            anchor: .center
        )
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
