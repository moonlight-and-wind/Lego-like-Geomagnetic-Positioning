import CoreGraphics
import XCTest
@testable import GeomagMac

final class TrajectoryAnalysisTests: XCTestCase {
    func testProjectionOnHorizontalSegment() throws {
        let route = [XYPoint(x: 0, y: 0), XYPoint(x: 4, y: 0)]
        let projection = try XCTUnwrap(
            TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 2, y: 1), on: route)
        )
        XCTAssertEqual(projection.distance, 1, accuracy: 1e-9)
        XCTAssertEqual(projection.segmentIndex, 0)
        XCTAssertEqual(projection.projectedPoint.x, 2, accuracy: 1e-9)
        XCTAssertEqual(projection.projectedPoint.y, 0, accuracy: 1e-9)
        XCTAssertEqual(projection.parameter, 0.5, accuracy: 1e-9)
    }

    func testProjectionClampsToSegmentEnds() throws {
        let route = [XYPoint(x: 0, y: 0), XYPoint(x: 4, y: 0)]
        let projection = try XCTUnwrap(
            TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 5, y: 0), on: route)
        )
        XCTAssertEqual(projection.distance, 1, accuracy: 1e-9)
        XCTAssertEqual(projection.projectedPoint.x, 4, accuracy: 1e-9)
        XCTAssertEqual(projection.parameter, 1, accuracy: 1e-9)
    }

    func testProjectionSkipsZeroLengthSegments() throws {
        let route = [
            XYPoint(x: 1, y: 1),
            XYPoint(x: 1, y: 1),
            XYPoint(x: 1, y: 3),
        ]
        let projection = try XCTUnwrap(
            TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 2, y: 2), on: route)
        )
        XCTAssertEqual(projection.distance, 1, accuracy: 1e-9)
        XCTAssertEqual(projection.segmentIndex, 1)
    }

    func testProjectionOnClosedRectangle() throws {
        let route = [
            XYPoint(x: 4, y: 3),
            XYPoint(x: 4, y: 4.8),
            XYPoint(x: 5.8, y: 4.8),
            XYPoint(x: 5.8, y: 3),
            XYPoint(x: 4, y: 3),
        ]
        let projection = try XCTUnwrap(
            TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 4.5, y: 3.2), on: route)
        )
        XCTAssertEqual(projection.distance, 0.2, accuracy: 1e-9)
    }

    func testRouteCornersFractions() {
        let route = [
            XYPoint(x: 4, y: 3),
            XYPoint(x: 4, y: 4.8),
            XYPoint(x: 5.8, y: 4.8),
            XYPoint(x: 5.8, y: 3),
            XYPoint(x: 4, y: 3),
        ]
        let corners = TrajectoryAnalysis.routeCorners(route)
        XCTAssertEqual(corners.map(\.fraction), [0.25, 0.5, 0.75])
        XCTAssertEqual(corners.map(\.point), [
            XYPoint(x: 4, y: 4.8),
            XYPoint(x: 5.8, y: 4.8),
            XYPoint(x: 5.8, y: 3),
        ])
    }

    func testStepSamplesAlignConfidenceAndHealth() throws {
        let result = try loadSampleResult()
        let samples = TrajectoryAnalysis.stepSamples(for: result)
        XCTAssertEqual(samples.count, result.pfTrack.count - 1)
        XCTAssertEqual(samples.first?.id, 1)
        XCTAssertEqual(samples.last?.id, result.pfTrack.count - 1)
        XCTAssertNotNil(samples.first?.confidence)
        XCTAssertNotNil(samples.first?.health)
        XCTAssertNotNil(samples.first?.pfLateralError)
        XCTAssertNotNil(samples.first?.pdrLateralError)
        XCTAssertEqual(samples.compactMap(\.confidence).count, result.pfConfidenceHistory?.count)
        XCTAssertEqual(samples.compactMap(\.health).count, result.localizationHealthHistory?.count)
    }

    func testProgressAndStepRoundTrip() {
        XCTAssertEqual(TrajectoryAnalysis.stepIndex(forProgress: 0, pointCount: 30), 0)
        XCTAssertEqual(TrajectoryAnalysis.stepIndex(forProgress: 1, pointCount: 30), 29)
        XCTAssertEqual(TrajectoryAnalysis.stepIndex(forProgress: 0.5, pointCount: 30), 15)
        XCTAssertEqual(TrajectoryAnalysis.progress(forStep: 15, pointCount: 30), 15.0 / 29.0, accuracy: 1e-12)
        XCTAssertEqual(TrajectoryAnalysis.progress(forStep: 999, pointCount: 30), 1, accuracy: 1e-12)
    }

    func testRouteTextParserFlagsDuplicatesAndOutsideMap() {
        let bounds = CoordinateBounds(minX: 0, maxX: 2, minY: 0, maxY: 2)
        let rows = RouteTextParser.points(
            from: "0,0; 0,0; 3,1; bad",
            mapBounds: bounds
        )
        XCTAssertEqual(rows.count, 4)
        XCTAssertFalse(rows[0].isDuplicate)
        XCTAssertFalse(rows[0].isOutsideMap)
        XCTAssertTrue(rows[1].isDuplicate)
        XCTAssertTrue(rows[2].isOutsideMap)
        XCTAssertNil(rows[3].point)
    }

    func testPlotLayoutRoundTrip() {
        let bounds = CoordinateBounds(minX: 0, maxX: 10, minY: 0, maxY: 5)
        let layout = PlotLayout(
            bounds: bounds,
            rect: CGRect(x: 0, y: 0, width: 400, height: 200)
        )
        let point = XYPoint(x: 3, y: 2)
        let back = layout.world(layout.screen(point))
        XCTAssertEqual(back.x, 3, accuracy: 1e-9)
        XCTAssertEqual(back.y, 2, accuracy: 1e-9)
    }

    func testViewportZoomKeepsAnchorWorldPointFixed() {
        let bounds = CoordinateBounds(minX: 0, maxX: 10, minY: 0, maxY: 5)
        let layout = PlotLayout(
            bounds: bounds,
            rect: CGRect(x: 0, y: 0, width: 400, height: 200)
        )
        let canvas = CGSize(width: 400, height: 200)
        let world = XYPoint(x: 3, y: 2)
        var viewport = PlotViewport()
        let anchor = viewport.screen(world, layout: layout, canvasSize: canvas)
        viewport.applyZoom(factor: 2, anchor: anchor, layout: layout, canvasSize: canvas)
        let updated = viewport.screen(world, layout: layout, canvasSize: canvas)
        XCTAssertEqual(updated.x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(updated.y, anchor.y, accuracy: 1e-9)
        XCTAssertEqual(viewport.zoom, 2, accuracy: 1e-9)
    }

    func testViewportZoomClampsAndResets() {
        let bounds = CoordinateBounds(minX: 0, maxX: 10, minY: 0, maxY: 5)
        let layout = PlotLayout(
            bounds: bounds,
            rect: CGRect(x: 0, y: 0, width: 400, height: 200)
        )
        let canvas = CGSize(width: 400, height: 200)
        var viewport = PlotViewport()
        viewport.applyZoom(factor: 100, anchor: .zero, layout: layout, canvasSize: canvas)
        XCTAssertEqual(viewport.zoom, PlotViewport.maxZoom, accuracy: 1e-9)
        viewport.applyZoom(factor: 0.0001, anchor: .zero, layout: layout, canvasSize: canvas)
        XCTAssertEqual(viewport.zoom, PlotViewport.minZoom, accuracy: 1e-9)
        viewport.reset()
        XCTAssertEqual(viewport, PlotViewport())
    }

    private func loadSampleResult() throws -> PositioningResult {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "native_route_13_2",
                withExtension: "json",
                subdirectory: "Samples"
            ) ?? Bundle.main.url(
                forResource: "native_route_13_2",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            PositioningResult.self,
            from: Data(contentsOf: url)
        )
    }
}
