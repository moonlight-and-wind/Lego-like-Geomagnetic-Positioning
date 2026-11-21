import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from Geomag import Experiment, Initializer, PDRConfig, PFConfig, build_pdr_from_config, build_pf_from_config
from Geomag.algorithms import (
    get_heading_diagnostics,
    get_map,
    get_sensor,
    get_sensor_diagnostics,
    get_step_length_diagnostics,
    get_test_len,
    get_true_route,
)
from Geomag.models import LocalizationHealthMonitor, PFState
from Geomag.own_dataset_registry import (
    assert_own_dataset_evaluable,
    available_own_dataset_keys,
    get_own_dataset_spec,
    independent_repeat_keys,
)
from Geomag.pipeline import GeomagPipeline
from Geomag.progress_matching import (
    OnlineMagneticProgressMatcher,
    aggregate_progress_templates,
    load_progress_matcher,
)


@dataclass
class BranchConfig:
    branch: str = "uji"
    window_size: int = 400
    max_frames: int | None = None
    show: bool = True
    output_json: str | None = None
    output_png: str | None = None
    write_outputs: bool = True

    # UJI branch.
    uji_test_file: str = "tt02.txt"
    uji_data_root: str = "data/raw"

    # Own-data branch.
    own_profile: str = "own_branch"
    own_data_source: str = "auto"
    own_dataset_key: str = "route1_run2"
    own_data_dir: str = "data/own_data/Geomagnetic Navigation 2026-03-19 20-10-45"
    own_map_mode: str = "raw"
    own_map_profile: str = "auto"
    own_map_npz_path: str | None = None
    own_map_offset_x_m: float = 0.0
    own_map_offset_y_m: float = 0.0
    own_route_xy_m: list[list[float]] | None = None
    own_initial_heading_deg: float | None = None
    own_use_route_initial_heading: bool = True
    own_mirror_y: bool = False
    own_heading_offset_deg: float = -90.0
    own_heading_method: str = "gyro"
    own_quaternion_use_magnetometer: bool = False
    own_gyro_bias_stationary_min_duration_s: float = 0.0
    own_gyro_rate_scale: float = 1.0
    own_trim_head: int = 0
    own_trim_tail: int = 0
    own_pf_smoothing_alpha: float = 0.3
    own_pf_smoothing_mode: str = "ema"
    own_vector_map_enabled: bool = False
    own_vector_map_path: str = "data/processed/own_vector_map.npz"
    own_vector_weight: float = 0.10
    own_vector_angle_sigma_deg: float = 25.0
    own_vector_reject_deg: float = 60.0
    own_vector_norm_tolerance_ratio: float = 0.35
    own_alignment_mode: str = "active_walk_uniform_speed"
    own_heading_snap_deg: float = 0.0
    own_step_peak_prominence: float = 0.30
    own_step_min_interval_s: float = 0.40
    own_step_weinberg_k: float = 0.31
    own_step_length_scale: float = 1.0
    own_progress_template_json: str | None = None
    own_progress_correction_gain: float = 0.0
    own_repeat_progress_enabled: bool = True
    own_repeat_progress_gain: float = 0.30
    own_step_cadence_weight: float = 0.0
    own_step_variability_weight: float = 0.0
    own_pf_joint_calibration: bool = True
    own_pf_recovery_enabled: bool = True
    own_pf_warning_streak: int = 2
    own_pf_expand_streak: int = 4
    own_pf_reinitialize_streak: int = 7
    own_initial_anchor_tolerance_m: float = 1.0
    own_gyro_heading_window_steps: int = 5
    own_gyro_heading_fault_threshold_deg: float = 110.0
    own_gyro_heading_clear_threshold_deg: float = 15.0
    own_gyro_heading_clear_streak: int = 3
    # Development-only fault injection. Normal positioning leaves this unset.
    # Supported kinds are magnetic_bias, magnetic_noise, magnetic_dropout,
    # gyro_bias, and initial_position_offset.
    own_fault_injection: dict[str, Any] | None = None


DEFAULT_UJI_DATA_ROOT = "data/raw"
DEFAULT_OWN_BRANCH_DATA_DIR = "data/own_data/Geomagnetic Navigation 2026-03-19 20-10-45"


_OWN_FAULT_KINDS = {
    "magnetic_bias",
    "magnetic_noise",
    "magnetic_dropout",
    "gyro_bias",
    "initial_position_offset",
}


def prepare_own_fault_injection(spec, total_frames):
    """Validate a development fault specification and resolve its frame window."""
    if not spec:
        return None
    fault = dict(spec)
    kind = str(fault.get("kind", "")).strip().lower()
    if kind not in _OWN_FAULT_KINDS:
        raise ValueError(
            f"Unsupported own fault kind: {kind!r}. "
            f"Use one of {sorted(_OWN_FAULT_KINDS)}."
        )
    start_fraction = float(fault.get("start_fraction", 0.30))
    end_fraction = float(fault.get("end_fraction", 0.55))
    if not 0.0 <= start_fraction < end_fraction <= 1.0:
        raise ValueError(
            "Fault start_fraction and end_fraction must satisfy "
            "0 <= start < end <= 1."
        )
    frame_count = max(1, int(total_frames))
    start_frame = min(frame_count - 1, int(math.floor(start_fraction * frame_count)))
    end_frame = min(
        frame_count,
        max(start_frame + 1, int(math.ceil(end_fraction * frame_count))),
    )
    default_magnitudes = {
        "magnetic_bias": 30.0,
        "magnetic_noise": 22.0,
        "magnetic_dropout": 0.0,
        "gyro_bias": 0.90,
        "initial_position_offset": 2.0,
    }
    return {
        "name": str(fault.get("name", kind)),
        "kind": kind,
        "start_fraction": start_fraction,
        "end_fraction": end_fraction,
        "start_frame": int(start_frame),
        "end_frame_exclusive": int(end_frame),
        "magnitude": float(
            fault.get("magnitude", default_magnitudes[kind])
        ),
        "seed": int(fault.get("seed", 20260801)),
        "affected_sensor_frames": int(end_frame - start_frame),
    }


def apply_own_sensor_fault(mag, acc, gyro, frame_idx, fault, rng):
    """Return copied sensor vectors with a deterministic validation fault."""
    mag_out = np.asarray(mag, dtype=float).copy()
    acc_out = np.asarray(acc, dtype=float).copy()
    gyro_out = np.asarray(gyro, dtype=float).copy()
    if not fault or fault["kind"] == "initial_position_offset":
        return mag_out, acc_out, gyro_out, False
    active = fault["start_frame"] <= int(frame_idx) < fault["end_frame_exclusive"]
    if not active:
        return mag_out, acc_out, gyro_out, False

    magnitude = float(fault["magnitude"])
    kind = fault["kind"]
    if kind == "magnetic_bias":
        mag_out[:3] += magnitude * np.asarray([1.0, -0.55, 0.30])
    elif kind == "magnetic_noise":
        mag_out[:3] += rng.normal(0.0, magnitude, size=3)
    elif kind == "magnetic_dropout":
        # A zero vector models an unavailable/invalid magnetometer sample
        # without introducing NaNs into the established numerical pipeline.
        mag_out[:3] = 0.0
    elif kind == "gyro_bias":
        gyro_out[2] += magnitude
    return mag_out, acc_out, gyro_out, True


def update_heading_integrity(
    heading_delta_history,
    *,
    fault_active=False,
    clear_streak=0,
    window_steps=5,
    fault_threshold_deg=110.0,
    clear_threshold_deg=15.0,
    required_clear_streak=3,
):
    """Detect implausible sustained yaw while preserving ordinary 90° turns."""
    window = max(2, int(window_steps))
    recent = list(heading_delta_history)[-window:]
    net_delta = float(sum(float(value) for value in recent))
    direction = 1.0 if net_delta >= 0.0 else -1.0
    same_direction = [
        float(value) for value in recent if direction * float(value) > 0.0
    ]
    estimated_bias_delta = (
        float(np.median(np.asarray(same_direction, dtype=float)))
        if same_direction
        else 0.0
    )
    enough_history = len(recent) >= window
    started = bool(
        not fault_active
        and enough_history
        and abs(math.degrees(net_delta)) > float(fault_threshold_deg)
    )
    active = bool(fault_active or started)
    current_clear_streak = int(clear_streak)
    if active:
        short_window = list(heading_delta_history)[-3:]
        short_max_delta_deg = max(
            (abs(math.degrees(value)) for value in short_window),
            default=math.inf,
        )
        if len(short_window) >= 3 and short_max_delta_deg < float(
            clear_threshold_deg
        ):
            current_clear_streak += 1
        else:
            current_clear_streak = 0
        if current_clear_streak >= max(1, int(required_clear_streak)):
            active = False
            current_clear_streak = 0
    return {
        "fault_active": active,
        "fault_started": started,
        "clear_streak": current_clear_streak,
        "window_net_delta_deg": float(math.degrees(net_delta)),
        "estimated_bias_delta_rad": estimated_bias_delta,
        "estimated_bias_delta_deg": float(
            math.degrees(estimated_bias_delta)
        ),
    }


def resolve_uji_selection(selection):
    token = str(selection or "tt02").strip()
    if not token:
        token = "tt02"

    path = Path(token)
    if path.suffix:
        test_file = token
    elif token.isdigit():
        test_file = f"tt{int(token):02d}.txt"
    elif token.lower().startswith("tt"):
        test_file = f"{token}.txt"
    else:
        test_file = token

    return {
        "uji_test_file": test_file,
        "uji_data_root": DEFAULT_UJI_DATA_ROOT,
    }


def resolve_own_selection(selection):
    token = str(selection or "own_branch").strip()
    if not token:
        token = "own_branch"

    if token in available_own_dataset_keys():
        return {
            "own_profile": "package",
            "own_data_source": "registry",
            "own_dataset_key": token,
            "own_data_dir": get_own_dataset_spec(token)["dataset_dir"],
        }

    if token in {"own_branch", "legacy", "web"}:
        return {
            "own_profile": "own_branch",
            "own_data_source": "directory",
            "own_dataset_key": "own_branch",
            "own_data_dir": DEFAULT_OWN_BRANCH_DATA_DIR,
        }

    return {
        "own_profile": "own_branch",
        "own_data_source": "directory",
        "own_dataset_key": Path(token).name or "own_branch",
        "own_data_dir": token,
    }


def build_uji_configs():
    pdr_config = PDRConfig(
        step_judge="peak_dynamic",
        step_judge_params={
            "peak_sigma": 0.4,
            "peak_prominence": 0.2,
            "min_samples_per_step": 4.5,
        },
        step_length="weinberg",
        step_length_params={"weinberg_k": 0.45},
        heading="gyro",
        heading_params={"dt": 0.01},
        mag="norm_mean",
    )
    pf_config = PFConfig(
        state_params={
            "num_particles": 5000,
            "min_particles": 2000,
            "max_particles": 10000000000000,
        },
        motion="gaussian",
        motion_params={"heading_noise_std": 0.03, "step_noise_std": 0.03},
        weight="ddtw",
        weight_params={"sigma": 0.1, "max_hist": 100},
        particle_size="kld",
        particle_size_params={"epsilon": 0.10, "bin_size_xy": 0.5, "bin_size_theta": 0.35},
        resample_trigger="ess_or_target",
        resample_trigger_params={"ess_ratio_threshold": 0.40},
        resample="systematic",
        resample_params={"inject_ratio": 0.10, "noise_scale": 0.08},
    )
    return pdr_config, pf_config


def build_own_package_configs():
    # Own data needs a less aggressive magnetic likelihood than the UJI defaults.
    pdr_config = PDRConfig(
        step_judge="peak_dynamic",
        step_judge_params={
            "peak_sigma": 0.45,
            "peak_prominence": 0.30,
            "min_samples_per_step": 15,
            "min_step_interval_s": 0.40,
        },
        step_length="adaptive",
        step_length_params={
            "weinberg_k": 0.31,
            "base_weight": 1.0,
            "cadence_weight": 0.0,
            "variability_weight": 0.0,
        },
        heading="gyro",
        heading_params={
            "dt": 0.01,
            "calibrate_gyro_bias": True,
            # The controlled captures keep the phone face-up. A simple
            # omega·gravity projection is not a full attitude solution and
            # over-rotates route1; keep device-Z integration until a proper
            # quaternion/ESKF implementation is available.
            "project_gyro_to_gravity": False,
        },
        mag="norm_mean",
    )
    pf_config = PFConfig(
        state_params={
            "num_particles": 5000,
            "min_particles": 2000,
            "max_particles": 10000000000000,
            "map_knn_k": 7,
            "map_idw_power": 1.5,
            "init_position_std": 0.20,
            "init_step_scale_std": 0.08,
            "min_step_scale": 0.70,
            "max_step_scale": 1.25,
            "init_heading_bias_std": 0.06,
        },
        motion="gaussian",
        motion_params={
            "heading_noise_std": 0.03,
            "step_noise_std": 0.03,
            "turn_heading_noise_std": 0.12,
            "turn_threshold_rad": 0.14,
            "step_scale_random_walk_std": 0.005,
            "heading_bias_random_walk_std": 0.004,
        },
        weight="ddtw",
        weight_params={
            "sigma": 1.0,
            "max_hist": 100,
            "calibrate_bias": True,
            "bias_calibration_updates": 5,
        },
        particle_size="kld",
        particle_size_params={"epsilon": 0.10, "bin_size_xy": 0.5, "bin_size_theta": 0.35},
        resample_trigger="ess_or_target",
        resample_trigger_params={"ess_ratio_threshold": 0.40},
        resample="systematic",
        resample_params={"inject_ratio": 0.10, "noise_scale": 0.08},
    )
    return pdr_config, pf_config


def build_own_branch_configs():
    pdr_config = PDRConfig(
        step_judge="peak_dynamic",
        step_judge_params={
            "peak_sigma": 0.45,
            "peak_prominence": 0.30,
            "min_samples_per_step": 15,
        },
        step_length="weinberg",
        step_length_params={"weinberg_k": 0.45},
        heading="gyro",
        heading_params={"dt": None, "alpha": 0.90},
        mag="norm_mean",
    )
    pf_config = PFConfig(
        state_params={
            "num_particles": 5000,
            "min_particles": 2000,
            "map_knn_k": 7,
            "map_idw_power": 1.5,
        },
        motion="gaussian",
        motion_params={"heading_noise_std": 0.12, "step_noise_std": 0.22},
        weight="ddtw",
        weight_params={"sigma": 0.5},
        particle_size="kld",
        particle_size_params={"epsilon": 0.10, "bin_size_xy": 0.5, "bin_size_theta": 0.35},
        resample_trigger="ess_or_target",
        resample_trigger_params={"ess_ratio_threshold": 0.40},
        resample="systematic",
        resample_params={"inject_ratio": 0.10, "noise_scale": 0.08},
    )
    return pdr_config, pf_config


def build_own_configs(profile="own_branch"):
    token = str(profile).strip().lower()
    if token in {"own_branch", "legacy", "web"}:
        return build_own_branch_configs()
    if token in {"package", "registry"}:
        return build_own_package_configs()
    raise ValueError(f"Unsupported own profile: {profile}. Use 'own_branch' or 'package'.")


def build_configs(branch: str):
    token = str(branch).strip().lower()
    if token == "uji":
        return build_uji_configs()
    if token == "own":
        return build_own_configs()
    raise ValueError(f"Unsupported branch: {branch}. Use 'uji' or 'own'.")


def build_own_tile_matrix(raw_matrix, mode="raw", rows=8, cols=12):
    arr = np.asarray(raw_matrix, dtype=float)
    if arr.ndim != 2 or arr.shape[0] == 0 or arr.shape[1] == 0:
        raise ValueError("Own magnetic map input must be a non-empty 2D matrix.")

    token = str(mode).strip().lower()
    if token == "raw":
        return arr
    if token not in {"tile12", "tile_12"}:
        raise ValueError(f"Unsupported own map mode: {mode}. Use 'raw' or 'tile12'.")

    ridx = np.linspace(0, arr.shape[0] - 1, rows, dtype=int)
    cidx = np.linspace(0, arr.shape[1] - 1, cols, dtype=int)
    return arr[ridx][:, cidx]


def _load_own_map_npz(path):
    with np.load(path, allow_pickle=False) as data:
        if not hasattr(data, "files"):
            raise ValueError(f"Own map npz has no named arrays: {path}")
        grid = None
        for key in data.files:
            arr = np.asarray(data[key])
            if arr.ndim == 2 and arr.size > 0:
                grid = np.asarray(arr, dtype=float)
                break
        if grid is None:
            raise ValueError(f"Own map npz contains no valid 2D grid: {path}")
        scalars = {}
        for key in ("x_min", "x_max", "y_min", "y_max"):
            if key in data:
                scalars[key] = float(np.asarray(data[key]).reshape(-1)[0])
    return grid, scalars


def resolve_own_map_profile(config: BranchConfig):
    token = str(config.own_map_profile or "auto").strip().lower()
    if token == "auto":
        profile = str(config.own_profile).strip().lower()
        return (
            "survey_kriging"
            if profile in {"own_branch", "legacy", "web"}
            else "tile_manifest"
        )
    if token not in {"survey_kriging", "tile_manifest"}:
        raise ValueError(
            "Unsupported own map profile: "
            f"{config.own_map_profile}. Use 'auto', 'survey_kriging', or "
            "'tile_manifest'."
        )
    return token


def resolve_own_data_source(config: BranchConfig):
    """Resolve where sensor files come from, independently of algorithm tuning."""
    token = str(config.own_data_source or "auto").strip().lower()
    if token == "auto":
        profile = str(config.own_profile).strip().lower()
        return "registry" if profile in {"package", "registry"} else "directory"
    if token not in {"registry", "directory"}:
        raise ValueError(
            "Unsupported own data source: "
            f"{config.own_data_source}. Use 'auto', 'registry', or 'directory'."
        )
    return token


def validate_own_route_bounds(route, geomag_map):
    """Fail early when route coordinates and map geometry do not match."""
    points = np.asarray(route, dtype=float)
    if points.ndim != 2 or points.shape[0] < 2 or points.shape[1] < 2:
        raise ValueError("Own route must contain at least two finite [x, y] points.")
    points = points[:, :2]
    if not np.all(np.isfinite(points)):
        raise ValueError("Own route contains non-finite coordinates.")

    x_min = float(geomag_map["rangex_min"])
    x_max = float(geomag_map["rangex_max"])
    y_min = float(geomag_map["rangey_min"])
    y_max = float(geomag_map["rangey_max"])
    tolerance = 1e-6
    outside = np.flatnonzero(
        (points[:, 0] < x_min - tolerance)
        | (points[:, 0] > x_max + tolerance)
        | (points[:, 1] < y_min - tolerance)
        | (points[:, 1] > y_max + tolerance)
    )
    if outside.size:
        index = int(outside[0])
        x, y = points[index]
        raise ValueError(
            "Own route and magnetic map use incompatible coordinates: "
            f"point {index + 1} ({x:.3f}, {y:.3f}) is outside map bounds "
            f"x=[{x_min:.3f}, {x_max:.3f}], "
            f"y=[{y_min:.3f}, {y_max:.3f}]."
        )


def attach_own_vector_map(result, map_profile, vector_map_path):
    """Attach a regular three-axis map without changing scalar-map behaviour."""
    path = Path(vector_map_path)
    if not path.exists():
        raise FileNotFoundError(
            f"Own vector map not found: {path}. "
            "Build it with `python -m Geomag.vector_map`."
        )
    with np.load(path, allow_pickle=False) as data:
        if "line_vectors" not in data:
            raise ValueError(f"Vector map has no line_vectors array: {path}")
        line_vectors = np.asarray(data["line_vectors"], dtype=float)
        x_positions = np.asarray(data.get("x_line_positions_m", []), dtype=float)
        y_positions = np.asarray(data.get("y_sample_positions_m", []), dtype=float)
    if (
        line_vectors.ndim != 3
        or line_vectors.shape[2] != 3
        or line_vectors.shape[0] < 2
        or line_vectors.shape[1] < 2
    ):
        raise ValueError(
            f"Vector map must have shape (lines, samples, 3): {line_vectors.shape}"
        )

    profile = str(map_profile).strip().lower()
    if profile == "survey_kriging":
        if (
            x_positions.size != line_vectors.shape[0]
            or y_positions.size != line_vectors.shape[1]
        ):
            raise ValueError("Vector map coordinate arrays do not match line_vectors.")
        vector_grid = np.transpose(line_vectors, (1, 0, 2))
        meta = {
            "origin_xy_m": [float(x_positions[0]), float(y_positions[0])],
            "spacing_x_m": float(
                (x_positions[-1] - x_positions[0])
                / max(x_positions.size - 1, 1)
            ),
            "spacing_y_m": float(
                (y_positions[-1] - y_positions[0])
                / max(y_positions.size - 1, 1)
            ),
            "anchor": "corner",
            "flip_y": False,
        }
    elif profile == "tile_manifest":
        # This mirrors the established scalar tile-manifest interpretation.
        # It is retained for a controlled ablation, while survey_kriging is the
        # physically documented geometry of the scan lines.
        rows, cols = line_vectors.shape[:2]
        vector_grid = line_vectors
        meta = {
            "origin_xy_m": [0.0, 0.0],
            "spacing_x_m": 11.52 / float(cols),
            "spacing_y_m": 8.80 / float(rows),
            "anchor": "center",
            "flip_y": True,
        }
    else:
        raise ValueError(
            "The reconstructed vector map requires survey_kriging or "
            "tile_manifest geometry; custom npz geometry is ambiguous."
        )

    result["vector_grid"] = vector_grid
    result["vector_grid_meta"] = meta
    result["vector_map_source"] = str(path)
    result["vector_map_frame"] = "survey_phone"
    return result


def build_own_geomag_map(config: BranchConfig):
    map_profile = resolve_own_map_profile(config)
    map_offset_x_m = float(config.own_map_offset_x_m)
    map_offset_y_m = float(config.own_map_offset_y_m)
    npz_path = config.own_map_npz_path
    if npz_path is None and map_profile == "survey_kriging":
        npz_path = "data/own_data/my_mag_map.npz"
    if npz_path:
        grid, bounds = _load_own_map_npz(npz_path)
        rows, cols = grid.shape
        tile_size_x_m = (
            (bounds["x_max"] - bounds["x_min"]) / max(cols - 1, 1)
            if {"x_min", "x_max"} <= bounds.keys()
            else 0.02
        )
        tile_size_y_m = (
            (bounds["y_max"] - bounds["y_min"]) / max(rows - 1, 1)
            if {"y_min", "y_max"} <= bounds.keys()
            else 0.02
        )
        result = get_map(
            source="own",
            own_grid_array=grid,
            own_grid_meta={
                "tile_size_x_m": tile_size_x_m,
                "tile_size_y_m": tile_size_y_m,
                "anchor": "corner",
                "flip_y": False,
                "origin_xy_m": [
                    bounds.get("x_min", 0.0) + map_offset_x_m,
                    bounds.get("y_min", 0.0) + map_offset_y_m,
                ],
                "force_tile_matrix": True,
            },
        )
        result["own_map_profile"] = (
            "custom_npz" if config.own_map_npz_path else map_profile
        )
        result["geometry_source"] = str(npz_path)
        if config.own_vector_map_enabled:
            attach_own_vector_map(
                result,
                result["own_map_profile"],
                config.own_vector_map_path,
            )
        return result

    import importlib.util
    _map_path = Path(__file__).resolve().parent.parent / "data" / "own_data" / "magnetometer_map_own.py"
    _spec = importlib.util.spec_from_file_location("magnetometer_map_own", str(_map_path))
    if _spec is None or _spec.loader is None:
        raise ImportError(f"Unable to load own magnetic map module: {_map_path}")
    _map_mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_map_mod)
    own_map_raw = _map_mod.data

    tile_matrix = build_own_tile_matrix(own_map_raw, mode=config.own_map_mode, rows=8, cols=12)
    rows, cols = tile_matrix.shape
    if str(config.own_map_mode).strip().lower() == "raw":
        tile_size_x_m = 11.52 / float(cols)
        tile_size_y_m = 8.80 / float(rows)
        oversample = 1
    else:
        tile_size_x_m = 0.96
        tile_size_y_m = 1.10
        oversample = 3

    if oversample > 1:
        from Geomag.algorithms import _bilinear_upsample
        tile_matrix = _bilinear_upsample(tile_matrix, oversample)
        tile_size_x_m = tile_size_x_m / float(oversample)
        tile_size_y_m = tile_size_y_m / float(oversample)

    result = get_map(
        source="own",
        own_grid_array=tile_matrix,
        own_grid_meta={
            "tile_size_x_m": tile_size_x_m,
            "tile_size_y_m": tile_size_y_m,
            "anchor": "center",
            "flip_y": True,
            "origin_xy_m": [map_offset_x_m, map_offset_y_m],
        },
    )
    result["own_map_profile"] = map_profile
    result["geometry_source"] = "data/own_data_package/manifest.json"
    if config.own_vector_map_enabled:
        attach_own_vector_map(
            result,
            map_profile,
            config.own_vector_map_path,
        )
    return result


def parse_route_control_points(route_text: str):
    points = []
    for pair in str(route_text or "").split(";"):
        token = pair.strip()
        if not token or "," not in token:
            continue
        x_str, y_str = token.split(",", 1)
        points.append([float(x_str.strip()), float(y_str.strip())])
    if len(points) < 2:
        raise ValueError("Route control points must contain at least two x,y pairs.")
    return points


def default_own_branch_route_controls():
    return parse_route_control_points("0.96,0; 0.96,5.05; 3.84,5.05")


def densify_route_controls(route_xy, step_size=0.05):
    pts = _polyline_points(route_xy)
    dense = []
    step = max(float(step_size), 1e-6)
    for i in range(pts.shape[0] - 1):
        p1 = pts[i]
        p2 = pts[i + 1]
        dist = float(np.linalg.norm(p2 - p1))
        n = max(2, int(dist / step))
        endpoint = i == pts.shape[0] - 2
        xs = np.linspace(float(p1[0]), float(p2[0]), n, endpoint=endpoint)
        ys = np.linspace(float(p1[1]), float(p2[1]), n, endpoint=endpoint)
        for x, y in zip(xs, ys, strict=True):
            dense.append([float(x), float(y)])
    return dense


def _polyline_points(route_xy):
    arr = np.asarray(route_xy, dtype=float)
    if arr.ndim != 2 or arr.shape[0] < 2 or arr.shape[1] < 2:
        raise ValueError("route_xy must be shape (N, 2) with N >= 2.")
    return arr[:, :2]


def _polyline_cumulative(route_xy):
    pts = _polyline_points(route_xy)
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    total = float(cum[-1])
    if total <= 1e-9:
        raise ValueError("Route polyline length is zero.")
    return pts, cum, total


def sample_route_segment(route_xy, start_frac=0.0, end_frac=1.0, n=300):
    pts, cum, total = _polyline_cumulative(route_xy)
    start_frac = float(np.clip(start_frac, 0.0, 1.0))
    end_frac = float(np.clip(end_frac, 0.0, 1.0))
    if end_frac <= start_frac:
        raise ValueError("end_frac must be larger than start_frac.")

    dist = np.linspace(start_frac * total, end_frac * total, max(2, int(n)), dtype=float)
    x = np.interp(dist, cum, pts[:, 0])
    y = np.interp(dist, cum, pts[:, 1])
    return np.column_stack([x, y])


def slice_route_controls(route_xy, start_frac=0.0, end_frac=1.0):
    """Return the control-point polyline inside a normalized route interval."""
    pts, cumulative, total = _polyline_cumulative(route_xy)
    start_frac = float(np.clip(start_frac, 0.0, 1.0))
    end_frac = float(np.clip(end_frac, 0.0, 1.0))
    if end_frac <= start_frac:
        raise ValueError("end_frac must be larger than start_frac.")

    start_distance = start_frac * total
    end_distance = end_frac * total
    controls = [
        [
            float(np.interp(start_distance, cumulative, pts[:, 0])),
            float(np.interp(start_distance, cumulative, pts[:, 1])),
        ]
    ]
    for index, distance in enumerate(cumulative[1:-1], start=1):
        if start_distance < float(distance) < end_distance:
            controls.append([float(pts[index, 0]), float(pts[index, 1])])
    controls.append(
        [
            float(np.interp(end_distance, cumulative, pts[:, 0])),
            float(np.interp(end_distance, cumulative, pts[:, 1])),
        ]
    )
    return controls


def corrected_own_heading(heading_angle, mirror_y=True, heading_offset_deg=0.0):
    ang = float(heading_angle) + math.radians(float(heading_offset_deg))
    if mirror_y:
        ang = -ang
    return float(((ang + math.pi) % (2.0 * math.pi)) - math.pi)


def snap_heading_to_grid(heading_angle, anchor_angle, interval_deg=90.0):
    """Snap heading to the nearest direction in a known orthogonal/grid walk."""
    interval = math.radians(float(interval_deg))
    if interval <= 0.0:
        return float(((float(heading_angle) + math.pi) % (2.0 * math.pi)) - math.pi)

    delta = math.atan2(
        math.sin(float(heading_angle) - float(anchor_angle)),
        math.cos(float(heading_angle) - float(anchor_angle)),
    )
    direction_index = math.floor(delta / interval + 0.5)
    if delta < 0.0:
        direction_index = math.ceil(delta / interval - 0.5)
    snapped = float(anchor_angle) + float(direction_index) * interval
    return float(((snapped + math.pi) % (2.0 * math.pi)) - math.pi)


def update_grid_heading_state(
    heading_angle,
    current_grid_heading,
    interval_deg=90.0,
    departure_count=0,
    departure_direction=0,
    confirm_steps=3,
):
    """Update a grid heading after sustained departure from its current axis.

    A nearest-axis snap waits until the measured turn exceeds half the grid
    interval. For the controlled captures that is too late because the phone
    recorded only part of the physical 90-degree turn. Three consecutive
    departures reject isolated straight-line gyro noise while committing the
    known grid turn near its onset.
    """
    interval = math.radians(float(interval_deg))
    if interval <= 0.0:
        return (
            float(((float(heading_angle) + math.pi) % (2.0 * math.pi)) - math.pi),
            0,
            0,
        )

    current = float(current_grid_heading)
    delta = math.atan2(
        math.sin(float(heading_angle) - current),
        math.cos(float(heading_angle) - current),
    )
    threshold = math.radians(
        max(8.0, min(30.0, 0.155 * float(interval_deg)))
    )
    direction = 1 if delta > 0.0 else (-1 if delta < 0.0 else 0)
    if abs(delta) >= threshold and direction != 0:
        count = int(departure_count) + 1 if direction == departure_direction else 1
    else:
        count = 0
        direction = 0

    if count >= max(1, int(confirm_steps)):
        current = float(
            ((current + direction * interval + math.pi) % (2.0 * math.pi))
            - math.pi
        )
        count = 0
        direction = 0
    return current, count, direction


def infer_initial_heading_from_route(route_xy):
    pts = _polyline_points(route_xy)
    for i in range(1, pts.shape[0]):
        dx = float(pts[i, 0] - pts[0, 0])
        dy = float(pts[i, 1] - pts[0, 1])
        if math.hypot(dx, dy) > 1e-9:
            return float(math.atan2(dy, dx))
    raise ValueError("Cannot infer initial heading from a zero-length route.")


def summarize_error(track, route, geomag_map, progress=None):
    route_x, route_y = GeomagPipeline._route_to_xy_for_error(route, geomag_map)
    if route_x is None or route_y is None:
        return None, None
    series = GeomagPipeline._compute_error_series(track, route_x, route_y, progress=progress)
    stats = GeomagPipeline._summarize_error(series)
    return series, stats


def summarize_cross_track_error(track, route, geomag_map):
    route_x, route_y = GeomagPipeline._route_to_xy_for_error(route, geomag_map)
    if route_x is None or route_y is None:
        return None, None
    series = GeomagPipeline._compute_cross_track_error_series(track, route_x, route_y)
    stats = GeomagPipeline._summarize_error(series)
    return series, stats


def _detect_heading_turns(heading_history, progress, threshold_deg=25.0, window_steps=3):
    headings = np.asarray(heading_history, dtype=float).reshape(-1)
    progress_arr = np.asarray(progress, dtype=float).reshape(-1)
    if headings.size < 2 or progress_arr.size != headings.size:
        return []
    window = max(1, int(window_steps))
    delta = np.zeros(headings.size, dtype=float)
    for idx in range(1, headings.size):
        start = max(0, idx - window)
        delta[idx] = math.atan2(
            math.sin(headings[idx] - headings[start]),
            math.cos(headings[idx] - headings[start]),
        )
    candidates = np.flatnonzero(np.abs(delta) >= math.radians(float(threshold_deg)))
    turns = []
    for idx in candidates:
        item = {
            "step_index": int(idx),
            "turn_start_step_index": int(max(0, idx - window)),
            "progress": float(progress_arr[idx]),
            "window_delta_heading_deg": float(math.degrees(delta[idx])),
        }
        if turns and int(idx) - turns[-1]["step_index"] <= window:
            if abs(item["window_delta_heading_deg"]) > abs(
                turns[-1]["window_delta_heading_deg"]
            ):
                turns[-1] = item
        else:
            turns.append(item)
    return turns


def _reference_turn_progress(route_xy):
    points, cumulative, total = _polyline_cumulative(route_xy)
    if points.shape[0] <= 2:
        return []
    return [float(value / total) for value in cumulative[1:-1]]


def infer_active_walk_interval(
    step_times,
    capture_start_time,
    capture_end_time,
):
    """Estimate walking bounds from step events without using route labels.

    Step detectors normally fire near one point in a gait cycle rather than
    exactly at motion onset or endpoint. Half of the robust median step
    interval is therefore added on both sides. The estimate is clipped to the
    consumed sensor interval, so short captures remain unchanged.
    """
    capture_start = float(capture_start_time)
    capture_end = float(capture_end_time)
    if capture_end <= capture_start:
        raise ValueError("capture_end_time must be greater than capture_start_time.")

    times = np.asarray(step_times, dtype=float).reshape(-1)
    times = times[np.isfinite(times)]
    times = times[(times >= capture_start) & (times <= capture_end)]
    times = np.unique(times)
    if times.size < 2:
        return {
            "start_time": capture_start,
            "end_time": capture_end,
            "duration": capture_end - capture_start,
            "median_step_interval": None,
            "padding": 0.0,
            "head_excluded": 0.0,
            "tail_excluded": 0.0,
            "confidence": "low",
            "reason": "fewer_than_two_step_events",
        }

    intervals = np.diff(times)
    median_interval = float(np.median(intervals))
    robust_intervals = intervals[
        (intervals >= 0.5 * median_interval) & (intervals <= 1.8 * median_interval)
    ]
    if robust_intervals.size:
        median_interval = float(np.median(robust_intervals))
    padding = 0.5 * median_interval
    active_start = max(capture_start, float(times[0] - padding))
    active_end = min(capture_end, float(times[-1] + padding))
    if active_end <= active_start:
        active_start, active_end = capture_start, capture_end
        confidence = "low"
        reason = "invalid_estimated_interval"
    else:
        confidence = "high" if times.size >= 4 else "medium"
        reason = "step_event_envelope"
    return {
        "start_time": float(active_start),
        "end_time": float(active_end),
        "duration": float(active_end - active_start),
        "median_step_interval": float(median_interval),
        "padding": float(padding),
        "head_excluded": float(active_start - capture_start),
        "tail_excluded": float(capture_end - active_end),
        "confidence": confidence,
        "reason": reason,
    }


def build_uniform_walk_progress(
    step_times,
    capture_start_time,
    capture_end_time,
    mode="active_walk_uniform_speed",
):
    """Map detected steps to reference-route progress for constant-speed tests."""
    times = np.asarray(step_times, dtype=float).reshape(-1)
    token = str(mode).strip().lower()
    if token == "capture_time":
        interval = {
            "start_time": float(capture_start_time),
            "end_time": float(capture_end_time),
            "duration": float(capture_end_time) - float(capture_start_time),
            "median_step_interval": None,
            "padding": 0.0,
            "head_excluded": 0.0,
            "tail_excluded": 0.0,
            "confidence": "legacy",
            "reason": "full_capture_interval",
        }
    elif token == "active_walk_uniform_speed":
        interval = infer_active_walk_interval(
            times,
            capture_start_time=capture_start_time,
            capture_end_time=capture_end_time,
        )
    else:
        raise ValueError(
            f"Unsupported own alignment mode: {mode}. "
            "Use 'active_walk_uniform_speed' or 'capture_time'."
        )

    duration = max(float(interval["duration"]), 1e-9)
    progress = np.clip(
        (times - float(interval["start_time"])) / duration,
        0.0,
        1.0,
    )
    return progress.astype(float).tolist(), interval


def _extract_repeat_progress_template(dataset_key, *, step_judge_params):
    """Extract per-step magnetic vectors from one registered capture."""
    from Geomag import algorithms

    spec = assert_own_dataset_evaluable(dataset_key)
    frames = algorithms._load_own_sensor_frames(spec["dataset_dir"])
    if len(frames) < 3:
        raise ValueError(f"Repeat capture {dataset_key} has too few sensor frames.")
    state_keys = ("last_sensor_frame", "last_step_samples", "last_step_time")
    saved_state = {key: algorithms._ALGO_STATE.get(key) for key in state_keys}
    buffer = []
    vectors = []
    step_times = []
    try:
        algorithms._ALGO_STATE["last_step_time"] = None
        algorithms._ALGO_STATE["last_step_samples"] = None
        for frame in frames:
            algorithms._ALGO_STATE["last_sensor_frame"] = frame
            sample = [frame["acc"], frame["gyro"], frame["mag"], frame["time"]]
            buffer.append(sample)
            if not algorithms.judge_step(
                buffer,
                method="peak_dynamic",
                **dict(step_judge_params or {}),
            ):
                continue
            magnetic = np.asarray([item[2][:3] for item in buffer], dtype=float)
            magnitude = np.linalg.norm(magnetic, axis=1)
            valid = (
                np.all(np.isfinite(magnetic), axis=1)
                & np.isfinite(magnitude)
                & (magnitude >= 10.0)
                & (magnitude <= 100.0)
            )
            if np.any(valid):
                vectors.append(np.median(magnetic[valid], axis=0))
                step_times.append(float(frame["time"]))
            buffer.clear()
    finally:
        for key, value in saved_state.items():
            algorithms._ALGO_STATE[key] = value
    if len(vectors) < 3:
        raise ValueError(
            f"Repeat capture {dataset_key} produced fewer than three valid steps."
        )
    progress, _ = build_uniform_walk_progress(
        step_times,
        capture_start_time=float(frames[0]["time"]),
        capture_end_time=float(frames[-1]["time"]),
    )
    return np.asarray(vectors, dtype=float), np.asarray(progress, dtype=float)


def _build_repeat_progress_matcher(dataset_keys, *, step_judge_params):
    """Build a robust causal template from independent repeat captures."""
    keys = [dataset_keys] if isinstance(dataset_keys, str) else list(dataset_keys)
    templates = [
        _extract_repeat_progress_template(
            key,
            step_judge_params=step_judge_params,
        )
        for key in keys
    ]
    vectors, progress, _ = aggregate_progress_templates(templates)
    return OnlineMagneticProgressMatcher(vectors, progress)


def summarize_corner_errors(track, route_xy, detected_turns):
    """Compare sequential detected turns with registered interior vertices."""
    track_arr = np.asarray(track, dtype=float)
    route_arr = _polyline_points(route_xy)
    corners = route_arr[1:-1]
    matches = []
    for corner_index, turn in enumerate((detected_turns or [])[: len(corners)]):
        step_index = int(turn.get("turn_start_step_index", turn["step_index"]))
        if step_index < 0 or step_index >= len(track_arr):
            continue
        estimate = track_arr[step_index, :2]
        reference = corners[corner_index, :2]
        matches.append(
            {
                "corner_index": int(corner_index),
                "step_index": step_index,
                "progress": float(turn["progress"]),
                "estimate_xy_m": estimate.astype(float).tolist(),
                "reference_xy_m": reference.astype(float).tolist(),
                "error_m": float(np.linalg.norm(estimate - reference)),
            }
        )
    stats = GeomagPipeline._summarize_error([item["error_m"] for item in matches])
    return matches, stats


def endpoint_error(track, route_xy):
    track_arr = np.asarray(track, dtype=float)
    route_arr = _polyline_points(route_xy)
    if track_arr.size == 0:
        return None
    return float(np.linalg.norm(track_arr[-1, :2] - route_arr[-1, :2]))


def smooth_pf_output(
    previous_xy,
    raw_xy,
    *,
    mode="ema",
    alpha=0.3,
    step_len=0.0,
    heading_angle=0.0,
    weight_diagnostics=None,
    motion_diagnostics=None,
):
    """Smooth the reported PF position without changing particle state.

    ``motion_adaptive`` predicts the next displayed point from the PDR motion
    and smooths only the PF correction residual. This avoids the permanent
    spatial lag introduced by applying an EMA directly to absolute positions.
    """
    previous = np.asarray(previous_xy, dtype=float)[:2]
    raw = np.asarray(raw_xy, dtype=float)[:2]
    token = str(mode).strip().lower()
    history_weight = float(np.clip(alpha, 0.0, 0.999))
    if token == "none" or history_weight <= 0.0:
        return (float(raw[0]), float(raw[1])), {
            "mode": "none",
            "history_weight": 0.0,
            "correction_gain": 1.0,
            "residual_m": 0.0,
        }
    if token == "ema":
        output = history_weight * previous + (1.0 - history_weight) * raw
        return (float(output[0]), float(output[1])), {
            "mode": "ema",
            "history_weight": history_weight,
            "correction_gain": float(1.0 - history_weight),
            "residual_m": float(np.linalg.norm(raw - previous)),
        }
    if token != "motion_adaptive":
        raise ValueError(
            f"Unsupported PF smoothing mode: {mode}. "
            "Use 'none', 'ema', or 'motion_adaptive'."
        )

    predicted = previous + float(step_len) * np.asarray(
        [math.cos(float(heading_angle)), math.sin(float(heading_angle))],
        dtype=float,
    )
    residual = raw - predicted
    weight_diagnostics = dict(weight_diagnostics or {})
    motion_diagnostics = dict(motion_diagnostics or {})
    ess_ratio = float(
        np.clip(weight_diagnostics.get("ess_ratio", 1.0), 0.0, 1.0)
    )
    heading_delta_rad = abs(
        float(motion_diagnostics.get("heading_delta_rad", 0.0))
    )
    turn_strength = float(
        np.clip(heading_delta_rad / math.radians(45.0), 0.0, 1.0)
    )
    base_gain = 1.0 - history_weight
    correction_gain = float(
        np.clip(
            base_gain + 0.35 * turn_strength + 0.20 * (1.0 - ess_ratio),
            base_gain,
            0.90,
        )
    )
    output = predicted + correction_gain * residual
    return (float(output[0]), float(output[1])), {
        "mode": "motion_adaptive",
        "history_weight": history_weight,
        "correction_gain": correction_gain,
        "residual_m": float(np.linalg.norm(residual)),
        "ess_ratio": ess_ratio,
        "turn_strength": turn_strength,
        "predicted_xy": [float(predicted[0]), float(predicted[1])],
    }


def save_own_trajectory_plot(
    geomag_map,
    route,
    pdr_list,
    pf_list,
    output_png,
    show=False,
    pf_raw_list=None,
    title=None,
):
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        return None

    fig, ax = plt.subplots(figsize=(8, 6), dpi=130)
    z = np.asarray(geomag_map.get("grid_array"), dtype=float)
    if z.ndim == 2 and z.size > 0:
        meta = geomag_map.get("grid_map_contract", {}).get("meta", {})
        flip_y = bool(meta.get("flip_y", True))
        z_plot = np.flipud(z) if flip_y else z
        ax.imshow(
            z_plot,
            origin="lower",
            extent=[
                geomag_map["rangex_min"],
                geomag_map["rangex_max"],
                geomag_map["rangey_min"],
                geomag_map["rangey_max"],
            ],
            aspect="equal",
            cmap="viridis",
            alpha=0.9,
        )

    route_arr = np.asarray(route, dtype=float)
    pdr_arr = np.asarray(pdr_list, dtype=float)
    pf_arr = np.asarray(pf_list, dtype=float)
    pf_raw_arr = np.asarray(pf_raw_list, dtype=float) if pf_raw_list is not None else None

    if route_arr.ndim == 2 and route_arr.shape[1] >= 2:
        ax.plot(route_arr[:, 0], route_arr[:, 1], "w-", linewidth=2.0, label="route")
        ax.scatter([route_arr[0, 0]], [route_arr[0, 1]], c="lime", s=30, zorder=3, label="route_start")
        ax.scatter(
            [route_arr[-1, 0]],
            [route_arr[-1, 1]],
            c="black",
            marker="x",
            s=38,
            zorder=4,
            label="route_end",
        )
    if pdr_arr.ndim == 2 and pdr_arr.shape[1] >= 2:
        ax.plot(pdr_arr[:, 0], pdr_arr[:, 1], "--", color="orange", linewidth=1.5, label="pdr")
    if pf_raw_arr is not None and pf_raw_arr.ndim == 2 and pf_raw_arr.shape[1] >= 2:
        ax.plot(
            pf_raw_arr[:, 0],
            pf_raw_arr[:, 1],
            "-",
            color="magenta",
            linewidth=1.1,
            alpha=0.75,
            label="pf_raw",
        )
    if pf_arr.ndim == 2 and pf_arr.shape[1] >= 2:
        ax.plot(pf_arr[:, 0], pf_arr[:, 1], "-", color="cyan", linewidth=1.8, label="pf_smoothed")
        ax.scatter(
            [pf_arr[-1, 0]],
            [pf_arr[-1, 1]],
            facecolors="none",
            edgecolors="cyan",
            s=42,
            zorder=4,
            label="pf_end",
        )

    ax.set_title(title or "Own Simulation")
    ax.set_xlabel("X (m)")
    ax.set_ylabel("Y (m)")
    ax.grid(True, alpha=0.2)
    ax.legend(loc="best")
    ax.set_aspect("equal")
    fig.tight_layout()

    out = Path(output_png)
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, bbox_inches="tight")
    if show:
        plt.show()
    plt.close(fig)
    return str(out)


def save_own_diagnostic_plot(
    progress,
    heading_history,
    raw_heading_history,
    step_length_history,
    ess_ratio_history,
    weight_diagnostic_history,
    reference_turn_progress,
    output_png,
    title=None,
):
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        return None

    progress_arr = np.asarray(progress, dtype=float)
    heading_deg = np.degrees(np.unwrap(np.asarray(heading_history, dtype=float)))
    step_length = np.asarray(step_length_history, dtype=float)
    ess_ratio = np.asarray(ess_ratio_history, dtype=float)
    shape_distance = np.asarray(
        [item.get("shape_distance_mean", np.nan) for item in weight_diagnostic_history],
        dtype=float,
    )
    level_residual = np.asarray(
        [item.get("level_residual_abs_mean", np.nan) for item in weight_diagnostic_history],
        dtype=float,
    )
    posterior_step_scale = np.asarray(
        [item.get("posterior_step_scale", np.nan) for item in weight_diagnostic_history],
        dtype=float,
    )
    posterior_heading_bias = np.asarray(
        [
            item.get("posterior_heading_bias_deg", np.nan)
            for item in weight_diagnostic_history
        ],
        dtype=float,
    )

    fig, axes = plt.subplots(5, 1, figsize=(10, 11), dpi=130, sharex=True)
    raw_heading_deg = np.degrees(np.unwrap(np.asarray(raw_heading_history, dtype=float)))
    axes[0].plot(progress_arr, raw_heading_deg, color="tab:gray", label="gyro")
    axes[0].plot(progress_arr, heading_deg, color="tab:blue", label="used")
    axes[0].set_ylabel("heading (deg)")
    axes[0].legend(loc="best")
    axes[1].plot(progress_arr, step_length, color="tab:orange")
    axes[1].set_ylabel("step (m)")
    axes[2].plot(progress_arr, ess_ratio, color="tab:green")
    axes[2].axhline(0.4, color="tab:red", linestyle="--", linewidth=1.0)
    axes[2].set_ylabel("ESS ratio")
    axes[3].plot(progress_arr, posterior_step_scale, label="step scale", color="tab:cyan")
    axes[3].plot(
        progress_arr,
        posterior_heading_bias,
        label="heading bias (deg)",
        color="tab:pink",
    )
    axes[3].set_ylabel("PF calibration")
    axes[3].legend(loc="best")
    axes[4].plot(progress_arr, shape_distance, label="DDTW shape", color="tab:purple")
    axes[4].plot(progress_arr, level_residual, label="level residual", color="tab:brown")
    axes[4].set_ylabel("mag residual")
    axes[4].set_xlabel("sensor time fraction")
    axes[4].legend(loc="best")

    for axis in axes:
        for turn_progress in reference_turn_progress:
            axis.axvline(float(turn_progress), color="black", alpha=0.20, linewidth=1.0)
        axis.grid(True, alpha=0.2)
    axes[0].set_title(title or "Own-data positioning diagnostics")
    fig.tight_layout()

    trajectory_path = Path(output_png)
    suffix = trajectory_path.suffix or ".png"
    out = trajectory_path.with_name(f"{trajectory_path.stem}_diagnostics{suffix}")
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, bbox_inches="tight")
    plt.close(fig)
    return str(out)


def _print_progress(current, total, width=36):
    total = max(int(total), 1)
    current = min(max(int(current), 0), total)
    update_every = max(1, int(math.ceil(total / 20.0)))
    if current not in {0, total} and current % update_every != 0:
        return
    ratio = current / total
    filled = int(width * ratio)
    bar = "#" * filled + "-" * (width - filled)
    sys.stdout.write(f"\rProgress [{bar}] {current}/{total} ({ratio * 100:5.1f}%)")
    sys.stdout.flush()


def _jsonable(value: Any):
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    return value


def _write_json(path, payload):
    if not path:
        return None
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(_jsonable(payload), indent=2), encoding="utf-8")
    return str(out)


def run_uji_branch(config: BranchConfig):
    pdr_config, pf_config = build_uji_configs()
    context = Initializer(
        num_runs=1,
        window_size=config.window_size,
        route_source="uji",
        sensor_source="uji",
        data_root=config.uji_data_root,
        uji_test_file=config.uji_test_file,
    ).create_context()

    result = Experiment(context, pdr_config=pdr_config, pf_config=pf_config).run(
        show=config.show,
        output_png=config.output_png,
        max_frames=config.max_frames,
        write_outputs=config.write_outputs,
    )
    result["branch"] = "uji"
    result["uji_test_file"] = config.uji_test_file
    if config.output_json:
        result["output_json"] = str(Path(config.output_json))
        _write_json(result["output_json"], result)
        print(f"Saved JSON: {result['output_json']}")
    return result


def run_own_branch(config: BranchConfig):
    """Run simulation on own (custom) data.

    Design note: This function manages its own sensor loop because own-data
    requires custom heading correction (``corrected_own_heading``) and route
    trimming not yet exposed through ``Experiment.run()``.  The PF update
    **does** go through the composable pipeline via ``pf_module.step()``,
    which invokes the same registered blocks as ``GeomagPipeline.run()``.

    When own-data heading/trim support is added to the pipeline config,
    this function should be refactored to use ``Experiment.run()`` like
    ``run_uji_branch`` does.
    """
    profile = str(config.own_profile).strip().lower()
    if profile not in {"own_branch", "legacy", "web", "package", "registry"}:
        raise ValueError(f"Unsupported own profile: {config.own_profile}. Use 'own_branch' or 'package'.")

    data_source = resolve_own_data_source(config)
    if data_source == "registry":
        dataset_spec = assert_own_dataset_evaluable(config.own_dataset_key)
        own_dataset_key = config.own_dataset_key
        own_data_dir = dataset_spec["dataset_dir"]
        route_controls = config.own_route_xy_m or get_true_route(
            source="own", own_dataset_key=own_dataset_key
        )
        route_full = route_controls
    else:
        own_dataset_key = None
        own_data_dir = config.own_data_dir
        custom_dataset_key = str(config.own_dataset_key or "").strip()
        if not custom_dataset_key or custom_dataset_key == "own_branch":
            custom_dataset_key = Path(own_data_dir).name or "own_branch"
        dataset_spec = {
            "key": custom_dataset_key,
            "dataset_dir": str(Path(own_data_dir).resolve()),
            "route_label": custom_dataset_key,
        }
        route_controls = config.own_route_xy_m or default_own_branch_route_controls()
        route_full = densify_route_controls(route_controls, step_size=0.05)

    geomag_map = build_own_geomag_map(config)
    if not route_full:
        raise ValueError("Own route is empty.")
    validate_own_route_bounds(route_full, geomag_map)

    full_frames = int(get_test_len(source="own", own_data_dir=own_data_dir, own_dataset_key=own_dataset_key))
    head = max(0, int(config.own_trim_head))
    tail = max(0, int(config.own_trim_tail))
    usable_frames = full_frames - head - tail
    if usable_frames <= 1:
        raise ValueError(
            f"Invalid own trim config: total={full_frames}, trim_head={head}, trim_tail={tail}."
        )
    if config.max_frames is not None and int(config.max_frames) <= 0:
        raise ValueError("max_frames must be positive or None.")

    total_frames = usable_frames if config.max_frames is None else min(usable_frames, int(config.max_frames))
    fault_injection = prepare_own_fault_injection(
        config.own_fault_injection,
        total_frames,
    )
    fault_rng = np.random.default_rng(
        None if fault_injection is None else fault_injection["seed"]
    )
    start_frac = head / float(full_frames)
    end_frac = (head + total_frames) / float(full_frames)
    if profile in {"own_branch", "legacy", "web"} and head == 0 and tail == 0 and config.max_frames is None:
        route = np.asarray(route_full, dtype=float)
    else:
        route = sample_route_segment(route_full, start_frac=start_frac, end_frac=end_frac, n=max(100, total_frames // 2))
    # Keep the sparse, user-supplied control points for corner/turn metrics.
    # ``route_full`` may be densified for trajectory interpolation; treating
    # every interpolated point as a corner creates hundreds of false reference
    # turns on an otherwise simple rectangular route.
    evaluation_route_controls = slice_route_controls(
        route_controls, start_frac=start_frac, end_frac=end_frac
    )

    pdr_config, pf_config = build_own_configs(profile=profile)
    if config.own_vector_map_enabled:
        pf_config.weight_params = dict(pf_config.weight_params or {})
        pf_config.weight_params.update(
            {
                "vector_weight": float(config.own_vector_weight),
                "vector_angle_sigma_deg": float(
                    config.own_vector_angle_sigma_deg
                ),
                "vector_reject_deg": float(config.own_vector_reject_deg),
                "vector_norm_tolerance_ratio": float(
                    config.own_vector_norm_tolerance_ratio
                ),
            }
        )
    if profile in {"package", "registry"}:
        pdr_config.step_judge_params = dict(
            pdr_config.step_judge_params or {}
        )
        pdr_config.step_judge_params.update(
            {
                "peak_prominence": float(
                    config.own_step_peak_prominence
                ),
                "min_step_interval_s": float(
                    config.own_step_min_interval_s
                ),
            }
        )
        pdr_config.step_length_params = dict(pdr_config.step_length_params or {})
        pdr_config.step_length_params.update(
            {
                "weinberg_k": float(config.own_step_weinberg_k),
                "cadence_weight": float(config.own_step_cadence_weight),
                "variability_weight": float(config.own_step_variability_weight),
            }
        )
        if not config.own_pf_joint_calibration:
            pf_config.state_params = dict(pf_config.state_params or {})
            pf_config.state_params.update(
                {"init_step_scale_std": 0.0, "init_heading_bias_std": 0.0}
            )
            pf_config.motion_params = dict(pf_config.motion_params or {})
            pf_config.motion_params.update(
                {
                    "step_scale_random_walk_std": 0.0,
                    "heading_bias_random_walk_std": 0.0,
                }
            )
    if config.own_initial_heading_deg is not None:
        initial_heading_rad = math.radians(float(config.own_initial_heading_deg))
    elif config.own_use_route_initial_heading:
        initial_heading_rad = infer_initial_heading_from_route(route)
    else:
        initial_heading_rad = None
    heading_method = str(config.own_heading_method).strip().lower()
    if heading_method == "quaternion":
        pdr_config.heading = "quaternion"
        pdr_config.heading_params = {
            "initial_heading_rad": initial_heading_rad,
            "heading_offset_deg": config.own_heading_offset_deg,
            "nominal_dt": 0.01,
            "assume_face_up": True,
            "gravity_gain": 1.5,
            "acc_reject_mps2": 2.0,
            "calibrate_gyro_bias": True,
            "use_magnetometer": bool(
                config.own_quaternion_use_magnetometer
            ),
            "magnetic_yaw_gain": 0.08,
            "magnetic_norm_tolerance_ratio": 0.15,
            "magnetic_reject_deg": 45.0,
            "magnetic_correction_limit_deg_s": 12.0,
        }
    elif heading_method in {"gyro", "core_motion", "q_fused", "tilt_compass"}:
        pdr_config.heading = heading_method
        pdr_config.heading_params = dict(pdr_config.heading_params or {})
        pdr_config.heading_params.update(
            {
                "initial_heading_rad": initial_heading_rad,
                "heading_offset_deg": config.own_heading_offset_deg,
                "stationary_min_duration_s": float(
                    config.own_gyro_bias_stationary_min_duration_s
                ),
                "gyro_rate_scale": float(config.own_gyro_rate_scale),
            }
        )
    else:
        raise ValueError(
            f"Unsupported own heading method: {config.own_heading_method}. "
            "Use 'gyro', 'core_motion', 'quaternion', 'q_fused', or "
            "'tilt_compass'."
        )
    pdr_module = build_pdr_from_config(pdr_config)
    pf_module = build_pf_from_config(pf_config)

    pf_init_xy = [float(route[0, 0]), float(route[0, 1])]
    if (
        fault_injection is not None
        and fault_injection["kind"] == "initial_position_offset"
    ):
        pf_init_xy[0] += float(fault_injection["magnitude"])
    pf_state = PFState(
        init_pos=pf_init_xy,
        mag_map=geomag_map,
        **dict(pf_config.state_params or {}),
    )
    health_monitor = LocalizationHealthMonitor(
        warning_streak=max(1, int(config.own_pf_warning_streak)),
        expand_streak=max(2, int(config.own_pf_expand_streak)),
        reinitialize_streak=max(3, int(config.own_pf_reinitialize_streak)),
    )
    trusted_start_xy = (float(route[0, 0]), float(route[0, 1]))
    unguarded_init_pos = pf_state.get_pos()
    initial_anchor_error_m = float(
        math.hypot(
            float(unguarded_init_pos[0]) - trusted_start_xy[0],
            float(unguarded_init_pos[1]) - trusted_start_xy[1],
        )
    )
    initial_anchor_mismatch = bool(
        initial_anchor_error_m
        > max(0.0, float(config.own_initial_anchor_tolerance_m))
    )
    initial_health = health_monitor.update(
        pf_state.last_position_uncertainty,
        step_index=0,
        integrity={"initial_anchor_mismatch": initial_anchor_mismatch},
    )
    localization_recovery_events = []
    if initial_anchor_mismatch:
        pf_state.reinitialize_at_anchor(
            trusted_start_xy,
            heading_angle=initial_heading_rad,
        )
        pf_state.last_position_uncertainty = pf_state.position_uncertainty()
        localization_recovery_events.append(
            {
                **initial_health,
                "anchor_xy_m": list(trusted_start_xy),
                "initial_estimate_xy_m": [
                    float(unguarded_init_pos[0]),
                    float(unguarded_init_pos[1]),
                ],
                "initial_anchor_error_m": initial_anchor_error_m,
            }
        )
    init_pos = pf_state.get_pos()
    pf_list = [init_pos]
    pf_raw_list = [init_pos]
    pdr_list = [init_pos]
    pf_smooth_x, pf_smooth_y = float(init_pos[0]), float(init_pos[1])
    ema_alpha = float(np.clip(config.own_pf_smoothing_alpha, 0.0, 0.999))
    smoothing_mode = str(config.own_pf_smoothing_mode).strip().lower()
    particle_counts = [len(pf_state.particles)]
    pf_confidence_history = [dict(pf_state.last_position_uncertainty)]
    localization_health_history = [initial_health]
    fault_active_step_history = [
        bool(
            fault_injection is not None
            and fault_injection["kind"] == "initial_position_offset"
            and fault_injection["start_frame"] == 0
        )
    ]
    last_reliable_pf_xy = (float(init_pos[0]), float(init_pos[1]))
    capture_track_progress = [0.0]
    ess_ratio_history = [1.0]
    heading_history = [float(initial_heading_rad) if initial_heading_rad is not None else 0.0]
    raw_heading_history = list(heading_history)
    step_length_history = [0.0]
    step_length_diagnostic_history = [{}]
    step_time_history = [0.0]
    step_sensor_time_history = []
    step_duration_history = [0.0]
    capture_start_sensor_time = None
    capture_end_sensor_time = None
    heading_diagnostic_history = [{}]
    motion_diagnostic_history = [{}]
    weight_diagnostic_history = [{}]
    sensor_integrity_history = [
        {
            "magnetometer_valid": True,
            "initial_anchor_error_m": initial_anchor_error_m,
            "initial_anchor_mismatch": initial_anchor_mismatch,
            "heading_fault": False,
        }
    ]
    smoothing_diagnostic_history = [
        {
            "mode": smoothing_mode,
            "history_weight": ema_alpha,
            "correction_gain": 1.0,
            "residual_m": 0.0,
        }
    ]
    geomag_hist = []
    geomag_vector_history = []
    progress_match_history = [{}]
    progress_matcher = None
    progress_template_source = None
    progress_correction_gain = float(config.own_progress_correction_gain)
    if (
        config.own_progress_template_json
        and progress_correction_gain > 0.0
    ):
        progress_matcher = load_progress_matcher(
            config.own_progress_template_json
        )
        progress_template_source = str(config.own_progress_template_json)
    elif (
        profile in {"package", "registry"}
        and bool(config.own_repeat_progress_enabled)
    ):
        repeat_keys = independent_repeat_keys(own_dataset_key)
        if repeat_keys:
            progress_matcher = _build_repeat_progress_matcher(
                repeat_keys,
                step_judge_params=pdr_config.step_judge_params,
            )
            progress_template_source = "registry:" + ",".join(repeat_keys)
            progress_correction_gain = float(
                config.own_repeat_progress_gain
            )
    _, _, route_length_m = _polyline_cumulative(evaluation_route_controls)
    cumulative_unscaled_distance_m = 0.0
    progress_step_scale = float(max(0.05, config.own_step_length_scale))
    sample_buffer = []
    heading_grid_anchor = (
        None
        if initial_heading_rad is None
        else corrected_own_heading(
            initial_heading_rad,
            mirror_y=config.own_mirror_y,
        )
    )
    heading_grid_state = heading_grid_anchor
    grid_departure_count = 0
    grid_departure_direction = 0
    grid_measurement_offset = 0.0
    grid_snap_cooldown = 0
    heading_delta_integrity_history = []
    heading_rate_integrity_history = []
    step_gyro_z_median_history = []
    heading_fault_active = False
    heading_fault_clear_streak = 0
    heading_bias_delta_estimate = 0.0
    heading_bias_rate_estimate = 0.0
    heading_recovery_anchor_xy = trusted_start_xy
    heading_recovery_secondary_xy = trusted_start_xy
    heading_recovery_hypotheses = [float(initial_heading_rad or 0.0)]

    for _ in range(head):
        get_sensor(source="own", own_data_dir=own_data_dir, own_dataset_key=own_dataset_key)

    _print_progress(0, total_frames)
    for frame_idx in range(total_frames):
        mag, acc, gyro = get_sensor(source="own", own_data_dir=own_data_dir, own_dataset_key=own_dataset_key)
        mag, acc, gyro, sensor_fault_active = apply_own_sensor_fault(
            mag,
            acc,
            gyro,
            frame_idx,
            fault_injection,
            fault_rng,
        )
        fault_window_active = bool(
            fault_injection is not None
            and fault_injection["start_frame"]
            <= frame_idx
            < fault_injection["end_frame_exclusive"]
        )
        sensor_time = get_sensor_diagnostics().get("time")
        alignment_time = (
            float(frame_idx)
            if sensor_time is None
            else float(sensor_time)
        )
        if capture_start_sensor_time is None:
            capture_start_sensor_time = alignment_time
        capture_end_sensor_time = alignment_time
        frame_sample = [acc, gyro, mag, sensor_time]
        sample_buffer.append(frame_sample)
        # Heading is a continuous state and must consume every gyro frame,
        # including frames that do not end a detected step.
        heading_raw_current = float(pdr_module.estimate_heading([frame_sample]))
        if not pdr_module.detect_step(sample_buffer):
            _print_progress(frame_idx + 1, total_frames)
            continue

        estimated_step_len = float(pdr_module.estimate_step_len(sample_buffer))
        cumulative_unscaled_distance_m += estimated_step_len
        step_mag_vectors = np.asarray(
            [sample[2][:3] for sample in sample_buffer], dtype=float
        )
        step_mag_norms = np.linalg.norm(step_mag_vectors, axis=1)
        valid_mag_frames = (
            np.all(np.isfinite(step_mag_vectors), axis=1)
            & np.isfinite(step_mag_norms)
            & (step_mag_norms >= 10.0)
            & (step_mag_norms <= 100.0)
        )
        valid_mag_ratio = float(np.mean(valid_mag_frames))
        magnetometer_valid = bool(valid_mag_ratio >= 0.80)
        obs_mag_vector = (
            np.mean(step_mag_vectors[valid_mag_frames], axis=0)
            if np.any(valid_mag_frames)
            else np.zeros(3, dtype=float)
        )
        progress_match_diagnostics = {}
        if progress_matcher is not None and magnetometer_valid:
            progress_match = progress_matcher.update(obs_mag_vector)
            progress_match_diagnostics = progress_match.as_dict()
            if progress_match.observation_count >= 4:
                target_scale = float(
                    np.clip(
                        progress_match.progress
                        * route_length_m
                        / max(cumulative_unscaled_distance_m, 1e-6),
                        0.85,
                        1.40,
                    )
                )
                gain = float(np.clip(progress_correction_gain, 0.0, 1.0))
                progress_step_scale += gain * (
                    target_scale - progress_step_scale
                )
                progress_match_diagnostics.update(
                    {
                        "target_step_scale": target_scale,
                        "applied_gain": gain,
                    }
                )
        step_length_scale = progress_step_scale
        step_len = float(estimated_step_len * step_length_scale)
        step_length_diagnostics = get_step_length_diagnostics()
        step_length_diagnostics.update(
            {
                "unscaled_step_length_m": float(estimated_step_len),
                "applied_scale": step_length_scale,
                "step_length_m": float(step_len),
            }
        )
        heading_raw = heading_raw_current
        heading_unconstrained = (
            corrected_own_heading(heading_raw, mirror_y=True)
            if config.own_mirror_y
            else heading_raw
        )
        if heading_grid_anchor is None:
            heading_grid_anchor = float(heading_unconstrained)
        if float(config.own_heading_snap_deg) > 0.0:
            if heading_grid_state is None:
                heading_grid_state = float(heading_grid_anchor)
            if grid_snap_cooldown > 0:
                heading_angle = float(heading_grid_state)
                grid_measurement_offset = math.atan2(
                    math.sin(heading_grid_state - heading_unconstrained),
                    math.cos(heading_grid_state - heading_unconstrained),
                )
                grid_snap_cooldown -= 1
                grid_departure_count = 0
                grid_departure_direction = 0
            else:
                aligned_measurement = float(
                    (
                        (
                            heading_unconstrained
                            + grid_measurement_offset
                            + math.pi
                        )
                        % (2.0 * math.pi)
                    )
                    - math.pi
                )
                previous_grid_heading = float(heading_grid_state)
                (
                    heading_angle,
                    grid_departure_count,
                    grid_departure_direction,
                ) = update_grid_heading_state(
                    aligned_measurement,
                    heading_grid_state,
                    interval_deg=config.own_heading_snap_deg,
                    departure_count=grid_departure_count,
                    departure_direction=grid_departure_direction,
                )
                if abs(
                    math.atan2(
                        math.sin(heading_angle - previous_grid_heading),
                        math.cos(heading_angle - previous_grid_heading),
                    )
                ) > 1e-9:
                    grid_snap_cooldown = 4
                    grid_measurement_offset = math.atan2(
                        math.sin(heading_angle - heading_unconstrained),
                        math.cos(heading_angle - heading_unconstrained),
                    )
            heading_grid_state = float(heading_angle)
        else:
            heading_angle = float(heading_unconstrained)
        previous_integrity_heading = float(heading_history[-1])
        integrity_heading_delta = math.atan2(
            math.sin(heading_angle - previous_integrity_heading),
            math.cos(heading_angle - previous_integrity_heading),
        )
        heading_delta_integrity_history.append(integrity_heading_delta)
        previous_step_sensor_time = (
            float(step_sensor_time_history[-1])
            if step_sensor_time_history
            else float(capture_start_sensor_time)
        )
        current_step_duration = max(
            1e-3,
            float(alignment_time) - previous_step_sensor_time,
        )
        heading_rate_integrity_history.append(
            float(integrity_heading_delta / current_step_duration)
        )
        current_step_gyro_z_median = float(
            np.median(
                np.asarray(
                    [sample[1][2] for sample in sample_buffer],
                    dtype=float,
                )
            )
        )
        step_gyro_z_median_history.append(current_step_gyro_z_median)
        heading_fault_was_active = heading_fault_active
        heading_integrity = update_heading_integrity(
            heading_delta_integrity_history,
            fault_active=heading_fault_active,
            clear_streak=heading_fault_clear_streak,
            window_steps=config.own_gyro_heading_window_steps,
            fault_threshold_deg=config.own_gyro_heading_fault_threshold_deg,
            clear_threshold_deg=config.own_gyro_heading_clear_threshold_deg,
            required_clear_streak=config.own_gyro_heading_clear_streak,
        )
        heading_fault_active = bool(heading_integrity["fault_active"])
        heading_fault_cleared = bool(
            heading_fault_was_active and not heading_fault_active
        )
        heading_fault_clear_streak = int(heading_integrity["clear_streak"])
        if heading_integrity["fault_started"]:
            heading_bias_delta_estimate = float(
                heading_integrity["estimated_bias_delta_rad"]
            )
            integrity_window = max(
                2, int(config.own_gyro_heading_window_steps)
            )
            recent_gyro_medians = step_gyro_z_median_history[
                -integrity_window:
            ]
            reference_gyro_medians = step_gyro_z_median_history[
                :-integrity_window
            ]
            reference_gyro_rate = (
                float(
                    np.median(
                        np.asarray(reference_gyro_medians, dtype=float)
                    )
                )
                if reference_gyro_medians
                else 0.0
            )
            heading_bias_rate_estimate = float(
                np.median(np.asarray(recent_gyro_medians, dtype=float))
                - reference_gyro_rate
            )
        pf_state.motion_heading_delta_override = (
            float(
                integrity_heading_delta
                - heading_bias_rate_estimate * current_step_duration
            )
            if heading_fault_active
            else None
        )
        obs_mag = (
            float(pdr_module.extract_mag())
            if magnetometer_valid
            else None
        )
        if obs_mag is not None:
            geomag_hist.append(obs_mag)
        geomag_vector_history.append(obs_mag_vector.astype(float).tolist())
        progress_match_history.append(progress_match_diagnostics)
        geomag_window = geomag_hist[-config.window_size :]

        last_px, last_py = pdr_list[-1]
        pdr_list.append(
            (
                float(last_px + step_len * math.cos(heading_angle)),
                float(last_py + step_len * math.sin(heading_angle)),
            )
        )
        pf_state.current_mag_vector = np.asarray(mag, dtype=float)
        pf_state.current_heading_angle = float(heading_angle)
        pf_xy = pf_module.step(
            pf_state=pf_state,
            step_len=step_len,
            heading_angle=heading_angle,
            geomag_seq=geomag_window,
            measurement_valid=magnetometer_valid,
        )
        pf_raw_list.append((float(pf_xy[0]), float(pf_xy[1])))
        smoothed_xy, smoothing_diagnostics = smooth_pf_output(
            (pf_smooth_x, pf_smooth_y),
            pf_xy,
            mode=smoothing_mode,
            alpha=ema_alpha,
            step_len=step_len,
            heading_angle=heading_angle,
            weight_diagnostics=pf_state.last_weight_diagnostics,
            motion_diagnostics=pf_state.last_motion_diagnostics,
        )
        pf_smooth_x, pf_smooth_y = smoothed_xy
        pf_list.append((pf_smooth_x, pf_smooth_y))
        confidence_sample = dict(pf_state.last_position_uncertainty)
        pf_confidence_history.append(confidence_sample)
        track_index = len(pf_list) - 1
        health_sample = health_monitor.update(
            confidence_sample,
            step_index=track_index,
            integrity={
                "magnetometer_valid": magnetometer_valid,
                "heading_fault": heading_fault_active,
                "heading_fault_started": heading_integrity["fault_started"],
                "heading_fault_cleared": heading_fault_cleared,
                "relative_heading_recovery": bool(
                    pf_state.heading_recovery_mode
                ),
            },
        )
        if (
            str(confidence_sample.get("level", "low")) != "low"
            and float(confidence_sample.get("score", 0.0)) >= 0.32
            and magnetometer_valid
            and not heading_fault_active
        ):
            last_reliable_pf_xy = (float(pf_xy[0]), float(pf_xy[1]))

        recovery_action = str(health_sample.get("action", "none"))
        if config.own_pf_recovery_enabled and recovery_action != "none":
            if recovery_action == "expand_search":
                pf_state.expand_search()
            elif recovery_action == "reinitialize_anchor":
                pf_state.reinitialize_at_anchor(
                    trusted_start_xy,
                    heading_angle=heading_angle,
                )
            elif recovery_action == "reinitialize_heading":
                recovery_anchor_index = max(
                    0,
                    track_index
                    - max(2, int(config.own_gyro_heading_window_steps)),
                )
                base_anchor_xy = tuple(
                    map(float, pf_raw_list[recovery_anchor_index])
                )
                base_anchor_heading = float(
                    heading_history[recovery_anchor_index]
                )
                recovery_lengths = [
                    *step_length_history[recovery_anchor_index + 1 :],
                    float(step_len),
                ]
                recovery_deltas = heading_delta_integrity_history[
                    -len(recovery_lengths) :
                ]
                recovery_durations = [
                    *step_duration_history[recovery_anchor_index + 1 :],
                    float(current_step_duration),
                ]
                recovered_x, recovered_y = base_anchor_xy
                recovered_heading = base_anchor_heading
                for recovery_length, recovery_delta, recovery_duration in zip(
                    recovery_lengths,
                    recovery_deltas,
                    recovery_durations,
                    strict=True,
                ):
                    recovered_heading = float(
                        (
                            (
                                recovered_heading
                                + recovery_delta
                                - heading_bias_rate_estimate
                                * recovery_duration
                                + math.pi
                            )
                            % (2.0 * math.pi)
                        )
                        - math.pi
                    )
                    recovered_x += float(
                        recovery_length * math.cos(recovered_heading)
                    )
                    recovered_y += float(
                        recovery_length * math.sin(recovered_heading)
                    )
                heading_recovery_hypotheses = [recovered_heading]
                heading_recovery_anchor_xy = (
                    float(recovered_x),
                    float(recovered_y),
                )
                heading_recovery_secondary_xy = (
                    float(pf_xy[0]),
                    float(pf_xy[1]),
                )
                last_reliable_pf_xy = heading_recovery_anchor_xy
                pf_state.reinitialize_global_heading(
                    anchor_xy=heading_recovery_anchor_xy,
                    secondary_anchor_xy=heading_recovery_secondary_xy,
                    heading_hypotheses=heading_recovery_hypotheses,
                )
            elif recovery_action == "concentrate_heading":
                pf_state.reinitialize_at_anchor(
                    pf_xy,
                    heading_angle=pf_state.mean_particle_heading(),
                    position_std=0.35,
                )
                pf_state.heading_recovery_mode = True
            elif recovery_action == "reinitialize":
                if pf_state.heading_recovery_mode:
                    pf_state.reinitialize_global_heading(
                        anchor_xy=heading_recovery_anchor_xy,
                        secondary_anchor_xy=heading_recovery_secondary_xy,
                        heading_hypotheses=heading_recovery_hypotheses,
                    )
                else:
                    pf_state.reinitialize_for_recovery(
                        anchor_xy=last_reliable_pf_xy,
                        pdr_hint_xy=pdr_list[-1],
                        heading_angle=heading_angle,
                    )
            recovery_event = {
                **health_sample,
                "anchor_xy_m": [
                    float(last_reliable_pf_xy[0]),
                    float(last_reliable_pf_xy[1]),
                ],
                "pdr_hint_xy_m": [
                    float(pdr_list[-1][0]),
                    float(pdr_list[-1][1]),
                ],
            }
            localization_recovery_events.append(recovery_event)
            print(
                "\n[localization] "
                f"step={track_index} action={recovery_action} "
                f"score={float(confidence_sample.get('score', 0.0)):.3f} "
                f"reasons={','.join(health_sample.get('reason_codes', []))}"
            )
        elif not config.own_pf_recovery_enabled and recovery_action != "none":
            health_monitor.recovery_count = max(
                0, health_monitor.recovery_count - 1
            )
            health_sample["action"] = "none"
            health_sample["recovery_count"] = int(
                health_monitor.recovery_count
            )
            health_sample["status"] = (
                "lost"
                if int(health_sample.get("lost_streak", 0))
                >= health_monitor.warning_streak
                else "ambiguous"
            )
        localization_health_history.append(health_sample)
        fault_active_step_history.append(
            bool(sensor_fault_active or fault_window_active)
        )
        smoothing_diagnostic_history.append(smoothing_diagnostics)
        particle_counts.append(len(pf_state.particles))
        capture_track_progress.append(
            float(frame_idx + 1) / max(float(total_frames), 1.0)
        )
        heading_history.append(float(heading_angle))
        raw_heading_history.append(float(heading_unconstrained))
        step_length_history.append(float(step_len))
        step_length_diagnostic_history.append(step_length_diagnostics)
        step_time_history.append(float(head + frame_idx + 1))
        step_sensor_time_history.append(float(alignment_time))
        step_duration_history.append(float(current_step_duration))
        heading_diagnostic_history.append(get_heading_diagnostics())
        motion_diagnostic_history.append(dict(pf_state.last_motion_diagnostics))
        weight_diagnostic_history.append(dict(pf_state.last_weight_diagnostics))
        sensor_integrity_history.append(
            {
                "magnetometer_valid": magnetometer_valid,
                "valid_magnetometer_frame_ratio": valid_mag_ratio,
                "magnetic_norm_ut": (
                    None if obs_mag is None else float(obs_mag)
                ),
                "heading_fault": heading_fault_active,
                "heading_fault_started": bool(
                    heading_integrity["fault_started"]
                ),
                "heading_fault_cleared": heading_fault_cleared,
                "heading_window_net_delta_deg": float(
                    heading_integrity["window_net_delta_deg"]
                ),
                "estimated_gyro_bias_delta_deg": float(
                    math.degrees(heading_bias_delta_estimate)
                ),
                "estimated_gyro_bias_rate_rad_s": float(
                    heading_bias_rate_estimate
                ),
                "step_gyro_z_median_rad_s": current_step_gyro_z_median,
                "relative_heading_mode": bool(
                    pf_state.heading_recovery_mode
                ),
            }
        )
        ess_ratio_history.append(
            float(pf_state.last_weight_diagnostics.get("ess_ratio", 1.0))
        )
        sample_buffer.clear()
        _print_progress(frame_idx + 1, total_frames)

    sys.stdout.write("\n")
    sys.stdout.flush()

    if capture_start_sensor_time is None or capture_end_sensor_time is None:
        raise ValueError("Own sensor capture contains no usable timestamps.")
    active_step_progress, active_walk_interval = build_uniform_walk_progress(
        step_sensor_time_history,
        capture_start_time=capture_start_sensor_time,
        capture_end_time=capture_end_sensor_time,
        mode=config.own_alignment_mode,
    )
    track_progress = [0.0, *active_step_progress]

    pdr_series, pdr_stats = summarize_error(
        pdr_list, route, geomag_map, progress=track_progress
    )
    pf_series, pf_stats = summarize_error(
        pf_list, route, geomag_map, progress=track_progress
    )
    pf_raw_series, pf_raw_stats = summarize_error(
        pf_raw_list, route, geomag_map, progress=track_progress
    )
    pdr_cross_series, pdr_cross_stats = summarize_cross_track_error(pdr_list, route, geomag_map)
    pf_cross_series, pf_cross_stats = summarize_cross_track_error(pf_list, route, geomag_map)
    pf_raw_cross_series, pf_raw_cross_stats = summarize_cross_track_error(
        pf_raw_list, route, geomag_map
    )

    output_png = config.output_png
    if output_png is None and config.write_outputs:
        output_png = f"results/branch_own_{config.own_dataset_key}.png"
    plot_path = (
        save_own_trajectory_plot(
            geomag_map=geomag_map,
            route=route,
            pdr_list=pdr_list,
            pf_list=pf_list,
            pf_raw_list=pf_raw_list,
            output_png=output_png,
            show=config.show,
            title=f"Own Simulation: {dataset_spec['key']}",
        )
        if output_png
        else None
    )
    reference_turn_progress = _reference_turn_progress(evaluation_route_controls)
    reference_turn_times_s = [
        float(
            active_walk_interval["start_time"]
            + progress * active_walk_interval["duration"]
        )
        for progress in reference_turn_progress
    ]
    detected_turns = _detect_heading_turns(heading_history, track_progress)
    pdr_corner_errors, pdr_corner_stats = summarize_corner_errors(
        pdr_list, evaluation_route_controls, detected_turns
    )
    pf_corner_errors, pf_corner_stats = summarize_corner_errors(
        pf_list, evaluation_route_controls, detected_turns
    )
    pf_raw_corner_errors, pf_raw_corner_stats = summarize_corner_errors(
        pf_raw_list, evaluation_route_controls, detected_turns
    )
    diagnostic_plot_path = (
        save_own_diagnostic_plot(
            progress=track_progress,
            heading_history=heading_history,
            raw_heading_history=raw_heading_history,
            step_length_history=step_length_history,
            ess_ratio_history=ess_ratio_history,
            weight_diagnostic_history=weight_diagnostic_history,
            reference_turn_progress=reference_turn_progress,
            output_png=output_png,
            title=f"Own-data diagnostics: {dataset_spec['key']}",
        )
        if output_png
        else None
    )

    payload = {
        "branch": "own",
        "own_profile": profile,
        "own_data_source": data_source,
        "dataset_key": dataset_spec["key"],
        "dataset_dir": dataset_spec["dataset_dir"],
        "route_label": dataset_spec["route_label"],
        "map_mode": str(config.own_map_mode),
        "map_profile": geomag_map.get(
            "own_map_profile", resolve_own_map_profile(config)
        ),
        "map_geometry_source": geomag_map.get("geometry_source"),
        "map_npz_path": config.own_map_npz_path,
        "map_offset_xy_m": [
            float(config.own_map_offset_x_m),
            float(config.own_map_offset_y_m),
        ],
        "vector_map_enabled": bool(config.own_vector_map_enabled),
        "vector_map_source": geomag_map.get("vector_map_source"),
        "vector_map_frame": geomag_map.get("vector_map_frame"),
        "vector_weight": float(config.own_vector_weight),
        "vector_angle_sigma_deg": float(
            config.own_vector_angle_sigma_deg
        ),
        "vector_reject_deg": float(config.own_vector_reject_deg),
        "vector_norm_tolerance_ratio": float(
            config.own_vector_norm_tolerance_ratio
        ),
        "mirror_y": bool(config.own_mirror_y),
        "initial_heading_rad": None if initial_heading_rad is None else float(initial_heading_rad),
        "initial_heading_deg": None if initial_heading_rad is None else float(math.degrees(initial_heading_rad)),
        "use_route_initial_heading": bool(config.own_use_route_initial_heading),
        "heading_offset_deg": float(config.own_heading_offset_deg),
        "heading_method": heading_method,
        "quaternion_use_magnetometer": bool(
            config.own_quaternion_use_magnetometer
        ),
        "gyro_bias_stationary_min_duration_s": float(
            config.own_gyro_bias_stationary_min_duration_s
        ),
        "gyro_rate_scale": float(config.own_gyro_rate_scale),
        "heading_snap_deg": float(config.own_heading_snap_deg),
        "step_peak_prominence": float(config.own_step_peak_prominence),
        "step_min_interval_s": float(config.own_step_min_interval_s),
        "step_weinberg_k": float(config.own_step_weinberg_k),
        "step_length_scale": float(config.own_step_length_scale),
        "progress_template_json": config.own_progress_template_json,
        "progress_template_source": progress_template_source,
        "repeat_progress_enabled": bool(config.own_repeat_progress_enabled),
        "progress_correction_gain": float(progress_correction_gain),
        "step_cadence_weight": float(config.own_step_cadence_weight),
        "step_variability_weight": float(config.own_step_variability_weight),
        "pf_joint_calibration": bool(config.own_pf_joint_calibration),
        "initial_anchor_tolerance_m": float(
            config.own_initial_anchor_tolerance_m
        ),
        "gyro_heading_integrity": {
            "window_steps": int(config.own_gyro_heading_window_steps),
            "fault_threshold_deg": float(
                config.own_gyro_heading_fault_threshold_deg
            ),
            "clear_threshold_deg": float(
                config.own_gyro_heading_clear_threshold_deg
            ),
            "clear_streak": int(config.own_gyro_heading_clear_streak),
        },
        "trim_head": int(head),
        "trim_tail": int(tail),
        "full_sensor_frames": int(full_frames),
        "sensor_frames_used": int(total_frames),
        "evaluation_scope": (
            "full_capture"
            if head == 0 and tail == 0 and total_frames == full_frames
            else "active_capture_segment"
        ),
        "steps_detected": max(0, len(pf_list) - 1),
        "map_point_cloud_mode": geomag_map.get("point_cloud_mode"),
        "map_point_cloud_shape": geomag_map.get("point_cloud_shape"),
        "map_bounds": [
            geomag_map.get("rangex_min"),
            geomag_map.get("rangex_max"),
            geomag_map.get("rangey_min"),
            geomag_map.get("rangey_max"),
        ],
        "route_len": int(len(route)),
        "pdr_error_stats": pdr_stats,
        "pf_error_stats": pf_stats,
        "pf_raw_error_stats": pf_raw_stats,
        "pdr_cross_track_error_stats": pdr_cross_stats,
        "pf_cross_track_error_stats": pf_cross_stats,
        "pf_raw_cross_track_error_stats": pf_raw_cross_stats,
        "pdr_corner_error_stats": pdr_corner_stats,
        "pf_corner_error_stats": pf_corner_stats,
        "pf_raw_corner_error_stats": pf_raw_corner_stats,
        "pdr_corner_errors": pdr_corner_errors,
        "pf_corner_errors": pf_corner_errors,
        "pf_raw_corner_errors": pf_raw_corner_errors,
        "pdr_endpoint_error_m": endpoint_error(pdr_list, evaluation_route_controls),
        "pf_endpoint_error_m": endpoint_error(pf_list, evaluation_route_controls),
        "pf_raw_endpoint_error_m": endpoint_error(
            pf_raw_list, evaluation_route_controls
        ),
        "pdr_error_series": None if pdr_series is None else np.asarray(pdr_series, dtype=float).tolist(),
        "pf_error_series": None if pf_series is None else np.asarray(pf_series, dtype=float).tolist(),
        "pf_raw_error_series": (
            None if pf_raw_series is None else np.asarray(pf_raw_series, dtype=float).tolist()
        ),
        "pdr_cross_track_error_series": (
            None if pdr_cross_series is None else np.asarray(pdr_cross_series, dtype=float).tolist()
        ),
        "pf_cross_track_error_series": (
            None if pf_cross_series is None else np.asarray(pf_cross_series, dtype=float).tolist()
        ),
        "pf_raw_cross_track_error_series": (
            None
            if pf_raw_cross_series is None
            else np.asarray(pf_raw_cross_series, dtype=float).tolist()
        ),
        "pdr_track": [list(map(float, xy)) for xy in pdr_list],
        "pf_track": [list(map(float, xy)) for xy in pf_list],
        "pf_confidence_history": pf_confidence_history,
        "localization_health_history": localization_health_history,
        "localization_recovery_events": localization_recovery_events,
        "localization_recovery_summary": {
            "enabled": bool(config.own_pf_recovery_enabled),
            "event_count": len(localization_recovery_events),
            "expand_search_count": sum(
                event.get("action") == "expand_search"
                for event in localization_recovery_events
            ),
            "reinitialize_count": sum(
                event.get("action")
                in {
                    "reinitialize",
                    "reinitialize_anchor",
                    "reinitialize_heading",
                }
                for event in localization_recovery_events
            ),
            "anchor_reinitialize_count": sum(
                event.get("action") == "reinitialize_anchor"
                for event in localization_recovery_events
            ),
            "heading_reinitialize_count": sum(
                event.get("action") == "reinitialize_heading"
                for event in localization_recovery_events
            ),
            "final_status": localization_health_history[-1]["status"],
        },
        "fault_injection": fault_injection,
        "fault_active_step_history": fault_active_step_history,
        "pf_raw_track": [list(map(float, xy)) for xy in pf_raw_list],
        "pf_smoothing_alpha": float(ema_alpha),
        "pf_smoothing_mode": smoothing_mode,
        "smoothing_diagnostic_history": smoothing_diagnostic_history,
        "alignment_mode": str(config.own_alignment_mode),
        "capture_interval_s": [
            float(capture_start_sensor_time),
            float(capture_end_sensor_time),
        ],
        "active_walk_interval": active_walk_interval,
        "heading_history_rad": [float(x) for x in heading_history],
        "heading_history_deg": [float(math.degrees(x)) for x in heading_history],
        "raw_heading_history_rad": [float(x) for x in raw_heading_history],
        "raw_heading_history_deg": [float(math.degrees(x)) for x in raw_heading_history],
        "step_length_history_m": [float(x) for x in step_length_history],
        "step_length_diagnostic_history": step_length_diagnostic_history,
        "step_frame_history": [float(x) for x in step_time_history],
        "step_sensor_time_history_s": [
            float(x) for x in step_sensor_time_history
        ],
        "step_duration_history_s": [float(x) for x in step_duration_history],
        "heading_diagnostic_history": heading_diagnostic_history,
        "motion_diagnostic_history": motion_diagnostic_history,
        "weight_diagnostic_history": weight_diagnostic_history,
        "sensor_integrity_history": sensor_integrity_history,
        "geomagnetic_observation_history": [float(x) for x in geomag_hist],
        "geomagnetic_vector_history": geomag_vector_history,
        "progress_match_history": progress_match_history,
        "detected_turns": detected_turns,
        "reference_turn_progress": reference_turn_progress,
        "reference_turn_times_s": reference_turn_times_s,
        "particle_counts": [int(x) for x in particle_counts],
        "track_progress": [float(x) for x in track_progress],
        "capture_track_progress": [
            float(x) for x in capture_track_progress
        ],
        "ess_ratio_history": [float(x) for x in ess_ratio_history],
        "error_alignment": str(config.own_alignment_mode),
        "route_xy_m": [list(map(float, xy)) for xy in route],
        "output_png": plot_path,
        "diagnostic_png": diagnostic_plot_path,
    }

    output_json = config.output_json
    if output_json is None and config.write_outputs:
        output_json = f"results/branch_own_{config.own_dataset_key}.json"
    payload["output_json"] = None if output_json is None else str(Path(output_json))
    _write_json(output_json, payload)

    print("=== OWN BRANCH DONE ===")
    print(f"dataset_key: {dataset_spec['key']}")
    print(f"map_mode: {config.own_map_mode}")
    print(f"map_profile: {payload['map_profile']}")
    print(f"steps_detected: {payload['steps_detected']}")
    print(f"pf_error_stats: {pf_stats}")
    print(f"pf_cross_track_error_stats: {pf_cross_stats}")
    print(f"pf_raw_error_stats: {pf_raw_stats}")
    print(f"pdr_error_stats: {pdr_stats}")
    print(f"saved_json: {payload['output_json']}")
    if plot_path:
        print(f"saved_plot: {plot_path}")

    return payload


def run_branch_simulation(config: BranchConfig):
    token = str(config.branch).strip().lower()
    if token == "uji":
        return run_uji_branch(config)
    if token == "own":
        return run_own_branch(config)
    raise ValueError(f"Unsupported branch: {config.branch}. Use 'uji' or 'own'.")
