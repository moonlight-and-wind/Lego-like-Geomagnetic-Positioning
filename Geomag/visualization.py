"""Visualization for geomagnetic positioning results.

Renders maps, trajectories, sensor streams, error plots, and
particle-count diagnostics via matplotlib.
"""

import re
from pathlib import Path

import numpy as np

from Geomag.algorithms import _bool_from_any, _fit_ordinary_kriging, _safe_float
from Geomag.distance import _latlon_to_xy

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _sensor_selector_set(group_tokens):
    valid = {
        "sensor", "acc", "gyro", "mag",
        "acc_x", "acc_y", "acc_z",
        "gyro_x", "gyro_y", "gyro_z",
        "mag_x", "mag_y", "mag_z",
    }
    return [token for token in group_tokens if token in valid]


def _expand_sensor_selectors(selectors):
    expanded = set()
    if "sensor" in selectors:
        expanded.update([
            "acc_x", "acc_y", "acc_z",
            "gyro_x", "gyro_y", "gyro_z",
            "mag_x", "mag_y", "mag_z",
        ])
    if "acc" in selectors:
        expanded.update(["acc_x", "acc_y", "acc_z"])
    if "gyro" in selectors:
        expanded.update(["gyro_x", "gyro_y", "gyro_z"])
    if "mag" in selectors:
        expanded.update(["mag_x", "mag_y", "mag_z"])
    for selector in selectors:
        if selector in {
            "acc_x", "acc_y", "acc_z",
            "gyro_x", "gyro_y", "gyro_z",
            "mag_x", "mag_y", "mag_z",
        }:
            expanded.add(selector)
    return sorted(expanded)


def _coerce_sensor_data(sensor_data):
    if sensor_data is None:
        raise ValueError("`sensor_data` is required when meta includes sensor-related options.")
    if isinstance(sensor_data, dict):
        t = np.asarray(sensor_data.get("t", []), dtype=float)
        acc = np.asarray(sensor_data.get("acc", []), dtype=float)
        gyro = np.asarray(sensor_data.get("gyro", []), dtype=float)
        mag = np.asarray(sensor_data.get("mag", []), dtype=float)
    else:
        raise ValueError("`sensor_data` must be a dict with keys: t, acc, gyro, mag.")

    if t.ndim != 1 or t.size == 0:
        raise ValueError("`sensor_data['t']` must be a non-empty 1D sequence.")
    for name, arr in [("acc", acc), ("gyro", gyro), ("mag", mag)]:
        if arr.ndim != 2 or arr.shape[0] != t.size or arr.shape[1] != 3:
            raise ValueError(
                f"`sensor_data['{name}']` must be shape (N, 3), same N as `t`."
            )
    return t, acc, gyro, mag


def _to_xy_route(route, origin_lat=None, origin_lon=None):
    arr = np.asarray(route, dtype=float)
    if arr.ndim != 2 or arr.shape[1] < 2:
        raise ValueError("`route` must be a 2D sequence with at least 2 columns.")
    a = arr[:, 0]
    b = arr[:, 1]
    if origin_lat is not None and origin_lon is not None:
        x, y = _latlon_to_xy(a, b, float(origin_lat), float(origin_lon))
        return np.asarray(x, dtype=float), np.asarray(y, dtype=float), "xy"
    return np.asarray(b, dtype=float), np.asarray(a, dtype=float), "latlon"


def _to_xy_assume_xy(route):
    arr = np.asarray(route, dtype=float)
    if arr.ndim != 2 or arr.shape[1] < 2:
        raise ValueError("`route` must be a 2D sequence with at least 2 columns.")
    return np.asarray(arr[:, 0], dtype=float), np.asarray(arr[:, 1], dtype=float), "xy"


def _load_uji_grid_for_plot(geomag_map, vis_resolution):
    model = None
    grid = None
    if isinstance(geomag_map, dict) and "output_model_npz" in geomag_map:
        model_path = Path(geomag_map["output_model_npz"])
        if model_path.exists():
            model = np.load(model_path)
            try:
                x_train = np.asarray(model["x_train"], dtype=float)
                y_train = np.asarray(model["y_train"], dtype=float)
                z_train = np.asarray(model["z_train"], dtype=float)
                variogram_model = str(model["variogram_model"][0])
                min_x = float(model["min_x"][0])
                max_x = float(model["max_x"][0])
                min_y = float(model["min_y"][0])
                max_y = float(model["max_y"][0])
                grid_x = np.arange(min_x, max_x + vis_resolution, vis_resolution, dtype=float)
                grid_y = np.arange(min_y, max_y + vis_resolution, vis_resolution, dtype=float)
                ok = _fit_ordinary_kriging(
                    x=x_train, y=y_train, z=z_train, variogram_model=variogram_model,
                )
                grid_z, _ = ok.execute("grid", grid_x, grid_y)
                grid = (
                    np.asarray(grid_x, dtype=float),
                    np.asarray(grid_y, dtype=float),
                    np.asarray(grid_z, dtype=float),
                )
                return model, grid
            except Exception:
                pass

    preview_paths = []
    if isinstance(geomag_map, dict) and "output_preview_npz" in geomag_map:
        preview_paths.append(Path(geomag_map["output_preview_npz"]))
    preview_paths.append(Path("data/processed/uji_mag_grid_preview_kriging.npz"))

    for p in preview_paths:
        if p.exists():
            data = np.load(p)
            grid_x = np.asarray(data["grid_x"], dtype=float)
            grid_y = np.asarray(data["grid_y"], dtype=float)
            grid_z = np.asarray(data["grid_magnitude"], dtype=float)
            return model, (grid_x, grid_y, grid_z)

    raise ValueError("Unable to load UJI map grid (missing model/preview artifacts).")


def _save_figure(fig, output_png, fig_idx, multi):
    if not output_png:
        return None
    target = Path(output_png)
    target.parent.mkdir(parents=True, exist_ok=True)
    if multi:
        stem = target.stem
        suffix = target.suffix or ".png"
        out = target.with_name(f"{stem}_{fig_idx + 1}{suffix}")
    else:
        out = target
    fig.savefig(out, bbox_inches="tight")
    return str(out)


def _default_visualize_output_png(mode, meta):
    out_dir = Path("pictures generated")
    out_dir.mkdir(parents=True, exist_ok=True)
    items = [str(x).strip().lower().rstrip("_") for x in (meta or []) if str(x).strip()]
    safe_items = [re.sub(r"[^a-z0-9]+", "-", token).strip("-") for token in items]
    safe_items = [token for token in safe_items if token]
    stem = f"{mode}-{'-'.join(safe_items)}" if safe_items else str(mode)
    candidate = out_dir / f"{stem}.png"
    index = 0
    while candidate.exists():
        index += 1
        candidate = out_dir / f"{stem}-{index}.png"
    return str(candidate)


# ---------------------------------------------------------------------------
# Public visualization router
# ---------------------------------------------------------------------------

def visualize(
    pos_list=None,
    pdr_list=None,
    route=None,
    geomag_map=None,
    mode="track",
    vis_resolution=0.2,
    meta=None,
    sensor_data=None,
    error_series=None,
    pdr_error_series=None,
    particle_counts=None,
    show=True,
    output_png=None,
):
    """Render geomagnetic positioning results.

    Parameters
    ----------
    mode : str
        ``"ujimap"`` for UJI map + trajectories + error + sensors;
        ``"usermap"`` for own-data continuous Kriging map.
    """
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise ImportError(
            "matplotlib is required for visualization. Install it with: pip install matplotlib"
        ) from exc

    mode = str(mode).lower()
    if output_png is None:
        output_png = _default_visualize_output_png(mode=mode, meta=meta)

    if mode == "ujimap":
        return _render_ujimap(
            pos_list=pos_list, pdr_list=pdr_list, route=route,
            geomag_map=geomag_map, vis_resolution=vis_resolution,
            meta=meta, sensor_data=sensor_data,
            error_series=error_series, pdr_error_series=pdr_error_series,
            particle_counts=particle_counts,
            show=show, output_png=output_png,
        )

    if mode == "usermap":
        return _render_usermap(
            geomag_map=geomag_map, vis_resolution=vis_resolution,
            meta=meta, show=show, output_png=output_png,
        )

    return None


# ---------------------------------------------------------------------------
# Mode-specific renderers
# ---------------------------------------------------------------------------

def _render_ujimap(
    pos_list, pdr_list, route, geomag_map, vis_resolution,
    meta, sensor_data, error_series, pdr_error_series, particle_counts,
    show, output_png,
):
    import matplotlib.pyplot as plt

    if meta is None:
        defaults = ["map"]
        if route is not None:
            defaults.append("true_route")
        if pos_list is not None:
            defaults.append("predicted")
        if pdr_list is not None:
            defaults.append("pdr")
        if pos_list is not None and route is not None:
            defaults.append("error")
        if particle_counts is not None:
            defaults.append("particles")
        items = defaults
    else:
        items = [str(x).strip().lower().rstrip("_") for x in meta if str(x).strip()]

    group_set = set(items)
    has_map = "map" in group_set
    has_true_route = "true_route" in group_set
    has_predicted = ("predicted" in group_set) or ("estimate" in group_set)
    has_pdr = "pdr" in group_set
    has_error_plot = "error" in group_set
    has_particles_plot = "particles" in group_set
    sensor_selectors = _sensor_selector_set(items)
    has_sensor_plot = len(sensor_selectors) > 0

    if not (has_map or has_true_route or has_predicted or has_pdr or has_sensor_plot or has_error_plot or has_particles_plot):
        raise ValueError(f"Unsupported ujimap meta options: {items}")

    panel_order = []
    if has_map or has_true_route or has_predicted or has_pdr:
        panel_order.append("map")
    if has_sensor_plot:
        panel_order.append("sensor")
    if has_error_plot:
        panel_order.append("error")
    if has_particles_plot:
        panel_order.append("particles")
    ncols = max(1, len(panel_order))
    fig, axes = plt.subplots(1, ncols, figsize=(6 * ncols, 5), dpi=120)
    if ncols == 1:
        axes = [axes]
    panel_axes = {name: axes[i] for i, name in enumerate(panel_order)}
    ax_map = panel_axes.get("map")
    ax_sensor = panel_axes.get("sensor")
    ax_error = panel_axes.get("error")
    ax_particles = panel_axes.get("particles")

    model = None
    origin_lat = None
    origin_lon = None
    if has_map and ax_map is not None:
        model, (grid_x, grid_y, grid_z) = _load_uji_grid_for_plot(geomag_map, vis_resolution)
        xx, yy = np.meshgrid(grid_x, grid_y)
        contour = ax_map.contourf(xx, yy, grid_z, levels=80, cmap="viridis")
        cbar = fig.colorbar(contour, ax=ax_map)
        cbar.set_label("Magnetic Magnitude")
        ax_map.set_xlabel("X (m)")
        ax_map.set_ylabel("Y (m)")
        ax_map.set_title("UJI Map")
        if model is not None and "origin_lat" in model and "origin_lon" in model:
            origin_lat = float(model["origin_lat"][0])
            origin_lon = float(model["origin_lon"][0])

    legend_enabled = False

    if has_true_route and ax_map is not None:
        if route is None:
            raise ValueError("`route` is required when meta includes 'true_route'.")
        if origin_lat is not None and origin_lon is not None:
            rx, ry, _ = _to_xy_route(route, origin_lat=origin_lat, origin_lon=origin_lon)
            ax_map.plot(rx, ry, color="red", linewidth=2.0, label="True Route")
        else:
            rx, ry, _ = _to_xy_route(route, origin_lat=None, origin_lon=None)
            ax_map.set_xlabel("Longitude (deg)")
            ax_map.set_ylabel("Latitude (deg)")
            ax_map.plot(rx, ry, color="red", linewidth=2.0, label="True Route")

        if len(route) > 0:
            ax_map.scatter([rx[0]], [ry[0]], color="lime", s=30, label="Start", zorder=3)
            ax_map.scatter([rx[-1]], [ry[-1]], color="black", s=30, label="End", zorder=3)
        legend_enabled = True

    if has_predicted and ax_map is not None:
        if pos_list is None:
            raise ValueError("`pos_list` is required when meta includes 'predicted'.")
        px, py, _ = _to_xy_assume_xy(pos_list)
        ax_map.plot(px, py, color="cyan", linewidth=1.7, label="Predicted")
        if len(px) > 0:
            ax_map.scatter([px[0]], [py[0]], color="deepskyblue", s=24, zorder=3)
        legend_enabled = True

    if has_pdr and ax_map is not None:
        if pdr_list is None:
            raise ValueError("`pdr_list` is required when meta includes 'pdr'.")
        qx, qy, _ = _to_xy_assume_xy(pdr_list)
        ax_map.plot(qx, qy, color="orange", linewidth=1.5, linestyle="--", label="PDR")
        if len(qx) > 0:
            ax_map.scatter([qx[0]], [qy[0]], color="goldenrod", s=22, zorder=3)
        legend_enabled = True

    if ax_map is not None:
        base_title = "UJI Map" if has_map else "Trajectories"
        overlays = []
        if has_true_route:
            overlays.append("True Route")
        if has_predicted:
            overlays.append("Predicted")
        if has_pdr:
            overlays.append("PDR")
        if overlays:
            ax_map.set_title(f"{base_title} + " + " + ".join(overlays))
        else:
            ax_map.set_title(base_title)
        if legend_enabled:
            ax_map.legend(loc="best")

    if has_sensor_plot and ax_sensor is not None:
        t, acc, gyro, mag = _coerce_sensor_data(sensor_data)
        channels = _expand_sensor_selectors(sensor_selectors)
        for channel in channels:
            sensor_name, axis_name = channel.split("_")
            axis_idx = {"x": 0, "y": 1, "z": 2}[axis_name]
            if sensor_name == "acc":
                values = acc[:, axis_idx]
            elif sensor_name == "gyro":
                values = gyro[:, axis_idx]
            else:
                values = mag[:, axis_idx]
            ax_sensor.plot(t, values, linewidth=1.0, label=channel)

        ax_sensor.set_title("Sensor Data")
        ax_sensor.set_xlabel("Sample / Time Axis")
        ax_sensor.set_ylabel("Value")
        ax_sensor.grid(True, alpha=0.25)
        ax_sensor.legend(loc="best", ncol=2, fontsize=8)

    if has_error_plot and ax_error is not None:
        def _compute_track_error(track_list):
            tx, ty, _ = _to_xy_assume_xy(track_list)
            rx2, ry2, _ = _to_xy_route(route, origin_lat=origin_lat, origin_lon=origin_lon)
            if rx2.size == 0 or tx.size == 0:
                return np.asarray([], dtype=float)
            route_distance = np.concatenate(
                [[0.0], np.cumsum(np.hypot(np.diff(rx2), np.diff(ry2)))]
            )
            if route_distance[-1] <= 1e-12:
                ref_x2 = np.full(tx.size, rx2[0], dtype=float)
                ref_y2 = np.full(ty.size, ry2[0], dtype=float)
            else:
                query = np.linspace(0.0, route_distance[-1], num=tx.size)
                ref_x2 = np.interp(query, route_distance, rx2)
                ref_y2 = np.interp(query, route_distance, ry2)
            return np.sqrt((tx - ref_x2) ** 2 + (ty - ref_y2) ** 2)

        pf_err = None
        pdr_err = None

        if error_series is not None:
            pf_err = np.asarray(error_series, dtype=float).reshape(-1)
            if pf_err.size == 0:
                raise ValueError("`error_series` must be non-empty when provided.")
        elif pos_list is not None and route is not None:
            pf_err = _compute_track_error(pos_list)

        if pdr_error_series is not None:
            pdr_err = np.asarray(pdr_error_series, dtype=float).reshape(-1)
            if pdr_err.size == 0:
                raise ValueError("`pdr_error_series` must be non-empty when provided.")
        elif pdr_list is not None and route is not None:
            pdr_err = _compute_track_error(pdr_list)

        if (pf_err is None or pf_err.size == 0) and (pdr_err is None or pdr_err.size == 0):
            raise ValueError(
                "Need (`pos_list` and `route`) and/or (`pdr_list` and `route`) to compute error plot, "
                "or provide `error_series` / `pdr_error_series`."
            )

        if pf_err is not None and pf_err.size > 0:
            ax_error.plot(
                np.arange(pf_err.size), pf_err,
                color="crimson", linewidth=1.8,
                marker="o" if pf_err.size < 2 else None, markersize=4,
                label="PF Error",
            )
        if pdr_err is not None and pdr_err.size > 0:
            ax_error.plot(
                np.arange(pdr_err.size), pdr_err,
                color="orange", linestyle="--", linewidth=1.8,
                marker="o" if pdr_err.size < 2 else None, markersize=4,
                label="PDR Error",
            )

        ax_error.set_title("Euclidean Error")
        ax_error.set_xlabel("Iteration")
        ax_error.set_ylabel("Distance")
        ax_error.grid(True, alpha=0.3)
        if (pf_err is not None and pf_err.size > 0) or (pdr_err is not None and pdr_err.size > 0):
            ax_error.legend(loc="best")

    if has_particles_plot and ax_particles is not None:
        if particle_counts is None:
            raise ValueError("`particle_counts` is required when meta includes 'particles'.")
        counts = np.asarray(particle_counts, dtype=float).reshape(-1)
        if counts.size == 0:
            raise ValueError("`particle_counts` must be non-empty.")
        ax_particles.plot(np.arange(counts.size), counts, color="teal", linewidth=1.8)
        ax_particles.set_title("Particle Count")
        ax_particles.set_xlabel("Iteration")
        ax_particles.set_ylabel("Num Particles")
        ax_particles.grid(True, alpha=0.3)

    fig.tight_layout()
    saved_path = _save_figure(fig, output_png, 0, False)
    if show:
        plt.show()
    plt.close(fig)
    return saved_path


def _render_usermap(geomag_map, vis_resolution, meta, show, output_png):
    import matplotlib.pyplot as plt

    items = [str(x).strip().lower().rstrip("_") for x in (meta or ["map"]) if str(x).strip()]
    if "map" not in items:
        raise ValueError("mode='usermap' currently supports map rendering only; include 'map' in meta.")
    if not isinstance(geomag_map, dict):
        raise ValueError("`geomag_map` must be a dict for mode='usermap'.")
    if geomag_map.get("source") != "own":
        raise ValueError("mode='usermap' requires own-map input from get_map(source='own').")
    grid_array = geomag_map.get("grid_array")
    if grid_array is None:
        raise ValueError("`grid_array` is missing. Provide a valid own_grid_array to get_map().")

    z = np.asarray(grid_array, dtype=float)
    if z.ndim != 2 or z.size == 0:
        raise ValueError("`grid_array` must be a non-empty 2D matrix.")

    meta_map = geomag_map.get("grid_map_contract", {}).get("meta", {})
    tile_size_x_m = _safe_float(meta_map.get("tile_size_x_m", meta_map.get("cell_size_m", 1.0)), 1.0)
    tile_size_y_m = _safe_float(meta_map.get("tile_size_y_m", meta_map.get("cell_size_m", 1.0)), 1.0)
    origin = meta_map.get("origin_xy_m", [0.0, 0.0])
    origin_x = float(origin[0]) if len(origin) > 0 else 0.0
    origin_y = float(origin[1]) if len(origin) > 1 else 0.0
    anchor = str(meta_map.get("anchor", "center")).strip().lower()
    if anchor not in {"center", "corner"}:
        anchor = "center"
    flip_y = _bool_from_any(meta_map.get("flip_y", True), default=True)
    variogram_model = str(meta_map.get("variogram_model", "spherical"))

    rows, cols = z.shape
    col_idx = np.arange(cols, dtype=float)
    row_idx = np.arange(rows, dtype=float)
    y_idx = (rows - 1.0 - row_idx) if flip_y else row_idx
    x_offset = 0.5 * tile_size_x_m if anchor == "center" else 0.0
    y_offset = 0.5 * tile_size_y_m if anchor == "center" else 0.0
    col_coords = origin_x + col_idx * tile_size_x_m + x_offset
    row_coords = origin_y + y_idx * tile_size_y_m + y_offset
    xx_train, yy_train = np.meshgrid(col_coords, row_coords)
    valid = np.isfinite(z)
    x_train = xx_train[valid]
    y_train = yy_train[valid]
    z_train = z[valid]
    if x_train.size < 4:
        raise ValueError("Need at least 4 valid matrix cells for Kriging-based continuous usermap.")

    min_x = float(origin_x)
    max_x = float(origin_x + cols * tile_size_x_m)
    min_y = float(origin_y)
    max_y = float(origin_y + rows * tile_size_y_m)
    grid_x = np.arange(min_x, max_x + vis_resolution, vis_resolution, dtype=float)
    grid_y = np.arange(min_y, max_y + vis_resolution, vis_resolution, dtype=float)
    ok = _fit_ordinary_kriging(x=x_train, y=y_train, z=z_train, variogram_model=variogram_model)
    grid_z, _ = ok.execute("grid", grid_x, grid_y)
    grid_z = np.asarray(grid_z, dtype=float)

    xx, yy = np.meshgrid(grid_x, grid_y)
    fig, ax = plt.subplots(figsize=(8, 6), dpi=120)
    contour = ax.contourf(xx, yy, grid_z, levels=80, cmap="viridis")
    ax.set_title("User Continuous Magnetic Map (Kriging)")
    ax.set_xlabel("X (m)")
    ax.set_ylabel("Y (m)")
    cbar = fig.colorbar(contour, ax=ax)
    cbar.set_label("Magnetic Magnitude")
    fig.tight_layout()
    saved_path = None
    if output_png:
        out = Path(output_png)
        out.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(out, bbox_inches="tight")
        saved_path = str(out)
    if show:
        plt.show()
    plt.close(fig)
    return saved_path
