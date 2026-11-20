# GeomagMac Native 重设计实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `NativeApps/GeomagMacNative` 从默认 SwiftUI 侧栏工具重构为「纸面仪表 + 阶段式工作台」，并补齐逐步核对、报告 PDF、拖拽/紧凑/状态记忆。

**Architecture:** 新增 `PipelineState`（Stage/预检）与 `TrajectoryAnalysis`（投影/逐步样本）纯逻辑层，视图改为 `AppShell + StageRail + 四个 StageView + TrajectoryPlot + Inspector/RunsRail`；`AppModel` 只增加阶段、结果来源、拖拽入口与自动推进，算法入口保持不变。视觉统一走 `Theme` token，浅/深两套。

**Tech Stack:** Swift 5 / SwiftUI / AppKit / CoreGraphics / XCTest；Xcode 27.2，macOS 27.2 SDK。

**Spec:** `docs/superpowers/specs/2026-11-20-geomagmac-native-redesign.md`

## Global Constraints

- 目标系统：只跑 macOS 27+；app/test target 均为 `MACOSX_DEPLOYMENT_TARGET = 27.0`；不保留 macOS 26 及以下兼容分支。
- 系统 chrome（标题栏、菜单、弹窗）跟随 macOS 27；纸面内容区不套 Liquid Glass、不加玻璃/渐变/投影。
- 不改 `NativePositioningEngine`、`Controlled*`、`MagneticTemplateStore` 的算法与输出；不重算指标。
- 不触碰用户未提交的 `NativeApps/GeomagCaptureHarmony/*`、`.gitignore`、`StoreSubmission/`、`.superpowers/`；只改 `NativeApps/GeomagMacNative` 与本计划/规格文档。
- 不自动 `git commit` / `git push`：用户未要求提交；每个任务结束只做构建、测试、截图与必要的手工验证。
- 工作目录统一：`/Users/xuminglei/dachuang/Lego-like-Geomagnetic-Positioning/NativeApps/GeomagMacNative`。
- 构建/测试统一派生数据目录 `/tmp/geomagmac-dd`，避免污染仓库：
  - Build: `xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd build`
  - Test: `xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd test`
- 视图层禁止裸色值/裸字号：颜色走 `Theme`，数字读数走等宽；必要文字不用 `faint`。
- 每个 UI 任务结束必须实际启动 App 截图核对（浅色；涉及深色时加 `GEOMAG_APPEARANCE=dark`），不能只凭编译通过判定完成。
- 禁止用 `--no-verify`、跳过 hook 或改写用户已有未提交修改。

## 文件结构

新增（app target）：

- `GeomagMac/Models/PipelineState.swift` — Stage / StageIssue / PipelineInputs / PipelineReadiness。
- `GeomagMac/Models/TrajectoryAnalysis.swift` — RouteProjection / StepSample / RouteCorner / RouteTextParser / PlotLayout / PlotViewport。
- `GeomagMac/Views/Theme.swift` — 浅/深 token、字体、尺寸、品牌 mark。
- `GeomagMac/Views/Components.swift` — PlateButton、SegmentedRail、MetricTile、StatusPill、ToggleRow、StageBadge、NoticeBanner、SectionHeader、Panel、FieldSlot。
- `GeomagMac/Views/AppShellView.swift` — 窗口骨架、StageRail、StatusBar、错误 banner、拖拽、紧凑布局。
- `GeomagMac/Views/DataStageView.swift` — 01 数据。
- `GeomagMac/Views/MapStageView.swift` — 02 磁图（含热力图/质量/建图）。
- `GeomagMac/Views/RunStageView.swift` — 03 运行（含日志 sheet）。
- `GeomagMac/Views/AnalysisStageView.swift` — 04 分析（含指标/时间轴/逐步偏差）。
- `GeomagMac/Views/TrajectoryPlot.swift` — 画布绘制/交互（替换 TrajectoryCanvas）。
- `GeomagMac/Views/InspectorView.swift` — 右栏：图层/选中步/诊断/磁图/导出。
- `GeomagMac/Views/RunsRailView.swift` — 左栏运行记录。
- `GeomagMac/Resources/Assets.xcassets` — AppIcon（新图标）。
- `GeomagMacTests/PipelineStateTests.swift`、`GeomagMacTests/TrajectoryAnalysisTests.swift`、`GeomagMacTests/ExportTests.swift`。

修改：

- `GeomagMac/ContentView.swift` — 薄壳，改为 `AppShellView`。
- `GeomagMac/Models/AppModel.swift` — 阶段/结果来源/拖拽/自动推进/选中步/持久化；保留全部算法调用。
- `GeomagMac/Models/ResultExporter.swift` — 图层参数、PDF 报告、PNG 样式。
- `GeomagMac/GeomagMacApp.swift` — 默认窗口、命令菜单、窗口 autosave。
- `GeomagMac.xcodeproj/project.pbxproj` — 新文件入 app/test target、Assets 入 Resources、部署目标 27.0。
- `README.md` — 更新操作流程与快捷键（收口任务）。

删除（迁移完成后）：

- `GeomagMac/Views/MetricCard.swift`
- `GeomagMac/Views/TrajectoryCanvas.swift`

---

### Task 0: 部署目标 27.0 与基线

**Files:**
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: 所有 target 的 `MACOSX_DEPLOYMENT_TARGET = 27.0`；基线测试通过。

- [ ] **Step 1: 改部署目标**

把 `project.pbxproj` 中所有 `MACOSX_DEPLOYMENT_TARGET = 13.0;` 与 `= 14.0;` 改为 `= 27.0;`（app、test、project 级共 6 处）。不要改 `SDKROOT` 或其他 build settings。

- [ ] **Step 2: 构建**

Run:
```bash
cd /Users/xuminglei/dachuang/Lego-like-Geomagnetic-Positioning/NativeApps/GeomagMacNative
xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd build
```
Expected: `BUILD SUCCEEDED`，无新增 warning。

- [ ] **Step 3: 跑基线测试**

Run:
```bash
xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd test
```
Expected: `TEST SUCCEEDED`；记录测试数量（当前 `NativeEngineTests` 全绿）。

---

### Task 1: PipelineState 纯逻辑

**Files:**
- Create: `GeomagMac/Models/PipelineState.swift`
- Create: `GeomagMacTests/PipelineStateTests.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`（两个 target 的 Sources、Models/Tests group）

**Interfaces:**
- Produces:
```swift
enum Stage: Int, CaseIterable, Identifiable, Codable {
    case data = 0, map, run, analysis
    var id: Int { rawValue }
    var title: String
    var shortTitle: String
}

enum StageIssue: String, CaseIterable, Equatable {
    case noDataset, emptyDatasetName, invalidRoute, routeGeometry, invalidHeading
    case noMap, mapBuiltFromCurrentDataset, coordinateFrameMismatch
    case routeOutsideMap, roomModeNeedsHeading
    var stage: Stage
    var message: String
}

struct PipelineInputs: Equatable {
    var hasDataset: Bool
    var usesBundledDataset: Bool
    var datasetNameIsEmpty: Bool
    var routeIsValid: Bool
    var routeGeometryIsValid: Bool
    var routeIsInsideMap: Bool
    var hasMap: Bool
    var mapBuiltFromCurrentDataset: Bool
    var coordinateFrameMatches: Bool
    var localizationModeNeedsHeading: Bool
    var hasExplicitHeading: Bool
    var isRunning: Bool
    var hasResult: Bool
}

struct PipelineReadiness: Equatable {
    let issues: [StageIssue]
    let dataReady: Bool
    let mapReady: Bool
    let routeReady: Bool
    let headingReady: Bool
    let canRun: Bool
    let nextStage: Stage
    static func evaluate(_ input: PipelineInputs) -> PipelineReadiness
}
```

- [ ] **Step 1: 写失败测试**

`GeomagMacTests/PipelineStateTests.swift`：
```swift
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
        var input = validInput(); input.datasetNameIsEmpty = true
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.dataReady)
        XCTAssertEqual(readiness.issues, [.emptyDatasetName])
        XCTAssertEqual(readiness.nextStage, .data)
    }

    func testRouteOutsideMapBlocksMapStage() {
        var input = validInput(); input.routeIsInsideMap = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.routeReady)
        XCTAssertEqual(readiness.nextStage, .map)
        XCTAssertEqual(readiness.issues, [.routeOutsideMap])
    }

    func testMapBuiltFromCurrentDatasetBlocksRun() {
        var input = validInput(); input.mapBuiltFromCurrentDataset = true
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
        var input = validInput(); input.isRunning = true
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertFalse(readiness.canRun)
    }

    func testNoMapNextStageIsMap() {
        var input = validInput(); input.hasMap = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertEqual(readiness.nextStage, .map)
        XCTAssertEqual(readiness.issues, [.noMap])
    }

    func testResultMovesNextStageToAnalysis() {
        var input = validInput(); input.hasResult = true
        XCTAssertEqual(PipelineReadiness.evaluate(input).nextStage, .analysis)
    }

    func testBundledIgnoresImportedOnlyChecks() {
        var input = validInput()
        input.usesBundledDataset = true
        input.datasetNameIsEmpty = true
        input.routeIsValid = false
        input.localizationModeNeedsHeading = true
        input.hasExplicitHeading = false
        let readiness = PipelineReadiness.evaluate(input)
        XCTAssertTrue(readiness.dataReady)
        XCTAssertTrue(readiness.routeReady)
        XCTAssertTrue(readiness.headingReady)
        XCTAssertTrue(readiness.issues.isEmpty)
    }

    func testIssueStageMapping() {
        XCTAssertEqual(StageIssue.emptyDatasetName.stage, .data)
        XCTAssertEqual(StageIssue.mapBuiltFromCurrentDataset.stage, .map)
        XCTAssertEqual(StageIssue.roomModeNeedsHeading.stage, .map)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run:
```bash
xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd test 2>&1 | grep -E "error:|PipelineStateTests" | head -20
```
Expected: 编译失败 `cannot find type 'PipelineInputs'`。

- [ ] **Step 3: 实现最小逻辑**

在 `PipelineState.swift` 中按以下规则实现：

```swift
static func evaluate(_ i: PipelineInputs) -> PipelineReadiness {
    var issues: [StageIssue] = []
    let dataReady: Bool
    let mapReady: Bool
    let routeReady: Bool
    let headingReady: Bool
    if i.usesBundledDataset {
        dataReady = i.hasDataset
        routeReady = true
        headingReady = true
        if !i.hasDataset { issues.append(.noDataset) }
    } else {
        dataReady = i.hasDataset && !i.datasetNameIsEmpty && i.routeIsValid && i.routeGeometryIsValid
        routeReady = i.routeIsInsideMap
        headingReady = !i.localizationModeNeedsHeading || i.hasExplicitHeading
        if !i.hasDataset { issues.append(.noDataset) }
        if i.datasetNameIsEmpty { issues.append(.emptyDatasetName) }
        if !i.routeIsValid { issues.append(.invalidRoute) }
        if !i.routeGeometryIsValid { issues.append(.routeGeometry) }
        if !i.routeIsInsideMap { issues.append(.routeOutsideMap) }
        if i.localizationModeNeedsHeading && !i.hasExplicitHeading { issues.append(.roomModeNeedsHeading) }
    }
    mapReady = i.hasMap && !i.mapBuiltFromCurrentDataset && i.coordinateFrameMatches
    if !i.hasMap { issues.append(.noMap) }
    if i.mapBuiltFromCurrentDataset { issues.append(.mapBuiltFromCurrentDataset) }
    if !i.coordinateFrameMatches { issues.append(.coordinateFrameMismatch) }
    let canRun = dataReady && mapReady && routeReady && headingReady && !i.isRunning
    let nextStage: Stage = !dataReady ? .data : !mapReady || !routeReady || !headingReady ? .map : (i.hasResult ? .analysis : .run)
    return PipelineReadiness(issues: issues, dataReady: dataReady, mapReady: mapReady, routeReady: routeReady, headingReady: headingReady, canRun: canRun, nextStage: nextStage)
}
```
issue 顺序必须与上面测试一致：data 类 issue 按 `noDataset → emptyDatasetName → invalidRoute → routeGeometry → routeOutsideMap → roomModeNeedsHeading`；map 类按 `noMap → mapBuiltFromCurrentDataset → coordinateFrameMismatch`。`StageIssue.stage`：data issues → `.data`；map/route/heading issues → `.map`。`Stage` 的 title：`数据 / 磁图 / 运行 / 分析`。

- [ ] **Step 4: 跑测试通过**

Run:
```bash
xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd test 2>&1 | tail -20
```
Expected: `TEST SUCCEEDED`，新增 10 个测试全部通过。

---

### Task 2: TrajectoryAnalysis / 路线解析 / 投影

**Files:**
- Create: `GeomagMac/Models/TrajectoryAnalysis.swift`
- Create: `GeomagMacTests/TrajectoryAnalysisTests.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
```swift
struct RouteProjection: Equatable {
    let distance: Double
    let segmentIndex: Int
    let projectedPoint: XYPoint
    let parameter: Double
}

struct StepSample: Identifiable, Equatable {
    let id: Int                  // PF 索引，1...n-1
    let pfPoint: XYPoint
    let pdrPoint: XYPoint?
    let pfLateralError: Double?
    let pdrLateralError: Double?
    let confidence: PFConfidenceSample?
    let health: LocalizationHealthSample?
}

struct RouteCorner: Equatable, Identifiable {
    let id: Int
    let fraction: Double
    let point: XYPoint
}

struct EditableRoutePoint: Identifiable, Equatable {
    let id: Int
    let raw: String
    let point: XYPoint?
    let isDuplicate: Bool
    let isOutsideMap: Bool
}

enum TrajectoryAnalysis {
    static func nearestProjection(of point: XYPoint, on route: [XYPoint]) -> RouteProjection?
    static func stepSamples(for result: PositioningResult) -> [StepSample]
    static func routeCorners(_ route: [XYPoint]) -> [RouteCorner]
    static func stepIndex(forProgress progress: Double, pointCount: Int) -> Int
    static func progress(forStep index: Int, pointCount: Int) -> Double
}

enum RouteTextParser {
    static func points(from text: String) -> [EditableRoutePoint]
    static func points(from text: String, mapBounds: CoordinateBounds?) -> [EditableRoutePoint]
}

struct PlotLayout: Equatable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    let rect: CGRect
    init(bounds: CoordinateBounds, rect: CGRect)
    func screen(_ point: XYPoint) -> CGPoint
    func world(_ point: CGPoint) -> XYPoint
}

struct PlotViewport: Equatable {
    var zoom: Double = 1
    var pan: CGSize = .zero
    func screen(_ point: XYPoint, layout: PlotLayout, canvasSize: CGSize) -> CGPoint
    func world(_ point: CGPoint, layout: PlotLayout, canvasSize: CGSize) -> XYPoint
    mutating func zoom(by factor: Double, anchor: CGPoint, layout: PlotLayout, canvasSize: CGSize)
    mutating func reset()
}
```

- [ ] **Step 1: 写失败测试**

`GeomagMacTests/TrajectoryAnalysisTests.swift` 至少覆盖：
```swift
func testProjectionOnHorizontalSegment() {
    let route = [XYPoint(x: 0, y: 0), XYPoint(x: 4, y: 0)]
    let p = TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 2, y: 1), on: route)!
    XCTAssertEqual(p.distance, 1, accuracy: 1e-9)
    XCTAssertEqual(p.segmentIndex, 0)
    XCTAssertEqual(p.projectedPoint.x, 2, accuracy: 1e-9)
    XCTAssertEqual(p.parameter, 0.5, accuracy: 1e-9)
}

func testProjectionClampsToSegmentEnds() {
    let route = [XYPoint(x: 0, y: 0), XYPoint(x: 4, y: 0)]
    let p = TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 5, y: 0), on: route)!
    XCTAssertEqual(p.distance, 1, accuracy: 1e-9)
    XCTAssertEqual(p.projectedPoint.x, 4, accuracy: 1e-9)
}

func testProjectionSkipsZeroLengthSegments() {
    let route = [XYPoint(x: 1, y: 1), XYPoint(x: 1, y: 1), XYPoint(x: 1, y: 3)]
    let p = TrajectoryAnalysis.nearestProjection(of: XYPoint(x: 2, y: 2), on: route)!
    XCTAssertEqual(p.distance, 1, accuracy: 1e-9)
}

func testRouteCornersFractions() {
    let route = [XYPoint(x: 4, y: 3), XYPoint(x: 4, y: 4.8), XYPoint(x: 5.8, y: 4.8), XYPoint(x: 5.8, y: 3), XYPoint(x: 4, y: 3)]
    let corners = TrajectoryAnalysis.routeCorners(route)
    XCTAssertEqual(corners.map(\.fraction), [0.25, 0.5, 0.75])
}

func testStepSamplesAlignConfidenceAndHealth() {
    // 构造 PF 3 点、confidence 2 个、health 2 个，断言 id 1/2 对齐 confidence[0]/[1]
}

func testProgressAndStepRoundTrip() {
    XCTAssertEqual(TrajectoryAnalysis.stepIndex(forProgress: 0, pointCount: 30), 0)
    XCTAssertEqual(TrajectoryAnalysis.stepIndex(forProgress: 1, pointCount: 30), 29)
    XCTAssertEqual(TrajectoryAnalysis.stepIndex(forProgress: 0.5, pointCount: 30), 15)
}

func testRouteTextParserFlagsDuplicatesAndOutsideMap() {
    // bounds x 0...2, y 0...2；文本 "0,0; 0,0; 3,1; bad"
}

func testPlotLayoutRoundTrip() {
    let bounds = CoordinateBounds(minX: 0, maxX: 10, minY: 0, maxY: 5)!
    let layout = PlotLayout(bounds: bounds, rect: CGRect(x: 0, y: 0, width: 400, height: 200))
    let p = XYPoint(x: 3, y: 2)
    let back = layout.world(layout.screen(p))
    XCTAssertEqual(back.x, 3, accuracy: 1e-9)
    XCTAssertEqual(back.y, 2, accuracy: 1e-9)
}

func testViewportZoomKeepsAnchorWorldPointFixed() {
    // zoom 2 倍后 anchor 下的世界坐标不变
}
```

`CoordinateBounds` 的初始化与成员名以 `GenericMagneticMapStore.swift` 现有定义为准；若没有 memberwise init，使用现有构造方式或在测试里用 `try`/解码构造。

- [ ] **Step 2: 跑测试确认失败**

Expected: 编译失败，缺 `TrajectoryAnalysis`。

- [ ] **Step 3: 实现**

规则：
- `nearestProjection`：遍历 route 相邻段；`t = clamp(dot(p-a, b-a) / |b-a|², 0, 1)`；零长段跳过；取距离最小；route 只有 1 点时返回距离该点、segment 0、parameter 0；空 route 返回 nil。
- `stepSamples`：PF 索引 1...n-1；`confidence = pfConfidenceHistory?[index-1]`；`health = localizationHealthHistory?[index-1]`；PDR 点取同索引（若存在）；横向误差用 `nearestProjection`。
- `routeCorners`：按累计长度算内部顶点 fraction，过滤 0/1；闭合路线包含最后一个内部顶点。
- `stepIndex`：`min(count-1, max(0, Int((Double(count-1) * clamp(progress,0,1)).rounded())))`。
- `RouteTextParser`：按 `;` 切分，按 `,` 切 x/y；每行 `id=index`、`raw` 保留原始片段、`point` 解析失败为 nil；`isDuplicate` 与前一点相同；`isOutsideMap` 仅当 point 非 nil 且 bounds 存在时判断。
- `PlotLayout`：按 `rect` 与 bounds 等比内嵌，y 轴翻转；`screen/world` 互逆。
- `PlotViewport`：`screen = center + (layout.screen(p) - center) * zoom + pan`；zoom 时先算 anchor 世界点，更新 zoom，再调整 pan 使该点回到 anchor。

- [ ] **Step 4: 跑测试通过**

Expected: `TEST SUCCEEDED`，新增测试全部通过。

---

### Task 3: Theme 与通用组件

**Files:**
- Create: `GeomagMac/Views/Theme.swift`
- Create: `GeomagMac/Views/Components.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
```swift
struct Theme {
    let canvas, surface, surfaceSecondary, raised, hairline, grid: Color
    let ink, muted, faint, signal, trace, warn, danger: Color
    let plotBackground, plotGrid, plotGridMajor, plotInk, mapBoundary: Color
    let trueRoute, pdr, pf, confidenceHigh, confidenceMedium, confidenceLow: Color
    static func resolve(_ scheme: ColorScheme) -> Theme
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.resolve(.light) }
extension EnvironmentValues { var theme: Theme }
extension View { func geomagTheme(_ theme: Theme) -> some View }

struct Panel<Content: View>: View
struct SectionHeader: View
struct PlateButton: View            // title, systemImage, kind: .primary/.secondary/.ghost/.danger, action
struct SegmentedRail<Item: Hashable>: View
struct MetricTile: View             // title, value, unit, compare, delta, tint
struct StatusPill: View             // text, tint, dot
struct ToggleRow: View              // title, swatch, isOn
struct StageBadge: View             // stage, state, subtitle
struct NoticeBanner: View           // severity, message, actionTitle, action
struct FieldSlot<Content: View>: View
```

- [ ] **Step 1: 实现 Theme**

浅/深 token 严格按规格 §6 的表格；所有视图只通过 `@Environment(\.theme)` 取色。字体：
```swift
enum ThemeFont {
    static func display(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
    static func label(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}
```
尺寸：面板 12、卡片 10、控件 8、微标 6；间距 4/8/12/16/20/24。无 shadow。

- [ ] **Step 2: 实现组件**

要求：
- `PlateButton` 高度 32（primary 34），`primary` 用 signal 底 + `signalOn` 字；`secondary` 用 surface + hairline；`ghost` 透明；`danger` 只用于不可逆。
- `SegmentedRail` 高 32，选中块 raised + 底部 2px signal 指示；禁用项显示原因 tooltip。
- `MetricTile`：标题 9、数值 19 等宽、对照 8.5 muted；左侧 2px trace 条；survey 不需要，本 App 只做纸面。
- `ToggleRow`：26×15 开关，选中 signal；带线型/颜色 swatch。
- `NoticeBanner`：severity `.info/.warn/.error`，左侧 2px 色条，右侧动作按钮。
- `StageBadge`：序号 9 等宽、名称 12、副标题 9；完成 check 用 trace，当前 signal 下划线。
- `FieldSlot`：surfaceSecondary 背景、8 圆角、44 高、内部 TextField 无边框。
- 品牌 mark：28×28 方框，内含 20×20 route 图形（signal 折线 + trace 起点），用于 StageRail/空态。

- [ ] **Step 3: 构建**

Expected: `BUILD SUCCEEDED`；组件暂未被引用也可以编译。

---

### Task 4: AppModel 阶段/预检/拖拽/自动推进

**Files:**
- Modify: `GeomagMac/Models/AppModel.swift`
- Modify: `GeomagMac/Models/PipelineState.swift`（如需扩展）
- Create: `GeomagMacTests/AppModelStageTests.swift`（若可直接构造 AppModel；否则用纯逻辑测试 + 手工验证）

**Interfaces:**
- Consumes: `PipelineInputs`/`PipelineReadiness`。
- Produces:
```swift
enum ResultSource { case liveRun, history, openedFile, bundledSample }

@Published var stage: Stage
@Published var resultSource: ResultSource
@Published var selectedStepIndex: Int?
@Published var inspectorVisible: Bool
@Published var isFocusMode: Bool
@Published var isCompact: Bool

var pipelineReadiness: PipelineReadiness { get }
func go(to stage: Stage)
func advanceFromCurrentStage()
func importDatasetDropped(at url: URL)
func openDroppedResult(at url: URL)
var appVersion: String { get }
```

- [ ] **Step 1: 扩展状态**

- `pipelineReadiness` 用现有属性映射：
```swift
let usesBundled = runInputMode == .bundled
let inputs = PipelineInputs(
    hasDataset: usesBundled ? true : importedDataset != nil,
    usesBundledDataset: usesBundled,
    datasetNameIsEmpty: customDatasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    routeIsValid: DatasetValidator.normalizedRouteText(customRouteText) != nil,
    routeGeometryIsValid: DatasetValidator.routeGeometryIssue(customRouteText) == nil,
    routeIsInsideMap: usesBundled ? true : routeMapValidation.isValid,
    hasMap: mapForCurrentSelection != nil,
    mapBuiltFromCurrentDataset: runInputMode == .imported && selectedMapUsesCurrentDataset,
    coordinateFrameMatches: coordinateFrameMatchesSelectedMap,
    localizationModeNeedsHeading: currentLocalizationMode == .roomAreaKnownStart,
    hasExplicitHeading: roomModeHasExplicitInitialHeading,
    isRunning: isBackendRunning,
    hasResult: result != nil
)
return PipelineReadiness.evaluate(inputs)
```
- `go(to:)`：仅当 `stage == .data || (stage == .map && readiness.dataReady) || (stage == .run && readiness.canRun) || (stage == .analysis && result != nil)` 才切换；否则记录一条阶段 issue。切换用 `withAnimation`（视图层）。
- `advanceFromCurrentStage()`：01 → 02（dataReady）、02 → 03（canRun）、03 → 04（result != nil）、04 无动作。
- `importDatasetDropped(at:)`：调用 `importDataset(at:)`（把现有 private 改成 internal/private(set) 可调用），成功后 `stage = .data`。
- `openDroppedResult(at:)`：`load(url:)`，设置 `.openedFile`，`stage = .analysis`。
- `loadBundledSample` → `resultSource = .bundledSample`；`openResultFile` → `.openedFile`；`loadRun` → `.history`；`runSelectedDataset` 成功 → `.liveRun`；`init` 后按 `result != nil` 设定初始 stage（默认 `.analysis`，恢复值不满足前置时回退）。
- 运行成功：若 `stage == .run` 则 `stage = .analysis`；否则只刷新阶段状态。
- `appVersion`：`Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"`。

- [ ] **Step 2: 构建**

Expected: `BUILD SUCCEEDED`；旧 `ContentView` 仍能编译（暂时不改视图）。

- [ ] **Step 3: 手工验证**

启动 App，选内置 13_2 → 03 运行 → 完成后应进入 04；切到 01 再运行一次，完成后不应强行跳转（阶段保持 01，阶段条显示完成）。用 `po model.stage` 或界面观察。

---

### Task 5: AppShell + StageRail + StatusBar + 01 数据阶段

**Files:**
- Create: `GeomagMac/Views/AppShellView.swift`
- Create: `GeomagMac/Views/DataStageView.swift`
- Modify: `GeomagMac/ContentView.swift`
- Modify: `GeomagMac/GeomagMacApp.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Theme/Components/AppModel pipeline state。
- Produces: 可运行的四阶段壳（02/03/04 先显示 `StagePlaceholderView`，下一任务替换），阶段条主操作、错误 banner、拖拽。

- [ ] **Step 1: 写 AppShell**

结构：
```swift
struct AppShellView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = Theme.resolve(scheme)
        VStack(spacing: 0) {
            StageRailView()
            stageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBarView()
        }
        .background(theme.canvas)
        .geomagTheme(theme)
        .frame(minWidth: 1100, minHeight: 720)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in ... }
        .overlay(alignment: .top) { errorBanner }
    }
}
```
`stageContent` 用 `switch model.stage` + `.id(model.stage)` + `.transition(.opacity.combined(with: .offset(y: 8)))`；`withAnimation(.easeOut(duration: 0.2))` 由阶段切换触发。
`StageRailView`：品牌块 236（紧凑 180）、四段 `StageBadge`、右侧主操作：
- 01 `校验并继续` → `model.advanceFromCurrentStage()`
- 02 `下一步：运行` → `model.advanceFromCurrentStage()`
- 03 `开始计算` / `取消` → run/cancel
- 04 `导出` → 先用临时 `Menu`（Task 9 接真实导出）
主操作禁用时显示 `model.pipelineReadiness` 第一条 issue 的 message（tooltip + 段内 banner）。
`StatusBarView`：左绿点 + `就绪/计算中/导入中`；中 `datasetKey → mapName · steps · PF final`；右 `v\(appVersion) · 纯 Swift 引擎`。
`GeomagMacApp`：`ContentView` 保留；`WindowGroup` 加 `.defaultSize(width: 1440, height: 900)`；`CommandGroup` 增加 `⌘1–4`、`⌘O`、`⌘R`。
`ContentView`：`AppShellView().environmentObject(model)`（model 由 App 注入，保持现状）。

- [ ] **Step 2: 写 DataStage**

布局：`HStack(spacing:0) { DataMain; Divider; Inspector }`，主区 `ScrollView` 20 padding，右栏 300。
- 顶部 `SegmentedRail`：`内置留出数据` / `导入采集`；右侧 `打开结果 JSON…` ghost 按钮。
- 内置：`runnableDatasets` 选择器 + 一张说明卡（内置原始 CSV，路线预定义，02 自动选组磁图）。
- 导入：`选择采集文件夹…`、数据集卡（流、帧、区间、质量、锚点、warnings）、名称/航向 `FieldSlot`、路线 `TextEditor`（等宽，最小 72 高）、解析点表（`EditableRoutePoint` 行：序号/x/y/重复/越界）、`RoutePreview` 迷你画布、重新校验。
- `RoutePreview`：120 高 Canvas，画路线折线 + 所选磁图 bounds 方框；无磁图时只画路线。
- 右栏：数据集详情、质量消息、锚点说明、`重新校验`；无数据空态。
- 主操作在 StageRail，不在页面内重复。

- [ ] **Step 3: 构建**

Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: 启动并截图**

```bash
xcodebuild ... build
pkill -x GeomagMac 2>/dev/null || true
open /tmp/geomagmac-dd/Build/Products/Debug/GeomagMac.app
```
用 `osascript` 取窗口 bounds，`screencapture -R` 保存 `/tmp/shot-01-light.png`；检查：阶段条、数据卡、路线表、右栏、主操作禁用原因。深色用 `GEOMAG_APPEARANCE=dark` 直接跑可执行文件再截一张。

---

### Task 6: 02 磁图阶段

**Files:**
- Create: `GeomagMac/Views/MapStageView.swift`
- Modify: `GeomagMac/Views/AppShellView.swift`（替换占位）
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `magneticMaps`、`selectedMagneticMap`、`buildMagneticMapFromImportedDataset`、`pipelineReadiness`。
- Produces: 磁图列表/详情/热力图/建图/预检。

- [ ] **Step 1: 实现**

布局：左栏 260 磁图列表（内置/用户分组，选中高亮，质量等级）；主区：
- 无磁图：空态 + 建图 CTA。
- 有选中：标题 + 模式 pill + 质量 4 指标（覆盖/有效格/总格/中位样本）+ `MagneticMapHeatmap`（从 ContentView 迁移，改为 Theme 颜色）+ 图例 + 消息；路线磁图显示空态说明。
- 建图表单：名称、只读网格 0.25m、合并警告、进度、`用当前采集建立磁图`（次级；主操作仍是阶段条）。
- 预检清单：5 行状态；issue 行显示原因与 `去修复`（跳到 01/聚焦字段）。
右栏：来源采集、坐标系、参考路线、打开目录、移除用户磁图（确认）。

- [ ] **Step 2: 构建 + 截图**

同样的构建/启动/截图流程；截图覆盖：有磁图选中、建图中/建图完成、无磁图空态。检查热力图块与图例在浅/深色都清晰。

---

### Task 7: 03 运行阶段

**Files:**
- Create: `GeomagMac/Views/RunStageView.swift`
- Modify: `GeomagMac/Views/AppShellView.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `runSelectedDataset`、`cancelBackendRun`、`backendProgress`、`backendLog`、`algorithmSettings`。
- Produces: 连接卡 + 运行控制台 + 参数检查器 + 日志 sheet。

- [ ] **Step 1: 实现**

主区：
- 连接卡：数据卡（名称/步数/区间）→ 箭头 → 磁图卡（名称/模式/覆盖）。
- 模式/预设：显示 `currentLocalizationMode?.title`、`selectedAlgorithmPreset` 选择器 + detail。
- 控制台：进度条、状态、最近 8 行日志（等宽，自动滚到底）、`查看完整日志`（sheet 迁移 `BackendLogView`）、取消。
- 就绪清单：复用 `pipelineReadiness`；有 issue 时显示原因与去修复，主操作禁用。
右栏：参数（平滑模式/α、航向吸附、步长比例、联合校准、矢量地图禁用说明）、恢复基线。
运行成功：`model.stage` 自动到 04；失败：错误 banner + 日志。
主操作在 StageRail：开始/取消。

- [ ] **Step 2: 构建 + 端到端**

用内置 13_2 跑一次：观察进度、日志、自动进入 04；取消一次，确认状态回到可运行。截图运行中/失败（可用不覆盖的磁图制造失败）。

---

### Task 8: TrajectoryPlot 静态绘制

**Files:**
- Create: `GeomagMac/Views/TrajectoryPlot.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `PlotLayout`、`PlotViewport`、`TrajectoryAnalysis.stepSamples`。
- Produces:
```swift
struct PlotLayers: Equatable { var trueRoute=true, pdr=true, pf=true, confidence=true }
struct TrajectoryPlot: View {
    let result: PositioningResult
    let layers: PlotLayers
    let progress: Double
    let selectedStep: Int?
    @Binding var viewport: PlotViewport
    var onSelectStep: (Int?) -> Void
}
```

- [ ] **Step 1: 实现静态绘制**

Canvas 内：
- 用 `result.mapBounds`（4 个数按 minX/maxX/minY/maxY）或用 route+pdr+pf 的 union bounds；优先 mapBounds。
- 网格 0.25m（锚定整数倍）、边界、角标、轴刻度、比例尺 1m、尺寸标签。
- 置信圈：`stride = max(1, count/10)`，fill 0.03 / stroke 0.22（深色同），高/中/低分档。
- 真实路线虚线 1.3、PDR 蓝 1.9、PF 绿 2.5；恢复标记菱形；起终点。
- 进度裁剪：按 `stepIndex` 显示 PDR/PF 前 N 段、置信圈前 N 个；端点随进度。
- 背景 `theme.plotBackground`，网格 `plotGrid`，边界 `mapBoundary`。

- [ ] **Step 2: 构建 + 视觉核对**

在 04 阶段先临时放一个 `TrajectoryPlot(result:..., layers:..., progress: 1, selectedStep: nil, viewport: .constant(.init()))` 替换旧画布，截图对比样张：矩形路线、绿色 PF、蓝色 PDR、淡置信圈、比例尺。此时交互尚未接入。

---

### Task 9: 画布交互（缩放/平移/悬停/选中/播放）

**Files:**
- Modify: `GeomagMac/Views/TrajectoryPlot.swift`
- Create: `GeomagMac/Views/PlotEventMonitor.swift`（滚轮桥接）

**Interfaces:**
- Produces: 光标中心缩放、拖拽平移、双击复位、悬停读数、点击选中步、`Space/←/→` 由上层接入。

- [ ] **Step 1: 缩放/平移**

- 捏合：`MagnificationGesture` → `viewport.zoom(by:anchor:layout:canvasSize:)`。
- 滚轮：`NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)`，判断 `event.window == NSApp.keyWindow` 且光标在画布 frame 内；`deltaY` 转为 `exp(-deltaY * 0.01)`；只在本视图 `onAppear/onDisappear` 安装/移除。
- 拖拽：`DragGesture(minimumDistance: 2)` 更新 `viewport.pan`；双击或「适应」复位。
- 范围 0.65–8×；缩放锚点世界坐标不变（Task 2 测试覆盖）。

- [ ] **Step 2: 悬停/选中**

- `.onContinuousHover { phase in ... }`：`PlotLayout.world` 换算；找最近 `StepSample`（屏幕距离 < 24pt）；HUD 显示 `x/y · PF 第 N 步 · 可靠度`；十字线。
- `SpatialTapGesture`：点击选中最近步；空白点击清除；`onSelectStep` 回传。
- 选中步画一个 ring + 端点高亮；`Esc` 清除由上层处理。

- [ ] **Step 3: 构建 + 手工验证**

启动 App，用真实 13_2：缩放看细节、拖拽、双击复位、悬停读数、点击固定；截图选中态。

---

### Task 10: 04 分析阶段 + 运行栏 + 检查器 + 时间轴 + 指标

**Files:**
- Create: `GeomagMac/Views/AnalysisStageView.swift`
- Create: `GeomagMac/Views/RunsRailView.swift`
- Create: `GeomagMac/Views/InspectorView.swift`
- Modify: `GeomagMac/Views/AppShellView.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: TrajectoryPlot、PipelineReadiness、`recentRuns`、layers、`playbackProgress`、`selectedStepIndex`。
- Produces: 完整 04 工作台。

- [ ] **Step 1: 主区**

`HStack(spacing:0) { RunsRailView (236); VStack { AnalysisHeader; InsightStrip; TrajectoryPlot; PlaybackBar; MetricsGrid; AnalysisFoot }; InspectorView (300) }`。
- Header：eyebrow `04 · 分析`、标题、subtitle、状态 pill、`对比 PDR`（切换 `showPDR`）、专注按钮。
- Insight：从 result 计算 PF vs PDR 终点差、平均可靠度、恢复次数；无数据时隐藏。
- PlaybackBar：播放/暂停、时间轴（转角标记来自 `routeCorners`，恢复事件来自 recoveryEvents）、`0:00 / 0:20`、倍速按钮循环 1×/2×/4×、`显示全部`。
- Playback timer：30fps，基础全程 8 秒（1×），按 `steps-1` 推进；`Space` 播放/暂停，`←/→` 单步。
- MetricsGrid：6 个 `MetricTile`，值/对照/改善百分比；无 PF 时用 PDR 单值。
- Foot：分支、平滑、联合校准、粒子数（「2000 粒子」为固定文案，如实际参数不同则从 `algorithmSettings` 读取；没有该字段就只显示已知项）。
- 历史只读 banner：`resultSource == .history` 时在 header 下显示「历史结果 · 只读」。

- [ ] **Step 2: RunsRail**

- 全部 `recentRuns`（不限制 5 条），按日期分组（今天/更早），行显示名称、时间、PF 终点、步数；当前 `loadedFileName` 高亮。
- 底部 `打开结果…` + `打开结果目录` + 刷新。
- 点击加载后 `model.stage = .analysis`，只读 banner。

- [ ] **Step 3: Inspector**

- 图层：4 个 `ToggleRow`，线型/颜色 swatch，绑定 `showTrueRoute/showPDR/showPF/showPFConfidence`。
- 选中步：`selectedStepIndex` 非空时显示步号、PF/PDR 横向偏差、置信度、定位状态；空时提示「点击轨迹或按 ←/→ 选择步」。
- 诊断：航向来源/校准、平均/末端可靠度、核心半径、位置歧义、有效行走、步数。
- 磁图卡：名称、来源、网格数/模式。
- 导出：菜单按钮（Task 11 接真实导出）。

- [ ] **Step 4: 构建 + 截图**

用内置 13_2 截图：完整工作台、专注模式、选中步、历史只读、无结果空态；浅/深各一遍。

---

### Task 11: 逐步横向偏差条 + 选中步联动

**Files:**
- Create: `GeomagMac/Views/StepErrorStrip.swift`
- Modify: `GeomagMac/Views/AnalysisStageView.swift`
- Modify: `GeomagMac/Views/TrajectoryPlot.swift`
- Modify: `GeomagMac/Views/InspectorView.swift`

**Interfaces:**
- Consumes: `TrajectoryAnalysis.stepSamples`、`selectedStepIndex`、`playbackProgress`。
- Produces: 同步的逐步偏差曲线。

- [ ] **Step 1: 实现**

- 高度 56–64；Canvas 绘制零线、PF 横向（trace）、PDR 横向（muted 蓝）、转角/恢复标记、当前步竖线。
- y 轴自适应最大值并标注单位 m；x 为步序；顶部小字「横向偏差 · 按真实路线最近线段投影」。
- 悬停显示该步数值；点击/拖动 seek 并选中步；与画布/时间轴共享 `selectedStepIndex`。
- 无 PF/PDR 或步数 <2 时显示空态。

- [ ] **Step 2: 构建 + 验证**

截图逐步条；点击第 10 步，确认画布 ring、右栏选中步、播放进度三处同步；`←/→` 逐步移动。

---

### Task 12: 导出 PDF 报告 / 当前视图 PNG / CSV

**Files:**
- Modify: `GeomagMac/Models/ResultExporter.swift`
- Create: `GeomagMac/Models/ReportExporter.swift`（如拆分更清晰）
- Create: `GeomagMacTests/ExportTests.swift`
- Modify: `GeomagMac/Views/InspectorView.swift`、`GeomagMac/Views/AppShellView.swift`

**Interfaces:**
- Produces:
```swift
struct ExportLayers { let trueRoute: Bool; let pdr: Bool; let pf: Bool; let confidence: Bool }
enum ResultExporter {
    static func export(result:to:baseName:) throws -> ExportedResultFiles // 保留
    static func renderPNG(result:layers:scale:) throws -> Data
    static func renderPDF(result:layers:) throws -> Data
    static func csvData(result:) -> Data // 不变
}
```

- [ ] **Step 1: 写导出测试**

- `renderPDF` 返回数据以 `%PDF` 开头、非空；用 `CGPDFDocument` 打开页数 = 1。
- `renderPNG` 返回非空，用 `NSBitmapImageRep(data:)` 读回尺寸与预期一致（2×）。
- `csvData` 表头与行数与改动前一致（用固定 result 构造）。
- 算法回归：解码 `native_route_13_2.json`，断言 `pfErrorStats.final`、`stepsDetected`、`pfClosureErrorM` 与已知值一致（防止 UI 改动误碰数据）。

- [ ] **Step 2: 实现**

- 把现有 `draw` 重构为 `draw(result:style:layers:in:size:)`；`ExportStyle` 提供 darkInstrument 与 lightReport 两套颜色。
- PDF：A4 横向 842×595；纸底、标题/副标题、图、图例、6 指标、脚注（数据集/磁图/模式/时间/算法）；`CGDataConsumer` + `beginPDFPage` + `endPDFPage`。
- PNG：1600×1000（现状）或 2× 当前画布；按 layers 绘制。
- 导出菜单：04 阶段条主操作 `Menu`：当前视图 PNG / 报告 PDF / CSV / 复制结论；沿用目录面板与 `resultExportDirectory`；完成后 inline banner/toast，不再 alert。
- CSV 表头与列不变。

- [ ] **Step 3: 跑测试 + 打开 PDF**

```bash
xcodebuild ... test
```
导出一次报告 PDF，`open` 打开，检查标题、图、指标、脚注与页边距。

---

### Task 13: 品牌图标 + 紧凑布局 + 持久化 + 键盘/无障碍

**Files:**
- Create: `GeomagMac/Resources/Assets.xcassets/AppIcon.appiconset/*`
- Create: `Tools/generate-app-icon.swift`（或 shell）
- Modify: `GeomagMac/Views/AppShellView.swift`
- Modify: `GeomagMac/Views/AnalysisStageView.swift`
- Modify: `GeomagMac/Models/AppModel.swift`
- Modify: `GeomagMac/GeomagMacApp.swift`
- Modify: `GeomagMac.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: macOS 27 图标、1100×720 紧凑布局、状态记忆、快捷键、VoiceOver/Reduce Motion。

- [ ] **Step 1: 图标**

- 生成 1024 全出血方图：`#0E1218` 底 + 12×12 发丝网格 + 纸白航线折线 + signal 起点 + trace 终点；不烘焙圆角/阴影。
- `Assets.xcassets/AppIcon.appiconset` 提供 16/32/64/128/256/512/1024（含 @2x）；`Contents.json` 的 idiom 为 `mac`。
- 若 Xcode 27 的 Icon Composer 能直接产出 `.icon`，优先；否则用 appiconset。把 Assets 加入 Resources build phase；现有 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 已配置。
- 构建后确认 Dock/Finder 图标非默认。

- [ ] **Step 2: 紧凑布局**

- `GeometryReader` 在 shell 测宽度；`width < 1240` 时 `model.isCompact = true`：阶段条隐藏副标题、品牌宽 180、Action 区缩紧；`width < 1160` 时分析右栏默认收起（用户可手动展开为覆盖层）。
- 1100×720 截图检查：阶段条不换行、指标仍 6 列或降为 3×2（按宽度决定）、画布不塌。

- [ ] **Step 3: 持久化**

- UserDefaults keys：`geomag.stage`、`geomag.showTrueRoute/showPDR/showPF/showPFConfidence`、`geomag.inspectorVisible`、`geomag.playbackSpeed`。
- `go(to:)`/图层 `didSet` 写入；启动恢复；stage 不满足前置时回退到 `.analysis`（有结果）或 `.data`。
- 窗口 frame autosave：`WindowAccessor` NSViewRepresentable 在 `viewDidMoveToWindow` 调 `window.setFrameAutosaveName("GeomagMacMainWindow")`。

- [ ] **Step 4: 键盘/无障碍/Reduce Motion**

- `GeomagMacApp.commands`：`⌘1–4`、`⌘O`、`⌘R`、`⌘E`、`⌘⌥I`。
- 分析视图 `.onKeyPress(.space)` 播放/暂停、`.leftArrow/.rightArrow` 单步、`F` 专注、`Esc` 退出专注/清除选中。
- 画布/偏差条/指标/开关补 `.accessibilityLabel`/`.accessibilityValue`；Tab 可达；焦点环可见。
- `@Environment(\.accessibilityReduceMotion)`：阶段切换/检查器/专注模式位移关闭，仅保留透明度。
- Debug 钩子（仅 DEBUG）：
  - `GEOMAG_APPEARANCE=dark|light` 强制外观，用于截图。
  - `GEOMAG_STAGE=data|map|run|analysis` 启动直达阶段，用于截图。
  两者在 `GeomagMacApp`/`AppModel` 读取，Release 不生效。

- [ ] **Step 5: 构建 + 截图**

浅/深 × 四阶段 × 1440×900，加 1100×720 紧凑版；确认图标、快捷键、状态记忆。

---

### Task 14: 收口与验收

**Files:**
- Modify: `README.md`（操作流程/快捷键/导出）
- Delete: `GeomagMac/Views/MetricCard.swift`、`GeomagMac/Views/TrajectoryCanvas.swift`（确认无引用后）
- Modify: `GeomagMac.xcodeproj/project.pbxproj`（移除旧文件引用）

- [ ] **Step 1: 删除旧视图**

`grep -R "TrajectoryCanvas\|MetricCard" GeomagMac GeomagMacTests` 必须无引用；从 pbxproj 删除对应 PBXBuildFile/PBXFileReference/group/Sources；构建通过。

- [ ] **Step 2: 全量测试**

```bash
xcodebuild -project GeomagMac.xcodeproj -scheme GeomagMac -destination 'platform=macOS' -derivedDataPath /tmp/geomagmac-dd test
```
Expected: `TEST SUCCEEDED`；记录测试数量。

- [ ] **Step 3: 手工验收清单**

- 四阶段全部可达；每段唯一主操作；阻塞有原因和去修复。
- 内置 13_2/13_3/15_2/15_3 全部跑通；导入采集→建图→合并→定位；历史只读；打开结果 JSON。
- 画布：滚轮/捏合缩放、拖拽、双击复位、播放/倍速/seek、单步、悬停、点击固定、图层、专注。
- 导出：PNG（当前图层）、PDF（报告）、CSV（表头不变）、复制结论。
- 1100×720 紧凑；状态记忆；快捷键；深色；Reduce Motion；VoiceOver 标签。
- 核心指标与改动前一致（route_13_2：PF final 0.0148 m、29 步、PF closure 0.0148 m）。

- [ ] **Step 4: 逐屏截图**

保存到 `/tmp/geomagmac-redesign-shots/`：
- 01 空态/已导入、02 列表/热力图/建图、03 就绪/运行中/失败、04 结果/历史/无结果/专注/选中步。
- 浅/深各一遍；1440×900 与 1100×720。
用 Read 逐张核对，再向用户汇报。

- [ ] **Step 5: 汇报**

列出：改了什么、测试结果、截图路径、已知限制（滚轮桥接、PDF 字体、紧凑断点）。不自动提交。

---

## 计划自检

- 规格 §2 信息架构 → Task 5/10；§3 阶段契约 → Task 5/6/7/10；§4 预检 → Task 1/4；§5 画布 → Task 8/9/11；§6 视觉 → Task 3/13；§7 导出 → Task 12；§8 错误/空态 → Task 5–10；§9 键盘/无障碍 → Task 13；§10 代码落点 → 全部；§11 测试验收 → Task 14。
- 类型名：`PipelineReadiness`、`StageIssue`、`TrajectoryAnalysis`、`PlotLayout`、`PlotViewport`、`PlotLayers`、`ExportLayers` 在计划中保持一致。
- 不含 TBD/TODO；每个 UI 任务都有构建 + 截图门槛；纯逻辑任务有失败测试 → 实现 → 通过测试。
