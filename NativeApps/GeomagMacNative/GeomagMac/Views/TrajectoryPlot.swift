import AppKit
import SwiftUI

struct PlotLayers: Equatable {
    var trueRoute = true
    var pdr = true
    var pf = true
    var confidence = true
}

struct TrajectoryPlot: View {
    let result: PositioningResult
    let layers: PlotLayers
    let progress: Double
    let selectedStep: Int?
    let gridCellSize: Double?
    @Binding var viewport: PlotViewport
    var onSelectStep: (Int?) -> Void

    @Environment(\.geomagTheme) private var theme
    @State private var hoverLocation: CGPoint?
    @State private var panStart: CGSize?
    @State private var magnificationStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, canvasSize in
                    draw(
                        context: &context,
                        size: canvasSize
                    )
                }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(magnificationGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        onSelectStep(nearestStep(to: value.location, size: size))
                    }
                )
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
                        let factor = min(
                            max(exp(Double(delta) * 0.05), 0.8),
                            1.25
                        )
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
                if size.width >= 640 {
                    summaryOverlay
                }
                readoutOverlay(size: size)
            }
        }
        .background(theme.plotBackground)
        .clipShape(RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.panelRadius)
                .stroke(theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("轨迹画布")
        .accessibilityValue(
            "\(result.datasetKey) · "
                + "\(result.stepsDetected.map(String.init) ?? "—") 步"
                + (selectedStep.map { " · 已选第 \($0) 步" } ?? "")
        )
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
            Text("轨迹对照")
                .font(ThemeFont.mono(8, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(theme.plotMuted)
                .padding(.bottom, 1)
            legendRow(.dashed, color: theme.trueRoute, title: "真实路线")
            legendRow(.solid, color: theme.pdr, title: "PDR 惯性推算")
            legendRow(.solid, color: theme.pf, title: "PF 地磁匹配")
            legendRow(.confidence, color: theme.confidenceHigh, title: "95% 置信范围")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func legendRow(
        _ style: LineSwatchStyle,
        color: Color,
        title: String
    ) -> some View {
        HStack(spacing: 7) {
            LineSwatch(style: style, color: color, width: 20)
            Text(title)
                .font(ThemeFont.caption(9.5))
                .foregroundStyle(theme.plotInk)
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

    private var summaryOverlay: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                if let steps = result.stepsDetected {
                    summaryValue("\(steps) 步")
                }
                if let interval = result.activeWalkInterval {
                    Text(String(format: "%.1f s · %d 帧", interval.duration, result.sensorFramesUsed ?? 0))
                        .font(ThemeFont.mono(8.5))
                        .foregroundStyle(theme.plotMuted)
                }
                summaryDivider
                if let final = result.pfErrorStats?.final {
                    summaryValue(String(format: "%.2f m", final))
                    Text("终点误差 · 闭合")
                        .font(ThemeFont.mono(8.5))
                        .foregroundStyle(theme.plotMuted)
                }
                summaryDivider
                if let map = result.mapBounds, map.count == 4 {
                    summaryValue(
                        String(format: "%.2f m", map[1] - map[0])
                    )
                    Text("磁图宽度")
                        .font(ThemeFont.mono(8.5))
                        .foregroundStyle(theme.plotMuted)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 16)
        .allowsHitTesting(false)
    }

    private func summaryValue(_ text: String) -> some View {
        Text(text)
            .font(ThemeFont.mono(13, weight: .semibold))
            .foregroundStyle(theme.plotInk)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(theme.plotBoundary)
            .frame(width: 58, height: 1)
            .padding(.vertical, 3)
    }

    private func readoutOverlay(size: CGSize) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 9) {
                if let location = hoverLocation {
                    let point = viewport.world(
                        location,
                        layout: layout(for: size),
                        canvasSize: size
                    )
                    Text(String(format: "x %.2f m", point.x))
                    readoutDivider
                    Text(String(format: "y %.2f m", point.y))
                    if let step = nearestStep(to: location, size: size) {
                        readoutDivider
                        Text(stepText(step))
                    }
                } else if let selectedStep {
                    Text(stepText(selectedStep))
                    readoutDivider
                    Text("已固定 · Esc 取消")
                } else {
                    Text("悬停读取坐标 · 点击固定步")
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

    private func stepText(_ step: Int) -> String {
        guard let sample = TrajectoryAnalysis.stepSamples(for: result)
            .first(where: { $0.id == step }) else {
            return "PF 第 \(step) 步"
        }
        let level = sample.confidence?.localizedLevel ?? "—"
        return "PF 第 \(step) 步 · 可靠度\(level)"
    }

    private func nearestStep(to location: CGPoint, size: CGSize) -> Int? {
        guard size.width > 0, size.height > 0 else { return nil }
        let plot = layout(for: size)
        var best: (id: Int, distance: CGFloat)?
        for sample in TrajectoryAnalysis.stepSamples(for: result) {
            let screen = viewport.screen(
                sample.pfPoint,
                layout: plot,
                canvasSize: size
            )
            let distance = hypot(screen.x - location.x, screen.y - location.y)
            if best == nil || distance < best!.distance {
                best = (sample.id, distance)
            }
        }
        guard let best, best.distance <= 26 else { return nil }
        return best.id
    }

    private func layout(for size: CGSize) -> PlotLayout {
        PlotLayout(
            bounds: plotBounds,
            rect: CGRect(origin: .zero, size: size)
        )
    }

    private var plotBounds: CoordinateBounds {
        if let map = result.mapBounds,
           map.count == 4,
           map.allSatisfy(\.isFinite),
           map[1] > map[0],
           map[3] > map[2] {
            return CoordinateBounds(
                minX: map[0],
                maxX: map[1],
                minY: map[2],
                maxY: map[3]
            )
        }
        let points = result.routeXY + result.pdrTrack + result.pfTrack
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
        let bounds = plotBounds

        drawGrid(context: &context, plot: plot, size: size)
        drawMapFrame(context: &context, plot: plot)
        if layers.confidence {
            drawConfidence(context: &context, plot: plot, size: size)
        }
        if layers.trueRoute {
            drawPolyline(
                result.routeXY,
                color: theme.trueRoute,
                width: 1.3,
                dash: [2, 4],
                opacity: 0.62,
                context: &context,
                plot: plot,
                size: size
            )
        }
        if layers.pdr {
            drawPolyline(
                visiblePrefix(result.pdrTrack, progress: progress),
                color: theme.pdr,
                width: 1.9,
                dash: [],
                opacity: 0.86,
                context: &context,
                plot: plot,
                size: size
            )
        }
        if layers.pf {
            let visible = visiblePrefix(result.pfTrack, progress: progress)
            drawPolyline(
                visible,
                color: theme.pf.opacity(0.16),
                width: 6,
                dash: [],
                opacity: 0.45,
                context: &context,
                plot: plot,
                size: size
            )
            drawPolyline(
                visible,
                color: theme.pf,
                width: 2.5,
                dash: [],
                opacity: 1,
                context: &context,
                plot: plot,
                size: size
            )
            drawRecoveryMarkers(context: &context, plot: plot, size: size)
        }
        drawEndpoints(context: &context, plot: plot, size: size)
        drawSelectedStep(context: &context, plot: plot)
        drawScaleBar(context: &context, plot: plot, size: size)
        drawDimensions(context: &context, plot: plot, size: size, bounds: bounds)
    }

    private func drawGrid(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        context.drawLayer { layer in
            let mapPath = mapPath(plot: plot)
            layer.clip(to: mapPath)

            let bounds = plotBounds
            let step = gridCellSize ?? 0.25
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
                layer.stroke(
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
                layer.stroke(
                    path,
                    with: .color(major ? theme.plotGridMajor : theme.plotGrid),
                    lineWidth: 1
                )
                y += step
            }
        }
    }

    private func drawMapFrame(context: inout GraphicsContext, plot: PlotLayout) {
        context.stroke(
            mapPath(plot: plot),
            with: .color(theme.plotBoundary),
            lineWidth: 1
        )
    }

    private func mapPath(plot: PlotLayout) -> Path {
        let bounds = plotBounds
        let size = plot.rect.size
        let points = [
            XYPoint(x: bounds.minX, y: bounds.minY),
            XYPoint(x: bounds.maxX, y: bounds.minY),
            XYPoint(x: bounds.maxX, y: bounds.maxY),
            XYPoint(x: bounds.minX, y: bounds.maxY),
        ].map { viewport.screen($0, layout: plot, canvasSize: size) }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func drawConfidence(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        guard let confidence = result.pfConfidenceHistory, !confidence.isEmpty else {
            return
        }
        let visibleCount = visiblePrefix(result.pfTrack, progress: progress).count
        let count = min(visibleCount - 1, confidence.count)
        guard count > 0 else { return }
        let stride = max(1, Int(ceil(Double(count) / 10.0)))
        for index in 0..<count where index % stride == 0 || index == count - 1 {
            guard result.pfTrack.indices.contains(index + 1) else { continue }
            let item = confidence[index]
            let center = viewport.screen(
                result.pfTrack[index + 1],
                layout: plot,
                canvasSize: size
            )
            let radius = CGFloat(item.radius95M) * plot.scale * viewport.zoom
            let color = confidenceColor(item.level)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(color.opacity(0.035))
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color.opacity(0.24)),
                lineWidth: 0.8
            )
        }
    }

    private func confidenceColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "high": theme.confidenceHigh
        case "medium": theme.confidenceMedium
        default: theme.confidenceLow
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
        let first = viewport.screen(points[0], layout: plot, canvasSize: size)
        path.move(to: first)
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

    private func drawRecoveryMarkers(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        guard let events = result.localizationRecoveryEvents else { return }
        for event in events where result.pfTrack.indices.contains(event.stepIndex) {
            let center = viewport.screen(
                result.pfTrack[event.stepIndex],
                layout: plot,
                canvasSize: size
            )
            let radius: CGFloat = event.action.hasPrefix("reinitialize") ? 7 : 5.5
            var marker = Path()
            marker.move(to: CGPoint(x: center.x, y: center.y - radius))
            marker.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            marker.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            marker.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            marker.closeSubpath()
            let color = event.action.hasPrefix("reinitialize")
                ? Color.purple
                : theme.signal
            context.fill(marker, with: .color(color.opacity(0.9)))
            context.stroke(
                marker,
                with: .color(theme.plotInk.opacity(0.9)),
                lineWidth: 1
            )
        }
    }

    private func drawEndpoints(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        let pdr = visiblePrefix(result.pdrTrack, progress: progress)
        let pf = visiblePrefix(result.pfTrack, progress: progress)
        var points: [(XYPoint, Color)] = []
        if layers.pdr, let last = pdr.last {
            points.append((last, theme.pdr))
        }
        if layers.pf, let last = pf.last {
            points.append((last, theme.pf))
        }
        for (point, color) in points {
            let center = viewport.screen(point, layout: plot, canvasSize: size)
            let rect = CGRect(
                x: center.x - 3.5,
                y: center.y - 3.5,
                width: 7,
                height: 7
            )
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(theme.plotBackground.opacity(0.8)),
                lineWidth: 1
            )
        }

        if let start = result.routeXY.first {
            let center = viewport.screen(start, layout: plot, canvasSize: size)
            let rect = CGRect(
                x: center.x - 3,
                y: center.y - 3,
                width: 6,
                height: 6
            )
            context.stroke(
                Path(rect),
                with: .color(theme.trueRoute),
                lineWidth: 1.2
            )
        }
    }

    private func drawSelectedStep(context: inout GraphicsContext, plot: PlotLayout) {
        guard let selectedStep,
              result.pfTrack.indices.contains(selectedStep) else {
            return
        }
        let size = plot.rect.size
        let center = viewport.screen(
            result.pfTrack[selectedStep],
            layout: plot,
            canvasSize: size
        )
        let radius: CGFloat = 7
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(theme.plotInk),
            lineWidth: 1.4
        )
    }

    private func drawScaleBar(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize
    ) {
        let meterPixels = plot.scale * viewport.zoom
        let candidates: [Double] = [0.25, 0.5, 1, 2, 5]
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
            Text(String(format: length == 0.25 ? "%.2f m" : "%.1f m", length))
                .font(ThemeFont.mono(8))
                .foregroundColor(theme.plotMuted),
            at: CGPoint(x: origin.x + pixels / 2, y: origin.y - 8),
            anchor: .center
        )
    }

    private func drawDimensions(
        context: inout GraphicsContext,
        plot: PlotLayout,
        size: CGSize,
        bounds: CoordinateBounds
    ) {
        let width = bounds.maxX - bounds.minX
        let height = bounds.maxY - bounds.minY
        var text = String(format: "%.2f × %.2f m", width, height)
        if let gridCellSize {
            text += String(format: " · 网格 %.2f m", gridCellSize)
        }
        context.draw(
            Text(text)
                .font(ThemeFont.mono(8))
                .foregroundColor(theme.plotMuted),
            at: CGPoint(x: size.width - 14, y: size.height - 16),
            anchor: .trailing
        )
    }

    private func visiblePrefix(_ points: [XYPoint], progress: Double) -> [XYPoint] {
        guard !points.isEmpty else { return [] }
        let count = max(
            1,
            Int((Double(points.count) * min(max(progress, 0), 1)).rounded(.up))
        )
        return Array(points.prefix(min(count, points.count)))
    }
}

private struct ScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onScroll = onScroll
    }

    private final class MonitorView: NSView {
        var onScroll: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self,
                      event.window == self.window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(local) else { return event }
                let delta = event.scrollingDeltaY
                guard abs(delta) > 0.01 else { return event }
                let anchor = CGPoint(
                    x: local.x,
                    y: self.bounds.height - local.y
                )
                self.onScroll?(delta, anchor)
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
