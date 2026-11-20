# GeomagMac Native 桌面端重设计规格

**Date:** 2026-11-20  
**Status:** 设计方向已在对话中获批（A 纸面仪表 + 交互优化 1/2/3）  
**Scope:** `NativeApps/GeomagMacNative`（纯 Swift 版），不改算法、不改旧 Python/Bokeh 版、不改手机端  
**Platform:** 只跑 macOS 27+；部署目标 `MACOSX_DEPLOYMENT_TARGET = 27.0`；开发机 Xcode 27.2 / macOS 27.2 SDK / 系统 27.2.1。原版按 macOS 26 使用，本次不再保留 26 及以下兼容。

## 1. 背景与目标

当前桌面端是 `NavigationSplitView` 单侧栏结构：1110 行的 `ContentView` 把示例、导入、算法参数、磁图、结果、显示开关、播放和全部诊断信息塞进一条长滚动栏；视觉基本是默认 SwiftUI 控件。日常使用最痛的是「流程割裂、找不到下一步」：导入、命名、校验、建图、选图、运行、看结果分散在不同区块，阻塞原因只在按钮 help 里。

本次重设计的目标：

1. 用阶段式工作台把流程变成 `01 数据 → 02 磁图 → 03 运行 → 04 分析`，每段有完成状态、阻塞提示和唯一主操作。
2. 建立「纸面仪表」视觉身份：纸白工作区 + 石墨画布、发丝线分层、无渐变无投影、全部读数等宽，并支持浅/深色。
3. 把分析阶段从「看一张图」升级为可核对的工作台：播放/拖动、逐步读数、逐步横向偏差、图层、专注模式。
4. 不丢功能：现有导入、命名、路线校验、建图、合并、质量热力图、模式判定、参数、日志、历史、导出、播放全部保留，只换位置。
5. 增加报告级导出与日常摩擦优化：PDF 报告图、拖拽导入、紧凑布局、状态记忆。

非目标：多运行并排对比 / 参数 A/B（留到 2.8）、未知起点全局重定位、算法改动、旧 Python App、手机端。

## 2. 信息架构

### 2.1 窗口

- 默认 1440×900，最小 1100×720；窗口尺寸由 AppKit 自动保存（设置 frame autosave name）。
- 顶部固定阶段条；其下按阶段切换内容；底部 26px 状态条（就绪状态、当前数据→磁图、App 版本与引擎、进度）。状态条不展示采集包的判据版本——桌面端结果 JSON 没有这个字段，避免假数据。
- 浅/深色跟随系统；画布在浅色下仍是石墨仪表屏，深色下更黑。
- 系统窗口 chrome、菜单、弹窗跟随 macOS 27 原生样式；纸面内容区是自定义视觉，不套 Liquid Glass、不加玻璃/渐变/投影。二者靠发丝线和留白衔接。
- 左栏「运行记录」只在分析阶段出现；右栏检查器可收起（`⌘⌥I` 或标题栏按钮）。
- 紧凑模式（宽度 < 1240）：阶段条隐藏副标题、品牌块收窄；分析阶段右栏默认收起，可由按钮覆盖展开；运行栏保持 220px。

### 2.2 阶段条

`Stage` 枚举：`data / map / run / analysis`。每段显示：

- 序号、名称、状态副标题（如 `route_13_2 · 29 步`、`route_13 · 26 网格`、`PF + PDR · 已完成`、`终点 0.01 m`）。
- 状态：`blocked`（缺前置）、`ready`、`running`、`done`、`attention`（有警告但可继续）。
- 当前段用 signal 下划线 + 白底（深色为抬起面）。
- 每段有且只有一个主操作，固定在阶段条右侧的 action 区（段内只放次级操作，不重复主按钮）：
  - 01：`校验并继续`
  - 02：`下一步：运行`
  - 03：`开始计算` / 运行中变为 `取消`
  - 04：`导出`（菜单：当前视图 PNG / 报告 PDF / CSV / 复制结论）
- 点击非当前段即切换；若目标段前置未满足，切过去并在段内展开阻塞项与「去修复」动作，不弹模态。

### 2.3 全局入口

- `⌘1/2/3/4` 切阶段；`⌘O` 打开结果 JSON；`⌘R` 开始计算；`⌘E` 导出菜单；`F` 专注画布；`Esc` 退出专注/清除选中步；`Space` 播放/暂停；`←/→` 上一步/下一步。
- 拖拽采集文件夹到窗口任意位置 = 导入并进入 01；拖拽结果 JSON = 打开结果并进入 04。
- 历史结果从左侧运行栏打开，标记「只读」；只改 `result`，不覆盖当前管线输入。
- 启动时：若已有可显示的结果（当前 `init` 会加载内置 13_2），进入 04 并显示阶段条全部完成；否则进入 01。记住上次阶段（若该阶段前置仍满足）。

## 3. 阶段契约

### 3.1 01 数据

主区：

- 三个入口：内置示例选择器、`选择采集文件夹…`、`打开结果 JSON…`；支持拖拽。两条内置路径要分清：选「内置示例」是打开预计算好的结果（进入 04 查看）；要在内置留出数据上重跑，则在 01 切到「内置留出数据」运行源，02 会自动选同组磁图，03 直接计算。
- 数据集卡：目录名、数据流行数与采样率、有效行走区间、估计帧数、质量等级、锚点数量与坐标系、警告列表；数据质量折叠区保留现有明细。
- 路线区：保留 `customRouteText` 为唯一真源；下方新增解析后的点列表（序号、x/y、行级错误），实时显示点序/重复点/近 180° 折返/越界校验；右侧或下方迷你路线预览（用当前路线 + 所选磁图边界）。不做地图点选加点（留后续）。
- 名称与初始航向：保留现有字段；房间自由定位模式必须显式填写航向，缺失时在 03 前显示阻塞。
- 主操作：`校验并继续`（数据未就绪时禁用并显示原因）；通过后进入 02。

右栏（检查器）：数据集详情与警告、真实路线输入说明、重新校验。

阻塞：没有数据集 / 名称为空 / 路线不足两点 / 点序错误 / 航向非法。每条阻塞带「去修复」，聚焦对应字段。

### 3.2 02 磁图

主区：

- 磁图列表（内置/用户/路线/网格），每行显示名称、来源采集、网格数、模式、质量等级。
- 选中磁图详情：覆盖热力图（复用现有 `MagneticMapHeatmap` 逻辑）、覆盖率、缺失格、每格样本中位数、消息；路线磁图显示「不生成房间热力图」的空态说明。
- `用当前采集建立磁图`：名称、网格尺寸只读 0.25m、合并提示、建图进度与结果；内置磁图不可覆盖；建图采集不能自我验证。
- 预检清单：`磁图已选择` / `覆盖当前路线` / `参考采集不是当前采集` / `坐标系一致` / `房间模式已有初始航向`。每项绿/红并带原因。
- 主操作：`下一步：运行`。

右栏：磁图元信息、参考采集、操作（打开磁图目录、移除用户磁图、重新读取）。

### 3.3 03 运行

主区：

- 连接卡：左侧数据卡（数据集名、29 步/区间）、中间箭头、右侧磁图卡（名称、模式、覆盖）。
- 模式与预设：显示由磁图决定的定位模式（已知路线验证 / 房间自由定位已知起点）；预设选择器 + 说明。
- 运行控制台：进度条、状态、实时日志（折叠/完整日志 sheet）、取消；失败时就地显示错误与「去修复」。
- 主操作：`开始计算`；完成后若用户仍在 03，自动进入 04；若已离开，阶段条显示完成与「查看分析」。

右栏：高级参数（平滑模式/α、航向吸附、步长比例、联合校准、实验性矢量地图禁用说明）、恢复基线。

### 3.4 04 分析

主区：

- 标题行：`04 · 分析`、结果名、数据集/磁图/模式/步数/时长/帧数、状态 pill（终点可靠度、恢复次数）、`对比 PDR`（仅切换显示，不做多运行对比）。
- 结论条：一句数据驱动的摘要（PF 把终点误差从 X 降到 Y；平均可靠度；恢复事件数）+ `查看诊断`。
- 画布：见 §5。
- 逐步横向偏差条：位于画布与时间轴之间，高度 56–64px；PF/PDR 两条逐步横向偏差曲线（按真实路线最近线段投影现算），转角和恢复事件打点，当前步游标；点击/拖动可 seek，悬停显示该步数值。
- 时间轴：播放/暂停、0–N 步或 0–activeWalk 时长、倍速 1×/2×/4×、转角/恢复标记、拖动 seek。
- 指标：6 张卡（终点/横向/沿程/转角/路程比例/闭合），PF 大字 + PDR 对照 + 改善百分比；路程比例显示目标 100%。
- 底部算法行：分支、平滑、联合校准、粒子数、会话时间。

左栏：最近运行列表（名称、时间、PF 终点误差、步数），全部运行按钮，打开结果目录；当前结果高亮；历史只读时显示 banner。

右栏：图层（真实路线/PDR/PF/置信范围）、选中步详情（步号、PF/PDR 横向偏差、置信度、定位状态）、诊断（航向来源、校准、平均/末端可靠度、核心半径、位置歧义、有效行走、步数）、当前磁图卡、导出（当前视图 PNG、报告 PDF、CSV、复制结论）。

## 4. 预检与状态模型

新增纯逻辑 `PipelineState.swift`：

```swift
enum Stage: Int, CaseIterable { case data, map, run, analysis }

enum StageIssue: Equatable {
    case noDataset, emptyDatasetName, invalidRoute, routeGeometry, invalidHeading
    case noMap, mapBuiltFromCurrentDataset, mapFrameMismatch
    case routeOutsideMap, roomModeNeedsHeading
}

struct PipelineReadiness: Equatable {
    var dataReady: Bool
    var mapReady: Bool
    var routeReady: Bool
    var headingReady: Bool
    var issues: [StageIssue]
    var canRun: Bool
    var nextStage: Stage
}
```

- 由 `AppModel` 现有计算属性（`importedDatasetReady`、`routeMapValidation`、`coordinateFrameMatchesSelectedMap`、`selectedMapUsesCurrentDataset`、`roomModeHasExplicitInitialHeading`、`mapForCurrentSelection`）组装，不复制业务判断。
- 每个 issue 映射到 `stage` 与修复提示；阶段条显示红色（阻断）或琥珀色（警告）。
- `AppModel` 增加 `@Published var stage: Stage`、`advanceStage()`、`go(to:)`；阶段切换 200ms 动画；保存到 UserDefaults。
- 运行完成时依据当前阶段决定是否自动进入分析；失败不跳转。
- 历史加载设置 `resultSource = .history`；新建运行/导入设置 `.live`；只影响 banner 与「只读」提示。

## 5. 画布与交互

新 `TrajectoryPlot.swift` 替换 `TrajectoryCanvas`：

- 纯投影：`PlotLayout`（bounds、scale、offset、`screen(world)`、`world(screen)`）；0.25m 网格锚定到整数倍；坐标轴刻度、比例尺、尺寸标签、角标。
- 绘制顺序：网格 → 磁图边界/角标 → 置信圈（每 3 个采样一个，高/中/低分档低透明度）→ 真实路线（虚线）→ PDR（蓝实线）→ PF（绿实线，深色下轻发光）→ 恢复标记 → 端点/起终点。
- 缩放/平移：捏合与滚轮以光标为中心缩放（滚轮用 AppKit 事件桥接），拖拽平移，双击/适应按钮复位；缩放范围 0.65–8×。
- 播放：按步进推进；端点随进度移动，置信圈按进度出现；`Space` 播放/暂停；`←/→` 单步；时间轴可拖动；倍速。
- 悬停：`.onContinuousHover` 十字线 + 固定读数 HUD（x/y、最近 PF 步、可靠度）；点击选中并固定该步；`Esc` 清除。
- 逐步横向偏差：`TrajectoryAnalysis.stepSamples` 输出每步 PF/PDR 到真实路线最近线段的横向距离；画布、偏差条、选中步卡片共用同一数据源。界面标注「按真实路线最近线段投影」口径。
- 图层开关实时生效；专注模式隐藏左右栏，保留阶段条/画布/偏差条/时间轴/指标。
- 空态：无结果时显示「打开结果 JSON / 载入内置示例」。
- 性能：Canvas 单次绘制；置信圈抽稀；播放 30fps；`route_15`（66 步）和长导入采集不卡顿。

## 6. 视觉系统（纸面仪表）

`Theme.swift` 定义 `Theme` 值类型（浅/深两套），视图只取 token，不写裸色值：

| Token | Light | Dark |
|---|---|---|
| canvas（页面底） | `#F5F3EE` | `#0B0E13` |
| surface | `#FFFFFF` | `#12161D` |
| surfaceSecondary | `#ECEAE3` | `#1A2029` |
| raised | `#FFFFFF` | `#263041` |
| hairline | `#D8D4C9` | `#2A323E` |
| grid | `#E3E0D7` | `#1F2733` |
| ink | `#14181D` | `#E8ECF2` |
| muted | `#5A6270` | `#9AA5B4` |
| faint（仅装饰） | `#7A8290` | `#6B7686` |
| signal | `#0A59F7` | `#4D9BFF` |
| trace | `#0A7355` | `#5CF2C7` |
| warn | `#B45309` | `#FFB454` |
| danger | `#C2410C` | `#FF6B57` |
| 画布底 | `#0E1218` | `#070A0F` |
| 真实路线 | `#F2F0E8` | `#AEB8C6` |
| PDR | `#4D9BFF` | `#4D9BFF` |
| PF | `#5CF2C7` | `#5CF2C7` |
| 置信高/中/低 | trace/warn/danger | trace/warn/danger |

- 圆角：面板 12、卡片 10、控件 8、微标 6；发丝线 1px；无投影、无渐变、无毛玻璃（系统窗口 chrome 除外）。
- 字体：UI 用系统字体（PingFang/SF）；标题 20 semibold；读数全部 `.monospacedDigit()` 或等宽设计；微标 9–10px，字距 1.2–1.6。
- 数字不跟随系统字号缩放（本 App 不做动态字号）；对比度：faint 只做装饰，必要信息用 muted/ink。
- 品牌：新 app 图标（石墨底 + 纸白航线 + signal 起点 + 发丝网格）+ 标题栏/空态品牌 mark。按 macOS 27 图标系统输出：1024 全出血方图、不烘焙圆角/阴影，由系统做遮罩；若本机 Xcode 27 的 Icon Composer 可直接生成分层 `.icon`，优先用它，否则回退到 `Assets.xcassets/AppIcon.appiconset` 全套尺寸。
- 动效：阶段切换 200ms 淡入 + 8px 位移；检查器 180ms 展开；专注模式 180ms；播放跟手；尊重 Reduce Motion（改为无位移直接切换）。不做无意义补间。

## 7. 导出

`ResultExporter` 扩展：

- 保留 `export(result:to:baseName:)` 的 PNG+CSV 行为与 CSV 表头不变。
- 新增 `renderPDF(result:layers:style:)`：报告风格（浅色纸面、A4 横向 842×595 pt），标题/副标题/图例/比例尺/6 指标/脚注（数据集、磁图、模式、时间、算法参数）；矢量 PDF，可打印。
- 新增 `renderPNG(result:layers:style:scale:)` 支持当前图层与 2× 输出；现有 PNG 入口改为读取当前图层。
- 导出菜单：`当前视图 PNG`、`报告 PDF`、`CSV 轨迹`、`复制结论与指标`。选择目录沿用现有 NSOpenPanel 与 `resultExportDirectory`。
- 报告导出不改变结果 JSON，不重算指标。

## 8. 错误、空态与加载

- 非阻断错误用阶段内联 banner（severity、消息、`去修复` / `关闭`），不用模态 alert；仅破坏性操作（移除磁图）保留确认。
- 空态：01 三入口；02 无磁图 → 建图 CTA；03 无结果/前置缺失 → 清单；04 无结果 → 打开结果。
- 加载：导入/建图/运行显示进度与状态；运行日志保留 40k 字符上限。
- 历史只读 banner；运行中切换阶段不打断，阶段条显示进度。
- 所有禁用按钮必须带原因（tooltip 或 inline 文案），不出现「灰着但不知道为什么」。

## 9. 键盘与无障碍

- 全局：`⌘1–4`、`⌘O`、`⌘R`、`⌘E`、`⌘⌥I`、`F`、`Esc`、`Space`、`←/→`。
- 所有交互控件可 Tab 到达，焦点环可见；画布有 `accessibilityLabel`/`accessibilityValue`（当前步、坐标、误差）。
- 图层开关/指标卡有 VoiceOver 标签；颜色不是唯一信息源（同时有文字/线型/数值）。
- Reduce Motion 下关闭阶段位移、检查器位移和专注模式缩放，仅保留透明度。

## 10. 代码落点

新增：

- `Models/PipelineState.swift` — Stage、StageIssue、PipelineReadiness、TrajectoryAnalysis/StepSample、RouteProjection。
- `Models/ReportExporter.swift` 或并入 `ResultExporter.swift` — PDF/PNG 报告绘制。
- `Views/Theme.swift` — 浅/深 token、字体、尺寸、品牌 mark。
- `Views/Components.swift` — PlateButton、SegRail、MetricTile、StatusPill、ToggleRow、StageBadge、NoticeBanner。
- `Views/AppShellView.swift` — 窗口骨架、阶段条、全局命令、拖拽、错误 banner、紧凑布局、窗口 autosave。
- `Views/DataStageView.swift`、`MapStageView.swift`、`RunStageView.swift`、`AnalysisStageView.swift`。
- `Views/TrajectoryPlot.swift` — 替换 `TrajectoryCanvas`（旧文件删除）。
- `Views/InspectorView.swift`、`Views/RunsRailView.swift`。
- `MagneticMapQualitySheet` / `MagneticMapHeatmap` 从 `ContentView` 迁到 02 主区与检查器；`BackendLogView` 迁到 03 日志 sheet；导出完成提示改为内联 banner/toast，不再用 alert。
- `Assets.xcassets/AppIcon.appiconset` + 图标生成脚本（`Tools/generate-app-icon.swift` 或 shell）。
- `GeomagMacTests/PipelineStateTests.swift`。

修改：

- `ContentView.swift` → 薄壳，持有 `@StateObject AppModel` 和 `AppShellView`。
- `AppModel.swift` → 增加 `stage`、`resultSource`、`advanceStage()`、公开 `importDataset(at:)`（拖拽）、自动进入 04、选中步/图层持久化；保留全部现有方法与算法调用。
- `GeomagMacApp.swift` → 默认窗口尺寸、命令菜单、窗口 autosave。
- `GeomagMac.xcodeproj/project.pbxproj` → 新文件加入 app/test target、Assets 加入 Resources；使用唯一 24 位 ID，逐步构建验证。
- `README.md` → 更新操作流程与快捷键（可选但建议）。

删除：`Views/MetricCard.swift` 与 `Views/TrajectoryCanvas.swift` 由新组件/画布取代（先迁移再删，确保无引用）。

## 11. 测试与验收

单元测试（宿主 `xcodebuild test`）：

- `PipelineReadiness`：内置数据/导入数据、缺名称/缺路线/点序错误/越界/坐标系不符/建图自证/缺航向/无磁图；`nextStage` 与 issue 映射。
- `RouteProjection`：水平/垂直/斜线、端点外、零长度段、闭合路线；逐步样本与 confidence/health 对齐（PF 首点为锚点）。
- `TrajectoryAnalysis`：PF/PDR 横向序列、转角标记、选中步边界。
- 导出：PDF 非空且页数 1、PNG 尺寸/非空、CSV 表头与行数不变。
- 算法回归：对 `route_13_2` 运行结果的核心指标与改动前一致（仅 UI 重构，不应改变输出）。

手动/截图验收：

- 1440×900 与 1100×720，浅/深各一遍：01 空态/已导入、02 磁图列表/质量热力图/建图、03 就绪/运行中/失败、04 结果/历史只读/无结果/专注模式/选中步。
- 真实数据：内置 13_2/13_3/15_2/15_3 全部跑通；导入采集文件夹；建图；合并；移除；打开历史；导出 PNG/CSV/PDF。
- 画布：捏合/滚轮缩放、拖拽、双击复位、播放/单步/倍速/seek、图层、悬停读数、点击固定。
- 拖拽导入、窗口尺寸记忆、阶段记忆、`⌘1–4`/`F`/`Esc`/`Space`/`←→`。
- 构建零新增 warning；测试全绿。

## 12. 风险与缓解

- **大文件重构**：先落 Theme/Components/PipelineState 纯逻辑与测试，再逐阶段替换；每阶段编译 + 截图，避免一次性删旧视图。
- **pbxproj 手改**：新增文件逐个构建；ID 唯一；不碰用户未提交的 `NativeApps/GeomagCaptureHarmony/*`、`StoreSubmission/`、`.superpowers/`。
- **macOS 27 目标**：工程 app/test target 都抬到 `MACOSX_DEPLOYMENT_TARGET = 27.0`；可以使用 27 SDK 的新 SwiftUI API，但只用本机能编译验证的；不保留 macOS 26 兼容分支。系统 chrome 跟随 27，自定义纸面内容不套 Liquid Glass。
- **滚轮缩放**：SwiftUI 无原生滚轮，使用 `NSViewRepresentable` 事件桥；若事件冲突，退化为捏合 + 按钮缩放，并在 UI 说明。
- **PDF 导出**：复用现有 CoreGraphics 绘制；先出报告版式再调字体/边距；测试打开与打印。
- **性能**：Canvas 抽稀置信圈；播放 30fps；用 66 步与长采集压测。
- **算法不变**：不改 `NativePositioningEngine`/`AppModel` 运行请求；用同数据前后对比核心指标。

## 13. 明确不做

- 多运行叠加 / 参数 A/B 对比（2.8 单独立项）。
- 未知起点全房间全局重定位。
- 地图点选加点、拖拽编辑路线（本期只做解析点列表 + 校验 + 预览）。
- 旧 Python/Bokeh App、手机端、算法/判据改动。
- 应用内改语言（保持中文）。
