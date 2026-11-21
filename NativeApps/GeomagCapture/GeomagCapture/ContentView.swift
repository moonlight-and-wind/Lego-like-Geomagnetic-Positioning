import SwiftUI

struct ContentView: View {
    @ObservedObject var recorder: MotionRecorder

    @State private var datasetName = Self.defaultDatasetName()
    @State private var routeText = ""
    @State private var generatedRouteText = ""
    @State private var generatedRouteIsReversed = false
    @State private var initialHeadingText = ""
    @State private var coordinateFrameText = ""
    @State private var startXText = "0"
    @State private var startYText = "0"
    @State private var eventLabel = ""
    @State private var anchorXText = "0"
    @State private var anchorYText = "0"
    @State private var mappingMode = true
    @State private var reverseRoute = false
    @State private var roomWidthText = "6"
    @State private var roomLengthText = "8"
    @State private var scanOriginXText = "0"
    @State private var scanOriginYText = "0"
    @State private var scanSpacingText = "0.5"
    @State private var isExporting = false
    @State private var confirmNextRouteAnchor = false
    @State private var confirmSkipRouteAnchor = false
    @State private var confirmIncompleteStop = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    configurationCard
                    liveMotionCard
                    spatialEventCard
                    controls
                    exportCard
                    guidanceCard
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Geomag Capture")
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "出现问题",
                isPresented: Binding(
                    get: { recorder.errorMessage != nil },
                    set: { if !$0 { recorder.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(recorder.errorMessage ?? "未知错误")
            }
            .fileExporter(
                isPresented: $isExporting,
                document: recorder.completedDocument,
                contentType: .geomagCapture,
                defaultFilename: recorder.suggestedFileName
            ) { result in
                switch result {
                case .success:
                    recorder.markExported()
                case let .failure(error):
                    recorder.reportExportError(error)
                }
            }
            .confirmationDialog(
                recorder.nextRouteAnchorIsFinal ? "确认已到达终点？" :
                    (recorder.nextRouteAnchorRequiresTurn ? "确认已到达并准备转弯？" : "确认已到达路线点？"),
                isPresented: $confirmNextRouteAnchor,
                titleVisibility: .visible
            ) {
                Button(recorder.nextRouteAnchorIsFinal ? "确认终点" :
                    (recorder.nextRouteAnchorRequiresTurn ? "记录锚点和转弯" : "记录路线锚点")) {
                    recorder.markNextRouteAnchorAndTurn(label: eventLabel)
                    eventLabel = ""
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(recorder.nextRouteAnchorDescription)
            }
            .confirmationDialog(
                "跳过不可到达的路线点？",
                isPresented: $confirmSkipRouteAnchor,
                titleVisibility: .visible
            ) {
                Button("确认跳过", role: .destructive) {
                    recorder.skipNextRouteAnchor()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请先暂停建图，再跳过障碍物占据的点。暂停区间不会被 macOS 插值成有效覆盖。")
            }
            .confirmationDialog(
                "还有路线锚点未完成",
                isPresented: $confirmIncompleteStop,
                titleVisibility: .visible
            ) {
                Button("仍然停止", role: .destructive) {
                    Task { await recorder.stopRecording() }
                }
                Button("继续采集", role: .cancel) {}
            } message: {
                Text("未完成的锚点会降低二维磁图覆盖率。确认数据确实采集完毕后再停止。")
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red.opacity(0.14) : Color.blue.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: recorder.isRecording ? "record.circle.fill" : "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(recorder.isRecording ? .red : .blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(recorder.statusMessage)
                    .font(.headline)
                Text(
                    recorder.isRecording
                        ? "\(duration(recorder.elapsedTime)) · \(number(recorder.observedRateHz)) Hz"
                        : "Core Motion · \(recorder.sensorAvailabilityText)"
                )
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .cardStyle()
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("采集配置", systemImage: "slider.horizontal.3")
                .font(.headline)

            Toggle("房间建图模式", isOn: $mappingMode)
                .font(.subheadline.weight(.semibold))

            if mappingMode {
                HStack(spacing: 8) {
                    labeledField("可扫描宽 X（米）", hint: "") {
                        TextField("6", text: $roomWidthText).keyboardType(.decimalPad)
                    }
                    labeledField("可扫描长 Y（米）", hint: "") {
                        TextField("8", text: $roomLengthText).keyboardType(.decimalPad)
                    }
                    labeledField("线距（米）", hint: "") {
                        TextField("0.5", text: $scanSpacingText).keyboardType(.decimalPad)
                    }
                }
                HStack(spacing: 8) {
                    labeledField("可扫描区左下角 X", hint: "与墙保持距离后的坐标") {
                        TextField("0.5", text: $scanOriginXText).keyboardType(.numbersAndPunctuation)
                    }
                    labeledField("可扫描区左下角 Y", hint: "与墙保持距离后的坐标") {
                        TextField("0.5", text: $scanOriginYText).keyboardType(.numbersAndPunctuation)
                    }
                }
                Button {
                    generateRoomScanTask()
                } label: {
                    Label("生成横向 + 纵向蛇形扫描任务", systemImage: "point.3.connected.trianglepath.dotted")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text("长、宽填写实际可扫描范围；左下角可填写与墙保持距离后的坐标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("反向采集路线", isOn: $reverseRoute)
                .font(.subheadline.weight(.semibold))
                .onChange(of: reverseRoute) { newValue in
                    updateGeneratedRouteDirection(reversed: newValue)
                }
            Text(reverseRoute ? "将从路线终点出发，坐标系保持不变。" : "按路线原顺序采集。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let endpoints = currentRouteEndpoints {
                Text(
                    String(
                        format: "当前任务：起点 (%.3f, %.3f) → 终点 (%.3f, %.3f)%@",
                        endpoints.start.0,
                        endpoints.start.1,
                        endpoints.end.0,
                        endpoints.end.1,
                        endpoints.isClosed ? "；该路线最终返回起点，正反向起点相同但顺序相反" : ""
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            labeledField("数据集名称", hint: "例如 route3_run1") {
                TextField("route3_run1", text: $datasetName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            labeledField("统一空间坐标系（必填）", hint: "同一楼层所有采集必须完全一致，例如 building-a-floor-1") {
                TextField("building-a-floor-1", text: $coordinateFrameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 10) {
                labeledField("起点 X（米）", hint: "楼层统一坐标") {
                    TextField("0", text: $startXText)
                        .keyboardType(.numbersAndPunctuation)
                }
                labeledField("起点 Y（米）", hint: "楼层统一坐标") {
                    TextField("0", text: $startYText)
                        .keyboardType(.numbersAndPunctuation)
                }
            }

            labeledField("真实路线坐标（可选，米）", hint: "必须使用米：180 cm 请填 1.80；到 Mac 后也可以再填") {
                TextField(
                    "1.44,0.55; 1.44,6.05; 4.32,6.05",
                    text: $routeText,
                    axis: .vertical
                )
                .lineLimit(2...4)
                    .keyboardType(.numbersAndPunctuation)
            }

            if let points = MotionRecorder.parseRoute(routeText) {
                RoutePreview(points: points)
                    .frame(height: 110)
                if let issue = MotionRecorder.routeIssue(points) {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Label("路线顺序有效 · \(points.count) 个点；预览应与实际行走形状一致", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else if !routeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("路线格式错误，请使用 x,y; x,y", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            labeledField("初始航向（数学角度）", hint: "0°=+X，90°=+Y，-90°=-Y；填写路线时可留空自动计算") {
                TextField("90", text: $initialHeadingText)
                    .keyboardType(.numbersAndPunctuation)
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(recorder.isRecording || recorder.isPreparingExport)
        .cardStyle()
    }

    private var spatialEventCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("空间锚点与转弯", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Spacer()
                Text("\(recorder.spatialEventCount) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(recorder.lastSpatialEventMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if recorder.routeAnchorTotal > 0 {
                ProgressView(value: recorder.routeCoverage)
                Text(
                    "扫描点进度 \(recorder.routeAnchorCompleted)/\(recorder.routeAnchorTotal)"
                        + (recorder.routeAnchorSkipped > 0 ? " · 已跳过 \(recorder.routeAnchorSkipped)" : "")
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if recorder.anchorReminderNeeded {
                Label("距离上一个锚点已超过 25 秒，请确认是否漏记扫描线端点。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if recorder.isRecording {
                TextField("事件名称（可选）", text: $eventLabel)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)

                HStack(spacing: 10) {
                    TextField("锚点 X（米）", text: $anchorXText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("锚点 Y（米）", text: $anchorYText)
                        .keyboardType(.numbersAndPunctuation)
                }
                .textFieldStyle(.roundedBorder)

                HStack(spacing: 10) {
                    Button {
                        recorder.markTurn(label: eventLabel)
                        eventLabel = ""
                    } label: {
                        Label("转弯前标记", systemImage: "arrow.turn.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!recorder.phoneIsFlat)

                    Button {
                        recorder.markAnchor(
                            label: eventLabel,
                            xText: anchorXText,
                            yText: anchorYText
                        )
                        eventLabel = ""
                    } label: {
                        Label("记录坐标锚点", systemImage: "mappin.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if recorder.hasNextRouteAnchor {
                    Button {
                        confirmNextRouteAnchor = true
                    } label: {
                        Label(
                            recorder.nextRouteAnchorDescription
                                + (recorder.nextRouteAnchorIsFinal ? " · 终点" :
                                    (recorder.nextRouteAnchorRequiresTurn ? " · 到达后点此，再转向" : " · 直行经过点")),
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(recorder.isPaused || !recorder.phoneIsFlat)

                    HStack {
                        Button {
                            recorder.undoLastRouteAnchor()
                        } label: {
                            Label("撤销上个路线点", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(!recorder.canUndoLastRouteAnchor || recorder.isPaused)

                        Spacer()

                        Button(role: .destructive) {
                            confirmSkipRouteAnchor = true
                        } label: {
                            Label("障碍物：跳过此点", systemImage: "nosign")
                        }
                        .disabled(!recorder.isPaused)
                    }
                    .font(.caption)
                }
            } else {
                Text("开始采集后，可在经过已知坐标时记录锚点，并在改变方向前标记转弯起点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var liveMotionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("实时传感器", systemImage: "gyroscope")
                    .font(.headline)
                Spacer()
                if recorder.counts.deviceMotion > 0 {
                    Label(
                        recorder.phoneIsFlat ? "姿态平稳" : "手机倾斜",
                        systemImage: recorder.phoneIsFlat ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(recorder.phoneIsFlat ? .green : .orange)
                }
            }

            HStack(spacing: 10) {
                metric("横滚", value: degrees(recorder.rollDegrees))
                metric("俯仰", value: degrees(recorder.pitchDegrees))
                metric("设备 yaw", value: degrees(recorder.yawDegrees))
            }

            HStack(spacing: 10) {
                metric(
                    "全局航向",
                    value: recorder.globalHeadingDegrees.map(degrees) ?? "—"
                )
                Text("全局航向 = 已知起始方向 + Core Motion 相对 yaw")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                metric("磁场", value: recorder.counts.magnetometer > 0
                    ? "\(number(recorder.magneticMagnitude)) µT" : "—")
                metric("磁场校准", value: recorder.magneticAccuracy.rawValue)
            }

            Divider()

            VStack(spacing: 8) {
                sampleRow("加速度计", count: recorder.counts.accelerometer)
                sampleRow("陀螺仪", count: recorder.counts.gyroscope)
                sampleRow("磁力计", count: recorder.counts.magnetometer)
                sampleRow("Device Motion", count: recorder.counts.deviceMotion)
            }
        }
        .cardStyle()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.isRecording {
                Button {
                    recorder.togglePause()
                } label: {
                    Label(
                        recorder.isPaused ? "恢复建图" : "暂停建图",
                        systemImage: recorder.isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    if recorder.hasIncompleteRouteAnchors {
                        confirmIncompleteStop = true
                    } else {
                        Task { await recorder.stopRecording() }
                    }
                } label: {
                    Label("停止并保存", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    anchorXText = startXText
                    anchorYText = startYText
                    recorder.startRecording(
                        datasetName: datasetName,
                        routeText: routeText,
                        initialHeadingText: initialHeadingText,
                        coordinateFrameText: coordinateFrameText,
                        startXText: startXText,
                        startYText: startYText,
                        reverseRoute: reverseRoute,
                        routeTextIsReversed: routeText == generatedRouteText && generatedRouteIsReversed
                    )
                } label: {
                    Label("开始采集", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.isPreparingExport)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var exportCard: some View {
        if recorder.isPreparingExport {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在生成 CSV 和元数据…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .cardStyle()
        } else if recorder.completedDocument != nil {
            VStack(alignment: .leading, spacing: 10) {
                Label("采集包已生成", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("包含传感器 CSV、DeviceMotion.csv、统一空间坐标和锚点/转弯事件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    isExporting = true
                } label: {
                    Label("导出 .geomagcapture…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .cardStyle()
        }
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("采集提示", systemImage: "figure.walk")
                .font(.headline)
            guidance("手机正面朝上、前端朝向行走方向。")
            guidance("开始后静止约 3 秒，再匀速行走。")
            guidance("到达终点后保持静止约 3 秒，再点击停止。")
            guidance("预设路线：到达点位后点紫色按钮，它会同时记录锚点和转弯起点，然后再转向。无预设路线时才单独点“转弯前标记”。")
            guidance("房间建图建议横向、纵向各扫描一遍，线距 0.4～0.6 m；同一区域重复 2～3 次。")
            if mappingMode {
                Divider()
                Label("遇到桌子、沙发等障碍物", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                guidance("① 在障碍物前的已知位置记录坐标锚点，然后点击“暂停建图”。")
                guidance("② 保持暂停并绕到障碍物另一侧；如果下个预设路线点本身不可到达，再点“障碍物：跳过此点”。")
                guidance("③ 到达另一侧已知位置后点击“恢复建图”，立即记录新的坐标锚点。")
                guidance("④ 沿障碍物可行走边缘补扫；不要搬动家具，也不要把障碍物内部当作已覆盖区域。")
            }
            guidance("采集期间保持屏幕点亮，不要切到后台。")
            Text("模拟器没有运动传感器；请在 Xcode 中选择已连接的真实 iPhone。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .cardStyle()
    }

    private func labeledField<Content: View>(
        _ title: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium))
            content()
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func generateRoomScanTask() {
        guard let width = Double(roomWidthText), let length = Double(roomLengthText),
              let originX = Double(scanOriginXText), let originY = Double(scanOriginYText),
              let spacing = Double(scanSpacingText),
              width > 0.5, length > 0.5,
              originX.isFinite, originY.isFinite,
              0.2...1.0 ~= spacing else {
            recorder.errorMessage = "可扫描区域的长、宽必须大于 0.5 m，左下角必须有效，线距应为 0.2～1.0 m。"
            return
        }
        var points: [(Double, Double)] = []
        let horizontalLines = Int(ceil(length / spacing))
        for line in 0...horizontalLines {
            let y = originY + min(Double(line) * spacing, length)
            points.append(line.isMultiple(of: 2) ? (originX, y) : (originX + width, y))
            points.append(line.isMultiple(of: 2) ? (originX + width, y) : (originX, y))
        }
        let verticalLines = Int(ceil(width / spacing))
        let startsFromRight = abs((points.last?.0 ?? originX) - (originX + width)) < 0.0001
        for step in 0...verticalLines {
            let line = startsFromRight ? verticalLines - step : step
            let x = originX + min(Double(line) * spacing, width)
            points.append(step.isMultiple(of: 2) ? (x, originY + length) : (x, originY))
            points.append(step.isMultiple(of: 2) ? (x, originY) : (x, originY + length))
        }
        points = points.reduce(into: []) { result, point in
            guard let previous = result.last,
                  hypot(previous.0 - point.0, previous.1 - point.1) < 0.0001 else {
                result.append(point)
                return
            }
        }
        if reverseRoute {
            applyGeneratedRoute(points.reversed(), reversed: true)
        } else {
            applyGeneratedRoute(points, reversed: false)
        }
    }

    private var currentRouteEndpoints: (
        start: (Double, Double),
        end: (Double, Double),
        isClosed: Bool
    )? {
        guard let parsed = MotionRecorder.parseRoute(routeText),
              let points = MotionRecorder.orderedRoute(
                parsed,
                reverseRoute: reverseRoute,
                inputIsReversed: routeText == generatedRouteText && generatedRouteIsReversed
              ),
              let first = points.first,
              let last = points.last else { return nil }
        return (
            (first[0], first[1]),
            (last[0], last[1]),
            hypot(first[0] - last[0], first[1] - last[1]) < 0.0001
        )
    }

    private func updateGeneratedRouteDirection(reversed: Bool) {
        guard routeText == generatedRouteText,
              generatedRouteIsReversed != reversed,
              let parsed = MotionRecorder.parseRoute(generatedRouteText) else { return }
        let points = parsed.map { ($0[0], $0[1]) }
        applyGeneratedRoute(points.reversed(), reversed: reversed)
    }

    private func applyGeneratedRoute<S: Sequence>(
        _ route: S,
        reversed: Bool
    ) where S.Element == (Double, Double) {
        let points = Array(route)
        let newRouteText = points.map { String(format: "%.3f,%.3f", $0.0, $0.1) }
            .joined(separator: "; ")
        routeText = newRouteText
        generatedRouteText = newRouteText
        generatedRouteIsReversed = reversed

        if let first = points.first {
            startXText = String(format: "%.3f", first.0)
            startYText = String(format: "%.3f", first.1)
            anchorXText = startXText
            anchorYText = startYText
        }
        if points.count >= 2 {
            let deltaX = points[1].0 - points[0].0
            let deltaY = points[1].1 - points[0].1
            initialHeadingText = String(format: "%.1f", atan2(deltaY, deltaX) * 180 / .pi)
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sampleRow(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(count) 样本").monospacedDigit()
        }
        .font(.subheadline)
    }

    private func guidance(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.blue)
            Text(text).font(.subheadline)
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func degrees(_ value: Double) -> String {
        recorder.counts.deviceMotion > 0 ? "\(number(value))°" : "—"
    }

    private static func defaultDatasetName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "route_new_\(formatter.string(from: Date()))"
    }
}

private struct RoutePreview: View {
    let points: [[Double]]

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let xs = points.map { $0[0] }
            let ys = points.map { $0[1] }
            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 1
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 1
            let spanX = max(maxX - minX, 0.1)
            let spanY = max(maxY - minY, 0.1)
            let inset: CGFloat = 14
            func screenPoint(_ point: [Double]) -> CGPoint {
                CGPoint(
                    x: inset + CGFloat((point[0] - minX) / spanX) * (size.width - inset * 2),
                    y: size.height - inset - CGFloat((point[1] - minY) / spanY) * (size.height - inset * 2)
                )
            }
            var path = Path()
            path.move(to: screenPoint(points[0]))
            for point in points.dropFirst() { path.addLine(to: screenPoint(point)) }
            context.stroke(path, with: .color(.blue), lineWidth: 3)
            for (index, point) in points.enumerated() {
                let center = screenPoint(point)
                let rect = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: rect), with: .color(index == 0 ? .green : .orange))
            }
        }
        .padding(4)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("真实路线预览")
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView(recorder: MotionRecorder())
}
