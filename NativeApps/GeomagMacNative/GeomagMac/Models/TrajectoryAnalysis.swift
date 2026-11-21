import CoreGraphics
import Foundation

struct RouteProjection: Equatable {
    let distance: Double
    let segmentIndex: Int
    let projectedPoint: XYPoint
    let parameter: Double
}

struct StepSample: Identifiable, Equatable {
    let id: Int
    let pfPoint: XYPoint
    let pdrPoint: XYPoint?
    let pfLateralError: Double?
    let pdrLateralError: Double?
    let confidence: PFConfidenceSample?
    let health: LocalizationHealthSample?
}

struct RouteCorner: Equatable, Identifiable {
    let id: Int
    let fraction: Double
    let point: XYPoint
}

struct EditableRoutePoint: Identifiable, Equatable {
    let id: Int
    let raw: String
    let point: XYPoint?
    let isDuplicate: Bool
    let isOutsideMap: Bool
}

enum TrajectoryAnalysis {
    static func nearestProjection(of point: XYPoint, on route: [XYPoint]) -> RouteProjection? {
        guard let first = route.first else { return nil }
        guard route.count > 1 else {
            return RouteProjection(
                distance: distance(point, first),
                segmentIndex: 0,
                projectedPoint: first,
                parameter: 0
            )
        }

        var best: RouteProjection?
        for index in 0..<(route.count - 1) {
            let a = route[index]
            let b = route[index + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 1e-12 else { continue }
            let rawParameter = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
            let parameter = min(max(rawParameter, 0), 1)
            let projected = XYPoint(x: a.x + parameter * dx, y: a.y + parameter * dy)
            let candidate = RouteProjection(
                distance: distance(point, projected),
                segmentIndex: index,
                projectedPoint: projected,
                parameter: parameter
            )
            if best == nil || candidate.distance < best!.distance {
                best = candidate
            }
        }

        return best ?? RouteProjection(
            distance: distance(point, first),
            segmentIndex: 0,
            projectedPoint: first,
            parameter: 0
        )
    }

    static func stepSamples(for result: PositioningResult) -> [StepSample] {
        guard result.pfTrack.count > 1 else { return [] }
        let confidence = result.pfConfidenceHistory ?? []
        let health = result.localizationHealthHistory ?? []
        return (1..<result.pfTrack.count).map { index in
            let pfPoint = result.pfTrack[index]
            let pdrPoint = index < result.pdrTrack.count ? result.pdrTrack[index] : nil
            let confidenceIndex = index - 1
            return StepSample(
                id: index,
                pfPoint: pfPoint,
                pdrPoint: pdrPoint,
                pfLateralError: nearestProjection(of: pfPoint, on: result.routeXY)?.distance,
                pdrLateralError: pdrPoint.flatMap {
                    nearestProjection(of: $0, on: result.routeXY)?.distance
                },
                confidence: confidenceIndex < confidence.count ? confidence[confidenceIndex] : nil,
                health: confidenceIndex < health.count ? health[confidenceIndex] : nil
            )
        }
    }

    static func routeCorners(_ route: [XYPoint]) -> [RouteCorner] {
        guard route.count >= 3 else { return [] }
        var lengths: [Double] = []
        var total = 0.0
        for index in 0..<(route.count - 1) {
            let length = distance(route[index], route[index + 1])
            lengths.append(length)
            total += length
        }
        guard total > 1e-9 else { return [] }

        var corners: [RouteCorner] = []
        var accumulated = 0.0
        for index in 0..<lengths.count where index < route.count - 2 {
            accumulated += lengths[index]
            let fraction = accumulated / total
            guard fraction > 0, fraction < 1 else { continue }
            corners.append(
                RouteCorner(id: corners.count, fraction: fraction, point: route[index + 1])
            )
        }
        return corners
    }

    static func stepIndex(forProgress progress: Double, pointCount: Int) -> Int {
        guard pointCount > 1 else { return 0 }
        let clamped = min(max(progress, 0), 1)
        return min(pointCount - 1, max(0, Int((Double(pointCount - 1) * clamped).rounded())))
    }

    static func progress(forStep index: Int, pointCount: Int) -> Double {
        guard pointCount > 1 else { return 0 }
        return Double(min(max(index, 0), pointCount - 1)) / Double(pointCount - 1)
    }

    private static func distance(_ a: XYPoint, _ b: XYPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

enum RouteTextParser {
    static func points(from text: String) -> [EditableRoutePoint] {
        points(from: text, mapBounds: nil)
    }

    static func points(from text: String, mapBounds: CoordinateBounds?) -> [EditableRoutePoint] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var rows: [EditableRoutePoint] = []
        var previous: XYPoint?
        for (index, part) in text.split(
            separator: ";",
            omittingEmptySubsequences: false
        ).enumerated() {
            let raw = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            let values = raw.split(separator: ",", omittingEmptySubsequences: false)
            var point: XYPoint?
            if values.count == 2,
               let x = Double(values[0].trimmingCharacters(in: .whitespacesAndNewlines)),
               let y = Double(values[1].trimmingCharacters(in: .whitespacesAndNewlines)),
               x.isFinite,
               y.isFinite {
                point = XYPoint(x: x, y: y)
            }
            let duplicate = point != nil && previous == point
            let outside = point.map { candidate in
                mapBounds.map { !$0.contains(x: candidate.x, y: candidate.y) } ?? false
            } ?? false
            rows.append(
                EditableRoutePoint(
                    id: index,
                    raw: raw,
                    point: point,
                    isDuplicate: duplicate,
                    isOutsideMap: outside
                )
            )
            if let point { previous = point }
        }
        return rows
    }
}

struct PlotLayout: Equatable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    let rect: CGRect

    private let padding: CGFloat = 34

    init(bounds: CoordinateBounds, rect: CGRect) {
        minX = bounds.minX
        maxX = bounds.maxX
        minY = bounds.minY
        maxY = bounds.maxY
        self.rect = rect
    }

    var contentSize: CGSize {
        CGSize(
            width: max(CGFloat(maxX - minX), 0.001),
            height: max(CGFloat(maxY - minY), 0.001)
        )
    }

    var scale: CGFloat {
        let availableWidth = max(rect.width - padding * 2, 1)
        let availableHeight = max(rect.height - padding * 2, 1)
        return min(availableWidth / contentSize.width, availableHeight / contentSize.height)
    }

    var plotSize: CGSize {
        CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }

    var plotOrigin: CGPoint {
        CGPoint(
            x: rect.minX + (rect.width - plotSize.width) / 2,
            y: rect.minY + (rect.height - plotSize.height) / 2
        )
    }

    func screen(_ point: XYPoint) -> CGPoint {
        CGPoint(
            x: plotOrigin.x + CGFloat(point.x - minX) * scale,
            y: plotOrigin.y + CGFloat(maxY - point.y) * scale
        )
    }

    func world(_ point: CGPoint) -> XYPoint {
        XYPoint(
            x: minX + Double((point.x - plotOrigin.x) / scale),
            y: maxY - Double((point.y - plotOrigin.y) / scale)
        )
    }
}

struct PlotViewport: Equatable {
    static let minZoom = 0.65
    static let maxZoom = 8.0

    var zoom: Double = 1
    var pan: CGSize = .zero

    func screen(_ point: XYPoint, layout: PlotLayout, canvasSize: CGSize) -> CGPoint {
        let base = layout.screen(point)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        return CGPoint(
            x: center.x + (base.x - center.x) * zoom + pan.width,
            y: center.y + (base.y - center.y) * zoom + pan.height
        )
    }

    func world(_ point: CGPoint, layout: PlotLayout, canvasSize: CGSize) -> XYPoint {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let base = CGPoint(
            x: center.x + (point.x - center.x - pan.width) / zoom,
            y: center.y + (point.y - center.y - pan.height) / zoom
        )
        return layout.world(base)
    }

    mutating func applyZoom(
        factor: Double,
        anchor: CGPoint,
        layout: PlotLayout,
        canvasSize: CGSize
    ) {
        let worldAnchor = world(anchor, layout: layout, canvasSize: canvasSize)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        let updated = screen(worldAnchor, layout: layout, canvasSize: canvasSize)
        pan.width += anchor.x - updated.x
        pan.height += anchor.y - updated.y
    }

    mutating func reset() {
        zoom = 1
        pan = .zero
    }
}
