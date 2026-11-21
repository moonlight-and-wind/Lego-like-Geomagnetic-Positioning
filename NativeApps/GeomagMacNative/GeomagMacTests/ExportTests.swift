import AppKit
import CoreGraphics
import XCTest
@testable import GeomagMac

final class ExportTests: XCTestCase {
    func testReportPDFHasOnePage() throws {
        let result = try loadSampleResult()
        let data = try ResultExporter.renderPDF(
            result: result,
            mapName: "route_13",
            gridCellSize: 0.2,
            layers: .all
        )
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(document.numberOfPages, 1)
    }

    func testPNGUsesExpectedDimensions() throws {
        let result = try loadSampleResult()
        let data = try ResultExporter.renderPNG(result: result, layers: .all)
        XCTAssertFalse(data.isEmpty)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 1600)
        XCTAssertEqual(bitmap.pixelsHigh, 1000)
    }

    func testCSVHeaderAndRowCountRemainStable() throws {
        let result = try loadSampleResult()
        let text = String(
            decoding: ResultExporter.csvData(result: result),
            as: UTF8.self
        )
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertTrue(text.hasPrefix("series,index,x_m,y_m,radius95_m"))
        XCTAssertEqual(
            lines.count,
            result.routeXY.count + result.pdrTrack.count + result.pfTrack.count + 1
        )
    }

    func testLayerFlagsDoNotChangePDFEnvelope() throws {
        let result = try loadSampleResult()
        let layers = ExportLayers(
            trueRoute: false,
            pdr: true,
            pf: true,
            confidence: false
        )
        let data = try ResultExporter.renderPDF(
            result: result,
            mapName: "route_13",
            gridCellSize: 0.2,
            layers: layers
        )
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "%PDF")
    }

    func testRunSummaryDecodesWithoutFullResult() throws {
        let data = try Data(contentsOf: sampleURL())
        let summary = try XCTUnwrap(RunSummary.decode(data))
        XCTAssertEqual(summary.datasetKey, "route_13_2")
        XCTAssertEqual(summary.stepsDetected, 29)
        XCTAssertEqual(
            try XCTUnwrap(summary.pfFinalError),
            0.014795913650790398,
            accuracy: 1e-9
        )
    }

    private func sampleURL() throws -> URL {
        try XCTUnwrap(
            Bundle.main.url(
                forResource: "native_route_13_2",
                withExtension: "json",
                subdirectory: "Samples"
            ) ?? Bundle.main.url(
                forResource: "native_route_13_2",
                withExtension: "json"
            )
        )
    }

    private func loadSampleResult() throws -> PositioningResult {
        return try JSONDecoder().decode(
            PositioningResult.self,
            from: Data(contentsOf: sampleURL())
        )
    }
}
