# Lego-like Geomagnetic Positioning

![Python](https://img.shields.io/badge/Python-3.8%2B-blue)
![License](https://img.shields.io/badge/License-MIT-green)

> **注意**：不要跑 `route1_run1`，传感器数据与注册路线对不上（实际忘了当时测的是哪个路线了）。默认正式评测使用 `route1_run2`、`route2_run2`；`route2_run1` 保留为可单独运行的重复采集。

# 运行方式：
## Mac端：
```bash
bash run.sh
```

## Windows 端：

直接运行 `run.bat`

## 原生 macOS App：GeomagMac

仓库的 [`GeomagMac/`](GeomagMac/) 目录包含一个使用 SwiftUI 和 Xcode 开发的原生 macOS 路径查看与算法实验 App。它可以：

- 显示白色真实路线、青色 PDR 路线和黄色 PF 地磁匹配路线
- 播放、缩放和拖动定位轨迹，并查看 PF/PDR 误差指标
- 直接读取结果 JSON，或运行 App 内置的算法后端
- 导入手机加速度计、陀螺仪和磁力计 CSV，并在运行前检查数据质量
- 在“当前优化基线”“90° 受控路线”“原始 PF”预设之间切换
- 调整平滑、航向网格约束、步长比例和 PF 联合校准参数
- 显示 PF 可靠度和异常恢复事件，保存运行参数、进度与完整日志
- 选择目标文件夹导出 1600×1000 PNG 轨迹图和 CSV 坐标数据

实时参数后端使用 `xuml-v7-optimization` 分支的修改版算法。建议先切换到该分支，再构建 App：

```bash
git switch xuml-v7-optimization
cd GeomagMac
../.venv/bin/python -m pip install -r Backend/requirements-build.txt
./Scripts/build_backend.sh
open GeomagMac.xcodeproj
```

在 Xcode 中选择 `GeomagMac` scheme 和 `My Mac` 后运行。构建脚本会将 Python、算法依赖、地图和自采数据打包到 App 内；运行构建后的 App 不需要另外安装 Python。生成的 `BackendDist/` 和 Xcode 缓存体积较大，不提交到 Git，只上传可复现的源码、构建脚本和三组示例结果。更完整的说明见 [`GeomagMac/README.md`](GeomagMac/README.md)。

2026-08-01 的原生界面回归测试已覆盖软件启动、示例切换、轨迹显隐、播放/
暂停、内置后端计算、日志、历史结果、异常恢复标记以及 PNG/CSV 导出。
从 App 内运行 `route2_run2` 得到 PF 平均误差 `0.893 m`、终点误差
`1.136 m`，与命令行基线一致；Python 测试为 153 项全部通过，两份 Xcode
工程均构建成功。

## 纯 Swift 原生应用（当前开发主线）

仓库现在保存三套互通的纯原生工程：

- [`NativeApps/GeomagCapture`](NativeApps/GeomagCapture)：iPhone 建图与定位数据采集端。建图模式按实际可扫描区域的长、宽和线距生成双向蛇形任务；支持路线预览、正反向起点更新、错误点序校验、姿态门控及同时间戳的锚点/转弯记录。
- [`NativeApps/GeomagCaptureHarmony`](NativeApps/GeomagCaptureHarmony)：HarmonyOS 采集端，导出相同采集包格式；房间和自由采集均可使用真实路线，支持基础蛇形、双向交叉、横穿长边补扫及保持原坐标系的正反向采集。
- [`NativeApps/GeomagMacNative`](NativeApps/GeomagMacNative)：macOS 建图与粒子滤波定位端。第一次独立采集用于建立统一房间坐标系下的二维磁图，第二次及后续独立采集用于已知起点、任意路线的定位验证；同一地图的多次建图采集按网格中位数合并，并提供覆盖热力图、网格样本/方向/方差分级与合并一致性检查。

2026-08-10 收尾更新统一了三端的路线方向、空间锚点和元数据：iPhone/HarmonyOS 均可反向采集；macOS 可从自由采集锚点恢复路线与初始航向、修复孤立姿态 yaw 跳变，并使用 0.25 m 网格、自适应任意角度航向、建图停顿步长补偿和网格多候选 PF。固定 90° 吸附不再作为默认算法。

2026-08-11 更新进一步修复了真实路线坐标和转弯事件：两端采集 App 会拦截重复点与近 `180°` 原路折返，按实际拐角把锚点和转弯写入同一时间戳，并在手机倾斜超过 `15°` 时阻止标记。macOS 会明确区分输入白线与定位结果，校验点序和地图范围；房间自由定位加入任意角度转弯区域识别和连续位移约束，不依赖固定 `90°` 航向吸附。

本轮正方形房间实测使用 8 组独立建图采集，合并得到 56 个有效网格、约 `88%` 覆盖率，质量评级为“优秀”。在该磁图上的独立自由路线 `localization_test_6` 中，PF 横向/沿程/终点误差分别为 `0.13/0.19/0.16 m`，路线长度比例 `103%`，转角误差 `42.9°`。这些结果用于记录当前已知起点、小房间数据集的阶段性基线，不能外推为未知起点或其他房间的通用精度。

建议先将房间左下角定义为 `(0, 0)`，单位使用米，以 `0.4～0.6 m` 的间距分别完成横向和纵向扫描。每条扫描线的端点、转弯点记录为已知坐标锚点，同一区域独立采集 2～3 次；建图数据与定位测试数据必须分开。桌子、沙发等固定障碍物无需搬开：在障碍物前后记录锚点，暂停绕行并沿边缘补扫，障碍物内部在热力图中保持未覆盖，PF 不会进入这些空白网格。

障碍物边缘补扫应使用新的数据集名称和相同楼层坐标系，沿家具外侧约 `0.3～0.5 m` 的可行走边界记录一圈坐标锚点，正反方向各采集一次后再合并进房间磁图；补扫路线不能穿过或填满家具内部。

macOS 端会利用锚点和 PDR 将磁场样本放入二维网格，保存 `Bx/By/Bz`、模长、方差、采集次数、方向数和空间梯度。定位时，PF 使用步长和航向传播粒子，并结合三轴磁场、模长与磁场变化趋势更新权重，同时估计步长比例、航向偏差和手机磁场偏置。黄色轨迹为 PF 加权位置，绿色范围表示粒子分布的置信范围。

运行阶段现在强制区分两种模式：Route 13/14/15 的窄带磁图属于“已知路线验证”，用于保留现有回归基线；二维锚点磁图属于“房间自由定位（已知起点）”，会关闭参考拐点、沿程进度、闭环终点和建图方向约束，并要求显式初始航向。真实路线只在 PF 完成后计算误差，不参与房间定位。转弯侧向跳变使用仅依赖当前航向与连续位移的通用约束处理，不再为新数据吸附参考拐点。

当前优先支持“已知起点、房间有效磁图范围内任意路线”。全房间未知起点重定位将在这一模式稳定后增加。三套原生工程的构建、数据格式和操作细节分别见各自目录中的 README；旧的 [`GeomagMac`](GeomagMac) 仍是 Python 算法打包版，和这里的纯 Swift 工程用途不同。

2026-08-09 的原生定位更新改用 Core Motion 用户加速度、动态步频和强转弯位移抑制；Route 13/15 磁图按航向分段注册，避免把转弯磁场写入错误坐标。PF 使用最长 10 步的多尺度三轴/梯度序列、连续路径覆盖掩膜、闭环终点磁序列确认、慢偏置和 `0.45～1.25` 步长状态。转弯恢复被限制到相邻路线段的公共拐点，并采用不跨越上一拐点的 3～5 步固定延迟回溯；转弯期间暂停 EMA，直线阶段恢复。PF 还会保留最多四个沿程位置簇，并把地图磁序列重复度和多峰质量计入置信度。Route 15 两次留出的沿程均值由 `2.92/1.80 m` 降至 `1.43/1.03 m`；四组留出的平均全程置信分数为 `0.66～0.70`、平均位置歧义为 `32%～38%`，不再用闭环终点的高置信代表整段路线。

用户磁图 `route_14_2` 对独立采集 `route_14_3` 的额外验证得到 PF 横向/沿程误差 `0.031/0.745 m`、转角误差 `12.1°`、闭合误差 `0.012 m`；全程置信分数为 `0.629`，位置歧义为 `43%`。

## iPhone 真机采集审计

`Geomag.iphone_capture_audit` 可批量检查 iPhone 导出的
`.geomagcapture` 采集包，包括采样连续性、起止静止段、手机平放程度、
Core Motion 磁场校准、四元数和同路线多次采集的重复性：

```bash
python -m Geomag.iphone_capture_audit "/path/to/Geomag Capture"
```

默认输出 `results/iphone_capture_audit/summary.json`、`report.md` 和
`repeat_signals.png`。对早期 iPhone 采集包，`Magnetometer.csv` 是带大幅硬铁偏置的
原始硬件数据；定位时必须使用 `DeviceMotion.csv` 的 `Magnetic Field X/Y/Z`
校准磁场列。新版 iPhone 采集包已将校准场写入 `Magnetometer.csv`，并将未校准
硬件流单独保存为 `MagnetometerRaw.csv`。

闭合路线的运动与地磁重复性验证可运行：

```bash
python -m Geomag.iphone_algorithm_validation \
  --source-root "/path/to/Geomag Capture"
```

该验证会保留原始采集包，生成派生输入，并输出
`results/iphone_algorithm_validation/report.md`、`summary.json` 和
`pdr_tracks.png`。新版包可使用 `--own-heading-method core_motion` 直接读取
`DeviceMotion.csv` 的相对航向；计步峰值显著度和最小间隔可分别用
`--own-step-peak-prominence`、`--own-step-min-interval-s` 调整。

## 老算法受控路线优化（当前主线）

算法阶段现已封版为 `iphone-controlled-pdr-2026-08-08`，后续优先转入原生
macOS/iOS 应用开发，不再继续针对这三条路线调参。验证目录会额外生成精简的
`algorithm_release.json`，供应用读取推荐配置、shadow 状态、适用范围和固定参数；
完整接入边界见 [算法封版与原生应用交接](docs/algorithm-native-handoff.md)。

当前重新以 `Geomag.iphone_algorithm_validation` 生成的 route-calibrated PDR
为优化基线，没有改用会把结果限制在已知矩形边上的 recent-capture 地磁进度图。
运行命令：

```bash
python -m Geomag.iphone_algorithm_validation \
  --source-root "/path/to/Geomag Capture" \
  --output-root results/iphone_algorithm_validation_optimized
```

本轮修复了原图中短边被严重拉长的主要原因：Core Motion 检测到转向时，旧算法
仍把转向过程中的步峰当成平移。优化版从连续 yaw 角速度检测每次转弯的实际起止
时刻，将该区间设为零平移，并分别对
四个直行段标定步长；受控精度试验模式的距离先验最低为 10%，再根据有效步数比例、
单步波动和传感器段长冲突逐段增强；航向先验同样最低为 10%，再根据方向圆方差、
与受控方向的偏差和转角完整度逐段增强，不会把查询轨迹直接投影到白色参考线。如果样本级分割导致任一
直行段没有完整步峰，则自动回退步级转弯分割；当前只有 `route_15_2` 触发回退。

下一阶段已经把独立标定采集的地磁模长序列接入老算法，但权限被严格限制在“段内
进度修正”：每条路线分别用 `route_13_1、route_14_2、route_15_1` 建立四段模板，
留出采集采用端点约束的单调 DTW。匹配最多融合 30%，不能改变段长、航向、转角或
端点，也不会把坐标投影到白色参考线。少于 5 个有效步峰、磁变化小于 1 µT、相关
系数低于 0.75 或匹配代价过高时自动拒绝，继续使用原 PDR 进度。

在通过进度门控的长边上，算法还会用 Core Motion 四元数对齐校准磁场三轴，估计
查询采集相对独立磁模板的 yaw 偏置。磁旋转方向必须与 PDR 的受控路线残差一致，
水平磁场和旋转拟合也必须通过检查；随后所有合格长边只共同产生一个“整次采集统一
航向修正”，最大融合 35%。同一个角度应用于整条轨迹，所以不会逐边扭曲矩形，且
闭合误差在数学上保持不变。该门控在 20 个留出直线段中接受 5 段：route_15_2/3
的两条长边以及 route_13_2 的第一边，其余矛盾或短边证据均未使用。

同时实现了不读取路线方向的双模板 shadow 消融：route_13/15 每次把另外两次采集
作为模板，route_14_3 使用 `route_14_1/2`；两个模板的 yaw 必须在 4° 内一致。
`route_14_1` 只作磁模板，不作查询精度样本，因为它虽然有 4 次样本级转弯，但步级
航向只识别出 3 次且四段步数为 `19/2/14/6`。无方向版本在五次严格留出上的平均
横向误差为 `0.142 m`，差于受控优化的 `0.135 m`：尤其 route_14 的两个模板
稳定同意约 `+6.5°`，应用后却使横向误差由 `0.043 m` 增至 `0.119 m`。因此该
版本被自动标记为 `rejected_shadow_regression`，不会替换当前算法。这证明两个模板
“彼此一致”仍不能代替它们与地图绝对方向的注册。

随后加入不读取路线形状的起始参考系注册：从每个原始采集开头 2.5 s 提取静止姿态
下的四元数对齐磁向量，先减去“查询相对模板”的起始 yaw，再比较行走期间新增的
相对漂移。九次采集的起始窗口都通过了旋转率、用户加速度和磁校准质量门控。注册后
无方向 shadow 的严格留出平均横向误差由 `0.142 m` 降至 `0.132 m`，优于不使用
该磁修正的受控优化 `0.135 m`；route_14_3 从错误的 `0.119 m` 恢复到
`0.038 m`。该版本标记为 `promising_shadow_requires_more_routes`，仍不替换当前主线：
它只证明“同一起点、同一初始手机朝向”条件下有效，还需要不同路线和不同起始朝向
验证。

严格只统计 `route_13_2/3、route_14_3、route_15_2/3` 五次留出采集：平均横向
误差由 `0.486 m` 降至 `0.135 m`，平均闭合误差由 `1.535 m` 降至 `0.161 m`。
如果关闭两项受控软先验、只删除转弯平移，两项指标分别为 `0.380 m` 和
`1.087 m`（固定步级分割基线）；采用当前样本级优先分割时为 `0.457 m` 和
`0.909 m`。因此不能把全部提升都误称为任意路线传感器算法能力。

输出中 `pdr_tracks.png` 保留原始基线，`pdr_tracks_turn_filtered.png` 是仅去除转弯
平移的诊断结果，`pdr_tracks_optimized.png` 是受控路线优化结果；`summary.json` 和
`report.md` 同时保存逐次、逐段指标及所用先验。新增的
`pdr_tracks_magnetic_fused.png` 和 `magnetic_progress_diagnostics.png` 分别显示
磁进度融合轨迹及逐段置信度/实际增益；
`pdr_tracks_magnetic_heading_fused.png` 和 `magnetic_heading_diagnostics.png`
显示统一磁航向校正结果；`pdr_tracks_direction_free_shadow.png` 保留被拒绝的
无方向双模板结果，`pdr_tracks_registered_direction_free_shadow.png` 显示起始注册后的
改进，便于复现实验结论。严格留出的 20 个直线段中有 9 段通过进度门控，
均集中在磁特征和步峰数量足够的长边；平均横向误差由融合前 `0.135 m` 小幅变为
`0.134 m`。进一步的磁航向门控将其降至 `0.123 m`，其中 route_15_3 从
`0.278 m` 降至 `0.229 m`；闭合误差始终保持 `0.161 m`。这说明磁证据没有破坏
轨迹形状，但也证明当前
`route_14/15` 的 0.6 m 短边无法仅靠现有序列可靠定位。新采集尚未与旧二维磁图
完成统一坐标注册，所以这里仍不伪造 PF 地磁定位精度。

## Geomag V2：最近数据重写版（实验参考）

`geomag_v2/` 是面向最近重新采集的 `route_13、route_14、route_15` 从零重写的
算法核心。它不调用旧 `Geomag` 流水线，不读取历史 own-data 注册表、旧磁图、
粒子滤波状态或旧结果。由于自由路径和短边泛化仍存在明显问题，V2 当前只作为诊断
和经验来源；项目主线已经回到旧 `Geomag` 流水线继续优化。

V2 将运动拆成四个直行段和四个转弯状态：转弯期间零平移，距离按整段传感器特征
估计，不再把零散峰逐个乘固定步长。由于本轮精度试验明确沿砖缝走矩形并作 90°
转向，V2 对相对边相等和独立标定边长使用置信度软先验；短边只有少量有效峰时，
自动降低惯导估距权重。地磁只允许在直行段内部对进度作最多 15% 的修正，不能改变
边长，也不能把坐标瞬移或硬投影到白色参考路线。

```bash
python -m geomag_v2 \
  --capture-root "/path/to/Geomag Capture"
# 安装项目后也可运行：geomag-v2 --capture-root "/path/to/Geomag Capture"
```

训练固定为 `route_13_1、route_14_2、route_15_1`，其余五次采集只作留出验证。
输出位于 `results/geomag_v2/`：

- `tracks.png`：V2 最终路径与白色参考路线
- `sensor_diagnostics.png`：不隐藏的纯传感器估距轨迹
- `blind_tracks.png` / `blind_report.md`：完整排除待测路线后的跨路线盲测
- `summary.json`：逐段输入、预测与指标
- `report.md`：可读验证报告

当前同路线留出集的纯传感器边长 MAE 为 `0.535 m`，软融合后为 `0.059 m`；平均
横向误差为 `0.028 m`，最大角点误差为 `0.279 m`。这些数字依赖“同一路线独立
标定 + 90° 矩形”的受控试验条件，不能直接当作任意路线定位精度。

V2 同时自动执行 leave-one-route-group-out 盲测：待测路线的所有采集、边长和地磁
模板都不进入训练，只保留矩形相对边相等的实验拓扑。当前盲测边长 MAE 为
`0.511 m`、平均横向误差 `0.228 m`、最大角点误差 `1.432 m`。这组数字更接近
“遇到未标定路线”的真实能力，也是下一阶段需要改善的主要基线。`route_14` 的
`6.0 m × 0.6 m` 已由采集者确认。架构边界和旧实现迁移关系见
[`docs/geomag-v2-architecture.md`](docs/geomag-v2-architecture.md)。

旧的 `python -m Geomag.recent_capture_pipeline` 命令仍可用于结果回归，但它会把
地磁进度限制到已知路线边，不能代表 V2 的最终结果。

### V2 自由路径模式

`geomag_v2.free_path` 取消固定四段、固定 90° 转角、矩形相对边相等和待测边长
先验。它通过角速度迟滞自动检测任意数量、任意角度的转弯区域；直行方向采用
Core Motion 圆均值抑制手持抖动，但不会吸附到预设角度。当前闭环采集已确认在
第四次转弯到达终点，之后仅继续记录，所以验证配置明确排除其尾部静止记录：

```bash
python -m geomag_v2.free_path \
  --capture-root "/path/to/Geomag Capture"
# 安装后也可运行：geomag-v2-free --capture-root "/path/to/Geomag Capture"
```

输出位于 `results/geomag_v2_free/`。当前同路线留出边长 MAE 为 `0.715 m`、平均
横向误差 `0.457 m`、平均终点误差 `1.041 m`；完整跨路线盲测分别为
`0.761 m`、`0.450 m` 和 `1.421 m`。自由模式的误差高于受控矩形模式，因为它不再
利用已知边长或 90° 几何把轨迹拉回参考线。这是实际任意路线开发的诚实基线。

通用 `MagneticMap` 已支持带坐标系标识的散点三轴磁图、近邻查询、设备磁场旋转、
保存/读取以及跨坐标系合并保护。本次自由模式没有启用地磁纠正：route 13/14/15
都以各自局部 `(0, 0)` 为起点，缺少统一楼层坐标锚点，直接合并会生成伪磁图。
要进入自由路径地磁融合，必须先给采集路线提供统一空间坐标或至少三个不共线锚点。

新版 iPhone `Geomag Capture` 已将采集包升级为格式 v3：要求填写统一坐标系、起点
和初始航向，自动记录起点，并可在采集中标记转角、手工坐标锚点或预填路线的下一个
坐标点。获得至少三个不共线锚点的新采集后，可以直接建图：

```bash
python -m geomag_v2.map_builder "/path/to/Geomag Capture" \
  --coordinate-frame building-a-floor-1 \
  --output-root results/geomag_v2_map
# 安装后也可运行 geomag-v2-map
```

输出包含 `magnetic_map.npz`、`summary.json` 和 `preview.png`。构建器会拒绝 v2 无
锚点数据、不同坐标系混合以及全部锚点共线的伪二维地图。

### 暂无 iPhone 时的 format-3 回填与留出磁融合

暂时无法继续真机采集时，可以把最近的 format-2 数据复制成带明确来源标记的
format-3 派生包。转换不会修改原始 `.geomagcapture`，route13、route14、route15
也始终保留为三个互不混合的局部坐标系：

```bash
python -m geomag_v2.retrofit_v3 \
  --source-root "/path/to/Geomag Capture" \
  --output-root results/geomag_v3_retrofit

python -m geomag_v2.retrofit_validation \
  --capture-root results/geomag_v3_retrofit \
  --output-root results/geomag_v3_retrofit_validation

python -m geomag_v2.multimap_validation \
  --capture-root results/geomag_v3_retrofit \
  --output-root results/geomag_v3_multimap_validation
# 安装后也可运行 geomag-v2-retrofit、geomag-v2-retrofit-validate、
# geomag-v2-multimap-validate
```

每条路线只用首组建图和训练距离模型：`route_13_1`、`route_14_2`、
`route_15_1`；其余五组严格留出。定位接口只接收已知起点、初始航向、Core Motion
惯性位移、测试磁观测和首组磁图，不读取测试路线的中间锚点、边长或闭环终点。
参考坐标只在定位结束后用于误差计算和绘图。磁匹配采用对手机水平姿态更稳健的
“磁场模长 + 垂直分量”特征，并以粒子滤波修正自由 PDR 轨迹。

推荐使用 `multimap_validation` 做逐次留一评估：每次将待测采集从磁图和距离训练中
完全排除，同一路线剩余采集共同建图。route13/15 每折有两次建图，route14 目前
只有两组数据，所以每折仍是一次建图、一次测试。`route_14_2` 起点前约 1.92 秒的
等待不会污染长边，因为建图按惯性活动进度赋坐标，而不是按整段录制时间铺开。

当前全部 8 折的平均横向误差由 `0.343 m` 降至 `0.149 m`，平均终点误差由
`1.009 m` 降至 `0.465 m`；横向和终点分别有 7/8 折改善。与此前相同的五组测试中，
横向误差由 `0.428 m` 降至 `0.115 m`，终点误差由 `0.937 m` 降至 `0.236 m`，
两项均为 5/5 改善。`route_13_2` 的终点歧义由 `1.268 m` 降至 `0.330 m`。
`route_15_1` 的横向误差仍由 `0.333 m` 上升至 `0.479 m`，说明两次重复图还不能
保证每个方向都稳定泛化，不能用总体平均值隐藏这个失败项。

多图定位会对每次采集在已知起点处估计磁特征零偏，以等进度重采样避免录制时长
造成权重失衡，并联合估计位置、步幅比例和航向偏差。对小范围磁图允许在转弯后
温和重估短段尺度；对长走廊型磁图保持尺度连续，避免短边修正破坏相邻长边。
结果目录包含逐折磁图、轨迹 CSV、`leave_one_out_tracks.png`、`summary.json` 和
`report.md`。

这些空间锚点由已知受控路线和 Core Motion 转弯检测派生，元数据会明确写入
`manual_ground_truth: false`。它们只能用于验证数据格式、建图、自由 PDR 和磁融合
的完整软件链路，不能冒充现场手工测量的独立真值；恢复 iPhone 后仍应使用采集端
直接记录的统一楼层坐标锚点做最终验证。

# First of All
This is the package I am using for testing my own geomagnetic positioning project using Particle filter, and I am trying to make the project **more lego-like such as pytorch** , and you can see some of the characteristics are from pytorch, actually. I am going to make this a acedemic-directed tool, 
everyone who come up with an idea of, whatever the filter problem is, can immediately turn on the mac, quickly have a simulation, and feel free to build anything you like. World of Machine Learning can do it, I hope we will do it. 

Although the algorithm I've written in the `main.py` is still dumb and I am still seeking the reason why it is performing below my expectation, however, like someone said on Youtube, I am the guy interested in building shovels, and I hope there will be more contributers can participate in it. 

The project per se is just in testing right now, with so many functional issues yet to be finished, but I hope this project, conversely, will never be an end, with firm cooperation of the intelligence of the community. **A project with continuous maintainence and contributers is a healthy project.**


For anyone who is interested, email `kudoumakoto6523@gmail.com` (same as the github account).

## Below are the content.

Lego-style geomagnetic indoor positioning for fast academic prototyping.

This repository is a testing package for geomagnetic positioning with particle filtering, IMU-based PDR, and DDTW-oriented magnetic matching. The current algorithm in [`main.py`](main.py) is still experimental and its performance is not yet where I want it to be, but the goal of the project is already clear:

- make geomagnetic positioning experiments easy to assemble
- expose reusable building blocks instead of one hard-coded pipeline
- let researchers quickly try a new filter idea, run a simulation, and inspect results

The project is closer to "building shovels" than claiming a finished localization system. If PyTorch can give machine learning researchers a flexible toolbox, this project aims to do something similar for geomagnetic and filter-oriented indoor positioning research.

## Status

This project is under active restructuring.

- The package layout is already modular and usable for experiments.
- The particle-filter pipeline is configurable and reorderable.
- UJI map building and visualization are implemented.
- Some algorithm hooks are still placeholders or baseline implementations.
- End-to-end accuracy is still being improved.

### Own-data baseline

The default own-data profile now applies a 0.40 s step cooldown, continuous
timestamp-based gyro integration, a trainable adaptive step model, online
gyroscope bias estimation, particle-level step-scale/heading-bias estimation,
turn-aware noise, a tighter known-start prior, and bilinear lookup on the
regular magnetic grid. On the two manifest-selected primary captures:

| Dataset | PF mean / P95 | Cross-track mean | Endpoint |
|---|---:|---:|---:|
| `route1_run2` | 1.141 m / 1.923 m | 0.335 m | 0.664 m |
| `route2_run2` | 0.893 m / 1.535 m | 0.413 m | 1.185 m |

These figures use the registered route geometry and align each detected step
with the fraction of the automatically detected active walking interval. This
matches the controlled constant-speed acquisition protocol while excluding
recording time before the first step or after the last step. They are useful
regression metrics, not centimeter-accurate ground truth.

### 定位异常压力测试与恢复报告

开发阶段可以在不修改原始采集文件的前提下，对已登记路线注入确定性
异常并复用完整定位流水线。默认测试磁场偏置、磁场噪声、磁力计失效、
陀螺仪偏置和错误初始位置：

```bash
python -m Geomag.stress_testing
```

默认使用 `route1_run2`、`route2_run2`，结果写入
`results/localization_stress/summary.md`、`summary.json` 和 `summary.csv`。报告包含异常
窗口内是否预警、预警/恢复延迟步数、扩搜与重初始化事件、异常前/中/后
平均和最大误差、异常结束后的误差改善、错误恢复动作及最终是否重新收敛。
每个基准与注入场景也会保存独立 JSON，便于追查逐步可靠度。

定位流水线针对三类完整性问题采用独立处理：磁力计无效帧不会再进入磁场
权重更新；配置的可信路线起点与初始粒子位置相差超过 1 m 时立即回到起点；
连续异常偏航会触发陀螺仪偏置估计与相对航向传播，输入恢复后再收紧航向
粒子。当前两组主数据的确定性测试中，三类故障共 6 个场景全部被检测；
磁力计失效和起点偏移均最终重新收敛，`route2_run2` 的陀螺仪偏置也重新
收敛。较长的 `route1_run2` 陀螺仪偏置平均误差已降至 1.371 m，但终点误差
仍为 3.124 m，因此仍按“部分恢复、未最终收敛”记录，而不是作为完成项。

只运行指定数据或场景：

```bash
python -m Geomag.stress_testing route2_run2 \
  --scenario gyro_bias --scenario magnetic_dropout \
  --output-dir results/localization_stress_route2
```

加入 `--plots` 可同时生成每次运行的轨迹图和诊断图。该工具的故障层默认
关闭，正常的 `python main.py` 和 macOS App 定位结果不会受到影响。报告将
异常结束后才出现的提示标为 `late_warning_only`，不会把迟到预警误算成
检测成功；磁力计失效、陀螺仪持续偏置和起点偏移固定为必须检测、必须
重新收敛的完整性故障，其他扰动则在误差显著增大时才要求检测。

如果逐场景 JSON 已存在，只需重新计算汇总指标而不重跑算法：

```bash
python -m Geomag.stress_testing --reuse-existing
```

Use the legacy full-recording alignment for comparison:

```bash
python main.py --own route1_run2 --own-alignment-mode capture_time --no-show
```

A stateful quaternion attitude estimator is also available for ablation. It
propagates the full three-axis gyroscope, constrains roll/pitch with gravity,
requires consecutive stationary evidence before estimating three-axis bias,
and optionally applies norm/direction-gated magnetic yaw correction:

```bash
python main.py --own route1_run2 --own-heading-method quaternion --no-show
python main.py --own route1_run2 --own-heading-method quaternion \
  --own-quaternion-use-magnetometer --no-show
```

It is not the default. On the legacy captures, quaternion gravity fusion
worsens `route1_run2` and does not recover the missing 90-degree yaw in
`route2_run1`; magnetic correction is also unreliable in the indoor field.
The gyro baseline remains the honest default until captures with verified
stationary calibration are available.

Own-data plots now distinguish the raw PF estimate (magenta) from its causal
EMA output (cyan). A second diagnostics image contains heading, step length,
ESS, posterior step scale/heading bias, and magnetic residual histories.
The selected captures use a low-lag EMA history weight of `0.30`. The previous
`0.70` setting over-smoothed the shorter `route2_run2`: reducing it lowers the
selected-pair aligned mean from `1.181` to `1.017 m` and endpoint mean from
`1.046` to `0.925 m`, while cross-track mean increases from `0.319` to
`0.374 m`. The strong EMA's unusually small `route1_run2` endpoint error was
partly a closed-loop artefact: on the return to the start area, lag pulled the
reported endpoint toward earlier positions. The lower weight is a more honest
real-time default. Smoothing can be disabled to inspect the filter directly:

```bash
python main.py --own route1_run2 --own-pf-smoothing-alpha 0 --no-show
```

The motion-prediction residual smoother is also available with
`--own-pf-smoothing-mode motion_adaptive`, but it remains experimental. It
improves `route2_run2` while making `route1_run2` worse and increasing the
selected pair's average cross-track error, so the causal EMA remains the
default.

Captures made with the phone facing forward while walking on orthogonal tile
seams can enable a 90-degree Manhattan heading prior:

```bash
python main.py --own route2_run1 --own-heading-snap-deg 90 --no-show
```

This is intentionally opt-in. Its hysteretic turn detector reduces
`route2_run1` smoothed aligned mean from 0.772 m to 0.691 m and cross-track
mean from 0.426 m to 0.073 m; the raw PF aligned mean becomes 0.217 m.
It still worsens the endpoint on `route1_run2`, where the final segment is
estimated as 6.21 m instead of 3.84 m. Enabling it globally would hide a
step/turn-timing calibration problem.

The adaptive step model exposes cadence and acceleration-variability
coefficients, but both remain zero until they can be fitted on separate
calibration captures:

```bash
python main.py --own route2_run1 \
  --own-step-weinberg-k 0.31 \
  --own-step-cadence-weight 0.0 \
  --own-step-variability-weight 0.0 \
  --no-show
```

Use `--no-own-pf-joint-calibration` for an ablation without per-particle
`step_scale` and `heading_bias`.

Walking speed changes the personalized Weinberg coefficient. Calibrate the
step scale on a separate straight, known-distance walk, then apply it to later
captures:

```bash
python -m Geomag.step_calibration \
  results/calibration_walk.json --known-distance-m 10 \
  --output-json results/step_calibration.json

python main.py --own route2_run2 \
  --own-step-length-scale 1.12 --no-show
```

Do not estimate the scale from the same route used for evaluation. Doing that
on `route2_run2` gives an oracle scale of `1.2685` and improves mean /
cross-track / endpoint errors from `0.893 / 0.413 / 1.185 m` to
`0.327 / 0.145 / 0.223 m`, but those values are only an upper-bound diagnosis
because the known route length was leaked into the estimator.

An independent known-turn capture can likewise calibrate the gyroscope rate
scale. `route1_run2` integrates to `-284.503°` around device Z for a registered
`-270°` route, giving `270 / 284.503 = 0.9490`. Applying that frozen value only
to `route2_run2` improves aligned / cross-track / endpoint error from
`0.893 / 0.413 / 1.185 m` to `0.861 / 0.384 / 1.060 m`:

```bash
python main.py --own route2_run2 \
  --own-gyro-rate-scale 0.9490245178 --no-show
```

For a repeatedly surveyed route, an experimental causal progress matcher can
use a prior independent run as a three-axis magnetic-change template:

```bash
python -m Geomag.batch_evaluation route2_run1 \
  --output-dir results/route2_run1_progress_template --no-plots

python main.py --own route2_run2 \
  --own-gyro-rate-scale 0.9490245178 \
  --own-progress-template-json \
    results/route2_run1_progress_template/route2_run1.json \
  --own-progress-correction-gain 0.30 --no-show
```

That exploratory combination reaches `0.837 / 0.380 / 0.819 m`, but the
matcher and gain were developed while inspecting `route2_run2`. It is disabled
by default and needs a third independent repeat before it can be reported as a
held-out improvement. It also applies only to a previously surveyed route, not
arbitrary indoor walking.

Map translation can be tested with `--own-map-offset-x-m` and
`--own-map-offset-y-m`. The route1-selected magnetic-shape offset worsened the
held-out route2 result, so the registered default remains `(0, 0)`.

The hybrid DDTW + absolute-level + gradient likelihood is implemented in
`DDTWWeight`, but remains opt-in: ablation on the current map reduced some final
errors while worsening mean error, so shape-only DDTW remains the default.
See [`docs/2026-07-29-own-data-improvement-report.md`](docs/2026-07-29-own-data-improvement-report.md)
for the full ablation and evaluation notes.

Before comparing algorithm changes, audit the acquisition quality and run the
same configuration over every enabled own-data capture:

```bash
python -m Geomag.data_quality
python -m Geomag.batch_evaluation
```

The operator confirmed that `route2_run2` is an independent second capture of
the same route as `route2_run1`. The manifest-selected default evaluation now
uses `route1_run2` and `route2_run2`; `route2_run1` remains runnable as a
separate repeat:

```bash
python -m Geomag.route_identity
python -m Geomag.batch_evaluation --no-plots
python -m Geomag.batch_evaluation route2_run1 --no-plots
```

Own-map geometry is explicit. Compare the measured survey grid and the
tile-coordinate interpretation independently:

```bash
python -m Geomag.batch_evaluation \
  --map-profile survey_kriging --output-dir results/map_profile_survey --no-plots
python -m Geomag.batch_evaluation \
  --map-profile tile_manifest --output-dir results/map_profile_tiles --no-plots
```

The original eight magnetometer-only survey archives can now be reconstructed
as a three-axis map and used as a yaw-aligned, anomaly-gated PF likelihood:

```bash
python -m Geomag.vector_map
python -m Geomag.batch_evaluation \
  --map-profile survey_kriging --vector-map \
  --vector-weight 0.10 --output-dir results/vector_survey_w010 --no-plots
```

This option is deliberately disabled by default. The survey archives contain
no synchronized phone attitude, so the run calibrates one relative yaw offset
at its first valid step. Later updates use horizontal magnetic direction only;
norm or direction anomalies fall back to scalar DDTW. With weight `0.10`, the
selected survey-profile aligned means change from `1.270 / 0.895 m` to
`1.212 / 0.901 m` for `route1_run2 / route2_run2`. Aggregate cross-track error
improves from `0.400` to `0.384 m`, while aggregate endpoint error changes from
`1.065` to `1.085 m`;
this is useful evidence, not yet a production default.

Passing dataset keys explicitly always overrides the manifest-selected default.
`--all-evaluable` runs every evaluable capture, including the secondary
`route2_run1` repeat. The older `--include-provisional` spelling remains an
alias.

The audit checks required files, timestamps, stream overlap, sample gaps,
start/end stationary windows, route duration, and device-Z yaw consistency.
It also blocks the known-invalid `route1_run1`. New captures should use
[`data/own_data_package/capture_metadata.template.json`](data/own_data_package/capture_metadata.template.json)
and record synchronized turn events. These metadata requirements also support
arbitrary real routes; the 90-degree tile route remains an optional controlled
test rather than a production assumption.

If you are interested in contributing ideas, code, experiments, or criticism, contributions are welcome.

## What The Repository Currently Covers

The current pipeline combines:

- IMU-based PDR for step and heading estimation
- geomagnetic matching
- particle filtering with DDTW-oriented weighting design
- UJIIndoorLoc-Mag map building
- direct user-defined magnetic map input

## Installation

Python `>= 3.11` is required.

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .
```

Current package dependencies from [`pyproject.toml`](pyproject.toml):

- `numpy`
- `pykrige`
- `matplotlib`

## Quick Start

Run the default experiment:

```bash
python main.py
```

Test UJI map building plus user-map visualization:

```bash
python main_get_map_temp.py
```

Plot true route overlays:

```bash
python main_get_true_route.py
```

Inspect sensor streams and visualization outputs:

```bash
python main_get_sensor_and_len.py
```

## Design Goal: Lego-Style Pipeline

The package is intentionally structured in a PyTorch-like style. Instead of forcing one giant script, it separates:

- orchestration
- state models
- block registries
- configurable PDR modules
- configurable PF modules

The default flow is:

`Initializer -> RunContext -> Experiment -> GeomagPipeline`

Basic example:

```python
from Geomag import Experiment, Initializer, PDRConfig, PFConfig

ctx = Initializer(
    num_runs=1,
    window_size=400,
    route_source="uji",
    sensor_source="uji",
    uji_test_file="tt01.txt",
).create_context()

pdr = PDRConfig(
    step_judge="peak_dynamic",
    step_judge_params={"peak_sigma": 0.40, "peak_prominence": 0.16},
    step_length="weinberg",
    step_length_params={"weinberg_k": 0.45},
    heading="gyro",
    heading_params={"dt": 0.02},
    mag="norm_mean",
)

pf = PFConfig(
    state_params={"num_particles": 500, "min_particles": 120, "max_particles": 5000},
    motion="gaussian",
    motion_params={"heading_noise_std": 0.10, "step_noise_std": 0.20},
    weight="ddtw",
    weight_params={"sigma": 6.0, "max_hist": 80},
    particle_size="kld",
    particle_size_params={"epsilon": 0.10},
    resample_trigger="ess_or_target",
    resample_trigger_params={"ess_ratio_threshold": 0.45},
    resample="cso",
)

result = Experiment(ctx, pdr_config=pdr, pf_config=pf).run(show=True)
```

## Reordering The Particle Filter

The PF side is built from composable stages, so you can rearrange them when needed.

```python
from Geomag import (
    ParticleSizeStage,
    PredictStage,
    ResampleDecisionStage,
    ResampleStage,
    UpdateStage,
    build_pf_sequential,
)

pf = build_pf_sequential(
    ("predict", PredictStage(motion="gaussian")),
    ("particle_size", ParticleSizeStage(particle_size="kld")),
    ("update", UpdateStage(weight="ddtw")),
    ("resample_decision", ResampleDecisionStage(trigger="ess_or_target")),
    ("resample", ResampleStage(resample="cso")),
)
```

You can inspect the registered blocks at runtime:

```python
from Geomag import Experiment, GeomagPipeline

print(GeomagPipeline.available_blocks())
print(Experiment.describe_api())
```

Current block families include:

- `step_judge`: `autocorr`, `frequency_fft`, `peak_dynamic`, `peak_fixed`, `valley_peak`, `zero_crossing`
- `step_length`: `adaptive`, `fixed`, `weinberg`
- `heading`: `core_motion`, `gyro`, `q_fused`, `tilt_compass`
- `mag`: `norm_last`, `norm_mean`
- `motion`: `gaussian`
- `weight`: `ddtw`
- `particle_size`: `kld`
- `resample_trigger`: `always`, `ess_or_target`
- `resample`: `cso`, `systematic`

## Map API

[`Geomag/algorithms.py`](Geomag/algorithms.py) exposes the public map entrypoint:

```python
from Geomag.algorithms import get_map
```

Two branches are currently supported:

- `source="uji"`: build a continuous map from UJIIndoorLoc-Mag
- `source="own"`: use a user-defined magnetic map, with direct matrix input preferred

### UJI Branch

```python
from Geomag.algorithms import get_map

uji_map = get_map(source="uji")
print(uji_map)
```

Behavior:

- downloads the UJI zip if missing
- extracts the dataset if missing
- parses `lines/` and `curves/`
- reconstructs sample positions
- fits an Ordinary Kriging model
- writes processed artifacts
- returns a metadata dictionary

Configuration lives in [`pyproject.toml`](pyproject.toml) under `[tool.map_builder]`.

Relevant keys:

- `preview_resolution`
- `max_kriging_points`
- `seed`
- `variogram_model`
- `output_model_npz`
- `output_preview_npz`
- `output_json`
- `output_png`

Typical returned fields include:

- `source`
- `continuous_map`
- `output_model_npz`
- `output_preview_npz`
- `output_json`
- `output_png`
- `zip_path`
- `extract_dir`

### Own Branch

Preferred input is a directly editable 2D matrix:

```python
from Geomag.algorithms import get_map

own_map = get_map(
    source="own",
    own_grid_array=[
        [45.10, 45.22, 45.31],
        [44.97, 45.05, 45.27],
        [44.83, 44.96, 45.14],
    ],
    own_grid_meta={
        "cell_size_m": 0.5,
        "origin_xy_m": [0.0, 0.0],
        "variogram_model": "spherical",
    },
)
print(own_map)
```

Important metadata:

- `cell_size_m`: distance between neighboring cells in meters
- `origin_xy_m`: physical origin for mapping matrix indices to world coordinates
- optional `variogram_model`: interpolation choice for visualization

Matrix convention:

- `matrix[row][col]` stores magnetic magnitude
- `x = origin_x + col * cell_size`
- `y = origin_y + row * cell_size`

## Visualization

Use `visualize(...)` with mode selection:

```python
from Geomag.algorithms import visualize
```

UJI map preview:

```python
visualize(geomag_map=uji_map, mode="ujimap")
```

User map preview:

```python
visualize(geomag_map=own_map, mode="usermap")
```

The visualization API also supports route and sensor overlays, as shown in:

- [`main_get_map_temp.py`](examples/main_get_map_temp.py)
- [`main_get_true_route.py`](examples/main_get_true_route.py)
- [`main_get_sensor_and_len.py`](examples/main_get_sensor_and_len.py)

## Repository Layout

- [`main.py`](main.py): thin runtime entrypoint
- [`Geomag/initiation.py`](Geomag/initiation.py): initialization orchestration
- [`Geomag/experiment.py`](Geomag/experiment.py): experiment loop wrapper
- [`Geomag/pipeline.py`](Geomag/pipeline.py): composable PDR and PF pipeline
- [`Geomag/models.py`](Geomag/models.py): shared state classes such as `PFState`, `Particle`, and `RunContext`
- [`Geomag/blocks.py`](Geomag/blocks.py): block interfaces and registries
- [`Geomag/algorithms.py`](Geomag/algorithms.py): map building, visualization, and algorithm implementations/placeholders
- [`Geomag/nn.py`](Geomag/nn.py): lightweight `Module` and `Sequential` abstractions
- [`Geomag/utils.py`](Geomag/utils.py): helper utilities for sensor collection and map loading

## Notes

- If `pykrige` is missing, continuous interpolation will fail with an explicit installation message.
- If `matplotlib` is missing, visualization will fail with an explicit installation message.
- The initializer tries to build the UJI map first and can fall back to existing processed artifacts if rebuilding is unavailable.
- The first `get_map(source="uji")` call may download the dataset automatically.

## Roadmap

Near-term goals:

- improve particle-filter performance and diagnostics
- replace baseline or placeholder parts with stronger research-grade implementations
- make more blocks plug-and-play
- add more examples, tests, and benchmark scripts
- make the package easier for outside contributors to extend

## Contributing

This project is meant to keep evolving. If you have:

- a new filter idea
- a better weighting method
- a stronger step detector
- a new dataset adapter
- a cleaner interface design

then this repository is intended to be a place where that idea can be tested quickly.

Pull requests, issue reports, design suggestions, and academic collaboration are all welcome.

## Contact

For collaboration or questions, email:

`kudoumakoto6523@gmail.com`
