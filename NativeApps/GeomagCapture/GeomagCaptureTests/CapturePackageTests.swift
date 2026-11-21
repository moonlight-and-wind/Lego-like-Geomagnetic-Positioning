import Foundation
import XCTest
@testable import GeomagCapture

@MainActor
final class CapturePackageTests: XCTestCase {
    func testGeneratedReverseRouteIsNotReversedTwice() {
        let reversedRoute = [[2.0, 0.0], [1.0, 0.0], [0.0, 0.0]]

        XCTAssertEqual(
            MotionRecorder.orderedRoute(
                reversedRoute,
                reverseRoute: true,
                inputIsReversed: true
            ),
            reversedRoute
        )
    }

    func testForwardRouteIsReorderedForReverseCapture() {
        let forwardRoute = [[0.0, 0.0], [1.0, 0.0], [2.0, 0.0]]

        XCTAssertEqual(
            MotionRecorder.orderedRoute(
                forwardRoute,
                reverseRoute: true,
                inputIsReversed: false
            ),
            Array(forwardRoute.reversed())
        )
    }

    func testMalformedRouteDoesNotSilentlyDropInvalidPoint() {
        XCTAssertNil(MotionRecorder.parseRoute("0,0; bad-point; 1,1"))
        XCTAssertNil(MotionRecorder.parseRoute("0,0; 1,1;"))
    }

    func testRouteValidationRejectsImmediateBacktrack() {
        XCTAssertNotNil(MotionRecorder.routeIssue([[0, 0], [0.6, 1.2], [0, 1.2], [1.8, 1.2]]))
        XCTAssertNil(MotionRecorder.routeIssue([[0, 0], [0, 1], [1, 1], [1, 0]]))
    }

    func testPackageExportsRouteDirection() throws {
        let files = try CapturePackageBuilder.buildFiles(
            snapshot: makeSnapshot(routeDirection: "reverse")
        )
        let metadata = try XCTUnwrap(files["geomag_dataset.json"])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        )
        XCTAssertEqual(object["route_direction"] as? String, "reverse")
    }

    func testPackageUsesCalibratedDeviceMotionMagnetometer() throws {
        let snapshot = makeSnapshot()

        let files = try CapturePackageBuilder.buildFiles(snapshot: snapshot)

        let magnetometer = try XCTUnwrap(
            String(data: try XCTUnwrap(files["Magnetometer.csv"]), encoding: .utf8)
        )
        XCTAssertTrue(magnetometer.contains("20,30,35"))
        XCTAssertFalse(magnetometer.contains("120,130,135"))
        let metadataData = try XCTUnwrap(files["capture_metadata.json"])
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        XCTAssertEqual(metadata["format_version"] as? Int, 3)
        XCTAssertEqual(
            metadata["algorithm_magnetic_field_file"] as? String,
            "Magnetometer.csv"
        )
    }

    func testInterruptedCaptureCanBeRecoveredFromDisk() throws {
        let snapshot = makeSnapshot(datasetKey: "recovery-\(UUID().uuidString)")
        let store = try CaptureRecoveryStore.begin(
            datasetKey: snapshot.datasetKey,
            startedAt: snapshot.startedAt,
            requestedSampleRateHz: snapshot.requestedSampleRateHz,
            route: snapshot.route,
            routeDirection: snapshot.routeDirection,
            initialHeadingDegrees: snapshot.initialHeadingDegrees,
            spatialReference: snapshot.spatialReference,
            spatialEvents: snapshot.spatialEvents
        )
        store.append(snapshot.accelerometer[0])
        store.append(snapshot.gyroscope[0])
        store.appendRaw(snapshot.magnetometer[0])
        store.append(snapshot.deviceMotion[0])
        store.updateSpatialEvents(snapshot.spatialEvents)
        store.close()

        let recovered = try XCTUnwrap(
            CaptureRecoveryStore.latestRecoverableCapture()
        )
        defer { CaptureRecoveryStore.discard(recovered.persistedURL) }

        XCTAssertTrue(recovered.wasInterrupted)
        XCTAssertTrue(recovered.suggestedFileName.contains(snapshot.datasetKey))
        let accelerometer = try XCTUnwrap(
            String(
                data: try XCTUnwrap(recovered.files["Accelerometer.csv"]),
                encoding: .utf8
            )
        )
        XCTAssertTrue(accelerometer.contains("0,0,0,9.80665"))
        XCTAssertNotNil(recovered.files["geomag_dataset.json"])
        XCTAssertNotNil(recovered.files["SpatialEvents.csv"])
    }

    func testFinalizedCaptureIsPersistedAtomically() throws {
        let snapshot = makeSnapshot(datasetKey: "final-\(UUID().uuidString)")
        let store = try CaptureRecoveryStore.begin(
            datasetKey: snapshot.datasetKey,
            startedAt: snapshot.startedAt,
            requestedSampleRateHz: snapshot.requestedSampleRateHz,
            route: snapshot.route,
            routeDirection: snapshot.routeDirection,
            initialHeadingDegrees: snapshot.initialHeadingDegrees,
            spatialReference: snapshot.spatialReference,
            spatialEvents: snapshot.spatialEvents
        )
        let files = try CapturePackageBuilder.buildFiles(snapshot: snapshot)

        let url = try store.finalize(files: files)
        defer { CaptureRecoveryStore.discard(url) }
        let recovered = try XCTUnwrap(
            CaptureRecoveryStore.latestRecoverableCapture()
        )

        XCTAssertFalse(recovered.wasInterrupted)
        XCTAssertEqual(recovered.persistedURL.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(recovered.files["capture_metadata.json"], files["capture_metadata.json"])
    }

    private func makeSnapshot(
        datasetKey: String = "capture-package-test",
        routeDirection: String = "forward"
    ) -> CaptureSnapshot {
        CaptureSnapshot(
            datasetKey: datasetKey,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_700_000_001),
            requestedSampleRateHz: 100,
            route: [[1.44, 0.55], [1.44, 6.05]],
            routeDirection: routeDirection,
            initialHeadingDegrees: 90,
            spatialReference: SpatialReference(
                coordinateFrame: "building-a-floor-1",
                startX: 1.44,
                startY: 0.55,
                initialHeadingDegrees: 90
            ),
            spatialEvents: [
                SpatialEventSample(
                    time: 0,
                    type: "anchor",
                    label: "start",
                    x: 1.44,
                    y: 0.55,
                    headingDegrees: 90,
                    deviceYawDegrees: 0
                ),
            ],
            accelerometer: [
                AccelerometerSample(time: 0, x: 0, y: 0, z: 9.80665),
            ],
            gyroscope: [
                GyroscopeSample(time: 0, x: 0, y: 0, z: 0),
            ],
            magnetometer: [
                MagnetometerSample(time: 0, x: 120, y: 130, z: 135),
            ],
            deviceMotion: [
                DeviceMotionSample(
                    time: 0,
                    quaternionX: 0,
                    quaternionY: 0,
                    quaternionZ: 0,
                    quaternionW: 1,
                    roll: 0,
                    pitch: 0,
                    yaw: 0,
                    gravityX: 0,
                    gravityY: 0,
                    gravityZ: 9.80665,
                    userAccelerationX: 0,
                    userAccelerationY: 0,
                    userAccelerationZ: 0,
                    rotationRateX: 0,
                    rotationRateY: 0,
                    rotationRateZ: 0,
                    magneticFieldX: 20,
                    magneticFieldY: 30,
                    magneticFieldZ: 35,
                    magneticAccuracy: 2
                ),
            ]
        )
    }
}
