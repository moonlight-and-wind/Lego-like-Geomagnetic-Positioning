import Foundation

/// Writes every incoming sensor sample to an app-owned recovery package.
/// The in-memory buffer remains available for the normal exporter, while this
/// store makes an interrupted field capture recoverable after relaunch.
final class CaptureRecoveryStore: @unchecked Sendable {
    struct RecoveredCapture: Sendable {
        let files: [String: Data]
        let suggestedFileName: String
        let persistedURL: URL
        let wasInterrupted: Bool
    }

    private enum Stream: String, CaseIterable {
        case accelerometer = "Accelerometer.csv"
        case gyroscope = "Gyroscope.csv"
        case magnetometer = "Magnetometer.csv"
        case magnetometerRaw = "MagnetometerRaw.csv"
        case deviceMotion = "DeviceMotion.csv"
    }

    private let lock = NSLock()
    private let partialURL: URL
    private let datasetKey: String
    private var handles: [Stream: FileHandle] = [:]
    private var isClosed = false

    private init(partialURL: URL, datasetKey: String) {
        self.partialURL = partialURL
        self.datasetKey = datasetKey
    }

    static func begin(
        datasetKey: String,
        startedAt: Date,
        requestedSampleRateHz: Double,
        route: [[Double]]?,
        routeDirection: String,
        initialHeadingDegrees: Double?,
        spatialReference: SpatialReference,
        spatialEvents: [SpatialEventSample]
    ) throws -> CaptureRecoveryStore {
        let root = try recoveryRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let partialURL = root.appendingPathComponent(
            "\(safeFileComponent(datasetKey))-\(fileTimestamp()).geomagcapture.partial",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: partialURL,
            withIntermediateDirectories: true
        )
        let store = CaptureRecoveryStore(
            partialURL: partialURL,
            datasetKey: datasetKey
        )
        try store.prepareFiles(
            startedAt: startedAt,
            requestedSampleRateHz: requestedSampleRateHz,
            route: route,
            routeDirection: routeDirection,
            initialHeadingDegrees: initialHeadingDegrees,
            spatialReference: spatialReference,
            spatialEvents: spatialEvents
        )
        return store
    }

    func append(_ sample: AccelerometerSample) {
        append(
            Self.row([sample.time, sample.x, sample.y, sample.z]),
            to: .accelerometer
        )
    }

    func append(_ sample: GyroscopeSample) {
        append(
            Self.row([sample.time, sample.x, sample.y, sample.z]),
            to: .gyroscope
        )
    }

    func appendRaw(_ sample: MagnetometerSample) {
        append(
            Self.row([sample.time, sample.x, sample.y, sample.z]),
            to: .magnetometerRaw
        )
    }

    func append(_ sample: DeviceMotionSample) {
        append(
            Self.row([
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
            ]),
            to: .deviceMotion
        )
        append(
            Self.row([
                sample.time,
                sample.magneticFieldX,
                sample.magneticFieldY,
                sample.magneticFieldZ,
            ]),
            to: .magnetometer
        )
    }

    func updateSpatialEvents(_ events: [SpatialEventSample]) {
        let data = CapturePackageBuilder.csvSpatialEvents(events)
        try? data.write(
            to: partialURL.appendingPathComponent("SpatialEvents.csv"),
            options: .atomic
        )
    }

    func finalize(files: [String: Data]) throws -> URL {
        close()
        let savedRoot = try Self.savedRoot()
        try FileManager.default.createDirectory(
            at: savedRoot,
            withIntermediateDirectories: true
        )
        let stagingURL = savedRoot.appendingPathComponent(
            ".\(UUID().uuidString).finalizing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: true
        )
        do {
            for (name, data) in files {
                try data.write(
                    to: stagingURL.appendingPathComponent(name),
                    options: .atomic
                )
            }
            let destination = Self.availableDestination(
                for: datasetKey,
                in: savedRoot
            )
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            try? FileManager.default.removeItem(at: partialURL)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            for handle in handles.values {
                try? handle.synchronize()
                try? handle.close()
            }
            handles.removeAll()
            isClosed = true
        }
    }

    static func latestRecoverableCapture() -> RecoveredCapture? {
        let candidates = [try? savedRoot(), try? recoveryRoot()]
            .compactMap { $0 }
            .flatMap { root -> [URL] in
                (try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            }
            .filter { url in
                url.lastPathComponent.hasSuffix(".geomagcapture")
                    || url.lastPathComponent.hasSuffix(".geomagcapture.partial")
            }
            .sorted { left, right in
                modificationDate(left) > modificationDate(right)
            }
        guard let url = candidates.first else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: url.path
        ) else { return nil }
        var files: [String: Data] = [:]
        for name in names where !name.hasPrefix(".") {
            let fileURL = url.appendingPathComponent(name)
            if let data = try? Data(contentsOf: fileURL) {
                files[name] = data
            }
        }
        let required = [
            "Accelerometer.csv",
            "Gyroscope.csv",
            "Magnetometer.csv",
            "DeviceMotion.csv",
            "geomag_dataset.json",
            "capture_metadata.json",
        ]
        guard required.allSatisfy({ files[$0] != nil }) else { return nil }
        let name = url.lastPathComponent
            .replacingOccurrences(of: ".geomagcapture.partial", with: "")
            .replacingOccurrences(of: ".geomagcapture", with: "")
        return RecoveredCapture(
            files: files,
            suggestedFileName: name,
            persistedURL: url,
            wasInterrupted: url.lastPathComponent.hasSuffix(".partial")
        )
    }

    static func discard(_ url: URL) {
        let allowedRoots = [try? recoveryRoot(), try? savedRoot()]
            .compactMap { $0?.standardizedFileURL.path }
        let standardized = url.standardizedFileURL.path
        guard allowedRoots.contains(where: {
            standardized.hasPrefix($0 + "/")
        }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func prepareFiles(
        startedAt: Date,
        requestedSampleRateHz: Double,
        route: [[Double]]?,
        routeDirection: String,
        initialHeadingDegrees: Double?,
        spatialReference: SpatialReference,
        spatialEvents: [SpatialEventSample]
    ) throws {
        let headers: [Stream: String] = [
            .accelerometer: "\"Time (s)\",\"X (m/s^2)\",\"Y (m/s^2)\",\"Z (m/s^2)\"\n",
            .gyroscope: "\"Time (s)\",\"X (rad/s)\",\"Y (rad/s)\",\"Z (rad/s)\"\n",
            .magnetometer: "\"Time (s)\",\"X (µT)\",\"Y (µT)\",\"Z (µT)\"\n",
            .magnetometerRaw: "\"Time (s)\",\"X (µT)\",\"Y (µT)\",\"Z (µT)\"\n",
            .deviceMotion: CapturePackageBuilder.deviceMotionHeader,
        ]
        for stream in Stream.allCases {
            let url = partialURL.appendingPathComponent(stream.rawValue)
            try Data((headers[stream] ?? "").utf8).write(to: url)
            handles[stream] = try FileHandle(forWritingTo: url)
            try handles[stream]?.seekToEnd()
        }
        try CapturePackageBuilder.csvSpatialEvents(spatialEvents).write(
            to: partialURL.appendingPathComponent("SpatialEvents.csv"),
            options: .atomic
        )
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let spatial: [String: Any] = [
            "coordinate_frame": spatialReference.coordinateFrame,
            "unit": "m",
            "start_position_xy_m": [spatialReference.startX, spatialReference.startY],
            "initial_heading_deg": spatialReference.initialHeadingDegrees,
        ]
        var dataset: [String: Any] = [
            "format_version": 2,
            "dataset_key": datasetKey,
            "route_direction": routeDirection,
            "spatial_reference": spatial,
            "spatial_events_file": "SpatialEvents.csv",
            "device_pose": "face_up_front_forward",
            "timestamp_mode": "seconds_since_capture_start",
            "created_at": iso.string(from: startedAt),
            "recovery_status": "recording_in_progress",
        ]
        if let route { dataset["route_xy_m"] = route }
        if let initialHeadingDegrees {
            dataset["initial_heading_deg"] = initialHeadingDegrees
        }
        let capture: [String: Any] = [
            "format_version": 3,
            "dataset_key": datasetKey,
            "route_direction": routeDirection,
            "created_at": iso.string(from: startedAt),
            "requested_sample_rate_hz": requestedSampleRateHz,
            "timestamp_mode": "seconds_since_capture_start",
            "reference_frame": "ios_device_and_core_motion_attitude",
            "device_pose": "face_up_front_forward",
            "algorithm_magnetic_field_file": "Magnetometer.csv",
            "raw_magnetic_field_file": "MagnetometerRaw.csv",
            "spatial_reference": spatial,
            "spatial_events_file": "SpatialEvents.csv",
            "recovery_status": "recording_in_progress",
        ]
        try JSONSerialization.data(
            withJSONObject: dataset,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: partialURL.appendingPathComponent("geomag_dataset.json"),
            options: .atomic
        )
        try JSONSerialization.data(
            withJSONObject: capture,
            options: [.prettyPrinted, .sortedKeys]
        ).write(
            to: partialURL.appendingPathComponent("capture_metadata.json"),
            options: .atomic
        )
        try Data(CapturePackageBuilder.packageReadme.utf8).write(
            to: partialURL.appendingPathComponent("README.txt"),
            options: .atomic
        )
    }

    private func append(_ text: String, to stream: Stream) {
        guard let data = text.data(using: .utf8) else { return }
        lock.withLock {
            guard !isClosed, let handle = handles[stream] else { return }
            try? handle.write(contentsOf: data)
        }
    }

    private static func recoveryRoot() throws -> URL {
        try applicationSupportRoot().appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
    }

    private static func savedRoot() throws -> URL {
        try applicationSupportRoot().appendingPathComponent(
            "SavedCaptures",
            isDirectory: true
        )
    }

    private static func applicationSupportRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("GeomagCapture", isDirectory: true)
    }

    private static func availableDestination(
        for datasetKey: String,
        in root: URL
    ) -> URL {
        let base = "\(safeFileComponent(datasetKey))-\(fileTimestamp())"
        var candidate = root.appendingPathComponent(
            base + ".geomagcapture",
            isDirectory: true
        )
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent(
                "\(base)-\(suffix).geomagcapture",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .distantPast
    }

    private static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let converted = value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let result = String(converted)
        return result.isEmpty ? "geomag-capture" : result
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func row(_ values: [Double]) -> String {
        values.map {
            String(
                format: "%.9g",
                locale: Locale(identifier: "en_US_POSIX"),
                $0
            )
        }.joined(separator: ",") + "\n"
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
