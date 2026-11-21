import AppKit
import Foundation

struct ExportedResultFiles {
    let pngURL: URL
    let csvURL: URL
}

enum ResultExporter {
    enum ExportError: LocalizedError {
        case noBitmapContext
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .noBitmapContext:
                "无法创建 PNG 绘图环境。"
            case .pngEncodingFailed:
                "无法编码 PNG 文件。"
            }
        }
    }

    private struct Bounds {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double

        init?(points: [XYPoint]) {
            guard let first = points.first else { return nil }
            minX = first.x
            maxX = first.x
            minY = first.y
            maxY = first.y
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
        }

        var width: Double { max(maxX - minX, 0.001) }
        var height: Double { max(maxY - minY, 0.001) }
    }

    static func export(
        result: PositioningResult,
        to directoryURL: URL,
        baseName: String
    ) throws -> ExportedResultFiles {
        let resolvedBaseName = availableBaseName(baseName, in: directoryURL)
        let pngURL = directoryURL.appendingPathComponent(resolvedBaseName).appendingPathExtension("png")
        let csvURL = directoryURL.appendingPathComponent(resolvedBaseName).appendingPathExtension("csv")

        let pngData = try renderPNG(result: result)
        try pngData.write(to: pngURL, options: .atomic)
        try csvData(result: result).write(to: csvURL, options: .atomic)
        return ExportedResultFiles(pngURL: pngURL, csvURL: csvURL)
    }

    private static func availableBaseName(_ baseName: String, in directoryURL: URL) -> String {
        var candidate = baseName
        var suffix = 2
        let fileManager = FileManager.default
        while ["png", "csv"].contains(where: { pathExtension in
            fileManager.fileExists(
                atPath: directoryURL
                    .appendingPathComponent(candidate)
                    .appendingPathExtension(pathExtension)
                    .path
            )
        }) {
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func csvData(result: PositioningResult) -> Data {
        var lines = [
            "series,index,x_m,y_m,radius95_m,core_radius80_m,"
                + "confidence_score,confidence_level,measurement_information,"
                + "localization_status,recovery_action"
        ]
        appendCSVRows(
            series: "true_route",
            points: result.routeXY,
            confidence: nil,
            health: nil,
            to: &lines
        )
        appendCSVRows(
            series: "pdr",
            points: result.pdrTrack,
            confidence: nil,
            health: nil,
            to: &lines
        )
        appendCSVRows(
            series: "pf",
            points: result.pfTrack,
            confidence: result.pfConfidenceHistory,
            health: result.localizationHealthHistory,
            to: &lines
        )
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func renderPNG(result: PositioningResult) throws -> Data {
        let pixelWidth = 1600
        let pixelHeight = 1000
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ExportError.noBitmapContext
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        draw(result: result, in: graphicsContext.cgContext, size: CGSize(width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportError.pngEncodingFailed
        }
        return data
    }

    private static func appendCSVRows(
        series: String,
        points: [XYPoint],
        confidence: [PFConfidenceSample]?,
        health: [LocalizationHealthSample]?,
        to lines: inout [String]
    ) {
        for (index, point) in points.enumerated() {
            let item = confidence.flatMap { index < $0.count ? $0[index] : nil }
            let healthItem = health.flatMap { index < $0.count ? $0[index] : nil }
            lines.append(
                "\(series),\(index),\(decimal(point.x)),\(decimal(point.y)),"
                    + "\(item.map { decimal($0.radius95M) } ?? ""),"
                    + "\(item.flatMap { $0.coreRadius80M }.map(decimal) ?? ""),"
                    + "\(item.map { decimal($0.score) } ?? ""),"
                    + "\(item?.level ?? ""),"
                    + "\(item.flatMap { $0.measurementInformation }.map(decimal) ?? ""),"
                    + "\(healthItem?.status ?? ""),"
                    + "\(healthItem?.action ?? "")"
            )
        }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func draw(result: PositioningResult, in context: CGContext, size: CGSize) {
        let fullRect = CGRect(origin: .zero, size: size)
        context.setFillColor(NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.065, alpha: 1).cgColor)
        context.fill(fullRect)

        drawText(
            result.displayName,
            at: CGPoint(x: 70, y: size.height - 82),
            font: .systemFont(ofSize: 38, weight: .semibold),
            color: .white
        )
        drawText(
            "GeomagMac · 地磁定位结果",
            at: CGPoint(x: 72, y: size.height - 120),
            font: .systemFont(ofSize: 20),
            color: NSColor.white.withAlphaComponent(0.58)
        )

        let plotRect = CGRect(x: 70, y: 190, width: size.width - 140, height: size.height - 350)
        let plotPath = CGPath(
            roundedRect: plotRect,
            cornerWidth: 24,
            cornerHeight: 24,
            transform: nil
        )
        context.saveGState()
        context.addPath(plotPath)
        context.clip()
        context.setFillColor(NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.085, alpha: 1).cgColor)
        context.fill(plotRect)
        drawGrid(in: context, rect: plotRect)

        let allPoints = result.routeXY + result.pdrTrack + result.pfTrack
        if let bounds = Bounds(points: allPoints) {
            drawConfidence(
                points: result.pfTrack,
                confidence: result.pfConfidenceHistory ?? [],
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawPolyline(
                result.routeXY,
                color: NSColor.white.withAlphaComponent(0.92),
                lineWidth: 4,
                dash: [],
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawPolyline(
                result.pdrTrack,
                color: NSColor(calibratedRed: 0.10, green: 0.84, blue: 0.92, alpha: 1),
                lineWidth: 5,
                dash: [],
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawPolyline(
                result.pfTrack,
                color: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.16, alpha: 1),
                lineWidth: 5,
                dash: [16, 10],
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawRecoveryMarkers(
                points: result.pfTrack,
                events: result.localizationRecoveryEvents ?? [],
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawEndpoint(
                result.pdrTrack.last,
                color: NSColor(calibratedRed: 0.10, green: 0.84, blue: 0.92, alpha: 1),
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawEndpoint(
                result.pfTrack.last,
                color: NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.16, alpha: 1),
                bounds: bounds,
                plotRect: plotRect,
                context: context
            )
            drawText(
                String(format: "%.1f × %.1f m", bounds.width, bounds.height),
                at: CGPoint(x: plotRect.maxX - 130, y: plotRect.minY + 24),
                font: .monospacedDigitSystemFont(ofSize: 16, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.48)
            )
        }
        context.restoreGState()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(2)
        context.addPath(plotPath)
        context.strokePath()

        drawLegend(
            at: CGPoint(x: 74, y: 145),
            hasConfidence: !(result.pfConfidenceHistory?.isEmpty ?? true),
            context: context
        )
        drawMetrics(result: result, at: CGPoint(x: 70, y: 55))
    }

    private static func drawGrid(in context: CGContext, rect: CGRect) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.065).cgColor)
        context.setLineWidth(1)
        for column in 1..<12 {
            let x = rect.minX + rect.width * CGFloat(column) / 12
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for row in 1..<8 {
            let y = rect.minY + rect.height * CGFloat(row) / 8
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()
    }

    private static func drawPolyline(
        _ points: [XYPoint],
        color: NSColor,
        lineWidth: CGFloat,
        dash: [CGFloat],
        bounds: Bounds,
        plotRect: CGRect,
        context: CGContext
    ) {
        guard points.count > 1 else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: dash)
        context.move(to: plotPoint(points[0], bounds: bounds, rect: plotRect))
        for point in points.dropFirst() {
            context.addLine(to: plotPoint(point, bounds: bounds, rect: plotRect))
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawEndpoint(
        _ point: XYPoint?,
        color: NSColor,
        bounds: Bounds,
        plotRect: CGRect,
        context: CGContext
    ) {
        guard let point else { return }
        let center = plotPoint(point, bounds: bounds, rect: plotRect)
        let marker = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: marker)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: marker)
    }

    private static func drawConfidence(
        points: [XYPoint],
        confidence: [PFConfidenceSample],
        bounds: Bounds,
        plotRect: CGRect,
        context: CGContext
    ) {
        let count = min(points.count, confidence.count)
        guard count > 0 else { return }
        let padding: CGFloat = 50
        let scale = min(
            max(plotRect.width - padding * 2, 1) / bounds.width,
            max(plotRect.height - padding * 2, 1) / bounds.height
        )
        let stride = max(1, Int(ceil(Double(count) / 10.0)))
        for index in 0..<count where index % stride == 0 || index == count - 1 {
            let item = confidence[index]
            let center = plotPoint(points[index], bounds: bounds, rect: plotRect)
            let radius = min(max(CGFloat(item.radius95M) * scale, 5), 96)
            let color: NSColor = switch item.level.lowercased() {
            case "high": .systemGreen
            case "medium": .systemOrange
            default: .systemRed
            }
            let ellipse = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor(color.withAlphaComponent(0.035).cgColor)
            context.fillEllipse(in: ellipse)
            context.setStrokeColor(color.withAlphaComponent(0.24).cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: ellipse)
        }
    }

    private static func drawRecoveryMarkers(
        points: [XYPoint],
        events: [LocalizationHealthSample],
        bounds: Bounds,
        plotRect: CGRect,
        context: CGContext
    ) {
        for event in events where points.indices.contains(event.stepIndex) {
            let center = plotPoint(points[event.stepIndex], bounds: bounds, rect: plotRect)
            let isReinitialize = event.action.hasPrefix("reinitialize")
            let radius: CGFloat = isReinitialize ? 15 : 12
            let color: NSColor = isReinitialize ? .systemPurple : .systemBlue
            context.saveGState()
            context.setFillColor(color.withAlphaComponent(0.92).cgColor)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: center.x, y: center.y - radius))
            context.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            context.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.addLine(to: CGPoint(x: center.x - radius, y: center.y))
            context.closePath()
            context.drawPath(using: .fillStroke)
            context.restoreGState()
        }
    }

    private static func plotPoint(_ point: XYPoint, bounds: Bounds, rect: CGRect) -> CGPoint {
        let padding: CGFloat = 50
        let availableWidth = max(rect.width - padding * 2, 1)
        let availableHeight = max(rect.height - padding * 2, 1)
        let scale = min(availableWidth / bounds.width, availableHeight / bounds.height)
        let plotWidth = bounds.width * scale
        let plotHeight = bounds.height * scale
        let left = rect.minX + (rect.width - plotWidth) / 2
        let bottom = rect.minY + (rect.height - plotHeight) / 2
        return CGPoint(
            x: left + (point.x - bounds.minX) * scale,
            y: bottom + (point.y - bounds.minY) * scale
        )
    }

    private static func drawLegend(
        at origin: CGPoint,
        hasConfidence: Bool,
        context: CGContext
    ) {
        let entries: [(String, NSColor, Bool)] = [
            ("真实路线", .white, false),
            ("PDR 路线", NSColor(calibratedRed: 0.10, green: 0.84, blue: 0.92, alpha: 1), false),
            ("PF 地磁匹配", NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.16, alpha: 1), true),
        ]
        var x = origin.x
        for (title, color, dashed) in entries {
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(5)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: dashed ? [12, 8] : [])
            context.move(to: CGPoint(x: x, y: origin.y + 8))
            context.addLine(to: CGPoint(x: x + 46, y: origin.y + 8))
            context.strokePath()
            context.restoreGState()
            drawText(
                title,
                at: CGPoint(x: x + 60, y: origin.y - 3),
                font: .systemFont(ofSize: 18, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.78)
            )
            x += title == "PF 地磁匹配" ? 225 : 190
        }
        if hasConfidence {
            let circle = CGRect(x: x + 8, y: origin.y - 2, width: 22, height: 22)
            context.setFillColor(NSColor.systemOrange.withAlphaComponent(0.08).cgColor)
            context.fillEllipse(in: circle)
            context.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: circle)
            drawText(
                "PF 95% 置信范围",
                at: CGPoint(x: x + 42, y: origin.y - 3),
                font: .systemFont(ofSize: 18, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.78)
            )
        }
    }

    private static func drawMetrics(result: PositioningResult, at origin: CGPoint) {
        let metrics = [
            "PF 平均误差  \(meters(result.pfErrorStats?.mean))",
            "PF 终点误差  \(meters(result.pfErrorStats?.final))",
            "PDR 平均误差  \(meters(result.pdrErrorStats?.mean))",
            "定位点  \(result.pfTrack.count)",
        ]
        var x = origin.x
        for metric in metrics {
            drawText(
                metric,
                at: CGPoint(x: x, y: origin.y),
                font: .monospacedDigitSystemFont(ofSize: 19, weight: .medium),
                color: NSColor.white.withAlphaComponent(0.76)
            )
            x += 365
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
}
