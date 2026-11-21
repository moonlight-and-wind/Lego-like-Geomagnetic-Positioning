import XCTest
@testable import GeomagMac

final class RunComparisonTests: XCTestCase {
    func testSamplesOnSameRouteMatch() throws {
        let route132 = try decodeSample("native_route_13_2")
        let route133 = try decodeSample("native_route_13_3")
        let route152 = try decodeSample("native_route_15_2")

        XCTAssertTrue(RunComparison.routesMatch([route132, route133]))
        XCTAssertFalse(RunComparison.routesMatch([route132, route152]))
    }

    func testIdenticalParametersHaveNoDifferences() throws {
        let first = try decodeSample("native_route_13_2")
        let second = try decodeSample("native_route_13_2")
        let rows = RunComparison.parameterRows(for: [first, second])

        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0.values.count == 2 })
        XCTAssertTrue(rows.allSatisfy { !$0.isDifferent })
    }

    func testModifiedParametersAreDetected() throws {
        let baseline = try decodeSample("native_route_13_2")
        let changed = try decodeSample("native_route_13_2") { object in
            object["pf_smoothing_mode"] = "none"
            object["step_length_scale"] = 0.95
        }
        let rows = RunComparison.parameterRows(for: [baseline, changed])

        let smoothing = try XCTUnwrap(rows.first { $0.id == "smoothing_mode" })
        XCTAssertTrue(smoothing.isDifferent)
        XCTAssertEqual(smoothing.values, ["EMA", "不平滑"])

        let stepLength = try XCTUnwrap(rows.first { $0.id == "step_length_scale" })
        XCTAssertTrue(stepLength.isDifferent)
        XCTAssertEqual(stepLength.values, ["1.00×", "0.95×"])

        let alpha = try XCTUnwrap(rows.first { $0.id == "smoothing_alpha" })
        XCTAssertFalse(alpha.isDifferent)
    }

    func testMissingParameterIsShownAsUnrecorded() throws {
        let complete = try decodeSample("native_route_13_2")
        let incomplete = try decodeSample("native_route_13_2") { object in
            object.removeValue(forKey: "heading_snap_deg")
        }
        let rows = RunComparison.parameterRows(for: [complete, incomplete])
        let heading = try XCTUnwrap(rows.first { $0.id == "heading_snap_deg" })

        XCTAssertTrue(heading.isDifferent)
        XCTAssertEqual(heading.values, ["0.0°", "未记录"])
    }

    func testBestIndicesIgnoreMissingValues() {
        XCTAssertEqual(
            ComparisonMetric.finalError.bestIndices(in: [nil, 0.20, 0.10]),
            [2]
        )
        XCTAssertEqual(
            ComparisonMetric.confidence.bestIndices(in: [nil, 0.50, 0.80]),
            [2]
        )
        XCTAssertEqual(
            ComparisonMetric.pathRatio.bestIndices(in: [nil, 1.20, 0.90]),
            [2]
        )
        XCTAssertEqual(
            ComparisonMetric.finalError.bestIndices(in: [0.10, 0.10]),
            [0, 1]
        )
    }

    func testBestIndicesForSampleRuns() throws {
        let first = try decodeSample("native_route_13_2")
        let second = try decodeSample("native_route_13_3")
        let values = [first, second].map { ComparisonMetric.finalError.value(from: $0) }

        XCTAssertEqual(ComparisonMetric.finalError.bestIndices(in: values), [0])
        XCTAssertEqual(
            ComparisonMetric.pathRatio.bestIndices(
                in: [first, second].map { ComparisonMetric.pathRatio.value(from: $0) }
            ),
            [0]
        )
        XCTAssertEqual(
            ComparisonMetric.confidence.bestIndices(
                in: [first, second].map { ComparisonMetric.confidence.value(from: $0) }
            ),
            [1]
        )
    }

    func testMetricDisplaysUnits() throws {
        let result = try decodeSample("native_route_13_2")
        XCTAssertEqual(
            ComparisonMetric.finalError.display(
                ComparisonMetric.finalError.value(from: result)
            ),
            "0.01 m"
        )
        XCTAssertEqual(
            ComparisonMetric.confidence.display(
                ComparisonMetric.confidence.value(from: result)
            ),
            "68%"
        )
        XCTAssertEqual(ComparisonMetric.turnAngle.display(12.34), "12.3°")
    }

    func testTitleAndLetters() throws {
        let first = try decodeSample("native_route_13_2")
        let second = try decodeSample("native_route_13_3")

        XCTAssertEqual(RunComparison.maximumRunCount, 4)
        XCTAssertEqual(RunComparison.displayRouteLabel("route_15"), "Route 15")
        XCTAssertEqual(
            RunComparison.title(for: [first, second]),
            "Route 13 · 2 次运行对比"
        )
        XCTAssertEqual(RunComparison.title(for: [first]), "多运行对比")
        XCTAssertEqual(
            RunComparison.title(for: [first, try decodeSample("native_route_15_2")]),
            "2 次运行对比"
        )
        XCTAssertEqual(
            RunComparison.letters,
            ["A", "B", "C", "D"]
        )
    }

    private func decodeSample(
        _ name: String,
        mutate: (inout [String: Any]) -> Void = { _ in }
    ) throws -> PositioningResult {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: try sampleURL(name))
            ) as? [String: Any]
        )
        mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PositioningResult.self, from: data)
    }

    private func sampleURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.main.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Samples"
            ) ?? Bundle.main.url(forResource: name, withExtension: "json")
        )
    }
}
