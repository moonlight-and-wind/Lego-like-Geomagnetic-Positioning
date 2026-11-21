import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let geomagCapture = UTType(
        exportedAs: "com.xuminglei.geomag-capture",
        conformingTo: .package
    )
}

struct CaptureDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.geomagCapture] }
    static var writableContentTypes: [UTType] { [.geomagCapture] }

    let files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory,
              let wrappers = configuration.file.fileWrappers else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var loaded: [String: Data] = [:]
        for (name, wrapper) in wrappers {
            if let data = wrapper.regularFileContents {
                loaded[name] = data
            }
        }
        files = loaded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrappers = files.mapValues { data in
            FileWrapper(regularFileWithContents: data)
        }
        return FileWrapper(directoryWithFileWrappers: wrappers)
    }
}

struct AccelerometerSample: Sendable {
    let time: Double
    let x: Double
    let y: Double
    let z: Double
}

struct GyroscopeSample: Sendable {
    let time: Double
    let x: Double
    let y: Double
    let z: Double
}

struct MagnetometerSample: Sendable {
    let time: Double
    let x: Double
    let y: Double
    let z: Double
}

struct DeviceMotionSample: Sendable {
    let time: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let quaternionW: Double
    let roll: Double
    let pitch: Double
    let yaw: Double
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let userAccelerationX: Double
    let userAccelerationY: Double
    let userAccelerationZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    let magneticFieldX: Double
    let magneticFieldY: Double
    let magneticFieldZ: Double
    let magneticAccuracy: Int
}

struct SpatialReference: Sendable {
    let coordinateFrame: String
    let startX: Double
    let startY: Double
    let initialHeadingDegrees: Double
}

struct SpatialEventSample: Sendable {
    let time: Double
    let type: String
    let label: String
    let x: Double?
    let y: Double?
    let headingDegrees: Double?
    let deviceYawDegrees: Double?
}

struct CaptureSnapshot: Sendable {
    let datasetKey: String
    let startedAt: Date
    let stoppedAt: Date
    let requestedSampleRateHz: Double
    let route: [[Double]]?
    let routeDirection: String
    let initialHeadingDegrees: Double?
    let spatialReference: SpatialReference
    let spatialEvents: [SpatialEventSample]
    let accelerometer: [AccelerometerSample]
    let gyroscope: [GyroscopeSample]
    let magnetometer: [MagnetometerSample]
    let deviceMotion: [DeviceMotionSample]
}

enum CapturePackageBuilder {
    static let deviceMotionHeader = "Time (s),Quaternion X,Quaternion Y,Quaternion Z,Quaternion W,Roll (rad),Pitch (rad),Yaw (rad),Gravity X (m/s^2),Gravity Y (m/s^2),Gravity Z (m/s^2),User Acceleration X (m/s^2),User Acceleration Y (m/s^2),User Acceleration Z (m/s^2),Rotation Rate X (rad/s),Rotation Rate Y (rad/s),Rotation Rate Z (rad/s),Magnetic Field X (µT),Magnetic Field Y (µT),Magnetic Field Z (µT),Magnetic Accuracy\n"

    private struct SpatialMetadata: Encodable {
        let coordinateFrame: String
        let unit: String
        let startPositionXYM: [Double]
        let initialHeadingDeg: Double

        enum CodingKeys: String, CodingKey {
            case coordinateFrame = "coordinate_frame"
            case unit
            case startPositionXYM = "start_position_xy_m"
            case initialHeadingDeg = "initial_heading_deg"
        }
    }

    private struct DatasetMetadata: Encodable {
        let formatVersion: Int
        let datasetKey: String
        let routeXYM: [[Double]]?
        let routeDirection: String
        let initialHeadingDeg: Double?
        let spatialReference: SpatialMetadata
        let spatialEventsFile: String
        let devicePose: String
        let timestampMode: String
        let createdAt: String

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case datasetKey = "dataset_key"
            case routeXYM = "route_xy_m"
            case routeDirection = "route_direction"
            case initialHeadingDeg = "initial_heading_deg"
            case spatialReference = "spatial_reference"
            case spatialEventsFile = "spatial_events_file"
            case devicePose = "device_pose"
            case timestampMode = "timestamp_mode"
            case createdAt = "created_at"
        }
    }

    private struct CaptureMetadata: Encodable {
        struct Stream: Encodable {
            let file: String
            let samples: Int
            let observedRateHz: Double

            enum CodingKeys: String, CodingKey {
                case file, samples
                case observedRateHz = "observed_rate_hz"
            }
        }

        let formatVersion: Int
        let datasetKey: String
        let createdAt: String
        let stoppedAt: String
        let durationSeconds: Double
        let requestedSampleRateHz: Double
        let timestampMode: String
        let referenceFrame: String
        let devicePose: String
        let platform: String
        let systemVersion: String
        let algorithmMagneticFieldFile: String
        let rawMagneticFieldFile: String
        let spatialReference: SpatialMetadata
        let routeDirection: String
        let spatialEventsFile: String
        let streams: [String: Stream]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case datasetKey = "dataset_key"
            case createdAt = "created_at"
            case stoppedAt = "stopped_at"
            case durationSeconds = "duration_seconds"
            case requestedSampleRateHz = "requested_sample_rate_hz"
            case timestampMode = "timestamp_mode"
            case referenceFrame = "reference_frame"
            case devicePose = "device_pose"
            case platform, streams
            case systemVersion = "system_version"
            case algorithmMagneticFieldFile = "algorithm_magnetic_field_file"
            case rawMagneticFieldFile = "raw_magnetic_field_file"
            case spatialReference = "spatial_reference"
            case routeDirection = "route_direction"
            case spatialEventsFile = "spatial_events_file"
        }
    }

    static func build(snapshot: CaptureSnapshot) throws -> CaptureDocument {
        CaptureDocument(files: try buildFiles(snapshot: snapshot))
    }

    static func buildFiles(snapshot: CaptureSnapshot) throws -> [String: Data] {
        let duration = max(snapshot.stoppedAt.timeIntervalSince(snapshot.startedAt), 0.001)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata = CaptureMetadata(
            formatVersion: 3,
            datasetKey: snapshot.datasetKey,
            createdAt: iso.string(from: snapshot.startedAt),
            stoppedAt: iso.string(from: snapshot.stoppedAt),
            durationSeconds: duration,
            requestedSampleRateHz: snapshot.requestedSampleRateHz,
            timestampMode: "seconds_since_capture_start",
            referenceFrame: "ios_device_and_core_motion_attitude",
            devicePose: "face_up_front_forward",
            platform: "iPhone",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            algorithmMagneticFieldFile: "Magnetometer.csv",
            rawMagneticFieldFile: "MagnetometerRaw.csv",
            spatialReference: spatialMetadata(snapshot.spatialReference),
            routeDirection: snapshot.routeDirection,
            spatialEventsFile: "SpatialEvents.csv",
            streams: [
                "accelerometer": .init(
                    file: "Accelerometer.csv",
                    samples: snapshot.accelerometer.count,
                    observedRateHz: observedRate(snapshot.accelerometer.map(\.time))
                ),
                "gyroscope": .init(
                    file: "Gyroscope.csv",
                    samples: snapshot.gyroscope.count,
                    observedRateHz: observedRate(snapshot.gyroscope.map(\.time))
                ),
                "magnetometer": .init(
                    file: "Magnetometer.csv",
                    samples: snapshot.deviceMotion.count,
                    observedRateHz: observedRate(snapshot.deviceMotion.map(\.time))
                ),
                "magnetometer_raw": .init(
                    file: "MagnetometerRaw.csv",
                    samples: snapshot.magnetometer.count,
                    observedRateHz: observedRate(snapshot.magnetometer.map(\.time))
                ),
                "device_motion": .init(
                    file: "DeviceMotion.csv",
                    samples: snapshot.deviceMotion.count,
                    observedRateHz: observedRate(snapshot.deviceMotion.map(\.time))
                ),
                "spatial_events": .init(
                    file: "SpatialEvents.csv",
                    samples: snapshot.spatialEvents.count,
                    observedRateHz: 0
                ),
            ]
        )
        let datasetMetadata = DatasetMetadata(
            formatVersion: 2,
            datasetKey: snapshot.datasetKey,
            routeXYM: snapshot.route,
            routeDirection: snapshot.routeDirection,
            initialHeadingDeg: snapshot.initialHeadingDegrees,
            spatialReference: spatialMetadata(snapshot.spatialReference),
            spatialEventsFile: "SpatialEvents.csv",
            devicePose: "face_up_front_forward",
            timestampMode: "seconds_since_capture_start",
            createdAt: iso.string(from: snapshot.startedAt)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        return [
            "Accelerometer.csv": csvAccelerometer(snapshot.accelerometer),
            "Gyroscope.csv": csvGyroscope(snapshot.gyroscope),
            "Magnetometer.csv": csvCalibratedMagnetometer(snapshot.deviceMotion),
            "MagnetometerRaw.csv": csvMagnetometer(snapshot.magnetometer),
            "DeviceMotion.csv": csvDeviceMotion(snapshot.deviceMotion),
            "SpatialEvents.csv": csvSpatialEvents(snapshot.spatialEvents),
            "geomag_dataset.json": try encoder.encode(datasetMetadata),
            "capture_metadata.json": try encoder.encode(metadata),
            "README.txt": Data(packageReadme.utf8),
        ]
    }

    private static func csvAccelerometer(_ samples: [AccelerometerSample]) -> Data {
        var text = "\"Time (s)\",\"X (m/s^2)\",\"Y (m/s^2)\",\"Z (m/s^2)\"\n"
        for sample in samples {
            text += row([sample.time, sample.x, sample.y, sample.z])
        }
        return Data(text.utf8)
    }

    private static func csvGyroscope(_ samples: [GyroscopeSample]) -> Data {
        var text = "\"Time (s)\",\"X (rad/s)\",\"Y (rad/s)\",\"Z (rad/s)\"\n"
        for sample in samples {
            text += row([sample.time, sample.x, sample.y, sample.z])
        }
        return Data(text.utf8)
    }

    private static func csvMagnetometer(_ samples: [MagnetometerSample]) -> Data {
        var text = "\"Time (s)\",\"X (µT)\",\"Y (µT)\",\"Z (µT)\"\n"
        for sample in samples {
            text += row([sample.time, sample.x, sample.y, sample.z])
        }
        return Data(text.utf8)
    }

    private static func csvCalibratedMagnetometer(_ samples: [DeviceMotionSample]) -> Data {
        var text = "\"Time (s)\",\"X (µT)\",\"Y (µT)\",\"Z (µT)\"\n"
        for sample in samples {
            text += row([
                sample.time,
                sample.magneticFieldX,
                sample.magneticFieldY,
                sample.magneticFieldZ,
            ])
        }
        return Data(text.utf8)
    }

    private static func csvDeviceMotion(_ samples: [DeviceMotionSample]) -> Data {
        var text = deviceMotionHeader
        for sample in samples {
            text += row([
                sample.time,
                sample.quaternionX,
                sample.quaternionY,
                sample.quaternionZ,
                sample.quaternionW,
                sample.roll,
                sample.pitch,
                sample.yaw,
                sample.gravityX,
                sample.gravityY,
                sample.gravityZ,
                sample.userAccelerationX,
                sample.userAccelerationY,
                sample.userAccelerationZ,
                sample.rotationRateX,
                sample.rotationRateY,
                sample.rotationRateZ,
                sample.magneticFieldX,
                sample.magneticFieldY,
                sample.magneticFieldZ,
                Double(sample.magneticAccuracy),
            ])
        }
        return Data(text.utf8)
    }

    static func csvSpatialEvents(_ samples: [SpatialEventSample]) -> Data {
        var text = "Time (s),Type,Label,X (m),Y (m),Heading (deg),Device Yaw (deg)\n"
        for sample in samples {
            text += [
                number(sample.time),
                csvString(sample.type),
                csvString(sample.label),
                optionalNumber(sample.x),
                optionalNumber(sample.y),
                optionalNumber(sample.headingDegrees),
                optionalNumber(sample.deviceYawDegrees),
            ].joined(separator: ",") + "\n"
        }
        return Data(text.utf8)
    }

    private static func spatialMetadata(_ reference: SpatialReference) -> SpatialMetadata {
        SpatialMetadata(
            coordinateFrame: reference.coordinateFrame,
            unit: "m",
            startPositionXYM: [reference.startX, reference.startY],
            initialHeadingDeg: reference.initialHeadingDegrees
        )
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func optionalNumber(_ value: Double?) -> String {
        value.map(number) ?? ""
    }

    private static func csvString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func row(_ values: [Double]) -> String {
        values.map {
            String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), $0)
        }.joined(separator: ",") + "\n"
    }

    private static func observedRate(_ times: [Double]) -> Double {
        guard let first = times.first, let last = times.last, times.count > 1, last > first else {
            return 0
        }
        return Double(times.count - 1) / (last - first)
    }

    static let packageReadme = """
    Geomag Capture

    Accelerometer.csv, Gyroscope.csv and Magnetometer.csv use the same headers
    and SI units as GeomagMac Native. Magnetometer.csv contains the calibrated
    Core Motion magnetic field used by the positioning algorithm, while
    MagnetometerRaw.csv preserves the uncalibrated hardware stream for diagnosis.
    DeviceMotion.csv adds the quaternion, attitude, gravity, user acceleration,
    rotation rate and magnetic calibration accuracy. All timestamps are seconds
    since this capture started. SpatialEvents.csv records the shared spatial
    frame, known-coordinate anchors and manually marked turns used to build a
    global magnetic map.
    """
}
