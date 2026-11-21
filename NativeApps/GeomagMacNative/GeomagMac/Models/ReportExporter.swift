import AppKit
import CoreGraphics
import Foundation

enum ReportExporter {
    enum ReportError: LocalizedError {
        case noConsumer
        case noContext

        var errorDescription: String? {
            switch self {
            case .noConsumer: "无法创建 PDF 数据写入器。"
            case .noContext: "无法创建 PDF 绘图环境。"
            }
        }
    }

    static func renderPDF(
        result: PositioningResult,
        mapName: String,
        gridCellSize: Double?,
        layers: ExportLayers
    ) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ReportError.noConsumer
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 842, height: 595)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw ReportError.noContext
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context,
            flipped: false
        )
        draw(
            result: result,
            mapName: mapName,
            gridCellSize: gridCellSize,
            layers: layers,
            size: mediaBox.size,
            context: context
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private struct ReportProjection {
        let bounds: CoordinateBounds
        let rect: CGRect

        var scale: CGFloat {
            let width = CGFloat(max(bounds.maxX - bounds.minX, 0.001))
            let height = CGFloat(max(bounds.maxY - bounds.minY, 0.001))
            return min(rect.width / width, rect.height / height)
        }

        var origin: CGPoint {
            let width = CGFloat(bounds.maxX - bounds.minX) * scale
            let height = CGFloat(bounds.maxY - bounds.minY) * scale
            return CGPoint(
                x: rect.minX + (rect.width - width) / 2,
                y: rect.minY + (rect.height - height) / 2
            )
        }

        func screen(_ point: XYPoint) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(point.x - bounds.minX) * scale,
                y: origin.y + CGFloat(point.y - bounds.minY) * scale
            )
        }
    }

    private static func draw(
        result: PositioningResult,
        mapName: String,
        gridCellSize: Double?,
        layers: ExportLayers,
        size: CGSize,
        context: CGContext
    ) {
        let paper = NSColor(
            calibratedRed: 0.9608,
            green: 0.9529,
            blue: 0.9333,
            alpha: 1
        )
        let panel = NSColor.white
        let hairline = NSColor(
            calibratedRed: 0.8471,
            green: 0.8314,
            blue: 0.7882,
            alpha: 1
        )
        let grid = NSColor(
            calibratedRed: 0.8902,
            green: 0.8784,
            blue: 0.8431,
            alpha: 1
        )
        let ink = NSColor(
            calibratedRed: 0.0784,
            green: 0.0941,
            blue: 0.1137,
            alpha: 1
        )
        let muted = NSColor(
            calibratedRed: 0.3529,
            green: 0.3843,
            blue: 0.4392,
            alpha: 1
        )
        let trace = NSColor(
            calibratedRed: 0.0392,
            green: 0.4510,
            blue: 0.3333,
            alpha: 1
        )
        let pdrBlue = NSColor(
            calibratedRed: 0.1216,
            green: 0.3059,
            blue: 0.4745,
            alpha: 1
        )

        context.setFillColor(paper.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let title = result.friendlyTitle
        drawText(
            title,
            at: CGPoint(x: 54, y: size.height - 66),
            font: .systemFont(ofSize: 24, weight: .semibold),
            color: ink
        )
        let subtitle = "\(result.routeLabel) · \(result.datasetKey) · "
            + "\(result.stepsDetected.map(String.init) ?? "—") 步"
        drawText(
            subtitle,
            at: CGPoint(x: 54, y: size.height - 88),
            font: .systemFont(ofSize: 11, weight: .regular),
            color: muted
        )
        drawText(
            "GeomagMac · 地磁定位结果 · \(mapName)",
            at: CGPoint(x: 54, y: size.height - 108),
            font: .systemFont(ofSize: 10, weight: .regular),
            color: muted
        )

        context.setStrokeColor(hairline.cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 54, y: size.height - 120))
        context.addLine(to: CGPoint(x: size.width - 54, y: size.height - 120))
        context.strokePath()

        let plotRect = CGRect(
            x: 54,
            y: 146,
            width: 474,
            height: 330
        )
        context.setFillColor(panel.cgColor)
        context.fill(plotRect)
        context.setStrokeColor(hairline.cgColor)
        context.stroke(plotRect)

        let bounds = reportBounds(result)
        let projection = ReportProjection(
            bounds: bounds,
            rect: plotRect.insetBy(dx: 28, dy: 28)
        )

        context.saveGState()
        context.clip(to: plotRect)
        drawGrid(
            projection: projection,
            step: gridCellSize ?? 0.25,
            color: grid,
            context: context
        )
        if layers.pf, layers.confidence {
            drawConfidence(
                result: result,
                projection: projection,
                color: trace,
                context: context
            )
        }
        if layers.trueRoute {
            drawPolyline(
                result.routeXY,
                projection: projection,
                color: ink,
                width: 1.2,
                dash: [2, 3],
                context: context
            )
        }
        if layers.pdr {
            drawPolyline(
                result.pdrTrack,
                projection: projection,
                color: pdrBlue,
                width: 2,
                dash: [],
                context: context
            )
            drawEndpoint(
                result.pdrTrack.last,
                projection: projection,
                color: pdrBlue,
                context: context
            )
        }
        if layers.pf {
            drawPolyline(
                result.pfTrack,
                projection: projection,
                color: trace,
                width: 2.4,
                dash: [],
                context: context
            )
            drawEndpoint(
                result.pfTrack.last,
                projection: projection,
                color: trace,
                context: context
            )
            drawRecoveryMarkers(
                result: result,
                projection: projection,
                context: context
            )
        }
        context.restoreGState()

        drawLegend(
            layers: layers,
            hasPF: !result.pfTrack.isEmpty,
            hasConfidence: !(result.pfConfidenceHistory?.isEmpty ?? true),
            ink: ink,
            muted: muted,
            trace: trace,
            pdr: pdrBlue,
            at: CGPoint(x: 552, y: 448)
        )

        drawMetrics(
            result: result,
            ink: ink,
            muted: muted,
            at: CGPoint(x: 552, y: 360)
        )

        drawText(
            "磁图 \(mapName)"
                + (gridCellSize.map { String(format: " · %.2f m 网格", $0) } ?? "")
                + (result.mapBounds.flatMap { map -> String? in
                    guard map.count == 4 else { return nil }
                    return String(
                        format: " · %.2f × %.2f m",
                        map[1] - map[0],
                        map[3] - map[2]
                    )
                } ?? ""),
            at: CGPoint(x: 552, y: 188),
            font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            color: muted
        )
        drawText(
            "算法 \(result.branch) · 纯 Swift 引擎",
            at: CGPoint(x: 552, y: 172),
            font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            color: muted
        )

        let date = DateFormatter.reportFormatter.string(from: Date())
        drawText(
            "导出 \(date) · 图层 "
                + [
                    layers.trueRoute ? "真实路线" : nil,
                    layers.pdr ? "PDR" : nil,
                    layers.pf ? "PF" : nil,
                    layers.pf && layers.confidence ? "置信" : nil,
                ].compactMap { $0 }.joined(separator: " / "),
            at: CGPoint(x: 54, y: 42),
            font: .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
            color: muted
        )
        drawText(
            "GeomagMac Native",
            at: CGPoint(x: size.width - 54 - 100, y: 42),
            font: .systemFont(ofSize: 9, weight: .medium),
            color: muted
        )
    }

    private static func reportBounds(_ result: PositioningResult) -> CoordinateBounds {
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
        let padding = 0.35
        return CoordinateBounds(
            minX: minX - padding,
            maxX: maxX + padding,
            minY: minY - padding,
            maxY: maxY + padding
        )
    }

    private static func drawGrid(
        projection: ReportProjection,
        step: Double,
        color: NSColor,
        context: CGContext
    ) {
        let bounds = projection.bounds
        var x = ceil(bounds.minX / step) * step
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(0.6)
        while x <= bounds.maxX {
            let path = CGMutablePath()
            path.move(to: projection.screen(XYPoint(x: x, y: bounds.minY)))
            path.addLine(to: projection.screen(XYPoint(x: x, y: bounds.maxY)))
            context.addPath(path)
            x += step
        }
        var y = ceil(bounds.minY / step) * step
        while y <= bounds.maxY {
            let path = CGMutablePath()
            path.move(to: projection.screen(XYPoint(x: bounds.minX, y: y)))
            path.addLine(to: projection.screen(XYPoint(x: bounds.maxX, y: y)))
            context.addPath(path)
            y += step
        }
        context.strokePath()
    }

    private static func drawPolyline(
        _ points: [XYPoint],
        projection: ReportProjection,
        color: NSColor,
        width: CGFloat,
        dash: [CGFloat],
        context: CGContext
    ) {
        guard points.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: projection.screen(points[0]))
        for point in points.dropFirst() {
            path.addLine(to: projection.screen(point))
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: dash)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawConfidence(
        result: PositioningResult,
        projection: ReportProjection,
        color: NSColor,
        context: CGContext
    ) {
        guard let confidence = result.pfConfidenceHistory, !confidence.isEmpty else {
            return
        }
        let count = min(result.pfTrack.count, confidence.count)
        guard count > 0 else { return }
        let stride = max(1, Int(ceil(Double(count) / 10.0)))
        for index in 0..<count where index % stride == 0 || index == count - 1 {
            let item = confidence[index]
            let center = projection.screen(result.pfTrack[index])
            let radius = CGFloat(item.radius95M) * projection.scale
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(color.withAlphaComponent(0.06).cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(color.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(0.7)
            context.strokeEllipse(in: rect)
        }
    }

    private static func drawRecoveryMarkers(
        result: PositioningResult,
        projection: ReportProjection,
        context: CGContext
    ) {
        for event in result.localizationRecoveryEvents ?? []
        where result.pfTrack.indices.contains(event.stepIndex) {
            let center = projection.screen(result.pfTrack[event.stepIndex])
            let radius: CGFloat = event.action.hasPrefix("reinitialize") ? 4 : 3
            let marker = CGMutablePath()
            marker.move(to: CGPoint(x: center.x, y: center.y - radius))
            marker.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            marker.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            marker.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            marker.closeSubpath()
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
            context.addPath(marker)
            context.fillPath()
        }
    }

    private static func drawEndpoint(
        _ point: XYPoint?,
        projection: ReportProjection,
        color: NSColor,
        context: CGContext
    ) {
        guard let point else { return }
        let center = projection.screen(point)
        let rect = CGRect(
            x: center.x - 3,
            y: center.y - 3,
            width: 6,
            height: 6
        )
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
    }

    private static func drawLegend(
        layers: ExportLayers,
        hasPF: Bool,
        hasConfidence: Bool,
        ink: NSColor,
        muted: NSColor,
        trace: NSColor,
        pdr: NSColor,
        at origin: CGPoint
    ) {
        var y = origin.y
        drawText(
            "图例",
            at: CGPoint(x: origin.x, y: y + 16),
            font: .systemFont(ofSize: 9, weight: .semibold),
            color: muted
        )
        if layers.trueRoute {
            drawLegendRow(
                title: "真实路线",
                color: ink,
                dashed: true,
                at: CGPoint(x: origin.x, y: y)
            )
            y -= 17
        }
        if layers.pdr {
            drawLegendRow(
                title: "PDR 路线",
                color: pdr,
                dashed: false,
                at: CGPoint(x: origin.x, y: y)
            )
            y -= 17
        }
        if layers.pf, hasPF {
            drawLegendRow(
                title: "PF 地磁匹配",
                color: trace,
                dashed: false,
                at: CGPoint(x: origin.x, y: y)
            )
            y -= 17
        }
        if layers.pf, layers.confidence, hasConfidence {
            let circle = CGRect(x: origin.x, y: y - 1, width: 9, height: 9)
            NSColor.black.setStroke()
            let path = NSBezierPath(ovalIn: circle)
            path.lineWidth = 1
            trace.withAlphaComponent(0.7).setStroke()
            path.stroke()
            drawText(
                "95% 置信范围",
                at: CGPoint(x: origin.x + 18, y: y - 2),
                font: .systemFont(ofSize: 9, weight: .regular),
                color: ink
            )
        }
    }

    private static func drawLegendRow(
        title: String,
        color: NSColor,
        dashed: Bool,
        at origin: CGPoint
    ) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: origin.x, y: origin.y + 4))
        path.line(to: CGPoint(x: origin.x + 22, y: origin.y + 4))
        path.lineWidth = 2
        if dashed {
            path.setLineDash([2, 2], count: 2, phase: 0)
        }
        color.setStroke()
        path.stroke()
        drawText(
            title,
            at: CGPoint(x: origin.x + 30, y: origin.y - 2),
            font: .systemFont(ofSize: 9, weight: .regular),
            color: color
        )
    }

    private static func drawMetrics(
        result: PositioningResult,
        ink: NSColor,
        muted: NSColor,
        at origin: CGPoint
    ) {
        let metrics: [(String, String)] = [
            ("PF 终点误差", meters(result.pfErrorStats?.final)),
            ("PDR 终点误差", meters(result.pdrErrorStats?.final)),
            ("PF 横向误差", meters(result.pfCrossTrackErrorStats?.mean)),
            ("PF 沿程误差", meters(result.pfAlongTrackErrorStats?.mean)),
            ("PF 转角误差", degrees(result.pfTurnAngleErrorStats?.mean)),
            ("PF 路程比例", percent(result.pfPathLengthRatio)),
            ("PF 闭合误差", meters(result.pfClosureErrorM)),
        ]
        drawText(
            "指标",
            at: CGPoint(x: origin.x, y: origin.y + 16),
            font: .systemFont(ofSize: 9, weight: .semibold),
            color: muted
        )
        var y = origin.y
        for (title, value) in metrics {
            drawText(
                title,
                at: CGPoint(x: origin.x, y: y - 2),
                font: .systemFont(ofSize: 9, weight: .regular),
                color: muted
            )
            drawText(
                value,
                at: CGPoint(x: origin.x + 150, y: y - 2),
                font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                color: ink
            )
            y -= 18
        }
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        font: NSFont,
        color: NSColor
    ) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
            ]
        )
    }

    private static func meters(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f m", value)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private static func degrees(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f°", value)
    }
}

private extension DateFormatter {
    static let reportFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
