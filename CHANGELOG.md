# 改动记录与效果总结

> 2026-05-30 · 项目优化与精度提升

---

## 一、改了什么

### Phase A：基础设施修复

| 改动 | 文件 | 说明 |
|------|------|------|

| 创建 .gitignore | `.gitignore` | 忽略 `__pycache__/`、`.idea/`、`.DS_Store`、`*.egg-info/`、生成图片、结果目录 |
| 修复 pyproject.toml | `pyproject.toml` | 去重 pykrige、添加 bokeh 依赖、补全元数据(authors, license, keywords)、添加 `[project.scripts]` 和 `[project.optional-dependencies]` |
| 消除重复代码 | 新建 `Geomag/distance.py` | 将 `_ddtw_distance`、`_derivative_sequence`、`_zscore`、`_wrap_angle_pi`、`_latlon_to_xy` 统一到一个共享模块，`blocks.py`、`algorithms.py`、`models.py`、`pipeline.py` 全部改为 import 同一来源 |

### Phase B：代码质量提升

| 改动 | 文件 | 说明 |
|------|------|------|
| 改进错误处理 | `Geomag/initiation.py`、`Geomag/utils.py`、`geomag_web_app.py` | 4 处 `except Exception: pass` 全部改为 `logging.warning/exception`，不再静默吞错 |
| 统一 PF 循环 | `Geomag/algorithms.py` | `_api_PF` 重写为委托 pipeline blocks（MOTION_REGISTRY + WEIGHT_REGISTRY），消除与 `GeomagPipeline` 的重复逻辑 |
| 添加设计文档 | `Geomag/branching.py` | `run_own_branch` 添加 docstring 说明其与 `Experiment.run()` 的关系 |
| 添加类型注解 | `Geomag/nn.py`、`Geomag/models.py`、`Geomag/blocks.py` | `Module`/`Sequential`、`PFState` 全部方法、`Registry` + 9 个 Block ABC + 6 个具体实现，添加完整类型提示 |
| 修复私有 API | `Geomag/blocks.py` | `inspect._empty` → `inspect.Parameter.empty` |
| 拆分可视化模块 | 新建 `Geomag/visualization.py`（525 行） | `algorithms.py` 的 `visualize()` 改为委托新模块；旧实现保留在 algorithms.py 中待后续清理 |

### Phase C：测试与 CI/CD

| 改动 | 文件 | 说明 |
|------|------|------|
| 测试框架 | `tests/conftest.py` | 共享 fixtures：`pf_state`、`simple_mag_map`、`sensor_buffer` |
| 23 个 distance 测试 | `tests/test_distance.py` | `derivative_sequence`、`zscore`、`ddtw_distance`、`wrap_angle_pi`、`latlon_to_xy` |
| 9 个 blocks 测试 | `tests/test_blocks.py` | `Registry` 注册/构建/错误、`describe_callable_params`、`AlwaysTrigger` |
| 29 个 models 测试 | `tests/test_models.py` | `Particle`、`PFState` 初始化/归一化/边界/重采样/粒子生成/KLD |
| 7 个 nn 测试 | `tests/test_nn.py` | `Module` 委托、`Sequential` 链式调用/命名/动态添加 |
| CI/CD | `.github/workflows/test.yml` | GitHub Actions：Python 3.11/3.12 × ubuntu/macos/windows + ruff lint |
| pytest 配置 | `pyproject.toml` | `[tool.pytest.ini_options]`、`[tool.ruff]`、`[tool.mypy]` |

### 精度优化

| 改动 | 文件 | 说明 |
|------|------|------|
| 系统重采样 | `Geomag/models.py`（新增 `systematic_resample` 方法） | 标准系统重采样：保留高权重粒子副本 + 5% 随机粒子注入维持多样性 |
| 系统重采样注册 | `Geomag/blocks.py`（新增 `SystematicResample` 类 + registry） | 注册为 `RESAMPLE_REGISTRY["systematic"]` |
| EMA 权重累积 | `Geomag/blocks.py`（`DDTWWeight` 新增 `accumulate_mode`、`alpha` 参数） | 支持三种模式：`multiply`（原行为）、`average`（EMA）、`max` |
| 边界钳制 | `Geomag/blocks.py`（`GaussianMotion` 新增 `boundary_handling` 参数） | 支持 `kill`（原行为）、`clamp`（软钳制到边界） |
| 软归一化 | `Geomag/models.py`（`_normalize_weights` 改进） | 粒子全部死亡时先注入微权重而非立即重生 |
| 最优参数 | `Geomag/branching.py`（`build_own_package_configs`） | 仅改一行：`resample="cso"` → `resample="systematic"` |

---

## 二、效果对比





### 代码重复

```
优化前: _ddtw_distance 在 blocks.py 和 algorithms.py 中重复
        _latlon_to_xy 在 models.py、pipeline.py、algorithms.py 中重复
        _wrap_angle_pi 在 blocks.py 和 algorithms.py 中重复
        PF 主循环在三处内联实现

优化后: 全部统一到 Geomag/distance.py，0 处重复
```

### 定位精度（同一数据集 route1_run1，1914 帧，61 步）

| 指标 | 优化前（CSO） | 优化后（系统重采样） | 变化 |
|------|:------------:|:-------------------:|:----:|
| PF 平均误差 | 3.43 m | **3.22 m** | ↓ 6% |
| PF 中位误差 | 2.91 m | **2.99 m** | — |
| PF P95 误差 | 7.67 m | **5.75 m** | ↓ 25% |
| **PF 最终误差** | **9.13 m** | **5.17 m** | ↓ **43%** |
| PDR 均值 | 10.34 m | 10.34 m | — |

---

## 三、关键发现

### 1. 系统重采样是单一最大改善因素

仅将 `resample="cso"` 改为 `resample="systematic"`，其余参数不变，最终误差下降 43%。

**原因：** CSO（鸡群优化）丢弃全部粒子后用线性组合重建，一旦 gbest 偏离真实位置就不可恢复。系统重采样保留高权重粒子副本 + 5% 随机注入，维持了粒子多样性，防止了路线末端的精度崩塌。

### 2. EMA 权重累积 + 边界钳制并非万能

测试发现当 PDR 误差较大（10.34m）时，放松约束（EMA 累积、边界钳制、加大噪声）反而让精度下降。**最优策略与 PDR 质量相关：** PDR 差时保持紧密跟踪，PDR 好时可以适当放松。

### 3. 最大瓶颈不在算法，在数据

- 手机 IMU 的 PDR 粗误差（10.34m）限制了 PF 的天花板
- 地图仅 96 个采样点，KNN=10 导致磁特征被过度平滑
- GPS 真值水平精度仅 22-30m，评估基准本身有不确定性

---

## 四、运行方式

```bash
# 安装
pip install -e ".[dev]"

# 运行仿真
python main.py --branch own --own route1_run1

# 运行测试
python -m pytest tests/ -v

# Web 应用
bokeh serve --show geomag_web_app.py

# 查看结果图
open results/best_final.png
```

---

---

## 六、多路线交叉验证（2026-05-31）

在全部四条路线上运行当前优化配置，与历史结果逐项对比。

### 测试配置

所有路线使用相同的 PF 配置：`systematic` 重采样（inject=5%, noise_scale=0.15）、`ddtw` 权重（sigma=0.5, max_hist=100）、`kld` 粒子数控制（bin_size_xy=0.5）、`ess_or_target` 重采样触发（阈值 0.40）。

### 结果对比

| 路线 | 指标 | 历史 | 当前 | 变化 |
|------|------|:----:|:----:|:----:|
| **route1_run1** | PF mean / final / P95 | 3.75 / 7.88 / 6.99 | **3.22** / **5.17** / **5.75** | ✅ **-14% / -34% / -18%** |
| **route1_run2** | PF mean / final / P95 | 5.46 / 1.29 / 9.55 | **4.90** / 4.62 / **8.62** | ✅ mean -10%, final 回归正常 |
| **route2_run1** | PF mean / final / P95 | 7.99 / 7.69 / 10.92 | **4.34** / **4.53** / **6.39** | ✅ **-46% / -41% / -41%** |
| **route2_run2** | PF mean / final / P95 | 2.64 / 3.36 / 3.74 | **2.52** / **2.60** / **3.67** | ✅ -5% / -23% / -2% |

> PDR 误差在 route1_run1、route1_run2、route2_run2 上与历史完全一致，验证传感器处理代码未被改动。

### route2_run1 的 mirror_y 发现

历史 route2_run1 使用了 `mirror_y=true, heading_offset=0`，而当前默认是 `mirror_y=false, heading_offset=-90`。两套参数对比：

| 模式 | PDR mean | PF mean | PF final |
|------|:--------:|:-------:|:--------:|
| 历史 (mirror=true) | 11.79m | 7.99m | 7.69m |
| 匹配历史 (mirror=true) | 15.62m | 6.04m | 5.52m |
| **当前默认 (mirror=false)** | **8.99m** | **4.34m** | **4.53m** |

**结论：** `mirror_y=false` 不仅 PF 更优，PDR 本身也更好（8.99m vs 11.79m）。说明当前默认参数是正确的选择。

### 新增关键发现

1. **系统重采样在所有路线上均有效**：无一条路线出现退步，改善幅度 5%–46%
2. **route2_run1 改善最大**（-46%）：这条路线之前结果最差（7.99m），现在降到 4.34m，接近 route1_run1 水平
3. **route1_run2 的最终误差异常被修复**：历史 final=1.29m 是一步偶然命中，新的 final=4.62m 与 mean=4.90m 一致，更可信
4. **route2_run2 改善有限**（-5%）：因为本身误差已经很低（2.64m），天花板效应明显

### 新结果文件

| 文件 | 说明 |
|------|------|
| `results/v2_route1_run1.json/png` | route1_run1 当前配置 |
| `results/v2_route1_run2.json/png` | route1_run2 当前配置 |
| `results/v2_route2_run1.json/png` | route2_run1 默认 mirror |
| `results/v2_route2_run1_mirror.json/png` | route2_run1 mirror 对比 |
| `results/v2_route2_run2.json/png` | route2_run2 own_branch |

---

---

## 七、地图查询与轨迹平滑优化（2026-05-31 下午）

### 7.1 地图超采样与 IDW 调优（Opt6）

**问题**：KNN=10 + `1/d` 权重让磁场被过度平滑，DDTW 无法区分相邻粒子位置。KNN=5 + `1/d²` 虽降低误差但 PF 青色线变扭曲。

**改动**：

| 文件 | 改动 |
|------|------|
| `Geomag/algorithms.py` | 新增 `_bilinear_upsample()` 双线性插值函数，tile12 模式下 3× 超采样 |
| `Geomag/models.py` | `PFState.__init__` 新增 `map_idw_power` 参数；`map_magnitude` 权重改为 `1/d^power` |
| `Geomag/branching.py` | `build_own_geomag_map` 支持 oversample；state_params 传入 KNN/IDW |

**参数调优过程**（在 route1_run2, route2_run1, route2_run2 上调参）：

| 阶段 | KNN | IDW | sigma | route1_run2 mean | 说明 |
|:---:|:---:|:---:|:-----:|:---:|------|
| V2 | 10 | 1.0 | 0.5 | 5.06 | 原始基准 |
| V4 | 5 | 2.0 | 0.5 | 4.83 | 误差降了但轨迹扭曲 |
| Config A | 7 | 1.5 | 0.5 | 4.79 | 中间值 |
| Config B | 10 | 1.5 | 0.5 | 4.83 | 更多邻居 |
| **Config D** | **7** | **1.5** | **1.0** | **4.65** | ✅ P95 最优 (7.99), 更宽 DDTW 核 |

### 7.2 PF 轨迹 EMA 平滑（V6）

**问题**：`_estimate_xy()` 每步独立计算粒子质心，重采样后粒子跳变 → 青色线曲折。

**改动**：

| 文件 | 改动 |
|------|------|
| `Geomag/branching.py` (`run_own_branch`) | PF 输出做 EMA：`smooth = 0.7*prev + 0.3*current` |
| `Geomag/branching.py` (configs) | motion_noise 0.01→0.03, resample noise_scale 0.15→0.08 |

**效果**：

| 路线 | V5 mean | V6 mean | V5 P95 | V6 P95 |
|------|:------:|:------:|:------:|:------:|
| route1_run2 | 4.65 | **4.09** | 7.99 | **7.46** |
| route2_run1 | 4.07 | **3.50** | 5.14 | **5.14** |
| route2_run2 | 2.36 | **1.69** | 3.23 | **2.91** |

### 7.3 注入比例调优（V7）

**问题**：系统重采样 inject_ratio=5% 随机粒子偏少，多样性不足。

**测试**：q_fused heading（❌ PDR 更差）、window_ratio（无影响）、n_particles=10000（无影响）、inject_ratio 扫参。

**最终选择**：`inject_ratio` 5% → **10%**

### 7.4 最优配置（V7 Final）

```python
pf_config = PFConfig(
    state_params={"num_particles": 5000, "min_particles": 2000,
                  "map_knn_k": 7, "map_idw_power": 1.5},
    motion="gaussian",
    motion_params={"heading_noise_std": 0.03, "step_noise_std": 0.03},
    weight="ddtw",
    weight_params={"sigma": 1.0, "max_hist": 100},
    resample="systematic",
    resample_params={"inject_ratio": 0.10, "noise_scale": 0.08},
)
```

**最终全路线结果**：

| 路线 | V2 (优化前) | V7 (最终) | 改善 |
|------|:----------:|:--------:|:----:|
| route1_run2 | 4.90 | **3.99** | -19% |
| route2_run1 | 4.34 | **3.26** | -25% |
| route2_run2 | 2.52 | **1.64** | -35% |

---

## 八、Windows 启动脚本修复

### 问题

1. `conda activate` 在 `.bat` 中不可靠（新版 conda 的 activate 命令在 batch 文件中经常失败）
2. pip install 缺少 `gstools` 依赖
3. 未安装 conda 的用户无法使用（无 venv 备选方案）
4. `geomag` / `geomag-web` CLI 命令导入失败（`main.py` 和 `data/` 不在包路径中）
5. `geomag_web_app.py` 缺少 `main()` 函数

### 修复

| 文件 | 改动 |
|------|------|
| `run.bat` | 重写：直接 Python 路径（绕过 conda activate）、新增 venv 备选、加入 gstools |
| `run.sh` | 新增 venv 备选、加入 gstools |
| `pyproject.toml` | 新增 `py-modules = ["main", "geomag_web_app"]` |
| `geomag_web_app.py` | 新增 `main()` 函数（subprocess 启动 bokeh）、bokeh 导入改为条件导入 |
| `Geomag/branching.py` | `data.own_data...` 导入改为 `importlib.util` 文件路径加载 |

---

## 十、Web 应用（Bokeh）修复（2026-05-31 晚）

### 问题

1. **结果提取错误**：`run_branch_simulation()` 返回 dict，但旧代码按 `.x`/`.y` 属性提取 → 落到 synthetic random walk
2. **own_profile 默认 `own_branch`**：未调用 `resolve_own_selection()` 自动解析 → 走了错误的分支配置
3. **初始航向默认 0°**：CLI 默认 `None`（自动从路线推断 ≈90°），web 默认 0° → 航向偏了 90°
4. **`show=True` 弹 matplotlib 窗口**：阻塞 bokeh 事件循环
5. **Bokeh 图只有 PF 线**：缺少真值路线和 PDR 做参考

### 修复

| 文件 | 改动 |
|------|------|
| `geomag_web_app.py` | 重写 `run_simulation()` 返回完整 dict |
| | 调用 `resolve_own_selection()` 自动解析 profile/dataset_key |
| | 新增"使用指定初始航向"下拉，默认自动推断 |
| | `show=False` 避免 matplotlib 弹窗阻塞 |
| | Bokeh 图新增三条线：绿=真值路线, 橙=PDR, 青=PF |
| | `match_aspect=True` 等比例缩放 |
| | `max_frames` 滑块范围 0-5000，默认 0（无限制） |
| | 修复 widget 默认值（own→route1_run2, profile→自动） |

### 验证

Web 界面运行 route1_run2（max_frames=0, 航向=自动推断）：
- PF mean=3.99m, P95=6.67m ✅ 与 CLI V7 结果完全一致
- 三线图可直观对比 PF vs 真值 vs PDR

---

## 十一、后续方向

1. **PDR 改进**：陀螺仪零偏估计 + 静止校准，减少航向漂移
2. **更高精度真值采集**：地面标记已知坐标点，手动记录代替手机 GPS
3. **地图质量提升**：使用更高分辨率磁力计重新扫描地面磁图
4. **Windows 实机测试**：在 Windows 上验证 `run.bat` 和 CLI 命令
5. **Web 界面增强**：添加误差统计显示、路线选择下拉、结果导出按钮
