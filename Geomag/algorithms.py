import json
import math
import re
import tomllib
import zipfile
import csv
from pathlib import Path
from urllib.request import urlretrieve
from gstools import Gaussian, krige
from pykrige.ok import OrdinaryKriging
import numpy as np

UJI_ZIP_URL = "https://archive.ics.uci.edu/static/public/343/ujiindoorloc%2Bmag.zip"
MARKER_RE = re.compile(r"<\d+>")
_SENSOR_STATE = {
    "source": None,
    "key": None,
    "frames": None,
    "index": 0,
}
_STEP_CONFIG = {
    "judge_method": "peak_dynamic",
    "step_length_method": "weinberg",
    "peak_sigma": 0.45,
    "peak_prominence": 0.18,
    "fixed_threshold": 10.7,
    "zero_crossing_band": 0.22,
    "min_samples_per_step": 4,
    "freq_ratio_threshold": 3.0,
    "autocorr_threshold": 0.35,
    "weinberg_k": 0.45,
    "fixed_step_length_m": 0.7,
    "heading_offset_deg": 0.0,
    "orientation_as_azimuth_deg": True,
    "mag_sigma": 8.0,
}
_ALGO_STATE = {
    "last_sensor_frame": None,
    "last_step_samples": None,
    "heading_rad": 0.0,
    "heading_debug": {},
}

# ============================================================
# Private Definitions
# ============================================================

# --- Private constants (used by get_map(source="uji")) ---


# --- Private helpers used by get_map(source="uji"): dataset bootstrap ---
def _download_uji_zip(zip_path, force_download=False):
    zip_path = Path(zip_path)
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    if zip_path.exists() and not force_download:
        return zip_path

    # TODO: Add checksum validation for dataset integrity.
    urlretrieve(UJI_ZIP_URL, zip_path)
    return zip_path


def _extract_uji_zip(zip_path, extract_dir, force_extract=False):
    zip_path = Path(zip_path)
    extract_dir = Path(extract_dir)
    extract_dir.mkdir(parents=True, exist_ok=True)

    marker = extract_dir / ".extracted_ok"
    if marker.exists() and not force_extract:
        return extract_dir

    with zipfile.ZipFile(zip_path, "r") as archive:
        archive.extractall(extract_dir)

    marker.write_text("ok", encoding="utf-8")
    return extract_dir


# --- Private helpers used by get_map(source="uji"): configuration ---
def _load_map_builder_cfg(config_path):
    config_path = Path(config_path)
    if not config_path.exists():
        return {}
    with config_path.open("rb") as handle:
        config = tomllib.load(handle)

    tool_cfg = config.get("tool", {})
    if isinstance(tool_cfg, dict):
        map_cfg = tool_cfg.get("map_builder", {})
        if isinstance(map_cfg, dict):
            return map_cfg
    return {}


# --- Private helpers used by get_map(source="uji"): UJI text parsing ---
def _is_sensor_row(line):
    parts = line.strip().split()
    if len(parts) < 10:
        return False
    try:
        int(float(parts[0]))
        [float(v) for v in parts[1:10]]
        return True
    except ValueError:
        return False


def _is_segment_row(line):
    parts = line.strip().split()
    if len(parts) != 6:
        return False
    try:
        [float(v) for v in parts]
        return True
    except ValueError:
        return False


def _parse_uji_file(path):
    sensor_rows = []
    segment_rows = []

    with Path(path).open("r", encoding="utf-8", errors="ignore") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if MARKER_RE.search(line):
                continue
            if _is_sensor_row(line):
                parts = line.split()
                mx, my, mz = float(parts[1]), float(parts[2]), float(parts[3])
                sensor_rows.append((mx, my, mz))
                continue
            if _is_segment_row(line):
                p = [float(v) for v in line.split()]
                lat1, lon1, lat2, lon2 = p[0], p[1], p[2], p[3]
                i0, i1 = int(round(p[4])), int(round(p[5]))
                segment_rows.append((lat1, lon1, lat2, lon2, i0, i1))

    if not sensor_rows or not segment_rows:
        return np.array([]), np.array([]), np.array([])

    n = len(sensor_rows)
    lats = np.full(n, np.nan, dtype=float)
    lons = np.full(n, np.nan, dtype=float)
    mags = np.empty(n, dtype=float)

    for i, (mx, my, mz) in enumerate(sensor_rows):
        mags[i] = math.sqrt(mx * mx + my * my + mz * mz)

    for lat1, lon1, lat2, lon2, i0, i1 in segment_rows:
        if i1 < i0:
            i0, i1 = i1, i0
            lat1, lon1, lat2, lon2 = lat2, lon2, lat1, lon1
        i0 = max(i0, 0)
        i1 = min(i1, n - 1)
        if i0 > i1:
            continue
        count = i1 - i0 + 1
        lats[i0 : i1 + 1] = np.linspace(lat1, lat2, count)
        lons[i0 : i1 + 1] = np.linspace(lon1, lon2, count)

    valid = np.isfinite(lats) & np.isfinite(lons)
    return lats[valid], lons[valid], mags[valid]


# --- Private helpers used by get_map(source="uji"): geometry and sampling ---
def _collect_uji_points(dataset_root):
    dataset_root = Path(dataset_root)
    paths = list((dataset_root / "lines").rglob("*.txt"))
    paths += list((dataset_root / "curves").rglob("*.txt"))

    lat_all = []
    lon_all = []
    mag_all = []

    for path in sorted(paths):
        lat, lon, mag = _parse_uji_file(path)
        if lat.size == 0:
            continue
        lat_all.append(lat)
        lon_all.append(lon)
        mag_all.append(mag)

    if not lat_all:
        raise RuntimeError("No valid UJI training points parsed from lines/curves.")

    return np.concatenate(lat_all), np.concatenate(lon_all), np.concatenate(mag_all)


def _latlon_to_xy(lat, lon, lat0, lon0):
    radius = 6378137.0
    dlat = np.radians(lat - lat0)
    dlon = np.radians(lon - lon0)
    x = radius * dlon * np.cos(np.radians((lat + lat0) * 0.5))
    y = radius * dlat
    return x, y


def _reduce_points_for_kriging(x, y, z, max_points, seed):
    if x.size <= max_points:
        return x, y, z
    rng = np.random.default_rng(seed)
    idx = rng.choice(x.size, size=max_points, replace=False)
    return x[idx], y[idx], z[idx]


# --- Private helpers shared by get_map(source="uji") and visualize(...) ---
def _fit_ordinary_kriging(x, y, z, variogram_model):
    try:
        from pykrige.ok import OrdinaryKriging
    except ImportError as exc:
        raise ImportError(
            "pykrige is required for Kriging interpolation. Install it with: pip install pykrige"
        ) from exc

    return OrdinaryKriging(
        x,
        y,
        z,
        variogram_model=variogram_model,
        verbose=False,
        enable_plotting=False,
    )


def _predict_continuous_grid(ok_model, min_x, max_x, min_y, max_y, resolution):
    grid_x = np.arange(min_x, max_x + resolution, resolution, dtype=float)
    grid_y = np.arange(min_y, max_y + resolution, resolution, dtype=float)
    grid_z, grid_ss = ok_model.execute("grid", grid_x, grid_y)
    return grid_x, grid_y, np.asarray(grid_z, dtype=float), np.asarray(grid_ss, dtype=float)


# --- Private helper used by get_map(source="uji"): preview artifact plotting ---
def _plot_grid_map(grid_x, grid_y, grid_z, output_png):
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise ImportError(
            "matplotlib is required for visualization. Install it with: pip install matplotlib"
        ) from exc

    output_png = Path(output_png)
    output_png.parent.mkdir(parents=True, exist_ok=True)

    extent = [float(grid_x[0]), float(grid_x[-1]), float(grid_y[0]), float(grid_y[-1])]
    fig, ax = plt.subplots(figsize=(10, 7), dpi=150)
    im = ax.imshow(
        np.asarray(grid_z, dtype=float),
        origin="lower",
        extent=extent,
        aspect="auto",
        cmap="viridis",
    )
    ax.set_title("UJI Magnetic Magnitude Map (Continuous Kriging Preview)")
    ax.set_xlabel("X (m)")
    ax.set_ylabel("Y (m)")
    cbar = fig.colorbar(im, ax=ax)
    cbar.set_label("Magnetic Magnitude")
    fig.tight_layout()
    # Overwrite if existing.
    fig.savefig(output_png, bbox_inches="tight")
    plt.close(fig)


# --- Private builder used by get_map(source="uji"): continuous UJI map ---
def _build_uji_continuous_map(
    extracted_root,
    output_model_npz,
    output_preview_npz,
    output_json,
    output_png,
    preview_resolution,
    max_kriging_points,
    variogram_model,
    seed,
):
    lat, lon, mag = _collect_uji_points(extracted_root)
    lat0 = float(lat.min())
    lon0 = float(lon.min())
    x, y = _latlon_to_xy(lat, lon, lat0=lat0, lon0=lon0)
    x_train, y_train, z_train = _reduce_points_for_kriging(
        x, y, mag, max_points=max_kriging_points, seed=seed
    )

    min_x, max_x = float(np.min(x)), float(np.max(x))
    min_y, max_y = float(np.min(y)), float(np.max(y))
    ok = _fit_ordinary_kriging(
        x=x_train,
        y=y_train,
        z=z_train,
        variogram_model=variogram_model,
    )
    grid_x, grid_y, grid_z, grid_ss = _predict_continuous_grid(
        ok_model=ok,
        min_x=min_x,
        max_x=max_x,
        min_y=min_y,
        max_y=max_y,
        resolution=preview_resolution,
    )

    output_model_npz = Path(output_model_npz)
    output_preview_npz = Path(output_preview_npz)
    output_json = Path(output_json)
    output_png = Path(output_png)
    output_model_npz.parent.mkdir(parents=True, exist_ok=True)
    output_preview_npz.parent.mkdir(parents=True, exist_ok=True)
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_png.parent.mkdir(parents=True, exist_ok=True)

    np.savez_compressed(
        output_model_npz,
        mode=np.array(["continuous_ordinary_kriging"]),
        x_train=np.asarray(x_train, dtype=float),
        y_train=np.asarray(y_train, dtype=float),
        z_train=np.asarray(z_train, dtype=float),
        variogram_model=np.array([variogram_model]),
        min_x=np.array([min_x], dtype=float),
        max_x=np.array([max_x], dtype=float),
        min_y=np.array([min_y], dtype=float),
        max_y=np.array([max_y], dtype=float),
        origin_lat=np.array([lat0], dtype=float),
        origin_lon=np.array([lon0], dtype=float),
    )
    np.savez_compressed(
        output_preview_npz,
        grid_magnitude=np.asarray(grid_z, dtype=float),
        grid_variance=np.asarray(grid_ss, dtype=float),
        grid_x=grid_x,
        grid_y=grid_y,
        resolution=np.array([preview_resolution], dtype=float),
    )
    _plot_grid_map(grid_x=grid_x, grid_y=grid_y, grid_z=grid_z, output_png=output_png)

    metadata = {
        "source": "uji",
        "continuous_map": True,
        "dataset_root": str(extracted_root),
        "points_total": int(x.size),
        "points_used_for_kriging": int(x_train.size),
        "variogram_model": variogram_model,
        "preview_resolution": float(preview_resolution),
        "bounds_xy_m": [min_x, max_x, min_y, max_y],
        "preview_grid_shape": [int(len(grid_y)), int(len(grid_x))],
        "origin_latlon": [lat0, lon0],
        "output_model_npz": str(output_model_npz),
        "output_preview_npz": str(output_preview_npz),
        "output_png": str(output_png),
    }
    output_json.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    metadata["output_json"] = str(output_json)
    return metadata


# --- Private builder used by get_map(source="own"): interface contract ---
def _build_own_map_interface(
    own_grid_array=None,
    own_grid_map_path=None,
    own_grid_format="array",
    own_grid_meta=None,
):
    matrix_array = None
    matrix_shape = None
    matrix_valid = False
    if own_grid_array is not None:
        matrix_array = np.asarray(own_grid_array, dtype=float)
        matrix_valid = matrix_array.ndim == 2 and matrix_array.size > 0
        if matrix_valid:
            matrix_shape = [int(matrix_array.shape[0]), int(matrix_array.shape[1])]

    grid_path = Path(own_grid_map_path) if own_grid_map_path is not None else None
    default_meta = {
        "cell_size_m": None,
        "origin_xy_m": [0.0, 0.0],
        "x_axis_direction": "east",
        "y_axis_direction": "north",
        "mag_unit": "uT",
    }
    merged_meta = dict(default_meta)
    if isinstance(own_grid_meta, dict):
        merged_meta.update(own_grid_meta)

    grid_input_specs = {
        "array": {
            "description": "Direct in-memory 2D matrix (list[list[float]] or np.ndarray)",
            "shape": "(H, W)",
            "dtype": "float",
            "semantics": "matrix[row, col] -> magnetic magnitude at grid cell",
        },
        "npy_matrix": {
            "description": "2D magnetic map matrix as plain numpy array",
            "shape": "(H, W)",
            "dtype": "float",
            "semantics": "matrix[row, col] -> magnetic magnitude at grid cell",
        },
        "npz_matrix": {
            "description": "2D magnetic map matrix packed in npz",
            "required_keys": ["grid_magnitude"],
            "optional_keys": ["mask", "grid_variance"],
            "shape": "(H, W)",
        },
        "csv_matrix": {
            "description": "2D matrix stored as CSV table",
            "shape": "(H, W)",
            "note": "No header recommended; each row is one grid row.",
        },
    }

    return {
        "source": "own",
        "status": "interface_only",
        "grid_array": matrix_array.tolist() if matrix_valid else None,
        "array_input": {
            "provided": own_grid_array is not None,
            "valid_2d": matrix_valid,
            "shape": matrix_shape,
        },
        "grid_map_contract": {
            "selected_format": own_grid_format,
            "path": str(grid_path) if grid_path is not None else None,
            "exists": grid_path.exists() if grid_path is not None else None,
            "supported_formats": grid_input_specs,
            "meta": merged_meta,
            "matrix_convention": {
                "indexing": "row-major",
                "value": "magnetic magnitude",
                "world_mapping": "x = origin_x + col * cell_size; y = origin_y + row * cell_size",
            },
        },
        "next_step": "Use own_grid_array for direct editable matrix input; keep file path only as optional fallback.",
    }


# ============================================================
# Public Definitions
# ============================================================

# --- Public API: map factory (called by Initializer.create_context / temp scripts) ---
def _api_get_map(
    source="uji",
    data_root="data/raw",
    config_path="pyproject.toml",
    force_download=False,
    force_extract=False,
    own_grid_array=None,
    own_grid_map_path=None,
    own_grid_format="array",
    own_grid_meta=None,
):
    source = source.lower()

    if source == "uji":
        cfg = _load_map_builder_cfg(config_path)
        preview_resolution = float(cfg.get("preview_resolution", 1.0))
        max_kriging_points = int(cfg.get("max_kriging_points", 2500))
        seed = int(cfg.get("seed", 42))
        variogram_model = str(cfg.get("variogram_model", "spherical"))
        output_model_npz = cfg.get("output_model_npz", "data/processed/uji_mag_model_kriging.npz")
        output_preview_npz = cfg.get(
            "output_preview_npz",
            "data/processed/uji_mag_grid_preview_kriging.npz",
        )
        output_json = cfg.get("output_json", "data/processed/uji_mag_grid_kriging_meta.json")
        output_png = cfg.get("output_png", "data/processed/uji_mag_grid_kriging.png")

        data_root_path = Path(data_root)
        uji_root = data_root_path / "uji_indoorloc_mag"
        zip_path = uji_root / "ujiindoorloc+mag.zip"
        extract_dir = uji_root / "extracted"
        _download_uji_zip(zip_path, force_download=force_download)
        _extract_uji_zip(zip_path, extract_dir, force_extract=force_extract)
        extracted_root = extract_dir / "UJIIndoorLoc-Mag" / "UJIIndoorLoc-Mag"

        map_info = _build_uji_continuous_map(
            extracted_root=extracted_root,
            output_model_npz=output_model_npz,
            output_preview_npz=output_preview_npz,
            output_json=output_json,
            output_png=output_png,
            preview_resolution=preview_resolution,
            max_kriging_points=max_kriging_points,
            variogram_model=variogram_model,
            seed=seed,
        )
        map_info["zip_path"] = str(zip_path)
        map_info["extract_dir"] = str(extract_dir)
        return map_info

    if source == "own":
        raw_map =  _build_own_map_interface(
            own_grid_array=own_grid_array,
            own_grid_map_path=own_grid_map_path,
            own_grid_format=own_grid_format,
            own_grid_meta=own_grid_meta,
        )
        data = own_grid_array
        gridx = np.arange(own_grid_meta["x_min"], own_grid_meta["x_max"], 0.01)
        gridy = np.arange(own_grid_meta["y_min"], own_grid_meta["y_max"], 0.01)
        cov_model = Gaussian(dim=2, len_scale=1, anis=.2, angles=-.5, var=.5, nugget=.1)
        OK1 = OrdinaryKriging(data[:, 0], data[:, 1], data[:, 2], cov_model)
        z1, ss1 = OK1.execute('grid', gridx, gridy)
        return {"map":z1 , "rangex_min": own_grid_meta["x_min"], "rangex_max": own_grid_meta["x_max"], "rangey_min": own_grid_meta["y_min"], "rangey_max":own_grid_meta["y_max"]}

    raise ValueError(f"Unsupported map source: {source}")


# --- Public API placeholders used by Experiment.run() ---
def _parse_uji_true_route_file(path):
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"UJI test file not found: {path}")

    lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="ignore").splitlines()]
    lines = [line for line in lines if line]
    marker_idx = next((i for i, line in enumerate(lines) if MARKER_RE.fullmatch(line)), None)
    if marker_idx is None:
        raise ValueError(f"UJI test file has no segment marker <n>: {path}")

    sample_count = marker_idx
    if sample_count <= 0:
        raise ValueError(f"UJI test file has no sample rows before marker: {path}")

    lat = np.full(sample_count, np.nan, dtype=float)
    lon = np.full(sample_count, np.nan, dtype=float)

    for line in lines[marker_idx + 1 :]:
        parts = line.split()
        if len(parts) != 6:
            continue
        try:
            lat1, lon1, lat2, lon2 = float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3])
            i0, i1 = int(round(float(parts[4]))), int(round(float(parts[5])))
        except ValueError:
            continue

        if i1 < i0:
            i0, i1 = i1, i0
            lat1, lon1, lat2, lon2 = lat2, lon2, lat1, lon1
        i0 = max(0, i0)
        i1 = min(sample_count - 1, i1)
        if i0 > i1:
            continue

        count = i1 - i0 + 1
        lat[i0 : i1 + 1] = np.linspace(lat1, lat2, count)
        lon[i0 : i1 + 1] = np.linspace(lon1, lon2, count)

    valid = np.isfinite(lat) & np.isfinite(lon)
    if not np.any(valid):
        raise ValueError(f"No valid route points reconstructed from UJI file: {path}")

    # Fill uncovered indices to keep route length aligned to sample count.
    valid_idx = np.where(valid)[0]
    missing_idx = np.where(~valid)[0]
    if missing_idx.size > 0:
        lat[missing_idx] = np.interp(missing_idx, valid_idx, lat[valid_idx])
        lon[missing_idx] = np.interp(missing_idx, valid_idx, lon[valid_idx])

    return [[float(a), float(b)] for a, b in zip(lat, lon)]


def _normalize_name(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def _pick_column(fieldnames, candidates):
    norm_to_name = {_normalize_name(name): name for name in fieldnames}
    for candidate in candidates:
        key = _normalize_name(candidate)
        if key in norm_to_name:
            return norm_to_name[key]
    return None


def _load_uji_sensor_frames(test_path):
    test_path = Path(test_path)
    if not test_path.exists():
        raise FileNotFoundError(f"UJI test file not found: {test_path}")

    frames = []
    with test_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            if MARKER_RE.search(line):
                break
            if not _is_sensor_row(line):
                continue
            parts = line.split()
            # Format: ts, mx, my, mz, ax, ay, az, ox, oy, oz
            mx, my, mz = float(parts[1]), float(parts[2]), float(parts[3])
            ax, ay, az = float(parts[4]), float(parts[5]), float(parts[6])
            gx, gy, gz = float(parts[7]), float(parts[8]), float(parts[9])
            frames.append(
                {
                    "time": float(parts[0]),
                    "mag": [mx, my, mz],
                    "acc": [ax, ay, az],
                    "gyro": [gx, gy, gz],
                    "gyro_mode": "orientation_deg",
                    "source": "uji",
                }
            )

    if not frames:
        raise ValueError(f"No valid sensor rows found in UJI test file: {test_path}")
    return frames


def _load_csv_xyz(path, time_candidates, x_candidates, y_candidates, z_candidates):
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"Sensor CSV not found: {path}")

    with path.open("r", encoding="utf-8", errors="ignore", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"CSV has no header: {path}")

        time_col = _pick_column(reader.fieldnames, time_candidates)
        x_col = _pick_column(reader.fieldnames, x_candidates)
        y_col = _pick_column(reader.fieldnames, y_candidates)
        z_col = _pick_column(reader.fieldnames, z_candidates)
        if time_col is None or x_col is None or y_col is None or z_col is None:
            raise ValueError(
                f"CSV {path} must contain time/x/y/z columns. Found: {reader.fieldnames}"
            )

        rows = []
        for row in reader:
            t_raw = str(row.get(time_col, "")).strip()
            x_raw = str(row.get(x_col, "")).strip()
            y_raw = str(row.get(y_col, "")).strip()
            z_raw = str(row.get(z_col, "")).strip()
            if not t_raw or not x_raw or not y_raw or not z_raw:
                continue
            if (
                t_raw.lower() == "nan"
                or x_raw.lower() == "nan"
                or y_raw.lower() == "nan"
                or z_raw.lower() == "nan"
            ):
                continue
            try:
                rows.append((float(t_raw), float(x_raw), float(y_raw), float(z_raw)))
            except ValueError:
                continue

    if not rows:
        raise ValueError(f"No valid numeric rows in CSV: {path}")

    rows.sort(key=lambda item: item[0])
    times = np.asarray([r[0] for r in rows], dtype=float)
    x = np.asarray([r[1] for r in rows], dtype=float)
    y = np.asarray([r[2] for r in rows], dtype=float)
    z = np.asarray([r[3] for r in rows], dtype=float)

    unique_times, unique_idx = np.unique(times, return_index=True)
    return unique_times, x[unique_idx], y[unique_idx], z[unique_idx]


def _load_own_sensor_frames(own_data_dir):
    base = Path(own_data_dir)
    mag_t, mag_x, mag_y, mag_z = _load_csv_xyz(
        base / "Magnetometer.csv",
        time_candidates=["Time (s)", "time", "timestamp"],
        x_candidates=["X (µT)", "X", "mx"],
        y_candidates=["Y (µT)", "Y", "my"],
        z_candidates=["Z (µT)", "Z", "mz"],
    )
    acc_t, acc_x, acc_y, acc_z = _load_csv_xyz(
        base / "Accelerometer.csv",
        time_candidates=["Time (s)", "time", "timestamp"],
        x_candidates=["X (m/s^2)", "X", "ax"],
        y_candidates=["Y (m/s^2)", "Y", "ay"],
        z_candidates=["Z (m/s^2)", "Z", "az"],
    )
    gyr_t, gyr_x, gyr_y, gyr_z = _load_csv_xyz(
        base / "Gyroscope.csv",
        time_candidates=["Time (s)", "time", "timestamp"],
        x_candidates=["X (rad/s)", "X", "gx"],
        y_candidates=["Y (rad/s)", "Y", "gy"],
        z_candidates=["Z (rad/s)", "Z", "gz"],
    )

    acc_x_i = np.interp(mag_t, acc_t, acc_x)
    acc_y_i = np.interp(mag_t, acc_t, acc_y)
    acc_z_i = np.interp(mag_t, acc_t, acc_z)
    gyr_x_i = np.interp(mag_t, gyr_t, gyr_x)
    gyr_y_i = np.interp(mag_t, gyr_t, gyr_y)
    gyr_z_i = np.interp(mag_t, gyr_t, gyr_z)

    frames = []
    for i in range(mag_t.size):
        frames.append(
            {
                "time": float(mag_t[i]),
                "mag": [float(mag_x[i]), float(mag_y[i]), float(mag_z[i])],
                "acc": [float(acc_x_i[i]), float(acc_y_i[i]), float(acc_z_i[i])],
                "gyro": [float(gyr_x_i[i]), float(gyr_y_i[i]), float(gyr_z_i[i])],
                "gyro_mode": "angular_rate_rad_s",
                "source": "own",
            }
        )
    if not frames:
        raise ValueError(f"No sensor frames built from own dataset: {own_data_dir}")
    return frames


def _sensor_stream_key(source, data_root, uji_test_file, own_data_dir):
    return (source, str(Path(data_root)), str(uji_test_file), str(Path(own_data_dir)))


def _ensure_sensor_stream(source, data_root, uji_test_file, own_data_dir, reset=False):
    key = _sensor_stream_key(source, data_root, uji_test_file, own_data_dir)
    if reset or _SENSOR_STATE["frames"] is None or _SENSOR_STATE["key"] != key:
        if source == "uji":
            base = (
                Path(data_root)
                / "uji_indoorloc_mag"
                / "extracted"
                / "UJIIndoorLoc-Mag"
                / "UJIIndoorLoc-Mag"
                / "tests"
            )
            test_path = Path(uji_test_file)
            if not test_path.is_absolute():
                test_path = base / uji_test_file
            frames = _load_uji_sensor_frames(test_path)
        elif source == "own":
            frames = _load_own_sensor_frames(own_data_dir)
        else:
            raise ValueError(f"Unsupported sensor source: {source}")

        _SENSOR_STATE["source"] = source
        _SENSOR_STATE["key"] = key
        _SENSOR_STATE["frames"] = frames
        _SENSOR_STATE["index"] = 0
    return _SENSOR_STATE["frames"]


# TODO: Provide the ground-truth route for a test run.
def _api_get_true_route(
    source="uji",
    data_root="data/raw",
    uji_test_file="tt01.txt",
    own_location_csv=None,
    own_data_dir="data/Geomagnetic Navigation 2026-03-03 15-28-45",
):
    source = source.lower()

    if source == "uji":
        base = Path(data_root) / "uji_indoorloc_mag" / "extracted" / "UJIIndoorLoc-Mag" / "UJIIndoorLoc-Mag" / "tests"
        test_path = Path(uji_test_file)
        if not test_path.is_absolute():
            test_path = base / uji_test_file
        return _parse_uji_true_route_file(test_path)

    if source == "own":
        if own_location_csv is None:
            csv_path = Path(own_data_dir) / "Location.csv"
        else:
            csv_path = Path(own_location_csv)
        if not csv_path.exists():
            raise FileNotFoundError(f"Own route CSV not found: {csv_path}")

        with csv_path.open("r", encoding="utf-8", errors="ignore", newline="") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames:
                raise ValueError(f"Own route CSV has no header: {csv_path}")

            lat_col = _pick_column(reader.fieldnames, ["Latitude (°)", "Latitude", "lat", "latitude"])
            lon_col = _pick_column(reader.fieldnames, ["Longitude (°)", "Longitude", "lon", "longitude"])
            if lat_col is None or lon_col is None:
                raise ValueError(
                    f"Own route CSV must contain latitude/longitude columns. Found: {reader.fieldnames}"
                )

            route = []
            for row in reader:
                lat_raw = str(row.get(lat_col, "")).strip()
                lon_raw = str(row.get(lon_col, "")).strip()
                if not lat_raw or not lon_raw:
                    continue
                if lat_raw.lower() == "nan" or lon_raw.lower() == "nan":
                    continue
                try:
                    lat = float(lat_raw)
                    lon = float(lon_raw)
                except ValueError:
                    continue
                route.append([lat, lon])

        if not route:
            raise ValueError(f"No valid latitude/longitude rows found in: {csv_path}")
        return route

    raise ValueError(f"Unsupported true-route source: {source}")


# TODO: Return test length (number of sensor frames to consume).
def _api_get_test_len(
    source="uji",
    data_root="data/raw",
    uji_test_file="tt01.txt",
    own_data_dir="data/Geomagnetic Navigation 2026-03-03 15-28-45",
):
    source = source.lower()
    frames = _ensure_sensor_stream(
        source=source,
        data_root=data_root,
        uji_test_file=uji_test_file,
        own_data_dir=own_data_dir,
        reset=True,
    )
    _ALGO_STATE["heading_rad"] = 0.0
    _ALGO_STATE["heading_debug"] = {}
    return len(frames)


# TODO: Fetch one frame of sensor data: magnetometer, accelerometer, gyroscope.
def _api_get_sensor(
    source="uji",
    data_root="data/raw",
    uji_test_file="tt01.txt",
    own_data_dir="data/Geomagnetic Navigation 2026-03-03 15-28-45",
):
    source = source.lower()
    frames = _ensure_sensor_stream(
        source=source,
        data_root=data_root,
        uji_test_file=uji_test_file,
        own_data_dir=own_data_dir,
        reset=False,
    )
    idx = _SENSOR_STATE["index"]
    if idx >= len(frames):
        raise StopIteration("Sensor stream exhausted. Call get_test_len(...) to reset stream.")
    frame = frames[idx]
    _SENSOR_STATE["index"] = idx + 1
    _ALGO_STATE["last_sensor_frame"] = frame
    return frame["mag"], frame["acc"], frame["gyro"]


# TODO: Determine whether buffered sensor samples contain a completed step.
def _extract_acc_magnitude(samples):
    if samples is None:
        return np.asarray([], dtype=float)
    acc_list = []
    for item in samples:
        if item is None or len(item) < 1:
            continue
        acc = item[0]
        if acc is None or len(acc) < 3:
            continue
        try:
            ax, ay, az = float(acc[0]), float(acc[1]), float(acc[2])
        except (TypeError, ValueError):
            continue
        acc_list.append([ax, ay, az])
    if not acc_list:
        return np.asarray([], dtype=float)
    acc_arr = np.asarray(acc_list, dtype=float)
    return np.linalg.norm(acc_arr, axis=1)


def _smooth_signal(x, window=3):
    x = np.asarray(x, dtype=float)
    if x.size == 0:
        return x
    if window <= 1 or x.size < window:
        return x
    kernel = np.ones(window, dtype=float) / float(window)
    return np.convolve(x, kernel, mode="same")


def _api_available_step_judge_methods():
    return [
        "peak_dynamic",  # Time-domain dynamic threshold peak detection (default, most common)
        "peak_fixed",  # Time-domain fixed-threshold peak detection
        "zero_crossing",  # Time-domain zero-crossing with band constraint
        "valley_peak",  # Time-domain valley-to-peak transition detection
        "frequency_fft",  # Frequency-domain periodicity + peak gate
        "autocorr",  # Autocorrelation periodicity + peak gate
    ]


def _api_set_step_judge_method(method="peak_dynamic", **kwargs):
    method = str(method).lower()
    if method not in available_step_judge_methods():
        raise ValueError(f"Unsupported step judge method: {method}")
    _STEP_CONFIG["judge_method"] = method
    for key, value in kwargs.items():
        if key in _STEP_CONFIG:
            _STEP_CONFIG[key] = value


def _api_judge_step(samples, method=None, **kwargs):
    """Return True if current buffered samples likely contain one completed step.

    Popular default method:
    - peak_dynamic: filtered acceleration magnitude + dynamic threshold + local peak.

    Other branches:
    - peak_fixed
    - zero_crossing
    - valley_peak
    """
    if method is None:
        method = _STEP_CONFIG["judge_method"]
    method = str(method).lower()
    cfg = dict(_STEP_CONFIG)
    cfg.update(kwargs)

    mag = _extract_acc_magnitude(samples)
    n = int(mag.size)
    if n < int(cfg["min_samples_per_step"]):
        return False

    sig = _smooth_signal(mag, window=3)
    if sig.size < 3:
        return False

    # Candidate peak at the penultimate sample (streaming-safe with growing buffer).
    c_idx = sig.size - 2
    is_local_peak = bool(sig[c_idx] > sig[c_idx - 1] and sig[c_idx] >= sig[c_idx + 1])

    hit = False
    if method == "peak_dynamic":
        mean_v = float(np.mean(sig))
        std_v = float(np.std(sig))
        threshold = mean_v + float(cfg["peak_sigma"]) * std_v
        recent_min = float(np.min(sig[max(0, c_idx - 8) : c_idx + 1]))
        prominence = float(sig[c_idx] - recent_min)
        hit = bool(is_local_peak and sig[c_idx] > threshold and prominence > float(cfg["peak_prominence"]))
    elif method == "peak_fixed":
        threshold = float(cfg["fixed_threshold"])
        hit = bool(is_local_peak and sig[c_idx] > threshold)
    elif method == "zero_crossing":
        d = sig - float(np.mean(sig))
        if d.size >= 4:
            # Zero-crossing near stream tail and sufficient oscillation amplitude.
            cross = bool((d[-3] <= 0.0 < d[-2]) or (d[-2] <= 0.0 < d[-1]))
            band = float(cfg["zero_crossing_band"])
            enough_swing = bool(np.max(d) > band and np.min(d) < -band)
            hit = bool(cross and enough_swing)
    elif method == "valley_peak":
        if is_local_peak:
            recent = sig[max(0, c_idx - 10) : c_idx + 1]
            valley = float(np.min(recent))
            rise = float(sig[c_idx] - valley)
            mean_v = float(np.mean(sig))
            std_v = float(np.std(sig))
            hit = bool(
                rise > float(cfg["peak_prominence"])
                and sig[c_idx] > mean_v + 0.25 * std_v
            )
    elif method == "frequency_fft":
        if sig.size >= 16:
            d = sig - float(np.mean(sig))
            spec = np.abs(np.fft.rfft(d))
            if spec.size >= 3:
                spec[0] = 0.0
                peak_bin = int(np.argmax(spec))
                peak_val = float(spec[peak_bin])
                mean_val = float(np.mean(spec[1:])) + 1e-9
                ratio = peak_val / mean_val
                hit = bool(ratio > float(cfg["freq_ratio_threshold"]) and is_local_peak)
    elif method == "autocorr":
        if sig.size >= 12:
            d = sig - float(np.mean(sig))
            ac = np.correlate(d, d, mode="full")[d.size - 1 :]
            if ac.size >= 6 and ac[0] > 1e-12:
                ac = ac / ac[0]
                lag_min = 2
                lag_max = min(ac.size - 1, max(4, int(sig.size * 0.5)))
                if lag_max > lag_min:
                    peak_corr = float(np.max(ac[lag_min : lag_max + 1]))
                    hit = bool(peak_corr > float(cfg["autocorr_threshold"]) and is_local_peak)
    else:
        raise ValueError(
            f"Unsupported step judge method: {method}. Available: {available_step_judge_methods()}"
        )

    if hit:
        _ALGO_STATE["last_step_samples"] = list(samples)
    return hit


# TODO: Estimate step length from buffered samples.
def _api_get_step_len(samples, method=None, **kwargs):
    if method is None:
        method = _STEP_CONFIG["step_length_method"]
    method = str(method).lower()
    cfg = dict(_STEP_CONFIG)
    cfg.update(kwargs)

    mag = _extract_acc_magnitude(samples)
    if mag.size == 0:
        return float(cfg["fixed_step_length_m"])
    mag_max = float(np.max(mag))
    mag_min = float(np.min(mag))

    if method == "weinberg":
        # Weinberg: L = k * (Amax - Amin)^(1/4)
        delta = max(mag_max - mag_min, 1e-9)
        return float(cfg["weinberg_k"]) * float(delta ** 0.25)
    if method == "fixed":
        return float(cfg["fixed_step_length_m"])

    raise ValueError("Unsupported step length method. Supported: ['weinberg', 'fixed']")


# TODO: Estimate heading angle from buffered samples.
def _wrap_angle_pi(rad):
    return float(((rad + math.pi) % (2.0 * math.pi)) - math.pi)


def _heading_from_acc_mag(acc, mag):
    ax, ay, az = float(acc[0]), float(acc[1]), float(acc[2])
    mx, my, mz = float(mag[0]), float(mag[1]), float(mag[2])

    norm_a = math.sqrt(ax * ax + ay * ay + az * az) + 1e-12
    ax, ay, az = ax / norm_a, ay / norm_a, az / norm_a

    roll = math.atan2(ay, az)
    pitch = math.atan2(-ax, math.sqrt(ay * ay + az * az))

    mx2 = mx * math.cos(pitch) + mz * math.sin(pitch)
    my2 = (
        mx * math.sin(roll) * math.sin(pitch)
        + my * math.cos(roll)
        - mz * math.sin(roll) * math.cos(pitch)
    )
    yaw = math.atan2(-my2, mx2)
    return _wrap_angle_pi(yaw)


def _azimuth_deg_to_xy_heading_rad(az_deg):
    # Smartphone/compass azimuth: 0 deg = North, clockwise positive.
    # XY heading used by motion model: 0 rad = +X(East), CCW positive.
    return _wrap_angle_pi(math.radians(90.0 - float(az_deg)))


def _api_get_heading_angle(samples, method="gyro", dt=0.02, alpha=None):
    if samples is None or len(samples) == 0:
        return float(_ALGO_STATE["heading_rad"])

    acc_arr = []
    gyro_arr = []
    mag_arr = []
    for item in samples:
        if item is None or len(item) < 3:
            continue
        acc, gyro, mag = item[0], item[1], item[2]
        if len(acc) < 3 or len(gyro) < 3 or len(mag) < 3:
            continue
        acc_arr.append([float(acc[0]), float(acc[1]), float(acc[2])])
        gyro_arr.append([float(gyro[0]), float(gyro[1]), float(gyro[2])])
        mag_arr.append([float(mag[0]), float(mag[1]), float(mag[2])])
    if not acc_arr:
        return float(_ALGO_STATE["heading_rad"])

    acc_arr = np.asarray(acc_arr, dtype=float)
    gyro_arr = np.asarray(gyro_arr, dtype=float)
    mag_arr = np.asarray(mag_arr, dtype=float)
    last_frame = _ALGO_STATE.get("last_sensor_frame") or {}
    sensor_source = str(last_frame.get("source", _SENSOR_STATE.get("source", "unknown"))).lower()
    gyro_mode = str(last_frame.get("gyro_mode", "unknown"))
    gyro_abs_med = float(np.median(np.abs(gyro_arr), axis=0).max()) if gyro_arr.size else 0.0

    method = str(method).lower()
    heading_offset_rad = math.radians(float(_STEP_CONFIG.get("heading_offset_deg", 0.0)))
    azimuth_mode = bool(_STEP_CONFIG.get("orientation_as_azimuth_deg", True))

    # If no explicit mode provided, infer from data scale.
    if gyro_mode == "unknown":
        if gyro_abs_med > 15.0:
            gyro_mode = "orientation_deg"
        else:
            gyro_mode = "angular_rate_rad_s"

    def gyro_heading_estimate():
        if gyro_mode == "orientation_deg":
            # UJI test files commonly provide orientation angles in degrees.
            # Use the first channel (azimuth-like) as absolute heading.
            heading_deg = float(np.mean(gyro_arr[:, 0]))
            if azimuth_mode:
                return _azimuth_deg_to_xy_heading_rad(heading_deg)
            return _wrap_angle_pi(math.radians(heading_deg))
        # Standard gyro angular-rate integration (z-yaw).
        return _wrap_angle_pi(float(_ALGO_STATE["heading_rad"] + np.mean(gyro_arr[:, 2]) * float(dt) * len(gyro_arr)))

    yaw_gyro = gyro_heading_estimate()
    yaw_compass = _heading_from_acc_mag(acc_arr.mean(axis=0), mag_arr.mean(axis=0))
    alpha_used = None

    if method == "gyro":
        yaw = yaw_gyro
    elif method == "tilt_compass":
        yaw = yaw_compass
    elif method == "q_fused":
        # Complementary fusion between gyro-like heading and tilt-compensated compass heading.
        # Use a high alpha for UJI because orientation channel is typically stable.
        alpha_used = 0.98 if alpha is None and sensor_source == "uji" else (0.90 if alpha is None else float(alpha))
        alpha_used = float(np.clip(alpha_used, 0.0, 1.0))
        sy = alpha_used * math.sin(yaw_gyro) + (1.0 - alpha_used) * math.sin(yaw_compass)
        cy = alpha_used * math.cos(yaw_gyro) + (1.0 - alpha_used) * math.cos(yaw_compass)
        yaw = _wrap_angle_pi(math.atan2(sy, cy))
    else:
        raise ValueError("Unsupported heading method. Supported: ['gyro', 'tilt_compass', 'q_fused']")

    yaw = _wrap_angle_pi(float(yaw + heading_offset_rad))
    _ALGO_STATE["heading_rad"] = float(yaw)
    _ALGO_STATE["heading_debug"] = {
        "method": method,
        "sensor_source": sensor_source,
        "gyro_mode": gyro_mode,
        "gyro_abs_median": gyro_abs_med,
        "heading_offset_deg": float(_STEP_CONFIG.get("heading_offset_deg", 0.0)),
        "alpha_used": alpha_used,
        "yaw_gyro_deg": float(math.degrees(yaw_gyro)),
        "yaw_compass_deg": float(math.degrees(yaw_compass)),
        "heading_rad": float(yaw),
        "heading_deg": float(math.degrees(yaw)),
    }
    return float(yaw)


# TODO: Extract geomagnetic feature/value used by the filter.
def _api_get_mag(method="norm_mean"):
    samples = _ALGO_STATE.get("last_step_samples")
    if samples:
        mags = []
        for item in samples:
            if item is None or len(item) < 3:
                continue
            mag = item[2]
            if mag is None or len(mag) < 3:
                continue
            m = float(np.linalg.norm(np.asarray(mag[:3], dtype=float)))
            mags.append(m)
        if mags:
            if method == "norm_last":
                return float(mags[-1])
            return float(np.mean(mags))

    frame = _ALGO_STATE.get("last_sensor_frame")
    if frame and "mag" in frame:
        m = np.asarray(frame["mag"][:3], dtype=float)
        return float(np.linalg.norm(m))
    return 0.0


# TODO: Run one particle-filter update step and return updated position.
def _derivative_sequence(x):
    x = np.asarray(x, dtype=float).reshape(-1)
    if x.size <= 1:
        return x.copy()
    if x.size == 2:
        return np.asarray([x[1] - x[0]], dtype=float)
    d = np.empty_like(x, dtype=float)
    d[0] = float(x[1] - x[0])
    d[-1] = float(x[-1] - x[-2])
    d[1:-1] = 0.5 * (x[2:] - x[:-2])
    return d


def _zscore(x):
    x = np.asarray(x, dtype=float).reshape(-1)
    if x.size == 0:
        return x
    mu = float(np.mean(x))
    sd = float(np.std(x))
    if sd < 1e-8:
        return x - mu
    return (x - mu) / sd


def _ddtw_distance(a, b, window_ratio=0.25):
    a = _zscore(_derivative_sequence(a))
    b = _zscore(_derivative_sequence(b))
    if a.size == 0 or b.size == 0:
        return 0.0

    n, m = int(a.size), int(b.size)
    window = max(abs(n - m), int(max(n, m) * float(window_ratio)), 4)
    dp = np.full((n + 1, m + 1), np.inf, dtype=float)
    dp[0, 0] = 0.0
    for i in range(1, n + 1):
        j0 = max(1, i - window)
        j1 = min(m, i + window)
        ai = float(a[i - 1])
        for j in range(j0, j1 + 1):
            cost = abs(ai - float(b[j - 1]))
            dp[i, j] = cost + min(dp[i - 1, j], dp[i, j - 1], dp[i - 1, j - 1])
    return float(dp[n, m] / max(1, n + m))


def _api_PF(step_len, heading_angle, geomag_list, pf_state):
    if pf_state is None or not hasattr(pf_state, "particles"):
        raise ValueError("PF requires a valid pf_state with particle storage.")

    step_len = float(step_len)
    heading_angle = float(heading_angle)
    obs = np.asarray(list(geomag_list), dtype=float).reshape(-1)
    sigma = float(getattr(pf_state, "weight_sigma", 3.0))
    rng = getattr(pf_state, "rng", np.random.default_rng(42))
    if getattr(pf_state, "map_points", None) is None:
        # No map available: return dead-reckoning-like estimate.
        return pf_state.get_pos()

    raw_weights = []
    for p in pf_state.particles:
        theta = _wrap_angle_pi(heading_angle + float(rng.normal(0.0, 0.12)))
        dist = max(0.0, step_len + float(rng.normal(0.0, 0.22)))
        p.theta = theta
        nx = float(p.x + dist * math.cos(theta))
        ny = float(p.y + dist * math.sin(theta))
        p.x, p.y = pf_state.clamp_to_map(nx, ny)

        pred_mag = float(pf_state.map_magnitude(p.x, p.y))
        p.mag_hist.append(pred_mag)
        hist_len = int(max(1, min(len(obs), 100)))
        pred_seq = np.asarray(p.mag_hist[-hist_len:], dtype=float)
        obs_seq = obs[-hist_len:] if obs.size else np.asarray([pred_mag], dtype=float)
        d = _ddtw_distance(obs_seq, pred_seq)
        w_ddtw = math.exp(-((d * d) / (2.0 * sigma * sigma + 1e-12)))
        w = float(max(1e-12, w_ddtw))
        p.weight = w
        raw_weights.append(w)

    total_weight = float(sum(raw_weights))
    if total_weight <= 1e-12:
        uniform_weight = 1.0 / max(len(pf_state.particles), 1)
        for p in pf_state.particles:
            p.weight = uniform_weight
    else:
        for p in pf_state.particles:
            p.weight = float(max(p.weight, 0.0) / total_weight)

    # KLD adaptive particle count.
    target_n = pf_state.adapt_particle_count_kld()
    ess = pf_state.effective_sample_size()
    if ess < 0.5 * len(pf_state.particles) or target_n != len(pf_state.particles):
        pf_state.cso_resample(target_count=target_n)

    return pf_state.get_pos()


def _parse_meta_groups(meta, defaults):
    if meta is None:
        raw_items = list(defaults)
    else:
        raw_items = [str(x).strip().lower() for x in meta if str(x).strip()]

    main_group = []
    separate_groups = []
    for token in raw_items:
        if token.endswith("_"):
            base = token[:-1]
            if base:
                separate_groups.append([base])
        else:
            main_group.append(token)

    groups = []
    if main_group:
        groups.append(main_group)
    groups.extend(separate_groups)
    if not groups:
        groups = [list(defaults)]
    return groups


def _to_xy_route(route, origin_lat=None, origin_lon=None):
    arr = np.asarray(route, dtype=float)
    if arr.ndim != 2 or arr.shape[1] < 2:
        raise ValueError("`route` must be a 2D sequence with at least 2 columns.")
    a = arr[:, 0]
    b = arr[:, 1]
    if origin_lat is not None and origin_lon is not None:
        x, y = _latlon_to_xy(a, b, float(origin_lat), float(origin_lon))
        return np.asarray(x, dtype=float), np.asarray(y, dtype=float), "xy"
    # Fallback: assume [lat, lon] and render in geographic axes.
    return np.asarray(b, dtype=float), np.asarray(a, dtype=float), "latlon"


def _to_xy_assume_xy(route):
    arr = np.asarray(route, dtype=float)
    if arr.ndim != 2 or arr.shape[1] < 2:
        raise ValueError("`route` must be a 2D sequence with at least 2 columns.")
    return np.asarray(arr[:, 0], dtype=float), np.asarray(arr[:, 1], dtype=float), "xy"


def _sensor_selector_set(group_tokens):
    valid = {
        "sensor",
        "acc",
        "gyro",
        "mag",
        "acc_x",
        "acc_y",
        "acc_z",
        "gyro_x",
        "gyro_y",
        "gyro_z",
        "mag_x",
        "mag_y",
        "mag_z",
    }
    return [token for token in group_tokens if token in valid]


def _expand_sensor_selectors(selectors):
    expanded = set()
    if "sensor" in selectors:
        expanded.update(
            [
                "acc_x",
                "acc_y",
                "acc_z",
                "gyro_x",
                "gyro_y",
                "gyro_z",
                "mag_x",
                "mag_y",
                "mag_z",
            ]
        )
    if "acc" in selectors:
        expanded.update(["acc_x", "acc_y", "acc_z"])
    if "gyro" in selectors:
        expanded.update(["gyro_x", "gyro_y", "gyro_z"])
    if "mag" in selectors:
        expanded.update(["mag_x", "mag_y", "mag_z"])
    for selector in selectors:
        if selector in {
            "acc_x",
            "acc_y",
            "acc_z",
            "gyro_x",
            "gyro_y",
            "gyro_z",
            "mag_x",
            "mag_y",
            "mag_z",
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
                    x=x_train,
                    y=y_train,
                    z=z_train,
                    variogram_model=variogram_model,
                )
                grid_z, _ = ok.execute("grid", grid_x, grid_y)
                grid = (
                    np.asarray(grid_x, dtype=float),
                    np.asarray(grid_y, dtype=float),
                    np.asarray(grid_z, dtype=float),
                )
                return model, grid
            except Exception:
                # Fallback to preview grid when kriging runtime dependencies are unavailable.
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
    index = 1
    while candidate.exists():
        index += 1
        candidate = out_dir / f"{stem}-{index}.png"
    return str(candidate)


# --- Public API: visualization router (called by Experiment.run / temp scripts) ---
# TODO: Visualize estimated track vs. route on the map.
def _api_visualize(
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
            if has_map:
                base_title = "UJI Map"
            else:
                base_title = "Trajectories"
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
                route_idx2 = np.linspace(0, rx2.size - 1, num=tx.size)
                route_idx2 = np.clip(np.rint(route_idx2).astype(int), 0, rx2.size - 1)
                ref_x2 = rx2[route_idx2]
                ref_y2 = ry2[route_idx2]
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
                    np.arange(pf_err.size),
                    pf_err,
                    color="crimson",
                    linewidth=1.8,
                    marker="o" if pf_err.size < 2 else None,
                    markersize=4,
                    label="PF Error",
                )
            if pdr_err is not None and pdr_err.size > 0:
                ax_error.plot(
                    np.arange(pdr_err.size),
                    pdr_err,
                    color="orange",
                    linestyle="--",
                    linewidth=1.8,
                    marker="o" if pdr_err.size < 2 else None,
                    markersize=4,
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

    if mode == "usermap":
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
        cell_size = float(meta_map.get("cell_size_m", 1.0) or 1.0)
        origin = meta_map.get("origin_xy_m", [0.0, 0.0])
        origin_x = float(origin[0]) if len(origin) > 0 else 0.0
        origin_y = float(origin[1]) if len(origin) > 1 else 0.0
        variogram_model = str(meta_map.get("variogram_model", "spherical"))

        rows, cols = z.shape
        col_coords = origin_x + np.arange(cols, dtype=float) * cell_size
        row_coords = origin_y + np.arange(rows, dtype=float) * cell_size
        xx_train, yy_train = np.meshgrid(col_coords, row_coords)
        valid = np.isfinite(z)
        x_train = xx_train[valid]
        y_train = yy_train[valid]
        z_train = z[valid]
        if x_train.size < 4:
            raise ValueError("Need at least 4 valid matrix cells for Kriging-based continuous usermap.")

        min_x = float(col_coords[0])
        max_x = float(col_coords[-1])
        min_y = float(row_coords[0])
        max_y = float(row_coords[-1])
        grid_x = np.arange(min_x, max_x + vis_resolution, vis_resolution, dtype=float)
        grid_y = np.arange(min_y, max_y + vis_resolution, vis_resolution, dtype=float)
        ok = _fit_ordinary_kriging(
            x=x_train,
            y=y_train,
            z=z_train,
            variogram_model=variogram_model,
        )
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
        if output_png:
            out = Path(output_png)
            out.parent.mkdir(parents=True, exist_ok=True)
            fig.savefig(out, bbox_inches="tight")
        if show:
            plt.show()
        plt.close(fig)
        return

    # TODO: Add track/route visualization for localization results.
    return


# ============================================================
# User Part (Public API)
# ============================================================


def get_map(*args, **kwargs):
    return _api_get_map(*args, **kwargs)


def get_true_route(*args, **kwargs):
    return _api_get_true_route(*args, **kwargs)


def get_test_len(*args, **kwargs):
    return _api_get_test_len(*args, **kwargs)


def get_sensor(*args, **kwargs):
    return _api_get_sensor(*args, **kwargs)


def available_step_judge_methods(*args, **kwargs):
    return _api_available_step_judge_methods(*args, **kwargs)


def set_step_judge_method(*args, **kwargs):
    return _api_set_step_judge_method(*args, **kwargs)


def judge_step(*args, **kwargs):
    return _api_judge_step(*args, **kwargs)


def get_step_len(*args, **kwargs):
    return _api_get_step_len(*args, **kwargs)


def get_heading_angle(*args, **kwargs):
    return _api_get_heading_angle(*args, **kwargs)


def get_mag(*args, **kwargs):
    return _api_get_mag(*args, **kwargs)


def PF(*args, **kwargs):
    return _api_PF(*args, **kwargs)


def visualize(*args, **kwargs):
    return _api_visualize(*args, **kwargs)
