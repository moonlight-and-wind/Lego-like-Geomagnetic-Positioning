# Geomag Capture for HarmonyOS

与 `GeomagMac Native` 配套的 HarmonyOS NEXT/HarmonyOS 6 采集端，使用加速度、陀螺仪、磁场和 Rotation Vector 导出兼容的 `.geomagcapture` 包。

## 功能

- 房间蛇形扫描与自由路线采集，记录坐标锚点、转弯、暂停和跳过点。
- 自由采集可选填 `x,y; x,y` 真实路线，并显示实际起点、终点、初始航向和逐点进度。
- 正向/反向采集；反向模式只反转路线顺序并自动重算起点、终点和初始航向，不改变房间坐标系。
- 开始前检查路线格式、重复点和近 `180°` 原路折返，避免点序错误污染 macOS 的真实路线。
- 到达拐点时一次操作用同一时间戳记录坐标锚点和转弯；直行点、终点不会写入伪转弯。
- 手机横滚或俯仰超过 `15°` 时禁止确认点位和标记转弯。
- 建图提供基础蛇形、双向交叉及“横穿长边补扫”三种任务。
- 导出 `route_direction`、`SpatialEvents.csv`、校准磁场和完整空间参考。
- 导出文件保存在设备 `Documents/GeomagCapture`（系统文件管理器中显示为 `geomagcapture`）目录。

## 使用

1. 使用 DevEco Studio 打开本目录，连接并解锁 HarmonyOS 真机。
2. 填写唯一数据集名称、统一坐标系和米制路线；自由采集也可填写实际路线坐标。
3. 检查界面显示的实际起点、终点和初始航向；正向完成后切换“反向”，从新起点采集。
4. 有预设路线时，到达点位后点击“到达点位并准备转弯”，再开始转向；没有路线时才单独标记转弯。
5. 导出的两次建图包在 macOS 中使用同一磁图名称合并。

路线坐标描述的是手机实际行走位置，不是墙体边界。无法贴墙行走时，应填写离墙后的可扫描区域坐标；房间长、宽仍用于描述扫描区域尺寸。

## 构建验证

在 DevEco Studio 中执行 `entry:assembleHap`。命令行环境已配置 OpenHarmony SDK 时可执行：

```bash
hvigorw assembleHap --mode module -p module=entry@default -p product=default
```
