import Foundation

@main
struct CapturePackageSmoke {
    static func main() throws {
        let snapshot = CaptureSnapshot(
            datasetKey: "smoke_route",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_700_000_001),
            requestedSampleRateHz: 100,
            route: [[1.44, 0.55], [1.44, 6.05]],
            routeDirection: "forward",
            initialHeadingDegrees: 90,
            spatialReference: .init(
                coordinateFrame: "building-a-floor-1",
                startX: 1.44,
                startY: 0.55,
                initialHeadingDegrees: 90
            ),
            spatialEvents: [
                .init(
                    time: 0,
                    type: "anchor",
                    label: "start",
                    x: 1.44,
                    y: 0.55,
                    headingDegrees: 90,
                    deviceYawDegrees: 0
                ),
                .init(
                    time: 1,
                    type: "anchor",
                    label: "finish",
                    x: 1.44,
                    y: 6.05,
                    headingDegrees: 90,
                    deviceYawDegrees: 0
                ),
            ],
            accelerometer: [.init(time: 0, x: 0, y: 0, z: 9.80665)],
            gyroscope: [.init(time: 0, x: 0, y: 0, z: 0)],
            magnetometer: [.init(time: 0, x: 20, y: 30, z: 35)],
            deviceMotion: [.init(
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
            )]
        )
        let document = try CapturePackageBuilder.build(snapshot: snapshot)
        let required = [
            "Accelerometer.csv",
            "Gyroscope.csv",
            "Magnetometer.csv",
            "MagnetometerRaw.csv",
            "DeviceMotion.csv",
            "SpatialEvents.csv",
            "geomag_dataset.json",
            "capture_metadata.json",
        ]
        precondition(required.allSatisfy { document.files[$0] != nil })
        precondition(
            String(data: document.files["Accelerometer.csv"]!, encoding: .utf8)?
                .hasPrefix("\"Time (s)\",\"X (m/s^2)\"") == true
        )
        let metadata = try JSONSerialization.jsonObject(
            with: document.files["geomag_dataset.json"]!
        ) as? [String: Any]
        precondition(metadata?["dataset_key"] as? String == "smoke_route")
        let calibratedMagnetometer = String(
            data: document.files["Magnetometer.csv"]!,
            encoding: .utf8
        )
        precondition(calibratedMagnetometer?.contains("20,30,35") == true)
        let captureMetadata = try JSONSerialization.jsonObject(
            with: document.files["capture_metadata.json"]!
        ) as? [String: Any]
        precondition(captureMetadata?["format_version"] as? Int == 3)
        precondition(captureMetadata?["raw_magnetic_field_file"] as? String == "MagnetometerRaw.csv")
        let spatialReference = captureMetadata?["spatial_reference"] as? [String: Any]
        precondition(spatialReference?["coordinate_frame"] as? String == "building-a-floor-1")
        let events = String(data: document.files["SpatialEvents.csv"]!, encoding: .utf8)
        precondition(events?.contains("\"finish\",1.44,6.05") == true)
        print("Capture package smoke test passed: \(document.files.keys.sorted())")
    }
}
