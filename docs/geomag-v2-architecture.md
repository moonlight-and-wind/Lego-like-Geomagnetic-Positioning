# Geomag V2 架构与迁移说明

## 为什么重写

旧流水线把计步、航向、粒子滤波、路线注册表和可视化长期叠加在一起。最近的
route 13/14/15 数据暴露出一个关键问题：0.6 m 短边可能只产生 0～5 个可用峰，
逐峰固定步长会把短边估成 1.5～2.6 m；随后再把地磁结果限制到白色路线，会让
最终图看起来正确，却没有修好基础轨迹。

V2 因此采用新的单向依赖：

```text
format-2 iPhone capture
          |
          v
strict capture reader
          |
          v
Core Motion turn state -> straight segment observations
          |
          v
segment distance model -> confidence-aware rectangle prior
          |
          v
bounded magnetic progress correction
          |
          v
trajectory + held-out evaluation
```

## 当前模块

| V2 模块 | 职责 | 不允许做的事 |
|---|---|---|
| `geomag_v2.capture` | 校验并读取 format-2 DeviceMotion | 回退到旧 CSV 或未校准磁场 |
| `geomag_v2.motion` | 检测四次转弯、隔离直行段、提取整段特征 | 在转弯期间累计平移 |
| `geomag_v2.distance` | Ridge 整段估距与置信度软先验 | 把输出坐标投影到白线 |
| `geomag_v2.magnetic` | DTW 段内进度修正 | 修改边长或超过 15% 修正 |
| `geomag_v2.pipeline` | 训练/留出评估、JSON、报告和绘图 | 将留出采集用于拟合 |
| `geomag_v2.free_motion` | 任意转角检测、稳健直行航向和自由积分 | 90° 吸附或矩形相对边约束 |
| `geomag_v2.magnetic_map` | 带坐标系的散点磁图和查询接口 | 合并不同空间坐标系 |
| `geomag_v2.map_builder` | 从 v3 锚点采集生成 NPZ 磁图和预览 | 无锚点或共线锚点伪装成二维地图 |
| `geomag_v2.free_path` | 无待测边长先验的自由路径评估 | 将参考折线用于轨迹推断 |

## 数据边界

- 训练：`route_13_1`、`route_14_2`、`route_15_1`
- 留出验证：`route_13_2`、`route_13_3`、`route_14_3`、`route_15_2`、`route_15_3`
- route 13：1.8 m × 1.8 m，采集者确认闭合
- route 14：6.0 m × 0.6 m，采集者已确认
- route 15：12.0 m × 0.6 m，记录为闭合

目录或注册表中其他旧路线即使存在，也不会被 V2 枚举或训练。

## 指标解释

主图只显示定位结果，纯传感器轨迹单独保存在 `sensor_diagnostics.png`，因此既不让
错误轨迹遮挡主图，也不隐藏基础误差。报告同时给出：

- 纯传感器四段边长与边长 MAE
- 软融合四段边长与边长 MAE
- 对参考折线的横向误差
- 四个角点和闭合点的误差

此外每次运行都执行跨路线盲测：完整排除一个路线组，只用另外两条路线训练距离
模型，不读取被排除路线的边长或地磁模板。它输出 `blind_report.md` 和
`blind_tracks.png`，用于区分同路线地图标定能力与未标定路线泛化能力。

采集没有角点人工时间戳，因此 V2 不报告伪造的逐时刻位置误差；目前能严格验证的
是分段几何和角点，而不是每个采样时刻的真实坐标。

## 从旧工程迁移

| 旧入口 | V2 替代 |
|---|---|
| `Geomag.recent_capture_pipeline` | `geomag_v2.pipeline` |
| 单峰固定步长 | `RidgeDistanceModel` 整段估距 |
| 逐样本航向漂移 | Core Motion 转弯状态 + 90° 受控试验先验 |
| 路线边硬限制 | 置信度边长软先验 |
| 路线上地磁进度 | 有界 DTW 段内进度 |
| 同图混画原始/最终结果 | 主结果图 + 独立传感器诊断图 |

旧 `Geomag/` 暂不删除，因为 macOS App 和历史基准仍依赖它。等 V2 增加任意路线
模式、实时接口以及足够多的独立采集后，再逐项替换 App 后端，最后移除 legacy。

## 自由路径阶段的空间坐标要求

自由惯导模式已经不要求四边或 90° 转向，但地磁融合仍需要所有建图采集共享同一个
空间坐标系。当前三条路线的 `(0, 0)` 都只是各自的局部起点，不能相互叠加。
`merge_maps` 会拒绝坐标系名称不同的磁图，避免产生看似可运行但空间错误的结果。

下一批建图数据至少需要记录：

- 明确的楼层坐标系名称和单位
- 每条路线起点在该坐标系中的 `(x, y)`
- 起始朝向，或三个不共线的已知坐标锚点
- 转角/锚点事件时间戳

有这些信息后，`MagneticMap` 才能接入自由路径粒子或图优化定位。

iPhone 采集格式 v3 已提供上述字段：`capture_metadata.json` 中保存
`spatial_reference`，`SpatialEvents.csv` 保存同步的起点、转角、坐标锚点和停止
事件。`geomag-v2-map` 会按时间在相邻坐标锚点之间插值建图，并在合并前验证共享
坐标系和二维锚点覆盖。
