import SwiftUI

struct TrajectoryCanvas: View {
    let result: PositioningResult
    let showTrueRoute: Bool
    let showPDR: Bool
    let showPF: Bool
    let showPFConfidence: Bool
    let playbackProgress: Double

    @State private var zoom = 1.0
    @State private var committedZoom = 1.0
    @State private var pan = CGSize.zero
    @State private var committedPan = CGSize.zero

    private let trueRouteColor = Color.white.opacity(0.92)
    private let pdrColor = Color(red: 0.10, green: 0.84, blue: 0.92)
    private let pfColor = Color(red: 1.0, green: 0.78, blue: 0.16)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                drawGrid(context: &context, size: size)

                let allPoints = result.routeXY + result.pdrTrack + result.pfTrack
                guard let bounds = PlotBounds(points: allPoints) else { return }

                if showTrueRoute {
                    draw(
                        points: result.routeXY,
                        color: trueRouteColor,
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round),
                        bounds: bounds,
                        context: &context,
                        size: size
                    )
                }

                if showPDR {
                    draw(
                        points: visiblePrefix(result.pdrTrack),
                        color: pdrColor,
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round),
                        bounds: bounds,
                        context: &context,
                        size: size
                    )
                }

                if showPF {
                    if showPFConfidence {
                        drawPFConfidence(
                            bounds: bounds,
                            context: &context,
                            size: size
                        )
                    }
                    draw(
                        points: visiblePrefix(result.pfTrack),
                        color: pfColor,
                        style: StrokeStyle(
                            lineWidth: 2.8,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [9, 6]
                        ),
                        bounds: bounds,
                        context: &context,
                        size: size
                    )
                    drawRecoveryMarkers(
                        bounds: bounds,
                        context: &context,
                        size: size
                    )
                }

                drawEndpoints(bounds: bounds, context: &context, size: size)
                let dimensions = String(format: "%.1f × %.1f m", bounds.width, bounds.height)
                context.draw(
                    Text(dimensions).font(.caption2).foregroundColor(.white.opacity(0.45)),
                    at: CGPoint(x: size.width - 48, y: size.height - 18),
                    anchor: .center
                )
            }
            .contentShape(Rectangle())
            .gesture(magnificationGesture.simultaneously(with: dragGesture))
            .onTapGesture(count: 2, perform: resetViewport)

            Button(action: resetViewport) {
                Label("复位视图", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("复位缩放与位置（也可以双击画布）")
            .padding(12)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.075, green: 0.09, blue: 0.12), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 0.65), 8.0)
            }
            .onEnded { _ in
                committedZoom = zoom
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                pan = CGSize(
                    width: committedPan.width + value.translation.width,
                    height: committedPan.height + value.translation.height
                )
            }
            .onEnded { _ in
                committedPan = pan
            }
    }

    private func resetViewport() {
        withAnimation(.easeInOut(duration: 0.2)) {
            zoom = 1.0
            committedZoom = 1.0
            pan = .zero
            committedPan = .zero
        }
    }

    private func visiblePrefix(_ points: [XYPoint]) -> [XYPoint] {
        guard !points.isEmpty else { return [] }
        let count = max(1, Int((Double(points.count) * playbackProgress).rounded(.up)))
        return Array(points.prefix(min(count, points.count)))
    }

    private func draw(
        points: [XYPoint],
        color: Color,
        style: StrokeStyle,
        bounds: PlotBounds,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard points.count > 1 else { return }
        var path = Path()
        path.move(to: screenPoint(points[0], bounds: bounds, size: size))
        for point in points.dropFirst() {
            path.addLine(to: screenPoint(point, bounds: bounds, size: size))
        }
        context.stroke(path, with: .color(color), style: style)
    }

    private func drawEndpoints(
        bounds: PlotBounds,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard playbackProgress > 0 else { return }
        let candidates: [(Bool, [XYPoint], Color)] = [
            (showPDR, visiblePrefix(result.pdrTrack), pdrColor),
            (showPF, visiblePrefix(result.pfTrack), pfColor),
        ]
        for (visible, points, color) in candidates where visible {
            guard let point = points.last else { continue }
            let center = screenPoint(point, bounds: bounds, size: size)
            let marker = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.fill(marker, with: .color(color))
            context.stroke(marker, with: .color(.black.opacity(0.65)), lineWidth: 1)
        }
    }

    private func drawPFConfidence(
        bounds: PlotBounds,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let confidence = result.pfConfidenceHistory, !confidence.isEmpty else { return }
        let points = visiblePrefix(result.pfTrack)
        let count = min(points.count, confidence.count)
        guard count > 0 else { return }
        let stride = max(1, Int(ceil(Double(count) / 10.0)))
        for index in 0..<count where index % stride == 0 || index == count - 1 {
            let item = confidence[index]
            let center = screenPoint(points[index], bounds: bounds, size: size)
            let radius = min(max(item.radius95M * plotScale(bounds: bounds, size: size) * zoom, 3), 72)
            let ellipse = Path(
                ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            let color: Color = switch item.level.lowercased() {
            case "high": .green
            case "medium": .orange
            default: .red
            }
            context.fill(ellipse, with: .color(color.opacity(0.035)))
            context.stroke(ellipse, with: .color(color.opacity(0.24)), lineWidth: 1)
        }
    }

    private func drawRecoveryMarkers(
        bounds: PlotBounds,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let events = result.localizationRecoveryEvents else { return }
        let visibleCount = visiblePrefix(result.pfTrack).count
        for event in events where event.stepIndex < visibleCount {
            guard result.pfTrack.indices.contains(event.stepIndex) else { continue }
            let center = screenPoint(result.pfTrack[event.stepIndex], bounds: bounds, size: size)
            let isReinitialize = event.action.hasPrefix("reinitialize")
            let radius = isReinitialize ? 9.0 : 7.0
            var marker = Path()
            marker.move(to: CGPoint(x: center.x, y: center.y - radius))
            marker.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            marker.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            marker.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            marker.closeSubpath()
            let color: Color = isReinitialize ? .purple : .blue
            context.fill(marker, with: .color(color.opacity(0.90)))
            context.stroke(marker, with: .color(.white.opacity(0.90)), lineWidth: 1.4)
        }
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        var minor = Path()
        let columns = 12
        let rows = 8
        for column in 1..<columns {
            let x = size.width * Double(column) / Double(columns)
            minor.move(to: CGPoint(x: x, y: 0))
            minor.addLine(to: CGPoint(x: x, y: size.height))
        }
        for row in 1..<rows {
            let y = size.height * Double(row) / Double(rows)
            minor.move(to: CGPoint(x: 0, y: y))
            minor.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(minor, with: .color(.white.opacity(0.055)), lineWidth: 1)
    }

    private func screenPoint(_ point: XYPoint, bounds: PlotBounds, size: CGSize) -> CGPoint {
        let scale = plotScale(bounds: bounds, size: size)
        let plotWidth = bounds.width * scale
        let plotHeight = bounds.height * scale
        let left = (size.width - plotWidth) / 2
        let bottom = (size.height - plotHeight) / 2
        let base = CGPoint(
            x: left + (point.x - bounds.minX) * scale,
            y: size.height - (bottom + (point.y - bounds.minY) * scale)
        )
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGPoint(
            x: center.x + (base.x - center.x) * zoom + pan.width,
            y: center.y + (base.y - center.y) * zoom + pan.height
        )
    }

    private func plotScale(bounds: PlotBounds, size: CGSize) -> Double {
        let padding = 34.0
        let availableWidth = max(size.width - padding * 2, 1)
        let availableHeight = max(size.height - padding * 2, 1)
        return min(availableWidth / bounds.width, availableHeight / bounds.height)
    }
}

private struct PlotBounds {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    init?(points: [XYPoint]) {
        guard let first = points.first else { return nil }
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
        if abs(maxX - minX) < 0.001 {
            minX -= 0.5
            maxX += 0.5
        }
        if abs(maxY - minY) < 0.001 {
            minY -= 0.5
            maxY += 0.5
        }
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    var width: Double { max(maxX - minX, 0.001) }
    var height: Double { max(maxY - minY, 0.001) }
}
