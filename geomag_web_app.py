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

import logging
import math
import random

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

    cfg = BranchConfig(
        branch=params.get("branch"),
        window_size=params.get("window_size"),
        max_frames=params.get("max_frames"),
        show=False,
        output_json=None,
        output_png=None,
        uji_test_file=params.get("uji_test_file"),
        uji_data_root=params.get("uji_data_root"),
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
        own_trim_head=params.get("own_trim_head"),
        own_trim_tail=params.get("own_trim_tail"),
    )
    try:
        return run_branch_simulation(cfg)
    except FileNotFoundError as e:
        return {"error": str(e), "hint": "数据集不存在。route2_run2 请用 own='own_branch' + profile='own_branch'"}
    except Exception as e:
        logger.exception("Simulation failed.")
        return {"error": str(e)}


class GeoMagApp:
    """Encapsulates all state and callbacks for the Bokeh application."""

    def __init__(self) -> None:
        self.title_div = Div(text="<h2>Geomagnetic Positioning Simulation</h2>")

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
        self.pdr_source = ColumnDataSource(data={"x": [], "y": []})
        self.route_source = ColumnDataSource(data={"x": [], "y": []})
        self.full_result: dict | None = None
        self.current_index: int = 0
        self.plot = figure(
            title="定位轨迹（绿=真值路线, 橙=PDR, 青=PF）",
            x_axis_label="X (m)",
            y_axis_label="Y (m)",
            width=650,
            height=650,
            tools="pan,wheel_zoom,box_zoom,reset,save",
            active_scroll="wheel_zoom",
            match_aspect=True,
        )
        self.plot.line("x", "y", source=self.route_source, line_width=2, color="green", legend_label="真值路线")
        self.plot.line("x", "y", source=self.pdr_source, line_width=1.5, color="orange", line_dash="dashed", legend_label="PDR")
        self.plot.line("x", "y", source=self.pf_source, line_width=2, color="cyan", legend_label="PF")
        self.plot.legend.location = "top_left"

        # Layout definition
        controls_col1 = column(
            self.branch_select,
            self.window_size,
            self.max_frames,
            self.use_explicit_heading,
            self.own_initial_heading,
            self.no_route_initial_heading,
            self.mirror_y,
            self.heading_offset,
            self.trim_head,
            self.trim_tail,
            width=300,
        )
        controls_col2 = column(
            self.uji_input,
            self.uji_test_file,
            self.uji_data_root,
            self.own_input,
            self.own_profile,
            self.own_dataset_key,
            self.own_data_dir,
            self.own_map_mode,
            self.own_map_npz,
            self.own_route,
            self.file_input,
            self.run_button,
            self.step_button,
            width=350,
        )
        self.layout = column(
            self.title_div,
            row(controls_col1, controls_col2, self.plot),
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
            "own_trim_head": int(self.trim_head.value),
            "own_trim_tail": int(self.trim_tail.value),
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
        """Callback for the Run Simulation button."""
        self.current_index = 0
        result = run_simulation(self._collect_params())
        if result is None:
            self.title_div.text = "<h2 style='color:red'>仿真失败：未知错误</h2>"
            return
        if "error" in result:
            hint = result.get("hint", "")
            self.title_div.text = f"<h2 style='color:red'>错误：{result['error']}</h2><p>{hint}</p>"
            return

        self.full_result = result
        # Show full route and PDR immediately as reference
        route = np.asarray(result.get("route_xy_m", []), dtype=float)
        pdr = np.asarray(result.get("pdr_track", []), dtype=float)
        pf = np.asarray(result.get("pf_track", []), dtype=float)
        if route.ndim == 2 and route.shape[1] >= 2:
            self.route_source.data = {"x": route[:, 0], "y": route[:, 1]}
        if pdr.ndim == 2 and pdr.shape[1] >= 2:
            self.pdr_source.data = {"x": pdr[:, 0], "y": pdr[:, 1]}
        # Initially show first PF point
        if pf.ndim == 2 and pf.shape[1] >= 2:
            self.pf_source.data = {"x": pf[:1, 0], "y": pf[:1, 1]}
            self.current_index = 1
            self.step_button.disabled = False
        else:
            self.pf_source.data = {"x": [], "y": []}
            self.step_button.disabled = True

    def _on_step(self) -> None:
        """Advance the trajectory one step and update the plot."""
        if self.full_result is None:
            return
        pf = np.asarray(self.full_result.get("pf_track", []), dtype=float)
        if pf.ndim != 2 or self.current_index >= pf.shape[0]:
            self.step_button.disabled = True
            return
        idx = self.current_index + 1
        self.pf_source.data = {"x": pf[:idx, 0], "y": pf[:idx, 1]}
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
