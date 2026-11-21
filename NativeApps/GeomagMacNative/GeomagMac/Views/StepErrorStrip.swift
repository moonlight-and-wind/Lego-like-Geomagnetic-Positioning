import SwiftUI

struct StepErrorStrip: View {
    let result: PositioningResult
    let progress: Double
    let selectedStep: Int?
    var onSelect: (Int) -> Void

    @Environment(\.geomagTheme) private var theme
    @State private var hoverLocation: CGPoint?

    private var samples: [StepSample] {
        TrajectoryAnalysis.stepSamples(for: result)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("逐步横向偏差")
                    .font(ThemeFont.micro(9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.muted)
                Text("按真实路线最近线段投影")
                    .font(ThemeFont.caption(8.5))
                    .foregroundStyle(theme.faint)
                Text("第 1–\(max(1, result.pfTrack.count - 1)) 步")
                    .font(ThemeFont.mono(8.5))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                Spacer()
                if let maximum = maximumError {
                    Text(String(format: "最大 %.2f m", maximum))
                        .font(ThemeFont.mono(8.5))
                        .foregroundStyle(theme.muted)
                }
            }

            if samples.count < 2 {
                Text("PF 步数不足，无法生成逐步偏差。")
                    .font(ThemeFont.caption(9))
                    .foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                GeometryReader { proxy in
                    Canvas { context, size in
                        draw(context: &context, size: size)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            hoverLocation = location
                        case .ended:
                            hoverLocation = nil
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let rect = plotRect(size: proxy.size)
                                let fraction = min(
                                    max((value.location.x - rect.minX) / max(rect.width, 1), 0),
                                    1
                                )
                                let step = TrajectoryAnalysis.stepIndex(
                                    forProgress: fraction,
                                    pointCount: result.pfTrack.count
                                )
                                onSelect(min(max(step, 1), result.pfTrack.count - 1))
                            }
                    )
                }
                .frame(height: 54)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: 1)
        }
        .accessibilityLabel("逐步横向偏差")
        .accessibilityValue(
            selectedStep.map { "已选第 \($0) 步" } ?? "未选择步"
        )
    }

    private var maximumError: Double? {
        let values = samples.compactMap(\.pfLateralError)
            + samples.compactMap(\.pdrLateralError)
        guard let maximum = values.max() else { return nil }
        return max(maximum, 0.2)
    }

    private func plotRect(size: CGSize) -> CGRect {
        CGRect(x: 8, y: 4, width: max(size.width - 16, 1), height: max(size.height - 12, 1))
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let rect = plotRect(size: size)
        guard let maximum = maximumError, maximum > 0 else { return }

        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.stroke(
            baseline,
            with: .color(theme.plotBoundary),
            lineWidth: 0.8
        )

        for corner in TrajectoryAnalysis.routeCorners(result.routeXY) {
            let x = rect.minX + CGFloat(corner.fraction) * rect.width
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: rect.maxY - 3))
            tick.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(
                tick,
                with: .color(theme.plotBoundary),
                lineWidth: 1
            )
        }

        let pfPoints = samples.enumerated().compactMap { index, sample -> (Int, CGPoint)? in
            guard let error = sample.pfLateralError else { return nil }
            return (
                sample.id,
                CGPoint(
                    x: xPosition(index: index, count: samples.count, rect: rect),
                    y: rect.maxY - CGFloat(error / maximum) * rect.height
                )
            )
        }
        let pdrPoints = samples.enumerated().compactMap { index, sample -> CGPoint? in
            guard let error = sample.pdrLateralError else { return nil }
            return CGPoint(
                x: xPosition(index: index, count: samples.count, rect: rect),
                y: rect.maxY - CGFloat(error / maximum) * rect.height
            )
        }

        if pfPoints.count > 1 {
            var area = Path()
            area.move(to: CGPoint(x: pfPoints[0].1.x, y: rect.maxY))
            for point in pfPoints {
                area.addLine(to: point.1)
            }
            area.addLine(to: CGPoint(x: pfPoints[pfPoints.count - 1].1.x, y: rect.maxY))
            area.closeSubpath()
            context.fill(area, with: .color(theme.trace.opacity(0.07)))

            var path = Path()
            path.move(to: pfPoints[0].1)
            for point in pfPoints.dropFirst() {
                path.addLine(to: point.1)
            }
            context.stroke(
                path,
                with: .color(theme.trace),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }

        if pdrPoints.count > 1 {
            var path = Path()
            path.move(to: pdrPoints[0])
            for point in pdrPoints.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(
                path,
                with: .color(theme.pdr.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
            )
        }

        if let events = result.localizationRecoveryEvents {
            for event in events {
                guard let point = pfPoints.first(where: { $0.0 == event.stepIndex }) else {
                    continue
                }
                let dotRect = CGRect(
                    x: point.1.x - 2.5,
                    y: point.1.y - 2.5,
                    width: 5,
                    height: 5
                )
                context.fill(
                    Path(ellipseIn: dotRect),
                    with: .color(theme.signal)
                )
            }
        }

        let progressX = rect.minX + CGFloat(min(max(progress, 0), 1)) * rect.width
        var progressLine = Path()
        progressLine.move(to: CGPoint(x: progressX, y: rect.minY))
        progressLine.addLine(to: CGPoint(x: progressX, y: rect.maxY))
        context.stroke(
            progressLine,
            with: .color(theme.signal.opacity(0.55)),
            lineWidth: 1
        )

        if let selectedStep {
            let fraction = TrajectoryAnalysis.progress(
                forStep: selectedStep,
                pointCount: result.pfTrack.count
            )
            let x = rect.minX + CGFloat(fraction) * rect.width
            var selectedLine = Path()
            selectedLine.move(to: CGPoint(x: x, y: rect.minY))
            selectedLine.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(
                selectedLine,
                with: .color(theme.plotInk.opacity(0.8)),
                lineWidth: 1
            )
            if let sample = samples.first(where: { $0.id == selectedStep }),
               let error = sample.pfLateralError {
                let y = rect.maxY - CGFloat(error / maximum) * rect.height
                let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                context.fill(
                    Path(ellipseIn: dot),
                    with: .color(theme.trace)
                )
            }
        }

        if let hoverLocation {
            let x = min(max(hoverLocation.x, rect.minX), rect.maxX)
            var hoverLine = Path()
            hoverLine.move(to: CGPoint(x: x, y: rect.minY))
            hoverLine.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(
                hoverLine,
                with: .color(theme.plotInk.opacity(0.35)),
                style: StrokeStyle(lineWidth: 0.8, dash: [2, 3])
            )
            let fraction = (x - rect.minX) / max(rect.width, 1)
            let step = TrajectoryAnalysis.stepIndex(
                forProgress: Double(fraction),
                pointCount: result.pfTrack.count
            )
            if let sample = samples.first(where: { $0.id == step }) {
                let text = String(
                    format: "第 %d 步 · PF %@ · PDR %@",
                    step,
                    sample.pfLateralError.map { String(format: "%.2f m", $0) } ?? "—",
                    sample.pdrLateralError.map { String(format: "%.2f m", $0) } ?? "—"
                )
                context.draw(
                    Text(text)
                        .font(ThemeFont.mono(8))
                        .foregroundColor(theme.plotMuted),
                    at: CGPoint(x: rect.maxX, y: rect.minY + 2),
                    anchor: .topTrailing
                )
            }
        }
    }

    private func xPosition(index: Int, count: Int, rect: CGRect) -> CGFloat {
        guard count > 1 else { return rect.minX }
        return rect.minX + CGFloat(Double(index) / Double(count - 1)) * rect.width
    }
}
