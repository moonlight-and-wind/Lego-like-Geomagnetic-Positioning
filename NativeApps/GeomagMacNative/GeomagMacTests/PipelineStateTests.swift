import XCTest
@testable import GeomagMac

final class PipelineStateTests: XCTestCase {
    private func validInput() -> PipelineInputs {
        PipelineInputs(
            hasDataset: true,
            usesBundledDataset: false,
            datasetNameIsEmpty: false,
            routeIsValid: true,
            routeGeometryIsValid: true,
            headingIsValid: true,
            routeIsInsideMap: true,
            hasMap: true,
            mapBuiltFromCurrentDataset: false,
            coordinateFrameMatches: true,
            localizationModeNeedsHeading: false,
            hasExplicitHeading: true,
            isRunning: false,
            hasResult: false
        )
    }

    func testValidImportedDataIsReadyButNeedsRun() {
        let readiness = PipelineReadiness.evaluate(validInput())
        XCTAssertTrue(readiness.dataReady)
        XCTAssertTrue(readiness.mapReady)
        XCTAssertTrue(readiness.routeReady)
        XCTAssertTrue(readiness.headingReady)
        XCTAssertTrue(readiness.canRun)
        XCTAssertTrue(readiness.issues.isEmpty)
        XCTAssertEqual(readiness.nextStage, .run)
    }

    func testMissingNameBlocksDataStage() {
        var input = validInput()
        input.datasetNameIsEmpty = true
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.dataReady)
        XCTAssertEqual(readiness.issues, [.emptyDatasetName])
        XCTAssertEqual(readiness.nextStage, .data)
    }

    func testInvalidHeadingBlocksDataStage() {
        var input = validInput()
        input.headingIsValid = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.dataReady)
        XCTAssertEqual(readiness.issues, [.invalidHeading])
        XCTAssertEqual(readiness.nextStage, .data)
    }

    func testRouteOutsideMapBlocksMapStage() {
        var input = validInput()
        input.routeIsInsideMap = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.routeReady)
        XCTAssertEqual(readiness.nextStage, .map)
        XCTAssertEqual(readiness.issues, [.routeOutsideMap])
    }

    func testMapBuiltFromCurrentDatasetBlocksRun() {
        var input = validInput()
        input.mapBuiltFromCurrentDataset = true
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.mapReady)
        XCTAssertFalse(readiness.canRun)
        XCTAssertEqual(readiness.nextStage, .map)
        XCTAssertEqual(readiness.issues, [.mapBuiltFromCurrentDataset])
    }

    func testRoomModeNeedsExplicitHeading() {
        var input = validInput()
        input.localizationModeNeedsHeading = true
        input.hasExplicitHeading = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.headingReady)
        XCTAssertFalse(readiness.canRun)
        XCTAssertEqual(readiness.issues, [.roomModeNeedsHeading])
    }

    func testRunningBlocksCanRun() {
        var input = validInput()
        input.isRunning = true
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.canRun)
    }

    func testNoMapNextStageIsMap() {
        var input = validInput()
        input.hasMap = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertEqual(readiness.nextStage, .map)
        XCTAssertEqual(readiness.issues, [.noMap])
    }

    func testResultMovesNextStageToAnalysis() {
        var input = validInput()
        input.hasResult = true
        XCTAssertEqual(PipelineReadiness.evaluate(input).nextStage, .analysis)
    }

    func testBundledIgnoresImportedOnlyChecks() {
        var input = validInput()
        input.usesBundledDataset = true
        input.datasetNameIsEmpty = true
        input.routeIsValid = false
        input.headingIsValid = false
        input.localizationModeNeedsHeading = true
        input.hasExplicitHeading = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertTrue(readiness.dataReady)
        XCTAssertTrue(readiness.routeReady)
        XCTAssertTrue(readiness.headingReady)
        XCTAssertTrue(readiness.issues.isEmpty)
    }

    func testBundledWithoutMapIsNotReady() {
        var input = validInput()
        input.usesBundledDataset = true
        input.hasMap = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertTrue(readiness.dataReady)
        XCTAssertFalse(readiness.mapReady)
        XCTAssertEqual(readiness.nextStage, .map)
        XCTAssertEqual(readiness.issues, [.noMap])
    }

    func testIssueStageMapping() {
        XCTAssertEqual(StageIssue.emptyDatasetName.stage, .data)
        XCTAssertEqual(StageIssue.mapBuiltFromCurrentDataset.stage, .map)
        XCTAssertEqual(StageIssue.roomModeNeedsHeading.stage, .map)
    }
}
