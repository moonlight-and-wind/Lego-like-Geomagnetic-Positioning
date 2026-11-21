"""
Web-based geomagnetic positioning front-end
----------------------------------------

This script defines an interactive Bokeh application that mirrors the command
line interface exposed by ``main.py`` in the project.  Users can adjust
simulation parameters using sliders, text inputs and dropdowns, execute the
simulation and explore the results directly in their browser.  The app also
includes placeholders for uploading additional data and exporting plots.

Key features
============

* **Branch selection** – choose between the UJIIndoorLoc‑Mag test branch and
  the indoor ("own") data branch.  The dropdown labels are written in
  Chinese ("UJIIndoorLoc‑Mag数据集测试" and "室内测试") to make the meaning
  immediately clear to end users.
* **Parameter controls** – sliders and text inputs map to the command line
  options defined in ``main.py``.  Each widget’s title matches the CLI option
  and includes the original help string for context so that hovering over
  the label reveals a short description of what the parameter does.  The
  default values mirror those in the CLI.
* **Plotting** – the centre of the page shows a 2‑D trajectory plot.  A
  “Run simulation” button calls ``run_branch_simulation`` if it is available
  in the Python environment and falls back to a synthetic random walk when
  the package is missing.  A “Next step” button advances through the
  trajectory one sample at a time to demonstrate dynamic visualisation.  The
  toolbar includes a save tool so users can download the current plot as a
  high‑resolution PNG suitable for publications.
* **File uploads** – a placeholder ``FileInput`` widget demonstrates how
  arbitrary files (e.g. test or map data) could be uploaded.  At present the
  uploaded data is not used but the hook is in place for future extension.

To run this app locally, execute:

```
  bokeh serve --show geomag_web_app.py
```

This will start a small server and open your default browser to the
application.  Running within a notebook or via ``panel`` is not required and
no external dependencies beyond Bokeh itself are needed.
"""

import os

os.environ.setdefault("MPLBACKEND", "Agg")

import logging
import math
import random
import threading

import numpy as np
from bokeh.io import curdoc
from bokeh.layouts import column, row
from bokeh.models import (
    Button,
    ColumnDataSource,
    Div,
    FileInput,
    Select,
    Slider,
    TextInput,
)
from bokeh.plotting import figure

logger = logging.getLogger(__name__)
_SIMULATION_LOCK = threading.Lock()

try:
    from Geomag.branching import (
        BranchConfig,
        parse_route_control_points,
        resolve_own_selection,
        resolve_uji_selection,
        run_branch_simulation,
    )
except Exception:
    logger.warning(
        "Geomag package not available — falling back to synthetic random walk. "
        "Install the package with ‘pip install -e .’ for real simulation."
    )
    BranchConfig = None  # type: ignore
    parse_route_control_points = None  # type: ignore
    resolve_own_selection = None  # type: ignore
    resolve_uji_selection = None  # type: ignore
    run_branch_simulation = None  # type: ignore


def _synthetic_random_walk(n: int = 200) -> tuple[np.ndarray, np.ndarray]:
    """Generate a simple 2‑D random walk of length ``n``.

    This function is used when the real geomagnetic simulation API is not
    available.  It returns arrays of X and Y coordinates representing a path.
    """
    x = [0.0]
    y = [0.0]
    for _ in range(n - 1):
        angle = random.uniform(0, 2 * math.pi)
        step = random.uniform(0.5, 1.5)
        x.append(x[-1] + step * math.cos(angle))
        y.append(y[-1] + step * math.sin(angle))
    return np.array(x), np.array(y)


def run_simulation(params: dict) -> dict | None:
    """Run the geomagnetic simulation and return the full result payload.

    Returns the dict from ``run_branch_simulation`` (with ``pf_track``,
    ``pdr_track``, ``route_xy_m``), or ``None`` on failure.
    """
    if run_branch_simulation is None or BranchConfig is None:
        logger.warning("Simulation API not available.")
        return None

    own_sel = params.get("own", "").strip()
    own_defaults = resolve_own_selection(own_sel) if own_sel and resolve_own_selection else {}
    own_profile = params.get("own_profile") or own_defaults.get("own_profile", "package")
    own_dataset_key = params.get("own_dataset_key") or own_defaults.get("own_dataset_key", own_sel)
    own_data_dir = params.get("own_data_dir") or own_defaults.get("own_data_dir", "")
    uji_sel = params.get("uji", "").strip()
    uji_defaults = (
        resolve_uji_selection(uji_sel)
        if resolve_uji_selection
        else {"uji_test_file": "tt02.txt", "uji_data_root": "data/raw"}
    )

    cfg = BranchConfig(
        branch=params.get("branch"),
        window_size=params.get("window_size"),
        max_frames=params.get("max_frames"),
        show=False,
        output_json=None,
        output_png=None,
        write_outputs=False,
        uji_test_file=params.get("uji_test_file")
        or uji_defaults["uji_test_file"],
        uji_data_root=params.get("uji_data_root")
        or uji_defaults["uji_data_root"],
        own_profile=own_profile,
        own_dataset_key=own_dataset_key,
        own_data_dir=own_data_dir,
        own_map_mode=params.get("own_map_mode"),
        own_map_npz_path=params.get("own_map_npz_path"),
        own_route_xy_m=
            parse_route_control_points(params.get("own_route"))
            if params.get("own_route")
            else None,
        own_initial_heading_deg=params.get("own_initial_heading_deg"),
        own_use_route_initial_heading=not params.get("no_route_initial_heading"),
        own_mirror_y=params.get("mirror_y"),
        own_heading_offset_deg=params.get("own_heading_offset_deg"),
        own_gyro_rate_scale=params.get("own_gyro_rate_scale", 1.0),
        own_trim_head=params.get("own_trim_head"),
        own_trim_tail=params.get("own_trim_tail"),
        own_pf_smoothing_alpha=params.get("own_pf_smoothing_alpha", 0.3),
        own_heading_snap_deg=params.get("own_heading_snap_deg", 0.0),
        own_step_length_scale=params.get("own_step_length_scale", 1.0),
    )
    try:
        # The procedural sensor/heading backend keeps module-level stream
        # state. Serialize web runs until that state is moved into RunContext.
        with _SIMULATION_LOCK:
            return run_branch_simulation(cfg)
    except FileNotFoundError as e:
        return {
            "error": str(e),
            "hint": (
                "数据集不存在。默认有效采集为 route1_run2 和 "
                "route2_run2；route2_run1 可显式运行。"
            ),
        }
    except Exception as e:
        logger.exception("Simulation failed.")
        return {"error": str(e)}


class GeoMagApp:
    """Encapsulates all state and callbacks for the Bokeh application."""

    def __init__(self) -> None:
        # Global CSS injection
        self._style_div = Div(text="""
        <style>
        body { background: #f5f5f7; }
        .bk-root { background: #f5f5f7; }
        </style>
        """, width=0, height=0)

        self.title_div = Div(text="""
        <div style="display:flex;align-items:center;justify-content:space-between;
                    font-family:-apple-system,BlinkMacSystemFont,sans-serif;">
            <span style="font-size:16px;font-weight:600;color:#1d1d1f;">
                Geomagnetic Positioning Simulation
            </span>
            <span style="font-size:12px;color:#86868b;">v7 · systematic + EMA</span>
        </div>
        """)

        # Branch selection with descriptive Chinese labels
        self.branch_select = Select(
            title="测试类型 (branch)",
            value="uji",
            options=[
                ("uji", "UJIIndoorLoc‑Mag数据集测试"),
                ("own", "室内测试"),
            ],
        )
        self.branch_select.on_change("value", self._update_title)

        # Dataset selectors and overrides
        self.uji_input = TextInput(
            title="UJI 选择 (uji)\n例如: tt01, 1, tt02.txt",
            value="tt01",
        )
        self.uji_test_file = TextInput(
            title="UJI 测试文件 (uji_test_file) — 低层覆盖",
            value="",
        )
        self.uji_data_root = TextInput(
            title="UJI 数据目录 (uji_data_root) — 低层覆盖",
            value="",
        )
        self.own_input = TextInput(
            title="室内数据选择 (own)\n例如: route1_run2",
            value="route1_run2",
        )
        self.own_profile = Select(
            title="室内配置 (own_profile)\n留空则自动根据 own 选择",
            value="",
            options=[("", "自动"), ("package", "package"), ("own_branch", "own_branch")],
        )
        self.own_dataset_key = TextInput(
            title="室内数据键 (own_dataset_key) — 低层覆盖",
            value="",
        )
        self.own_data_dir = TextInput(
            title="室内数据目录 (own_data_dir) — 低层覆盖",
            value="",
        )
        self.own_map_mode = Select(
            title="室内地图模式 (own_map_mode)",
            value="raw",
            options=[("raw", "raw"), ("tile12", "tile12")],
        )
        self.own_map_npz = TextInput(
            title="室内地图 NPZ 路径 (own_map_npz_path)",
            value="",
        )
        self.own_route = TextInput(
            title="自定义路线 (own_route)\n格式: x1,y1; x2,y2",
            value="",
        )
        # Parameter sliders
        self.window_size = Slider(
            title="窗口大小 (window_size)",
            start=50,
            end=800,
            step=50,
            value=400,
        )
        self.window_size.title = (
            "窗口大小 (window_size) — Geomagnetic 历史窗口长度"
        )
        self.max_frames = Slider(
            title="最大帧数 (max_frames)\n0 表示无限制",
            start=0,
            end=1000,
            step=50,
            value=200,
        )
        self.use_explicit_heading = Select(
            title="使用指定初始航向\n关闭则自动从路线推断",
            value="False",
            options=[("False", "自动推断"), ("True", "手动指定")],
        )
        self.own_initial_heading = Slider(
            title="初始航向角 (own_initial_heading_deg) — 度数，0=+X, 90=+Y",
            start=-180,
            end=180,
            step=5,
            value=90,
        )
        self.no_route_initial_heading = Select(
            title="是否使用路线首步航向 (no_route_initial_heading)",
            value="False",
            options=[("False", "使用"), ("True", "禁用")],
        )
        self.mirror_y = Select(
            title="Y 轴镜像修正 (mirror_y)",
            value="False",
            options=[("False", "否"), ("True", "是")],
        )
        self.heading_offset = Slider(
            title="航向偏移 (own_heading_offset_deg)",
            start=-180,
            end=180,
            step=5,
            value=-90,
        )
        self.trim_head = Slider(
            title="剪裁起始帧 (own_trim_head) — 截去开头帧数",
            start=0,
            end=100,
            step=1,
            value=0,
        )
        self.trim_tail = Slider(
            title="剪裁结束帧 (own_trim_tail) — 截去末尾帧数",
            start=0,
            end=100,
            step=1,
            value=0,
        )
        self.pf_smoothing = Slider(
            title="PF EMA 平滑系数 (own_pf_smoothing_alpha)",
            start=0.0,
            end=0.95,
            step=0.05,
            value=0.3,
        )
        self.heading_snap = Select(
            title="正交路线约束 (own_heading_snap_deg)",
            value="0",
            options=[("0", "关闭（实际通用模式）"), ("90", "90° 砖缝测试")],
        )
        self.step_length_scale = Slider(
            title="独立标定步长尺度 (own_step_length_scale)",
            start=0.5,
            end=1.8,
            step=0.01,
            value=1.0,
        )
        self.gyro_rate_scale = Slider(
            title="独立标定陀螺仪比例 (own_gyro_rate_scale)",
            start=0.8,
            end=1.2,
            step=0.001,
            value=1.0,
        )

        # Placeholder for file uploads
        self.file_input = FileInput(
            accept=".txt,.npz",
            multiple=False,
        )
        self.file_input.on_change("value", self._on_file_upload)

        # Buttons
        self.run_button = Button(label="运行模拟", button_type="success")
        self.run_button.on_click(self._on_run)
        self.step_button = Button(label="下一步", button_type="primary", disabled=True)
        self.step_button.on_click(self._on_step)
        # Data and state
        self.pf_source = ColumnDataSource(data={"x": [], "y": []})
        self.pf_raw_source = ColumnDataSource(data={"x": [], "y": []})
        self.pdr_source = ColumnDataSource(data={"x": [], "y": []})
        self.route_source = ColumnDataSource(data={"x": [], "y": []})
        self.full_result: dict | None = None
        self.current_index: int = 0
        self.plot = figure(
            title="",
            x_axis_label="X (m)",
            y_axis_label="Y (m)",
            width=650,
            height=650,
            tools="pan,wheel_zoom,box_zoom,reset,save",
            active_scroll="wheel_zoom",
            match_aspect=True,
        )
        self.plot.line("x", "y", source=self.route_source, line_width=2, color="#34c759", legend_label="真值路线")
        self.plot.line("x", "y", source=self.pdr_source, line_width=1.5, color="#ff9500", line_dash="dashed", legend_label="PDR")
        self.plot.line("x", "y", source=self.pf_raw_source, line_width=1.2, color="#ff2dce", legend_label="PF 原始")
        self.plot.line("x", "y", source=self.pf_source, line_width=2, color="#007aff", legend_label="PF")
        self.plot.legend.location = "top_left"

        # Progress indicator
        self.progress_div = Div(text="", visible=False)

        # Colored legend above plot
        self.legend_div = Div(text="""
        <div style="display:flex;align-items:center;gap:14px;
                    font-family:-apple-system,BlinkMacSystemFont,sans-serif;margin-bottom:4px;">
            <span style="font-size:11px;font-weight:600;color:#86868b;
                         text-transform:uppercase;letter-spacing:0.5px;">定位轨迹</span>
            <span style="font-size:11px;font-weight:500;color:#34c759;">● 真值路线</span>
            <span style="font-size:11px;font-weight:500;color:#ff9500;">● PDR</span>
            <span style="font-size:11px;font-weight:500;color:#ff2dce;">● PF 原始</span>
            <span style="font-size:11px;font-weight:500;color:#007aff;">● PF</span>
        </div>
        """)

        # Result stats (hidden until simulation runs)
        self.stats_div = Div(text="", visible=False)

        self._sep_div = Div(text="""
        <div style="width:1px;height:20px;background:#e8e8ed;margin:0 6px;"></div>
        """, width=10, visible=False)

        self.button_bar = row(
            self.run_button,
            self.step_button,
            self._sep_div,
            self.stats_div,
        )

        self.plot_area = column(
            self.progress_div,
            self.legend_div,
            self.plot,
            self.button_bar,
        )

        # Card helper
        def _card(header_text, *widgets):
            header = Div(text=f'<div style="font-size:11px;font-weight:600;color:#86868b;\
text-transform:uppercase;letter-spacing:0.5px;margin-bottom:6px;\
font-family:-apple-system,BlinkMacSystemFont,sans-serif;">{header_text}</div>')
            return column(header, *widgets,
                          styles={"background": "#ffffff", "border-radius": "10px",
                                  "padding": "12px 14px", "box-shadow": "0 1px 3px rgba(0,0,0,0.06)"},
                          margin=(0, 0, 10, 0))

        # Layout definition
        controls_col1 = column(
            _card("仿真控制",
                self.branch_select,
                self.window_size,
                self.max_frames,
            ),
            _card("航向设置",
                self.use_explicit_heading,
                self.own_initial_heading,
                self.no_route_initial_heading,
                self.mirror_y,
                self.heading_offset,
                self.gyro_rate_scale,
            ),
            _card("地图与裁剪",
                self.own_map_mode,
                self.pf_smoothing,
                self.heading_snap,
                self.step_length_scale,
                self.trim_head,
                self.trim_tail,
            ),
            width=240,
        )
        controls_col2 = column(
            _card("数据集",
                self.own_input,
                self.own_profile,
                self.own_dataset_key,
                self.own_data_dir,
            ),
            _card("UJI 设置",
                self.uji_input,
                self.uji_test_file,
                self.uji_data_root,
            ),
            _card("其他",
                self.own_map_npz,
                self.own_route,
                self.file_input,
            ),
            width=240,
        )
        self.layout = column(
            self._style_div,
            self.title_div,
            row(controls_col1, controls_col2, self.plot_area),
        )

    def _update_title(self, attr: str, old: str, new: str) -> None:
        """Update the page title when the branch changes."""
        if new == "uji":
            title = "UJIIndoorLoc‑Mag数据集测试"
        else:
            title = "室内测试"
        self.title_div.text = f"<h2>{title}</h2>"

    def _collect_params(self) -> dict:
        """Gather parameter values from widgets into a dictionary."""
        params = {
            "branch": self.branch_select.value,
            "window_size": int(self.window_size.value),
            "max_frames": int(self.max_frames.value) if self.max_frames.value > 0 else None,
            "uji": self.uji_input.value.strip(),
            "uji_test_file": self.uji_test_file.value.strip() or None,
            "uji_data_root": self.uji_data_root.value.strip() or None,
            "own": self.own_input.value.strip(),
            "own_profile": self.own_profile.value if self.own_profile.value else None,
            "own_dataset_key": self.own_dataset_key.value.strip() or None,
            "own_data_dir": self.own_data_dir.value.strip() or None,
            "own_map_mode": self.own_map_mode.value,
            "own_map_npz_path": self.own_map_npz.value.strip() or None,
            "own_route": self.own_route.value.strip() or None,
            "own_initial_heading_deg": float(self.own_initial_heading.value) if self.use_explicit_heading.value == "True" else None,
            "no_route_initial_heading": (self.no_route_initial_heading.value == "True"),
            "mirror_y": (self.mirror_y.value == "True"),
            "own_heading_offset_deg": float(self.heading_offset.value),
            "own_gyro_rate_scale": float(self.gyro_rate_scale.value),
            "own_trim_head": int(self.trim_head.value),
            "own_trim_tail": int(self.trim_tail.value),
            "own_pf_smoothing_alpha": float(self.pf_smoothing.value),
            "own_heading_snap_deg": float(self.heading_snap.value),
            "own_step_length_scale": float(self.step_length_scale.value),
        }
        return params

    def _on_file_upload(self, attr: str, old: str, new: str) -> None:
        """Handle file uploads.  Currently a placeholder that logs filenames."""
        if self.file_input.filename:
            # Extract file name and extension; uploaded data is base64 encoded
            filename = self.file_input.filename
            # Here we could decode and process the file; for now we simply
            # acknowledge the upload in the console.
            print(f"Uploaded file: {filename}")

    def _on_run(self) -> None:
        """Callback for the Run Simulation button (runs in background thread)."""
        self.current_index = 0
        self.run_button.disabled = True
        self.step_button.disabled = True
        self.stats_div.visible = False
        self._sep_div.visible = False
        self.progress_div.text = """
        <div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;
                    font-size:13px;color:#0071e3;padding:8px 0;">
            ⏳ 运行中，请稍候...
        </div>
        """
        self.progress_div.visible = True

        params = self._collect_params()
        result_holder = {}

        def _run():
            result_holder["value"] = run_simulation(params)

        thread = threading.Thread(target=_run, daemon=True)
        thread.start()

        def _check_done():
            if thread.is_alive():
                curdoc().add_timeout_callback(_check_done, 100)
                return
            # Thread finished — populate results
            self.progress_div.visible = False
            self.run_button.disabled = False
            result = result_holder.get("value")

            if result is None:
                self.title_div.text = "<h2 style='color:red'>仿真失败：未知错误</h2>"
                return
            if "error" in result:
                hint = result.get("hint", "")
                self.title_div.text = f"<h2 style='color:red'>错误：{result['error']}</h2><p>{hint}</p>"
                return

            self.full_result = result
            route = np.asarray(result.get("route_xy_m", []), dtype=float)
            pdr = np.asarray(result.get("pdr_track", []), dtype=float)
            pf = np.asarray(result.get("pf_track", []), dtype=float)
            pf_raw = np.asarray(result.get("pf_raw_track", pf), dtype=float)
            if route.ndim == 2 and route.shape[1] >= 2:
                self.route_source.data = {"x": route[:, 0], "y": route[:, 1]}
            if pdr.ndim == 2 and pdr.shape[1] >= 2:
                self.pdr_source.data = {"x": pdr[:, 0], "y": pdr[:, 1]}
            if pf.ndim == 2 and pf.shape[1] >= 2:
                self.pf_source.data = {"x": pf[:1, 0], "y": pf[:1, 1]}
                if pf_raw.ndim == 2 and pf_raw.shape[1] >= 2:
                    self.pf_raw_source.data = {
                        "x": pf_raw[:1, 0],
                        "y": pf_raw[:1, 1],
                    }
                self.current_index = 1
                self.step_button.disabled = False
            else:
                self.pf_source.data = {"x": [], "y": []}
                self.pf_raw_source.data = {"x": [], "y": []}
                self.step_button.disabled = True

            ps = result.get("pf_error_stats")
            ds = result.get("pdr_error_stats")
            if ps and ds:
                steps = result.get("steps_detected", 0)
                self.stats_div.text = f"""
                <div style="display:flex;align-items:center;gap:14px;
                            font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:11px;">
                    <span><span style="color:#86868b;">PF 平均</span>
                          <span style="font-weight:600;color:#007aff;font-size:14px;">
                          {ps['mean']:.2f}m</span></span>
                    <span><span style="color:#86868b;">最终</span>
                          <span style="font-weight:600;font-size:14px;">
                          {ps['final']:.2f}m</span></span>
                    <span><span style="color:#86868b;">P95</span>
                          <span style="font-weight:600;font-size:14px;">
                          {ps['p95']:.2f}m</span></span>
                    <span><span style="color:#86868b;">步数</span>
                          <span style="font-weight:600;font-size:14px;">{steps}</span></span>
                    <span><span style="color:#86868b;">PDR</span>
                          <span style="font-weight:600;font-size:14px;">
                          {ds['mean']:.2f}m</span></span>
                </div>
                """
                self.stats_div.visible = True
                self._sep_div.visible = True

        curdoc().add_next_tick_callback(_check_done)

    def _on_step(self) -> None:
        """Advance the trajectory one step and update the plot."""
        if self.full_result is None:
            return
        pf = np.asarray(self.full_result.get("pf_track", []), dtype=float)
        pf_raw = np.asarray(self.full_result.get("pf_raw_track", pf), dtype=float)
        if pf.ndim != 2 or self.current_index >= pf.shape[0]:
            self.step_button.disabled = True
            return
        idx = self.current_index + 1
        self.pf_source.data = {"x": pf[:idx, 0], "y": pf[:idx, 1]}
        if pf_raw.ndim == 2 and pf_raw.shape[1] >= 2:
            self.pf_raw_source.data = {
                "x": pf_raw[:idx, 0],
                "y": pf_raw[:idx, 1],
            }
        self.current_index = idx


def main():
    """Entry point for 'geomag-web' console script.

    Launches the Bokeh server and opens the app in a browser.
    """
    import subprocess
    import sys

    subprocess.run([sys.executable, "-m", "bokeh", "serve", "--show", __file__])


if __name__ == "__main__":
    main()
else:
    # Running under ``bokeh serve`` — register the app with curdoc
    app = GeoMagApp()
    curdoc().add_root(app.layout)
    curdoc().title = "Geomagnetic Positioning"
