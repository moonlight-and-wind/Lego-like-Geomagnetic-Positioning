# 算法封版与原生应用交接

本文件冻结 2026-08-08 的算法阶段，供后续原生 macOS 与 iOS 应用接入。此后应用开发默认复用该版本，不在界面层继续调参。

## 封版结论

| 配置 | 状态 | 严格留出平均横向误差 | 平均闭合误差 | 应用处理 |
|---|---|---:|---:|---|
| `controlled_core_motion_magnetic_yaw_v1` | 当前受控试验推荐 | 0.123 m | 0.161 m | 可作为受控闭合路线的正式结果 |
| `start_registered_direction_free_yaw_v1` | `promising_shadow_requires_more_routes` | 0.132 m | 0.161 m | 只显示为实验诊断，不替换正式结果 |
| `unregistered_direction_free_yaw_v1` | `rejected_shadow_regression` | 0.142 m | — | 不部署 |
| 二维自由路径 | `not_validated` | — | — | 不宣称已经支持 |
| 旧磁图 PF | `excluded_unregistered_legacy_map` | — | — | 新旧坐标未注册前不计精度 |

这些指标只统计 `route_13_2/3、route_14_3、route_15_2/3`，不能外推为任意室内路线精度。

## 稳定接入契约

验证命令：

```bash
python -m Geomag.iphone_algorithm_validation \
  --source-root "/path/to/Geomag Capture" \
  --output-root results/iphone_algorithm_validation_optimized
```

原生应用优先读取 `algorithm_release.json`，完整诊断读取 `summary.json`。正式轨迹位于 `magnetic_heading_runs`；shadow 轨迹位于 `registered_direction_free_shadow_runs`。应用必须同时保留 `profile`、`scope` 和 `deployment_status`，不得把 shadow 标成正式定位结果。

每个原始 `.geomagcapture` 至少包含：

- `Accelerometer.csv`
- `Gyroscope.csv`
- `Magnetometer.csv`（校准磁场）
- `DeviceMotion.csv`（时间戳、四元数、yaw、用户加速度、旋转率和磁精度）

受控配置还需要路线几何、初始前进方向和对应的独立标定采集。无方向 shadow 要求采集开头至少 2.5 秒保持静止；质量门控不通过时必须拒绝磁航向修正。

## 原生界面的边界

- 初版只选择封版配置，不向普通用户开放算法增益、阈值或路线先验调节。
- 结果页显示轨迹、步数、闭合误差、横向误差、采用的 profile、门控状态和拒绝原因。
- iOS 后续可同时显示 Core Motion 原始 yaw 与应用计算的全局航向，并写入采集包；现有数据仍可由四元数和相对 yaw 重建。
- macOS 导出时应同时保存轨迹 CSV、PNG、`algorithm_release.json` 和本次运行摘要，便于复现。
- 自由路径、任意起始朝向和短边地磁匹配在获得新验证数据前保持“实验/未验证”标签。

固定阈值由 `algorithm_release.json` 的 `frozen_parameters` 给出。若将来确需改算法，应生成新的 `release_id`，保留本版本结果，避免应用升级后同一数据静默产生不同轨迹。
