import CoreMotion
import Foundation
import UIKit

@MainActor
final class MotionRecorder: ObservableObject {
    struct SampleCounts: Equatable {
        var accelerometer = 0
        var gyroscope = 0
        var magnetometer = 0
        var deviceMotion = 0
    }

    enum MagneticAccuracy: String {
        case unavailable = "不可用"
        case uncalibrated = "未校准"
        case low = "低"
        case medium = "中"
        case high = "高"

        var symbol: String {
            switch self {
            case .unavailable: "questionmark.circle"
            case .uncalibrated: "exclamationmark.triangle"
            case .low: "wave.1.right"
            case .medium: "wave.2.right"
            case .high: "wave.3.right"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isPreparingExport = false
    @Published private(set) var elapsedTime = 0.0
    @Published private(set) var counts = SampleCounts()
    @Published private(set) var rollDegrees = 0.0
    @Published private(set) var pitchDegrees = 0.0
    @Published private(set) var yawDegrees = 0.0
    @Published private(set) var globalHeadingDegrees: Double?
    @Published private(set) var magneticMagnitude = 0.0
    @Published private(set) var magneticAccuracy: MagneticAccuracy = .unavailable
    @Published private(set) var statusMessage = "准备采集"
    @Published private(set) var completedDocument: CaptureDocument?
    @Published private(set) var suggestedFileName = "geomag-capture"
    @Published private(set) var spatialEventCount = 0
    @Published private(set) var lastSpatialEventMessage = "尚未记录空间事件"
    @Published private(set) var hasNextRouteAnchor = false
    @Published private(set) var nextRouteAnchorDescription = ""
    @Published private(set) var routeAnchorCompleted = 0
    @Published private(set) var routeAnchorTotal = 0
    @Published private(set) var routeAnchorSkipped = 0
    @Published private(set) var canUndoLastRouteAnchor = false
    @Published private(set) var anchorReminderNeeded = false
    @Published var errorMessage: String?

    let requestedSampleRateHz = 100.0

    private let manager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.xuminglei.GeomagCapture.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let buffer = CaptureBuffer()
    private var startUptime = 0.0
    private var startedAt = Date()
    private var datasetKey = ""
    private var route: [[Double]]?
    private var routeDirection = "forward"
    private var initialHeadingDegrees: Double?
    private var spatialReference: SpatialReference?
    private var spatialEvents: [SpatialEventSample] = []
    private var initialDeviceYawDegrees: Double?
    private var nextRouteAnchorIndex = 0
    private var routeAnchorEventIndices: [Int] = []
    private var lastAnchorTime = 0.0
    private var displayTimer: Timer?
    private var recoveryStore: CaptureRecoveryStore?
    private var persistedCaptureURL: URL?

    init() {
        Task { [weak self] in
            let recovered = await Task.detached(priority: .utility) {
                CaptureRecoveryStore.latestRecoverableCapture()
            }.value
            guard let self,
                  let recovered,
                  !self.isRecording,
                  self.completedDocument == nil else { return }
            self.completedDocument = CaptureDocument(files: recovered.files)
            self.suggestedFileName = recovered.suggestedFileName
            self.persistedCaptureURL = recovered.persistedURL
            self.statusMessage = recovered.wasInterrupted
                ? "发现上次中断的采集，已恢复可导出数据"
                : "发现尚未导出的本地采集包"
        }
    }

    var phoneIsFlat: Bool {
        abs(rollDegrees) <= 15 && abs(pitchDegrees) <= 15
    }

    var observedRateHz: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(counts.deviceMotion) / elapsedTime
    }

    var routeCoverage: Double {
        guard routeAnchorTotal > 0 else { return 0 }
        return min(Double(routeAnchorCompleted) / Double(routeAnchorTotal), 1)
    }

    var hasIncompleteRouteAnchors: Bool {
        routeAnchorTotal > 0 && routeAnchorCompleted < routeAnchorTotal
    }

    var nextRouteAnchorIsFinal: Bool {
        guard let route else { return false }
        return nextRouteAnchorIndex == route.count - 1
    }

    var nextRouteAnchorRequiresTurn: Bool {
        guard let route else { return false }
        return Self.routeTurns(at: nextRouteAnchorIndex, in: route)
    }

    var sensorAvailabilityText: String {
        let available = [
            manager.isAccelerometerAvailable,
            manager.isGyroAvailable,
            manager.isMagnetometerAvailable,
            manager.isDeviceMotionAvailable,
        ].filter { $0 }.count
        return "\(available)/4 路可用"
    }

    func startRecording(
        datasetName: String,
        routeText: String,
        initialHeadingText: String,
        coordinateFrameText: String,
        startXText: String,
        startYText: String,
        reverseRoute: Bool = false,
        routeTextIsReversed: Bool = false
    ) {
        guard !isRecording else { return }
        guard manager.isAccelerometerAvailable,
              manager.isGyroAvailable,
              manager.isMagnetometerAvailable,
              manager.isDeviceMotionAvailable else {
            errorMessage = "当前设备不提供完整的 Core Motion 传感器。iOS 模拟器不能采集，请连接真实 iPhone。"
            return
        }

        let normalizedName = Self.safeDatasetName(datasetName)
        guard !normalizedName.isEmpty else {
            errorMessage = "请填写数据集名称。"
            return
        }
        let coordinateFrame = coordinateFrameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coordinateFrame.isEmpty else {
            errorMessage = "请填写统一空间坐标系名称，例如 building-a-floor-1。"
            return
        }
        guard let startX = Double(startXText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let startY = Double(startYText.trimmingCharacters(in: .whitespacesAndNewlines)),
              startX.isFinite, startY.isFinite else {
            errorMessage = "起点 X、Y 必须是以米为单位的有效数字。"
            return
        }
        let trimmedRoute = routeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let forwardRoute = trimmedRoute.isEmpty ? nil : Self.parseRoute(trimmedRoute)
        if !trimmedRoute.isEmpty, forwardRoute == nil {
            errorMessage = "路线格式不正确。请使用 x1,y1; x2,y2，例如 1.44,0.55; 1.44,6.05。"
            return
        }
        if let forwardRoute, let issue = Self.routeIssue(forwardRoute) {
            errorMessage = issue
            return
        }
        let headingText = initialHeadingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedHeading = headingText.isEmpty ? nil : Double(headingText)
        if !headingText.isEmpty, parsedHeading?.isFinite != true {
            errorMessage = "初始航向必须是有效数字，或者留空。"
            return
        }
        let usesReverseRoute = reverseRoute && forwardRoute != nil
        let parsedRoute = Self.orderedRoute(
            forwardRoute,
            reverseRoute: usesReverseRoute,
            inputIsReversed: routeTextIsReversed
        )
        let routeHeading = parsedRoute.flatMap(Self.initialHeading)
        guard let resolvedHeading = (usesReverseRoute ? nil : parsedHeading) ?? routeHeading,
              resolvedHeading.isFinite else {
            errorMessage = "请填写初始航向；如果填写了真实路线，也可以留空由路线首段计算。"
            return
        }
        let resolvedStartX = parsedRoute?.first?[0] ?? startX
        let resolvedStartY = parsedRoute?.first?[1] ?? startY
        if !usesReverseRoute, let parsedRoute,
           let firstPoint = parsedRoute.first,
           hypot(firstPoint[0] - startX, firstPoint[1] - startY) > 0.25 {
            errorMessage = "真实路线第一个坐标必须与起点 X、Y 一致（允许 0.25 m 误差）。"
            return
        }
        if !usesReverseRoute, let parsedHeading,
           let routeHeading {
            let rawDifference = abs((parsedHeading - routeHeading).truncatingRemainder(dividingBy: 360))
            let difference = min(rawDifference, 360 - rawDifference)
            if difference > 20 {
                errorMessage = String(
                    format: "初始航向与路线首段相差 %.1f°。请按数学角度填写，或留空由路线自动计算。",
                    difference
                )
                return
            }
        }

        datasetKey = normalizedName
        route = parsedRoute
        routeDirection = usesReverseRoute ? "reverse" : "forward"
        initialHeadingDegrees = resolvedHeading
        let resolvedSpatialReference = SpatialReference(
            coordinateFrame: coordinateFrame,
            startX: resolvedStartX,
            startY: resolvedStartY,
            initialHeadingDegrees: resolvedHeading
        )
        spatialReference = resolvedSpatialReference
        spatialEvents = [
            SpatialEventSample(
                time: 0,
                type: "anchor",
                label: "start",
                x: resolvedStartX,
                y: resolvedStartY,
                headingDegrees: resolvedHeading,
                deviceYawDegrees: nil
            )
        ]
        spatialEventCount = spatialEvents.count
        lastSpatialEventMessage = String(format: "起点锚点 · (%.2f, %.2f)", resolvedStartX, resolvedStartY)
        initialDeviceYawDegrees = nil
        globalHeadingDegrees = resolvedHeading
        nextRouteAnchorIndex = parsedRoute == nil ? 0 : 1
        routeAnchorTotal = parsedRoute?.count ?? 0
        routeAnchorCompleted = parsedRoute == nil ? 0 : 1
        routeAnchorSkipped = 0
        routeAnchorEventIndices = []
        canUndoLastRouteAnchor = false
        lastAnchorTime = 0
        anchorReminderNeeded = false
        isPaused = false
        refreshNextRouteAnchor()
        startedAt = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        elapsedTime = 0
        counts = SampleCounts()
        completedDocument = nil
        buffer.reset()

        do {
            recoveryStore = try CaptureRecoveryStore.begin(
                datasetKey: normalizedName,
                startedAt: startedAt,
                requestedSampleRateHz: requestedSampleRateHz,
                route: parsedRoute,
                routeDirection: routeDirection,
                initialHeadingDegrees: resolvedHeading,
                spatialReference: resolvedSpatialReference,
                spatialEvents: spatialEvents
            )
            persistedCaptureURL = nil
        } catch {
            errorMessage = "无法建立采集恢复文件：\(error.localizedDescription)"
            statusMessage = "无法开始安全采集"
            return
        }

        let interval = 1 / requestedSampleRateHz
        manager.accelerometerUpdateInterval = interval
        manager.gyroUpdateInterval = interval
        manager.magnetometerUpdateInterval = interval
        manager.deviceMotionUpdateInterval = interval

        manager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { self.report(error) }
            guard let data else { return }
            let time = data.timestamp - self.startUptime
            guard time >= 0 else { return }
            let gravity = 9.80665
            let sample = AccelerometerSample(
                time: time,
                x: data.acceleration.x * gravity,
                y: data.acceleration.y * gravity,
                z: data.acceleration.z * gravity
            )
            self.buffer.append(sample)
            self.recoveryStore?.append(sample)
        }

        manager.startGyroUpdates(to: motionQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { self.report(error) }
            guard let data else { return }
            let time = data.timestamp - self.startUptime
            guard time >= 0 else { return }
            let sample = GyroscopeSample(
                time: time,
                x: data.rotationRate.x,
                y: data.rotationRate.y,
                z: data.rotationRate.z
            )
            self.buffer.append(sample)
            self.recoveryStore?.append(sample)
        }

        manager.startMagnetometerUpdates(to: motionQueue) { [weak self] data, error in
            guard let self else { return }
            if let error { self.report(error) }
            guard let data else { return }
            let time = data.timestamp - self.startUptime
            guard time >= 0 else { return }
            let sample = MagnetometerSample(
                time: time,
                x: data.magneticField.x,
                y: data.magneticField.y,
                z: data.magneticField.z
            )
            self.buffer.append(sample)
            self.recoveryStore?.appendRaw(sample)
        }

        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let reference: CMAttitudeReferenceFrame = frames.contains(.xArbitraryCorrectedZVertical)
            ? .xArbitraryCorrectedZVertical
            : .xArbitraryZVertical
        manager.startDeviceMotionUpdates(using: reference, to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            if let error { self.report(error) }
            guard let motion else { return }
            let time = motion.timestamp - self.startUptime
            guard time >= 0 else { return }
            let field = motion.magneticField.field
            let gravity = 9.80665
            let sample = DeviceMotionSample(
                time: time,
                quaternionX: motion.attitude.quaternion.x,
                quaternionY: motion.attitude.quaternion.y,
                quaternionZ: motion.attitude.quaternion.z,
                quaternionW: motion.attitude.quaternion.w,
                roll: motion.attitude.roll,
                pitch: motion.attitude.pitch,
                yaw: motion.attitude.yaw,
                gravityX: motion.gravity.x * gravity,
                gravityY: motion.gravity.y * gravity,
                gravityZ: motion.gravity.z * gravity,
                userAccelerationX: motion.userAcceleration.x * gravity,
                userAccelerationY: motion.userAcceleration.y * gravity,
                userAccelerationZ: motion.userAcceleration.z * gravity,
                rotationRateX: motion.rotationRate.x,
                rotationRateY: motion.rotationRate.y,
                rotationRateZ: motion.rotationRate.z,
                magneticFieldX: field.x,
                magneticFieldY: field.y,
                magneticFieldZ: field.z,
                magneticAccuracy: Int(motion.magneticField.accuracy.rawValue)
            )
            self.buffer.append(sample)
            self.recoveryStore?.append(sample)
        }

        isRecording = true
        statusMessage = "正在采集 · 请保持手机正面朝上、前端朝前"
        UIApplication.shared.isIdleTimerDisabled = true
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplay() }
        }
    }

    func markTurn(label: String) {
        guard isRecording, !isPaused else { return }
        guard phoneIsFlat else {
            errorMessage = "手机倾斜超过 15°。请先保持正面朝上，再在转弯前标记。"
            return
        }
        refreshDisplay()
        appendTurn(label: label, time: currentCaptureTime)
    }

    private func appendTurn(label: String, time: Double) {
        let eventLabel = normalizedEventLabel(label, fallback: "turn-\(spatialEvents.count)")
        spatialEvents.append(
            SpatialEventSample(
                time: time,
                type: "turn",
                label: eventLabel,
                x: nil,
                y: nil,
                headingDegrees: currentGlobalHeading,
                deviceYawDegrees: counts.deviceMotion > 0 ? yawDegrees : nil
            )
        )
        spatialEventCount = spatialEvents.count
        lastSpatialEventMessage = "已标记转弯起点 · \(eventLabel)"
        recoveryStore?.updateSpatialEvents(spatialEvents)
    }

    func markAnchor(label: String, xText: String, yText: String) {
        guard isRecording, !isPaused else { return }
        guard let x = Double(xText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(yText.trimmingCharacters(in: .whitespacesAndNewlines)),
              x.isFinite, y.isFinite else {
            errorMessage = "锚点 X、Y 必须是以米为单位的有效数字。"
            return
        }
        appendAnchor(label: label, x: x, y: y)
    }

    func markNextRouteAnchor(label: String) {
        guard isRecording, !isPaused,
              let route,
              route.indices.contains(nextRouteAnchorIndex) else { return }
        let point = route[nextRouteAnchorIndex]
        let fallback = "route-point-\(nextRouteAnchorIndex)"
        let eventIndex = appendAnchor(
            label: normalizedEventLabel(label, fallback: fallback),
            x: point[0],
            y: point[1]
        )
        routeAnchorEventIndices.append(eventIndex)
        canUndoLastRouteAnchor = true
        nextRouteAnchorIndex += 1
        routeAnchorCompleted = min(nextRouteAnchorIndex, routeAnchorTotal)
        refreshNextRouteAnchor()
    }

    func markNextRouteAnchorAndTurn(label: String) {
        guard isRecording, !isPaused,
              let route,
              route.indices.contains(nextRouteAnchorIndex) else { return }
        guard phoneIsFlat else {
            errorMessage = "手机倾斜超过 15°。请先保持正面朝上，再确认路线点。"
            return
        }
        let pointIndex = nextRouteAnchorIndex
        let shouldMarkTurn = Self.routeTurns(at: pointIndex, in: route)
        let point = route[pointIndex]
        let fallback = "route-point-\(pointIndex)"
        refreshDisplay()
        let time = currentCaptureTime
        let eventIndex = appendAnchor(
            label: normalizedEventLabel(label, fallback: fallback),
            x: point[0],
            y: point[1],
            time: time
        )
        routeAnchorEventIndices.append(eventIndex)
        canUndoLastRouteAnchor = true
        nextRouteAnchorIndex += 1
        routeAnchorCompleted = min(nextRouteAnchorIndex, routeAnchorTotal)
        refreshNextRouteAnchor()
        if shouldMarkTurn {
            appendTurn(label: "route-turn-\(pointIndex)", time: time)
            lastSpatialEventMessage = "已同时记录路线锚点和转弯起点 · 现在可以转向"
        }
    }

    func skipNextRouteAnchor() {
        guard isRecording, isPaused,
              let route,
              route.indices.contains(nextRouteAnchorIndex) else { return }
        refreshDisplay()
        let point = route[nextRouteAnchorIndex]
        spatialEvents.append(SpatialEventSample(
            time: currentCaptureTime,
            type: "anchor_skipped",
            label: "route-point-\(nextRouteAnchorIndex)",
            x: point[0],
            y: point[1],
            headingDegrees: currentGlobalHeading,
            deviceYawDegrees: counts.deviceMotion > 0 ? yawDegrees : nil
        ))
        nextRouteAnchorIndex += 1
        routeAnchorCompleted = min(nextRouteAnchorIndex, routeAnchorTotal)
        routeAnchorSkipped += 1
        canUndoLastRouteAnchor = false
        spatialEventCount = spatialEvents.count
        lastAnchorTime = currentCaptureTime
        anchorReminderNeeded = false
        lastSpatialEventMessage = String(
            format: "已跳过不可达路线点 · (%.2f, %.2f)",
            point[0], point[1]
        )
        refreshNextRouteAnchor()
        recoveryStore?.updateSpatialEvents(spatialEvents)
    }

    func undoLastRouteAnchor() {
        guard isRecording, !isPaused,
              let eventIndex = routeAnchorEventIndices.popLast(),
              spatialEvents.indices.contains(eventIndex),
              nextRouteAnchorIndex > 1 else { return }
        let removed = spatialEvents.remove(at: eventIndex)
        nextRouteAnchorIndex -= 1
        routeAnchorCompleted = min(nextRouteAnchorIndex, routeAnchorTotal)
        canUndoLastRouteAnchor = false
        spatialEventCount = spatialEvents.count
        lastAnchorTime = spatialEvents.last(where: { $0.type == "anchor" })?.time ?? 0
        anchorReminderNeeded = false
        lastSpatialEventMessage = String(
            format: "已撤销路线锚点 · (%.2f, %.2f)",
            removed.x ?? 0,
            removed.y ?? 0
        )
        refreshNextRouteAnchor()
        recoveryStore?.updateSpatialEvents(spatialEvents)
    }

    func togglePause() {
        guard isRecording else { return }
        refreshDisplay()
        isPaused.toggle()
        let type = isPaused ? "pause" : "resume"
        spatialEvents.append(SpatialEventSample(
            time: currentCaptureTime,
            type: type,
            label: type,
            x: nil,
            y: nil,
            headingDegrees: currentGlobalHeading,
            deviceYawDegrees: counts.deviceMotion > 0 ? yawDegrees : nil
        ))
        spatialEventCount = spatialEvents.count
        anchorReminderNeeded = false
        statusMessage = isPaused ? "建图已暂停 · 可移动到下一扫描线起点" : "建图已恢复 · 继续沿扫描线采集"
        recoveryStore?.updateSpatialEvents(spatialEvents)
    }

    func stopRecording(reason: String? = nil) async {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Finalize Geomag Capture",
            expirationHandler: nil
        )
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
        displayTimer?.invalidate()
        displayTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        await withCheckedContinuation { continuation in
            motionQueue.addBarrierBlock {
                continuation.resume()
            }
        }
        refreshDisplay()
        spatialEvents.append(
            SpatialEventSample(
                time: currentCaptureTime,
                type: "recording_stop",
                label: "stop",
                x: nil,
                y: nil,
                headingDegrees: currentGlobalHeading,
                deviceYawDegrees: counts.deviceMotion > 0 ? yawDegrees : nil
            )
        )
        spatialEventCount = spatialEvents.count
        recoveryStore?.updateSpatialEvents(spatialEvents)
        isPreparingExport = true
        statusMessage = "正在生成采集包…"
        await Task.yield()

        let stoppedAt = Date()
        guard let spatialReference else {
            errorMessage = "空间参考信息丢失，无法生成采集包。"
            isPreparingExport = false
            return
        }
        let snapshot = buffer.snapshot(
            datasetKey: datasetKey,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            requestedSampleRateHz: requestedSampleRateHz,
            route: route,
            routeDirection: routeDirection,
            initialHeadingDegrees: initialHeadingDegrees,
            spatialReference: spatialReference,
            spatialEvents: spatialEvents
        )
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                try CapturePackageBuilder.buildFiles(snapshot: snapshot)
            }.value
            let persistedURL = try recoveryStore?.finalize(files: files)
            completedDocument = CaptureDocument(files: files)
            persistedCaptureURL = persistedURL
            recoveryStore = nil
            suggestedFileName = datasetKey
            statusMessage = reason ?? "采集完成，可以导出"
        } catch {
            errorMessage = "无法生成采集包：\(error.localizedDescription)"
            statusMessage = "采集包生成失败"
        }
        isPreparingExport = false
    }

    func markExported() {
        if let persistedCaptureURL {
            CaptureRecoveryStore.discard(persistedCaptureURL)
            self.persistedCaptureURL = nil
        }
        statusMessage = "采集包已导出"
    }

    func reportExportError(_ error: Error) {
        errorMessage = "导出失败：\(error.localizedDescription)"
    }

    private func refreshDisplay() {
        elapsedTime = max(ProcessInfo.processInfo.systemUptime - startUptime, 0)
        let display = buffer.displaySnapshot()
        counts = display.counts
        guard let motion = display.latestMotion else { return }
        rollDegrees = motion.roll * 180 / .pi
        pitchDegrees = motion.pitch * 180 / .pi
        yawDegrees = motion.yaw * 180 / .pi
        if initialDeviceYawDegrees == nil {
            initialDeviceYawDegrees = yawDegrees
            if !spatialEvents.isEmpty {
                let start = spatialEvents[0]
                spatialEvents[0] = SpatialEventSample(
                    time: start.time,
                    type: start.type,
                    label: start.label,
                    x: start.x,
                    y: start.y,
                    headingDegrees: start.headingDegrees,
                    deviceYawDegrees: yawDegrees
                )
            }
        }
        globalHeadingDegrees = currentGlobalHeading
        recoveryStore?.updateSpatialEvents(spatialEvents)
        magneticMagnitude = sqrt(
            motion.magneticFieldX * motion.magneticFieldX
                + motion.magneticFieldY * motion.magneticFieldY
                + motion.magneticFieldZ * motion.magneticFieldZ
        )
        magneticAccuracy = Self.accuracy(rawValue: motion.magneticAccuracy)
        anchorReminderNeeded = isRecording && !isPaused && hasNextRouteAnchor
            && currentCaptureTime - lastAnchorTime > 25
    }

    nonisolated private func report(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.errorMessage == nil else { return }
            self.errorMessage = "Core Motion：\(error.localizedDescription)"
        }
    }

    private static func accuracy(rawValue: Int) -> MagneticAccuracy {
        switch rawValue {
        case Int(CMMagneticFieldCalibrationAccuracy.uncalibrated.rawValue): .uncalibrated
        case Int(CMMagneticFieldCalibrationAccuracy.low.rawValue): .low
        case Int(CMMagneticFieldCalibrationAccuracy.medium.rawValue): .medium
        case Int(CMMagneticFieldCalibrationAccuracy.high.rawValue): .high
        default: .unavailable
        }
    }

    private static func safeDatasetName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return trimmed.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { $0.append($1) }
    }

    private var currentCaptureTime: Double {
        max(ProcessInfo.processInfo.systemUptime - startUptime, 0)
    }

    private var currentGlobalHeading: Double? {
        guard let initialHeadingDegrees,
              let initialDeviceYawDegrees,
              counts.deviceMotion > 0 else { return initialHeadingDegrees }
        return initialHeadingDegrees + Self.wrappedDegrees(yawDegrees - initialDeviceYawDegrees)
    }

    private func normalizedEventLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    @discardableResult
    private func appendAnchor(label: String, x: Double, y: Double, time: Double? = nil) -> Int {
        refreshDisplay()
        let eventTime = time ?? currentCaptureTime
        let eventLabel = normalizedEventLabel(label, fallback: "anchor-\(spatialEvents.count)")
        spatialEvents.append(
            SpatialEventSample(
                time: eventTime,
                type: "anchor",
                label: eventLabel,
                x: x,
                y: y,
                headingDegrees: currentGlobalHeading,
                deviceYawDegrees: counts.deviceMotion > 0 ? yawDegrees : nil
            )
        )
        spatialEventCount = spatialEvents.count
        lastAnchorTime = eventTime
        anchorReminderNeeded = false
        lastSpatialEventMessage = String(format: "已记录锚点 %@ · (%.2f, %.2f)", eventLabel, x, y)
        recoveryStore?.updateSpatialEvents(spatialEvents)
        return spatialEvents.count - 1
    }

    private func refreshNextRouteAnchor() {
        guard let route,
              route.indices.contains(nextRouteAnchorIndex) else {
            hasNextRouteAnchor = false
            nextRouteAnchorDescription = ""
            return
        }
        hasNextRouteAnchor = true
        nextRouteAnchorDescription = String(
            format: "下个路线点 %d/%d · (%.2f, %.2f)",
            nextRouteAnchorIndex + 1,
            routeAnchorTotal,
            route[nextRouteAnchorIndex][0],
            route[nextRouteAnchorIndex][1]
        )
    }

    private static func wrappedDegrees(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result <= -180 { result += 360 }
        return result
    }

    static func parseRoute(_ value: String) -> [[Double]]? {
        let pairs = value.split(separator: ";", omittingEmptySubsequences: false)
        var points: [[Double]] = []
        for pair in pairs {
            let coordinates = pair.split(separator: ",", omittingEmptySubsequences: false)
            guard coordinates.count == 2,
                  let x = Double(coordinates[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let y = Double(coordinates[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                  x.isFinite, y.isFinite else { return nil }
            points.append([x, y])
        }
        return points.count >= 2 ? points : nil
    }

    static func routeIssue(_ route: [[Double]]) -> String? {
        guard route.count >= 2 else { return "真实路线至少需要两个坐标点。" }
        for index in 1..<route.count {
            let length = hypot(
                route[index][0] - route[index - 1][0],
                route[index][1] - route[index - 1][1]
            )
            if length < 0.05 {
                return "路线第 \(index) 与第 \(index + 1) 点距离小于 0.05 m，请删除重复点。"
            }
        }
        guard route.count >= 3 else { return nil }
        for index in 1..<(route.count - 1) {
            let ax = route[index][0] - route[index - 1][0]
            let ay = route[index][1] - route[index - 1][1]
            let bx = route[index + 1][0] - route[index][0]
            let by = route[index + 1][1] - route[index][1]
            let cosine = (ax * bx + ay * by) / (hypot(ax, ay) * hypot(bx, by))
            if cosine < -0.97 {
                return "路线第 \(index + 1) 点形成近 180° 原路折返，请检查坐标顺序；确需折返时建议拆成两次采集。"
            }
        }
        return nil
    }

    private static func routeTurns(at index: Int, in route: [[Double]]) -> Bool {
        guard index > 0, index < route.count - 1 else { return false }
        let ax = route[index][0] - route[index - 1][0]
        let ay = route[index][1] - route[index - 1][1]
        let bx = route[index + 1][0] - route[index][0]
        let by = route[index + 1][1] - route[index][1]
        let cosine = max(-1, min(1, (ax * bx + ay * by) / (hypot(ax, ay) * hypot(bx, by))))
        return acos(cosine) * 180 / .pi >= 15
    }

    static func orderedRoute(
        _ route: [[Double]]?,
        reverseRoute: Bool,
        inputIsReversed: Bool
    ) -> [[Double]]? {
        guard let route else { return nil }
        return inputIsReversed == reverseRoute ? route : Array(route.reversed())
    }

    private static func initialHeading(of route: [[Double]]) -> Double? {
        for index in 1..<route.count {
            let deltaX = route[index][0] - route[index - 1][0]
            let deltaY = route[index][1] - route[index - 1][1]
            if hypot(deltaX, deltaY) > 1e-9 {
                return atan2(deltaY, deltaX) * 180 / .pi
            }
        }
        return nil
    }
}

private final class CaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var accelerometer: [AccelerometerSample] = []
    private var gyroscope: [GyroscopeSample] = []
    private var magnetometer: [MagnetometerSample] = []
    private var deviceMotion: [DeviceMotionSample] = []

    func reset() {
        lock.withLock {
            accelerometer.removeAll(keepingCapacity: true)
            gyroscope.removeAll(keepingCapacity: true)
            magnetometer.removeAll(keepingCapacity: true)
            deviceMotion.removeAll(keepingCapacity: true)
        }
    }

    func append(_ sample: AccelerometerSample) {
        lock.withLock { accelerometer.append(sample) }
    }

    func append(_ sample: GyroscopeSample) {
        lock.withLock { gyroscope.append(sample) }
    }

    func append(_ sample: MagnetometerSample) {
        lock.withLock { magnetometer.append(sample) }
    }

    func append(_ sample: DeviceMotionSample) {
        lock.withLock { deviceMotion.append(sample) }
    }

    func displaySnapshot() -> (
        counts: MotionRecorder.SampleCounts,
        latestMotion: DeviceMotionSample?
    ) {
        lock.withLock {
            (
                MotionRecorder.SampleCounts(
                    accelerometer: accelerometer.count,
                    gyroscope: gyroscope.count,
                    magnetometer: magnetometer.count,
                    deviceMotion: deviceMotion.count
                ),
                deviceMotion.last
            )
        }
    }

    func snapshot(
        datasetKey: String,
        startedAt: Date,
        stoppedAt: Date,
        requestedSampleRateHz: Double,
        route: [[Double]]?,
        routeDirection: String,
        initialHeadingDegrees: Double?,
        spatialReference: SpatialReference,
        spatialEvents: [SpatialEventSample]
    ) -> CaptureSnapshot {
        lock.withLock {
            CaptureSnapshot(
                datasetKey: datasetKey,
                startedAt: startedAt,
                stoppedAt: stoppedAt,
                requestedSampleRateHz: requestedSampleRateHz,
                route: route,
                routeDirection: routeDirection,
                initialHeadingDegrees: initialHeadingDegrees,
                spatialReference: spatialReference,
                spatialEvents: spatialEvents,
                accelerometer: accelerometer,
                gyroscope: gyroscope,
                magnetometer: magnetometer,
                deviceMotion: deviceMotion
            )
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
