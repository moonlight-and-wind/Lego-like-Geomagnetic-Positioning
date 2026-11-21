"""Controlled validation for the August 2026 iPhone captures.

The raw ``.geomagcapture`` packages are never edited.  This module makes
derived, time-aligned copies without the stationary recording tails, applies
the gyro-Z bias measured during the initial stationary window, and evaluates
the motion pipeline on closed routes.  Particle-filter metrics are excluded:
these captures were not registered against the repository's older magnetic
map, so reporting those numbers would be misleading.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from Geomag import build_pdr_from_config
from Geomag.algorithms import (
    get_sensor,
    get_sensor_diagnostics,
    get_test_len,
)
from Geomag.branching import (
    _detect_heading_turns,
    build_own_package_configs,
    build_uniform_walk_progress,
    infer_initial_heading_from_route,
    update_grid_heading_state,
)
from Geomag.progress_matching import align_magnetic_progress


@dataclass(frozen=True)
class CaptureSpec:
    key: str
    route_group: str
    route_xy_m: tuple[tuple[float, float], ...]
    stationary_trim_s: float
    geometry_status: str

    @property
    def route_length_m(self) -> float:
        points = np.asarray(self.route_xy_m, dtype=float)
        return float(np.linalg.norm(np.diff(points, axis=0), axis=1).sum())


# Provisional geometry reconstructed from the entered centimetre-like values,
# the four right turns in Core Motion, and the confirmed return to the start.
# The translation only keeps the routes inside the legacy plotting bounds; it
# does not register them to the legacy magnetic survey.
ROUTE_13 = ((4.0, 3.0), (4.0, 4.8), (5.8, 4.8), (5.8, 3.0), (4.0, 3.0))
ROUTE_14 = ((7.0, 7.0), (7.0, 1.0), (6.4, 1.0), (6.4, 7.0), (7.0, 7.0))
ROUTE_15 = ((12.5, 0.5), (0.5, 0.5), (0.5, 1.1), (12.5, 1.1), (12.5, 0.5))

CAPTURES = (
    CaptureSpec("route_13_1", "route_13", ROUTE_13, 3.0, "operator_confirmed"),
    CaptureSpec("route_13_2", "route_13", ROUTE_13, 3.0, "operator_confirmed"),
    CaptureSpec("route_13_3", "route_13", ROUTE_13, 3.0, "operator_confirmed"),
    CaptureSpec("route_14_2", "route_14", ROUTE_14, 3.0, "operator_confirmed"),
    CaptureSpec("route_14_3", "route_14", ROUTE_14, 3.0, "operator_confirmed"),
    CaptureSpec("route_15_1", "route_15", ROUTE_15, 0.0, "recorded"),
    CaptureSpec("route_15_2", "route_15", ROUTE_15, 0.0, "recorded"),
    CaptureSpec("route_15_3", "route_15", ROUTE_15, 0.0, "recorded"),
)
MAGNETIC_MAP_ONLY_CAPTURES = (CaptureSpec("route_14_1", "route_14", ROUTE_14, 3.0, "map_only_start_anomaly"),)
CALIBRATION_KEYS = {"route_13_1", "route_14_2", "route_15_1"}
VALIDATION_KEYS = {
    "route_13_2",
    "route_13_3",
    "route_14_3",
    "route_15_2",
    "route_15_3",
}
ALGORITHM_RELEASE_ID = "iphone-controlled-pdr-2026-08-08"
SENSOR_FILES = (
    "Accelerometer.csv",
    "Gyroscope.csv",
    "Magnetometer.csv",
    "DeviceMotion.csv",
)


def _algorithm_release_manifest(
    comparison_summary: dict,
    frozen_parameters: dict,
) -> dict:
    """Build the small, stable contract consumed by the native applications."""
    return {
        "release_id": ALGORITHM_RELEASE_ID,
        "status": "frozen_for_native_integration",
        "recommended": {
            "profile": "controlled_core_motion_magnetic_yaw_v1",
            "result_key": "magnetic_heading_runs",
            "scope": "controlled_closed_routes_only",
            "deployment_status": "recommended_for_current_controlled_trials",
            "validation_cross_track_mean_m": comparison_summary[
                "validation_magnetic_heading_cross_track_mean_m"
            ],
            "validation_closure_mean_m": comparison_summary["validation_magnetic_heading_closure_mean_m"],
        },
        "direction_free_shadow": {
            "profile": "start_registered_direction_free_yaw_v1",
            "result_key": "registered_direction_free_shadow_runs",
            "deployment_status": comparison_summary["registered_direction_free_deployment_status"],
            "validation_cross_track_mean_m": comparison_summary[
                "validation_registered_direction_free_cross_track_mean_m"
            ],
            "validation_closure_mean_m": comparison_summary[
                "validation_registered_direction_free_closure_mean_m"
            ],
        },
        "rejected_shadow": {
            "profile": "unregistered_direction_free_yaw_v1",
            "result_key": "direction_free_shadow_runs",
            "deployment_status": comparison_summary["direction_free_deployment_status"],
            "validation_cross_track_mean_m": comparison_summary[
                "validation_direction_free_cross_track_mean_m"
            ],
        },
        "free_path_status": "not_validated",
        "legacy_pf_status": "excluded_unregistered_legacy_map",
        "frozen_parameters": frozen_parameters,
    }


def _read_csv(path: Path) -> tuple[list[str], list[list[str]]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.reader(handle)
        rows = list(reader)
    if len(rows) < 2:
        raise ValueError(f"Sensor CSV is empty: {path}")
    return rows[0], rows[1:]


def _time_value(row: list[str]) -> float:
    return float(row[0])


def _initial_gyro_z_bias(source: Path, duration_s: float = 2.5) -> float:
    header, rows = _read_csv(source / "Gyroscope.csv")
    try:
        z_index = next(i for i, value in enumerate(header) if "Z" in value)
    except StopIteration as exc:
        raise ValueError("Gyroscope.csv has no Z column.") from exc
    values = [float(row[z_index]) for row in rows if _time_value(row) <= duration_s]
    if len(values) < 20:
        raise ValueError(f"Not enough initial stationary gyro samples: {source}")
    return float(np.median(values))


def _sample_level_turn_regions(device_motion_csv: Path) -> list[dict]:
    """Detect turn onset/completion from the continuous Core Motion yaw rate."""
    header, rows = _read_csv(device_motion_csv)
    try:
        yaw_index = header.index("Yaw (rad)")
    except ValueError as exc:
        raise ValueError(f"DeviceMotion.csv has no Yaw (rad): {device_motion_csv}") from exc
    values = np.asarray([[_time_value(row), float(row[yaw_index])] for row in rows], dtype=float)
    time_s = values[:, 0]
    yaw_deg = np.degrees(np.unwrap(values[:, 1]))
    sample_rate = 1.0 / float(np.median(np.diff(time_s)))
    width = max(1, round(0.12 * sample_rate))
    rate = np.abs(np.gradient(yaw_deg, time_s))
    rate = np.convolve(rate, np.ones(width) / width, mode="same")
    quiet_samples = max(2, round(0.18 * sample_rate))
    padding = max(1, round(0.08 * sample_rate))
    regions = []
    index = 0
    while index < rate.size:
        if rate[index] < 28.0:
            index += 1
            continue
        onset = index
        last_active = index
        cursor = index + 1
        while cursor < rate.size:
            if rate[cursor] >= 12.0:
                last_active = cursor
            if cursor - last_active >= quiet_samples:
                break
            cursor += 1
        padded_onset = max(0, onset - padding)
        completion = min(rate.size - 1, last_active + padding)
        signed_angle = float(yaw_deg[completion] - yaw_deg[padded_onset])
        if abs(signed_angle) >= 30.0:
            regions.append(
                {
                    "onset_time_s": float(time_s[padded_onset]),
                    "completion_time_s": float(time_s[completion]),
                    "signed_angle_deg": signed_angle,
                }
            )
        index = max(cursor, onset + 1)
    return regions


def prepare_capture(
    source: Path,
    destination: Path,
    route_xy_m: tuple[tuple[float, float], ...],
    trim_s: float = 3.0,
) -> dict[str, float]:
    """Create an aligned validation copy and return preprocessing metadata."""
    loaded = {name: _read_csv(source / name) for name in SENSOR_FILES}
    common_end = min(_time_value(rows[-1]) for _, rows in loaded.values())
    keep_start = float(trim_s)
    keep_end = float(common_end - trim_s)
    if keep_end <= keep_start:
        raise ValueError(f"Capture is too short for {trim_s:g}s tail trimming: {source}")

    gyro_bias = _initial_gyro_z_bias(source)
    destination.mkdir(parents=True, exist_ok=True)
    row_counts: dict[str, int] = {}
    for name, (header, rows) in loaded.items():
        selected = [row[:] for row in rows if keep_start <= _time_value(row) <= keep_end]
        if not selected:
            raise ValueError(f"No rows remain after trimming: {source / name}")
        for row in selected:
            row[0] = f"{_time_value(row) - keep_start:.10g}"
        if name == "Gyroscope.csv":
            z_index = next(i for i, value in enumerate(header) if "Z" in value)
            for row in selected:
                row[z_index] = f"{float(row[z_index]) - gyro_bias:.10g}"
        with (destination / name).open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, quoting=csv.QUOTE_MINIMAL)
            writer.writerow(header)
            writer.writerows(selected)
        row_counts[name] = len(selected)

    metadata = {
        "dataset_key": source.stem,
        "format_version": 1,
        "route_xy_m": [list(point) for point in route_xy_m],
        "initial_heading_deg": None,
        "timestamp_mode": "seconds_since_validation_start",
        "validation_preprocessing": {
            "source": str(source.resolve()),
            "stationary_trim_each_end_s": float(trim_s),
            "gyro_z_bias_rad_s": gyro_bias,
            "route_geometry": "provisional_closed_route",
        },
    }
    (destination / "geomag_dataset.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return {
        "keep_start_s": keep_start,
        "keep_end_s": keep_end,
        "gyro_z_bias_rad_s": gyro_bias,
        "accelerometer_rows": float(row_counts["Accelerometer.csv"]),
    }


def _run_motion_pipeline(
    spec: CaptureSpec,
    prepared_dir: Path,
    snap_deg: float = 0.0,
) -> dict:
    """Run only the motion stack; an unregistered PF is intentionally absent."""
    pdr_config, _ = build_own_package_configs()
    # Keep the recent-iPhone validation profile independent from the legacy
    # own-data defaults.  These captures were originally validated with the
    # stricter cadence used by the plotted route-calibrated PDR baseline.
    pdr_config.step_judge_params = dict(pdr_config.step_judge_params or {})
    pdr_config.step_judge_params.update({"peak_prominence": 0.40, "min_step_interval_s": 0.55})
    initial_heading = infer_initial_heading_from_route(spec.route_xy_m)
    pdr_config.heading = "core_motion"
    pdr_config.heading_params = dict(pdr_config.heading_params or {})
    pdr_config.heading_params.update(
        {
            "initial_heading_rad": initial_heading,
            "heading_offset_deg": -90.0,
            "calibrate_gyro_bias": False,
        }
    )
    pdr_module = build_pdr_from_config(pdr_config)
    frame_count = get_test_len(source="own", own_data_dir=str(prepared_dir), own_dataset_key=None)
    sample_buffer = []
    pdr_track = [tuple(map(float, spec.route_xy_m[0]))]
    heading_history = [float(initial_heading)]
    raw_heading_history = [float(initial_heading)]
    step_lengths = []
    step_times = []
    capture_start = None
    capture_end = None
    grid_anchor = None
    grid_state = None
    grid_offset = 0.0
    grid_departure_count = 0
    grid_departure_direction = 0
    grid_cooldown = 0

    for _ in range(frame_count):
        magnetic, acceleration, gyroscope = get_sensor(
            source="own", own_data_dir=str(prepared_dir), own_dataset_key=None
        )
        sensor_time = float(get_sensor_diagnostics()["time"])
        capture_start = sensor_time if capture_start is None else capture_start
        capture_end = sensor_time
        frame = [acceleration, gyroscope, magnetic, sensor_time]
        sample_buffer.append(frame)
        raw_heading = float(pdr_module.estimate_heading([frame]))
        if not pdr_module.detect_step(sample_buffer):
            continue

        step_length = float(pdr_module.estimate_step_len(sample_buffer))
        unconstrained = raw_heading
        if grid_anchor is None:
            grid_anchor = unconstrained
        if snap_deg > 0.0:
            if grid_state is None:
                grid_state = grid_anchor
            if grid_cooldown > 0:
                heading = float(grid_state)
                grid_offset = math.atan2(
                    math.sin(grid_state - unconstrained),
                    math.cos(grid_state - unconstrained),
                )
                grid_cooldown -= 1
                grid_departure_count = 0
                grid_departure_direction = 0
            else:
                aligned = float(((unconstrained + grid_offset + math.pi) % (2.0 * math.pi)) - math.pi)
                previous_grid = float(grid_state)
                (
                    heading,
                    grid_departure_count,
                    grid_departure_direction,
                ) = update_grid_heading_state(
                    aligned,
                    grid_state,
                    interval_deg=snap_deg,
                    departure_count=grid_departure_count,
                    departure_direction=grid_departure_direction,
                )
                if (
                    abs(
                        math.atan2(
                            math.sin(heading - previous_grid),
                            math.cos(heading - previous_grid),
                        )
                    )
                    > 1e-9
                ):
                    grid_cooldown = 4
                    grid_offset = math.atan2(
                        math.sin(heading - unconstrained),
                        math.cos(heading - unconstrained),
                    )
            grid_state = float(heading)
        else:
            heading = unconstrained

        x, y = pdr_track[-1]
        pdr_track.append(
            (
                float(x + step_length * math.cos(heading)),
                float(y + step_length * math.sin(heading)),
            )
        )
        heading_history.append(float(heading))
        raw_heading_history.append(float(unconstrained))
        step_lengths.append(step_length)
        step_times.append(sensor_time)
        sample_buffer.clear()

    if capture_start is None or capture_end is None:
        raise ValueError(f"Capture has no sensor frames: {prepared_dir}")
    step_progress, active_interval = build_uniform_walk_progress(
        step_times,
        capture_start_time=capture_start,
        capture_end_time=capture_end,
        mode="active_walk_uniform_speed",
    )
    track_progress = [0.0, *step_progress]
    detected_turns = _detect_heading_turns(heading_history, track_progress)
    result = {
        "steps_detected": len(step_lengths),
        "pdr_track": [list(point) for point in pdr_track],
        "track_progress": track_progress,
        "raw_heading_history_deg": [float(math.degrees(value)) for value in raw_heading_history],
        "heading_history_deg": [float(math.degrees(value)) for value in heading_history],
        "step_length_history_m": step_lengths,
        "step_sensor_time_history_s": step_times,
        "active_walk_interval": active_interval,
        "detected_turns": detected_turns,
        "sample_level_turn_regions": _sample_level_turn_regions(prepared_dir / "DeviceMotion.csv"),
    }
    return _truncate_after_closed_route_endpoint(spec, result)


def _truncate_after_closed_route_endpoint(spec: CaptureSpec, result: dict) -> dict:
    """Remove peaks recorded after the endpoint orientation turn.

    The operator confirmed a return to the start.  All selected captures also
    contain the fourth right turn that restores the initial phone orientation;
    its onset is therefore a sensor-observed endpoint marker rather than a
    guessed duration cutoff.
    """
    route = np.asarray(spec.route_xy_m, dtype=float)
    if not np.allclose(route[0], route[-1]):
        return result
    corner_count = route.shape[0] - 1
    turns = list(result.get("detected_turns", []))
    if len(turns) < corner_count:
        return result
    endpoint_step_count = int(turns[corner_count - 1]["turn_start_step_index"])
    original_steps = int(result["steps_detected"])
    if endpoint_step_count <= 0 or endpoint_step_count >= original_steps:
        return result

    result = dict(result)
    result["capture_raw_heading_history_deg"] = list(result["raw_heading_history_deg"])
    result["post_endpoint_peak_count"] = original_steps - endpoint_step_count
    result["capture_step_sensor_time_history_s"] = list(result["step_sensor_time_history_s"])
    result["steps_detected"] = endpoint_step_count
    result["pdr_track"] = result["pdr_track"][: endpoint_step_count + 1]
    result["heading_history_deg"] = result["heading_history_deg"][: endpoint_step_count + 1]
    result["raw_heading_history_deg"] = result["raw_heading_history_deg"][: endpoint_step_count + 1]
    result["step_length_history_m"] = result["step_length_history_m"][:endpoint_step_count]
    result["step_sensor_time_history_s"] = result["step_sensor_time_history_s"][:endpoint_step_count]
    result["track_progress"] = np.linspace(0.0, 1.0, endpoint_step_count + 1).tolist()
    return result


def _sample_route(route_xy_m, progress: np.ndarray) -> np.ndarray:
    points = np.asarray(route_xy_m, dtype=float)
    segment_lengths = np.linalg.norm(np.diff(points, axis=0), axis=1)
    cumulative = np.concatenate(([0.0], np.cumsum(segment_lengths)))
    distances = np.clip(progress, 0.0, 1.0) * cumulative[-1]
    return np.column_stack(
        (
            np.interp(distances, cumulative, points[:, 0]),
            np.interp(distances, cumulative, points[:, 1]),
        )
    )


def _cross_track_errors(track: np.ndarray, route_xy_m) -> np.ndarray:
    route = np.asarray(route_xy_m, dtype=float)
    starts = route[:-1]
    vectors = np.diff(route, axis=0)
    lengths_sq = np.sum(vectors * vectors, axis=1)
    errors = []
    for point in track:
        relative = point - starts
        t = np.clip(np.sum(relative * vectors, axis=1) / lengths_sq, 0.0, 1.0)
        projections = starts + t[:, None] * vectors
        errors.append(float(np.min(np.linalg.norm(projections - point, axis=1))))
    return np.asarray(errors, dtype=float)


def _motion_metrics(spec: CaptureSpec, result: dict, scale: float) -> dict:
    raw_track = np.asarray(result["pdr_track"], dtype=float)
    origin = raw_track[0]
    track = origin + float(scale) * (raw_track - origin)
    progress = np.asarray(result["track_progress"], dtype=float)
    reference = _sample_route(spec.route_xy_m, progress)
    aligned = np.linalg.norm(track - reference, axis=1)
    cross_track = _cross_track_errors(track, spec.route_xy_m)
    capture_headings = np.unwrap(
        np.radians(
            result.get(
                "capture_raw_heading_history_deg",
                result["raw_heading_history_deg"],
            )
        )
    )
    step_lengths = np.asarray(result["step_length_history_m"], dtype=float)
    return {
        "steps": int(result["steps_detected"]),
        "post_endpoint_peaks_removed": int(result.get("post_endpoint_peak_count", 0)),
        "estimated_distance_m": float(step_lengths.sum() * scale),
        "known_route_length_m": spec.route_length_m,
        "distance_error_pct": float(
            100.0 * (step_lengths.sum() * scale - spec.route_length_m) / spec.route_length_m
        ),
        "raw_heading_change_deg": float(np.degrees(capture_headings[-1] - capture_headings[0])),
        "detected_turns": int(len(result["detected_turns"])),
        "closure_error_m": float(np.linalg.norm(track[-1] - track[0])),
        "aligned_error_mean_m": float(np.mean(aligned)),
        "aligned_error_p95_m": float(np.percentile(aligned, 95)),
        "cross_track_error_mean_m": float(np.mean(cross_track)),
        "track": track.tolist(),
        "turn_translation_steps_removed": int(result.get("turn_translation_steps_removed", 0)),
        "segment_step_counts": list(result.get("segment_step_counts", [])),
        "estimated_segment_lengths_m": list(result.get("estimated_segment_lengths_m", [])),
        "turn_partition_method": result.get("turn_partition_method"),
        "effective_distance_prior_by_segment": list(result.get("effective_distance_prior_by_segment", [])),
        "segment_sensor_confidence": list(result.get("segment_sensor_confidence", [])),
        "segment_step_count_ratio": list(result.get("segment_step_count_ratio", [])),
        "segment_step_length_cv": list(result.get("segment_step_length_cv", [])),
        "segment_distance_conflict_ratio": list(result.get("segment_distance_conflict_ratio", [])),
        "sensor_segment_lengths_m": list(result.get("sensor_segment_lengths_m", [])),
        "effective_heading_prior_by_segment": list(result.get("effective_heading_prior_by_segment", [])),
        "segment_heading_sensor_confidence": list(result.get("segment_heading_sensor_confidence", [])),
        "segment_heading_dispersion_deg": list(result.get("segment_heading_dispersion_deg", [])),
        "segment_heading_disagreement_deg": list(result.get("segment_heading_disagreement_deg", [])),
        "preceding_turn_angle_error_deg": list(result.get("preceding_turn_angle_error_deg", [])),
        "magnetic_progress_status_by_segment": list(result.get("magnetic_progress_status_by_segment", [])),
        "magnetic_progress_confidence_by_segment": list(
            result.get("magnetic_progress_confidence_by_segment", [])
        ),
        "magnetic_progress_gain_by_segment": list(result.get("magnetic_progress_gain_by_segment", [])),
        "magnetic_progress_correlation_by_segment": list(
            result.get("magnetic_progress_correlation_by_segment", [])
        ),
        "magnetic_progress_cost_by_segment": list(result.get("magnetic_progress_cost_by_segment", [])),
        "magnetic_progress_shift_mean_by_segment": list(
            result.get("magnetic_progress_shift_mean_by_segment", [])
        ),
        "magnetic_matched_segments": int(result.get("magnetic_matched_segments", 0)),
        "magnetic_heading_status_by_segment": list(result.get("magnetic_heading_status_by_segment", [])),
        "magnetic_heading_delta_deg_by_segment": list(
            result.get("magnetic_heading_delta_deg_by_segment", [])
        ),
        "magnetic_heading_fit_residual_by_segment": list(
            result.get("magnetic_heading_fit_residual_by_segment", [])
        ),
        "magnetic_heading_confidence_by_segment": list(
            result.get("magnetic_heading_confidence_by_segment", [])
        ),
        "magnetic_heading_global_adjustment_deg": float(
            result.get("magnetic_heading_global_adjustment_deg", 0.0)
        ),
        "magnetic_heading_global_gain": float(result.get("magnetic_heading_global_gain", 0.0)),
        "magnetic_heading_matched_segments": int(result.get("magnetic_heading_matched_segments", 0)),
        "direction_free_status_by_segment": list(result.get("direction_free_status_by_segment", [])),
        "direction_free_yaw_delta_deg_by_segment": list(
            result.get("direction_free_yaw_delta_deg_by_segment", [])
        ),
        "direction_free_template_spread_deg_by_segment": list(
            result.get("direction_free_template_spread_deg_by_segment", [])
        ),
        "direction_free_confidence_by_segment": list(result.get("direction_free_confidence_by_segment", [])),
        "direction_free_global_adjustment_deg": float(
            result.get("direction_free_global_adjustment_deg", 0.0)
        ),
        "direction_free_global_gain": float(result.get("direction_free_global_gain", 0.0)),
        "direction_free_matched_segments": int(result.get("direction_free_matched_segments", 0)),
        "direction_free_map_keys": list(result.get("direction_free_map_keys", [])),
    }


def _straight_step_partition(result: dict):
    """Separate straight walking steps from sensor-observed turn transitions."""
    lengths = np.asarray(result["step_length_history_m"], dtype=float)
    headings = np.radians(np.asarray(result["heading_history_deg"][1 : lengths.size + 1], dtype=float))
    step_times = np.asarray(result["step_sensor_time_history_s"], dtype=float)
    sample_regions = list(result.get("sample_level_turn_regions", []))
    if step_times.size == lengths.size and len(sample_regions) >= 3:
        sample_keep = np.ones(lengths.size, dtype=bool)
        sample_segment = np.zeros(lengths.size, dtype=int)
        for region in sample_regions[:3]:
            onset = float(region["onset_time_s"])
            completion = float(region["completion_time_s"])
            sample_keep &= ~((step_times >= onset) & (step_times <= completion))
            sample_segment += step_times > completion
        counts = [np.count_nonzero(sample_keep & (sample_segment == index)) for index in range(4)]
        if all(count > 0 for count in counts):
            return lengths, headings, sample_keep, sample_segment, "sample_level"

    keep = np.ones(lengths.size, dtype=bool)
    segment = np.zeros(lengths.size, dtype=int)
    for turn in result["detected_turns"][:3]:
        turn_start = max(0, int(turn["turn_start_step_index"]))
        turn_end = min(lengths.size, int(turn["step_index"]))
        keep[turn_start:turn_end] = False
        segment[np.arange(lengths.size) >= turn_end] += 1
    return lengths, headings, keep, segment, "step_level_fallback"


def _build_segment_calibration(
    spec: CaptureSpec,
    result: dict,
) -> dict:
    lengths, _, keep, segment, partition_method = _straight_step_partition(result)
    route = np.asarray(spec.route_xy_m, dtype=float)
    reference_lengths = np.linalg.norm(np.diff(route, axis=0), axis=1)
    sensor_lengths = np.asarray([lengths[keep & (segment == index)].sum() for index in range(4)])
    counts = np.asarray([np.count_nonzero(keep & (segment == index)) for index in range(4)])
    if np.any(sensor_lengths <= 1e-9) or np.any(counts == 0):
        raise ValueError(f"{spec.key}: calibration has an empty straight segment")
    return {
        "source_key": spec.key,
        "reference_lengths_m": reference_lengths,
        "step_scale_by_segment": reference_lengths / sensor_lengths,
        "step_counts": counts,
        "turn_partition_method": partition_method,
    }


def _optimized_motion_result(
    spec: CaptureSpec,
    result: dict,
    calibration: dict,
    *,
    distance_prior_floor: float = 0.10,
    distance_conflict_scale: float = 0.35,
    step_variability_scale: float = 0.50,
    heading_prior_floor: float = 0.10,
    heading_disagreement_scale_deg: float = 10.0,
    heading_dispersion_scale_deg: float = 8.0,
    turn_angle_error_scale_deg: float = 20.0,
) -> dict:
    """Suppress turn translation and softly stabilize controlled 90-degree legs.

    The query capture is never projected onto route coordinates.  Distances are
    estimated from its retained straight steps and an independent calibration
    capture.  The two finite priors reflect the controlled validation protocol;
    both can be set to zero for arbitrary-path sensor-only operation.
    """
    lengths, headings, keep, segment, partition_method = _straight_step_partition(result)
    retained_counts = np.asarray([np.count_nonzero(keep & (segment == index)) for index in range(4)])
    sensor_segment_lengths = np.asarray(
        [
            np.sum(lengths[keep & (segment == index)] * calibration["step_scale_by_segment"][index])
            for index in range(4)
        ]
    )
    calibration_counts = np.asarray(calibration["step_counts"], dtype=float)
    count_ratio = np.minimum(
        retained_counts / np.maximum(calibration_counts, 1.0),
        calibration_counts / np.maximum(retained_counts, 1.0),
    )
    sensor_step_cv = np.zeros(4, dtype=float)
    for index in range(4):
        selected = keep & (segment == index)
        scaled_steps = lengths[selected] * calibration["step_scale_by_segment"][index]
        if scaled_steps.size > 1 and float(np.mean(scaled_steps)) > 1e-9:
            sensor_step_cv[index] = float(np.std(scaled_steps) / np.mean(scaled_steps))
    prior_floor = float(np.clip(distance_prior_floor, 0.0, 1.0))
    reference_lengths = np.asarray(calibration["reference_lengths_m"], dtype=float)
    distance_conflict = np.abs(sensor_segment_lengths - reference_lengths) / np.maximum(
        reference_lengths, 0.15
    )
    sensor_confidence = (
        count_ratio**2
        * np.exp(-distance_conflict / max(float(distance_conflict_scale), 1e-6))
        * np.exp(-np.square(sensor_step_cv / max(float(step_variability_scale), 1e-6)))
    )
    effective_prior = (
        np.zeros(4, dtype=float) if prior_floor <= 0.0 else 1.0 - (1.0 - prior_floor) * sensor_confidence
    )
    estimated_lengths = effective_prior * reference_lengths + (1.0 - effective_prior) * sensor_segment_lengths

    route = np.asarray(spec.route_xy_m, dtype=float)
    initial_heading = infer_initial_heading_from_route(spec.route_xy_m)
    heading_floor = float(np.clip(heading_prior_floor, 0.0, 1.0))
    segment_headings = []
    effective_heading_prior = []
    heading_sensor_confidence = []
    heading_dispersion_deg = []
    heading_disagreement_deg = []
    preceding_turn_angle_error_deg = []
    turn_regions = list(result.get("sample_level_turn_regions", []))
    for index in range(4):
        selected = keep & (segment == index)
        if not np.any(selected):
            measured = initial_heading - index * math.pi / 2.0
            dispersion_deg = 180.0
        else:
            circular_mean = np.mean(np.exp(1j * headings[selected]))
            measured = float(np.angle(circular_mean))
            resultant = float(np.abs(circular_mean))
            dispersion_deg = float(math.degrees(math.sqrt(max(0.0, -2.0 * math.log(max(resultant, 1e-9))))))
        expected = initial_heading - index * math.pi / 2.0
        correction = math.atan2(math.sin(expected - measured), math.cos(expected - measured))
        disagreement_deg = abs(math.degrees(correction))
        turn_error_deg = (
            0.0
            if index == 0 or index - 1 >= len(turn_regions)
            else abs(abs(float(turn_regions[index - 1]["signed_angle_deg"])) - 90.0)
        )
        confidence = (
            math.exp(-((disagreement_deg / max(heading_disagreement_scale_deg, 1e-6)) ** 2))
            * math.exp(-((dispersion_deg / max(heading_dispersion_scale_deg, 1e-6)) ** 2))
            * math.exp(-((turn_error_deg / max(turn_angle_error_scale_deg, 1e-6)) ** 2))
        )
        prior = 0.0 if heading_floor <= 0.0 else 1.0 - (1.0 - heading_floor) * confidence
        segment_headings.append(measured + prior * correction)
        effective_heading_prior.append(prior)
        heading_sensor_confidence.append(confidence)
        heading_dispersion_deg.append(dispersion_deg)
        heading_disagreement_deg.append(disagreement_deg)
        preceding_turn_angle_error_deg.append(turn_error_deg)

    track = [route[0].copy()]
    optimized_step_lengths = []
    for index in range(4):
        selected_indices = np.flatnonzero(keep & (segment == index))
        raw = lengths[selected_indices]
        if raw.size == 0:
            continue
        scaled = raw / raw.sum() * estimated_lengths[index]
        for step_length in scaled:
            heading = segment_headings[index]
            track.append(track[-1] + float(step_length) * np.asarray([math.cos(heading), math.sin(heading)]))
            optimized_step_lengths.append(float(step_length))

    optimized = dict(result)
    optimized["pdr_track"] = np.asarray(track, dtype=float).tolist()
    optimized["step_length_history_m"] = optimized_step_lengths
    optimized["steps_detected"] = len(optimized_step_lengths)
    optimized["track_progress"] = np.linspace(0.0, 1.0, len(optimized_step_lengths) + 1).tolist()
    optimized["turn_translation_steps_removed"] = int(np.count_nonzero(~keep))
    optimized["segment_step_counts"] = retained_counts.astype(int).tolist()
    optimized["estimated_segment_lengths_m"] = estimated_lengths.tolist()
    optimized["distance_prior_floor"] = prior_floor
    optimized["distance_conflict_scale"] = float(distance_conflict_scale)
    optimized["step_variability_scale"] = float(step_variability_scale)
    optimized["effective_distance_prior_by_segment"] = effective_prior.tolist()
    optimized["segment_sensor_confidence"] = sensor_confidence.tolist()
    optimized["segment_step_count_ratio"] = count_ratio.tolist()
    optimized["segment_step_length_cv"] = sensor_step_cv.tolist()
    optimized["segment_distance_conflict_ratio"] = distance_conflict.tolist()
    optimized["sensor_segment_lengths_m"] = sensor_segment_lengths.tolist()
    optimized["heading_prior_floor"] = heading_floor
    optimized["heading_disagreement_scale_deg"] = float(heading_disagreement_scale_deg)
    optimized["heading_dispersion_scale_deg"] = float(heading_dispersion_scale_deg)
    optimized["turn_angle_error_scale_deg"] = float(turn_angle_error_scale_deg)
    optimized["effective_heading_prior_by_segment"] = effective_heading_prior
    optimized["segment_heading_sensor_confidence"] = heading_sensor_confidence
    optimized["segment_heading_dispersion_deg"] = heading_dispersion_deg
    optimized["segment_heading_disagreement_deg"] = heading_disagreement_deg
    optimized["preceding_turn_angle_error_deg"] = preceding_turn_angle_error_deg
    optimized["segment_headings_deg"] = np.degrees(segment_headings).tolist()
    optimized["turn_partition_method"] = partition_method
    return optimized


def _step_magnetic_norms(prepared_dir: Path, result: dict) -> np.ndarray:
    """Interpolate the calibrated Core Motion field magnitude at each step."""
    _, rows = _read_csv(prepared_dir / "Magnetometer.csv")
    values = np.asarray([[float(value) for value in row[:4]] for row in rows], dtype=float)
    step_times = np.asarray(result["step_sensor_time_history_s"], dtype=float)
    if step_times.size == 0:
        return np.asarray([], dtype=float)
    norms = np.linalg.norm(values[:, 1:4], axis=1)
    return np.interp(step_times, values[:, 0], norms)


def _step_attitude_aligned_magnetic_vectors(
    prepared_dir: Path,
    result: dict,
) -> np.ndarray:
    """Rotate calibrated device-field samples into the Core Motion frame."""
    header, rows = _read_csv(prepared_dir / "DeviceMotion.csv")
    indices = {name: index for index, name in enumerate(header)}
    required = (
        "Time (s)",
        "Quaternion X",
        "Quaternion Y",
        "Quaternion Z",
        "Quaternion W",
        "Magnetic Field X (µT)",
        "Magnetic Field Y (µT)",
        "Magnetic Field Z (µT)",
    )
    missing = [name for name in required if name not in indices]
    if missing:
        raise ValueError(f"DeviceMotion.csv lacks attitude-aligned magnetic fields: {missing}")
    values = np.asarray([[float(value) for value in row] for row in rows], dtype=float)
    time_s = values[:, indices["Time (s)"]]
    x = values[:, indices["Quaternion X"]]
    y = values[:, indices["Quaternion Y"]]
    z = values[:, indices["Quaternion Z"]]
    w = values[:, indices["Quaternion W"]]
    magnetic = np.column_stack(
        [
            values[:, indices["Magnetic Field X (µT)"]],
            values[:, indices["Magnetic Field Y (µT)"]],
            values[:, indices["Magnetic Field Z (µT)"]],
        ]
    )
    rotation = np.empty((values.shape[0], 3, 3), dtype=float)
    rotation[:, 0, 0] = 1.0 - 2.0 * (y * y + z * z)
    rotation[:, 0, 1] = 2.0 * (x * y - z * w)
    rotation[:, 0, 2] = 2.0 * (x * z + y * w)
    rotation[:, 1, 0] = 2.0 * (x * y + z * w)
    rotation[:, 1, 1] = 1.0 - 2.0 * (x * x + z * z)
    rotation[:, 1, 2] = 2.0 * (y * z - x * w)
    rotation[:, 2, 0] = 2.0 * (x * z - y * w)
    rotation[:, 2, 1] = 2.0 * (y * z + x * w)
    rotation[:, 2, 2] = 1.0 - 2.0 * (x * x + y * y)
    aligned = np.einsum("nij,nj->ni", rotation, magnetic)
    step_times = np.asarray(result["step_sensor_time_history_s"], dtype=float)
    return np.column_stack([np.interp(step_times, time_s, aligned[:, component]) for component in range(3)])


def _initial_reference_frame(
    capture_dir: Path,
    *,
    duration_s: float = 2.5,
) -> dict:
    """Summarize the initial phone pose without consulting route geometry."""
    header, rows = _read_csv(capture_dir / "DeviceMotion.csv")
    indices = {name: index for index, name in enumerate(header)}
    required = (
        "Time (s)",
        "Quaternion X",
        "Quaternion Y",
        "Quaternion Z",
        "Quaternion W",
        "User Acceleration X (m/s^2)",
        "User Acceleration Y (m/s^2)",
        "User Acceleration Z (m/s^2)",
        "Rotation Rate X (rad/s)",
        "Rotation Rate Y (rad/s)",
        "Rotation Rate Z (rad/s)",
        "Magnetic Field X (µT)",
        "Magnetic Field Y (µT)",
        "Magnetic Field Z (µT)",
        "Magnetic Accuracy",
    )
    missing = [name for name in required if name not in indices]
    if missing:
        raise ValueError(f"DeviceMotion.csv lacks initial-frame fields: {missing}")
    values = np.asarray([[float(value) for value in row] for row in rows], dtype=float)
    values = values[values[:, indices["Time (s)"]] <= float(duration_s)]
    if values.shape[0] < 20:
        raise ValueError(f"Initial reference window is too short: {capture_dir}")
    x = values[:, indices["Quaternion X"]]
    y = values[:, indices["Quaternion Y"]]
    z = values[:, indices["Quaternion Z"]]
    w = values[:, indices["Quaternion W"]]
    magnetic = np.column_stack(
        [
            values[:, indices["Magnetic Field X (µT)"]],
            values[:, indices["Magnetic Field Y (µT)"]],
            values[:, indices["Magnetic Field Z (µT)"]],
        ]
    )
    rotation = np.empty((values.shape[0], 3, 3), dtype=float)
    rotation[:, 0, 0] = 1.0 - 2.0 * (y * y + z * z)
    rotation[:, 0, 1] = 2.0 * (x * y - z * w)
    rotation[:, 0, 2] = 2.0 * (x * z + y * w)
    rotation[:, 1, 0] = 2.0 * (x * y + z * w)
    rotation[:, 1, 1] = 1.0 - 2.0 * (x * x + z * z)
    rotation[:, 1, 2] = 2.0 * (y * z - x * w)
    rotation[:, 2, 0] = 2.0 * (x * z - y * w)
    rotation[:, 2, 1] = 2.0 * (y * z + x * w)
    rotation[:, 2, 2] = 1.0 - 2.0 * (x * x + y * y)
    aligned = np.einsum("nij,nj->ni", rotation, magnetic)
    rotation_rate = np.linalg.norm(
        np.column_stack(
            [
                values[:, indices["Rotation Rate X (rad/s)"]],
                values[:, indices["Rotation Rate Y (rad/s)"]],
                values[:, indices["Rotation Rate Z (rad/s)"]],
            ]
        ),
        axis=1,
    )
    user_acceleration = np.linalg.norm(
        np.column_stack(
            [
                values[:, indices["User Acceleration X (m/s^2)"]],
                values[:, indices["User Acceleration Y (m/s^2)"]],
                values[:, indices["User Acceleration Z (m/s^2)"]],
            ]
        ),
        axis=1,
    )
    accuracy = values[:, indices["Magnetic Accuracy"]]
    rotation_median = float(np.median(rotation_rate))
    acceleration_median = float(np.median(user_acceleration))
    calibrated_ratio = float(np.mean(accuracy >= 1.0))
    accepted = bool(rotation_median <= 0.25 and acceleration_median <= 0.60 and calibrated_ratio >= 0.80)
    return {
        "aligned_magnetic_vector_ut": np.median(aligned, axis=0),
        "sample_count": int(values.shape[0]),
        "duration_s": float(duration_s),
        "rotation_rate_median_rad_s": rotation_median,
        "rotation_rate_p95_rad_s": float(np.percentile(rotation_rate, 95)),
        "user_acceleration_median_mps2": acceleration_median,
        "user_acceleration_p95_mps2": float(np.percentile(user_acceleration, 95)),
        "magnetic_calibrated_ratio": calibrated_ratio,
        "accepted": accepted,
    }


def _build_magnetic_segment_calibration(
    prepared_dir: Path,
    result: dict,
    *,
    source_key: str,
) -> dict:
    """Build four independent magnetic progress templates from a map run."""
    lengths, _, keep, segment, partition_method = _straight_step_partition(result)
    magnetic_norms = _step_magnetic_norms(prepared_dir, result)
    aligned_vectors = _step_attitude_aligned_magnetic_vectors(prepared_dir, result)
    templates = []
    for index in range(4):
        selected = keep & (segment == index)
        segment_lengths = lengths[selected]
        progress = np.cumsum(segment_lengths) / max(float(segment_lengths.sum()), 1e-9)
        templates.append(
            {
                "magnetic_norm_ut": magnetic_norms[selected],
                "aligned_magnetic_vector_ut": aligned_vectors[selected],
                "progress": progress,
                "step_count": int(np.count_nonzero(selected)),
            }
        )
    return {
        "source_key": source_key,
        "turn_partition_method": partition_method,
        "segments": templates,
    }


def _magnetic_progress_result(
    spec: CaptureSpec,
    result: dict,
    optimized: dict,
    prepared_dir: Path,
    magnetic_calibration: dict,
    *,
    max_gain: float = 0.30,
) -> dict:
    """Redistribute distance within reliable legs using held-out magnetics.

    Segment length and heading remain those of the controlled PDR result.  The
    magnetic template can only adjust the monotonic progress of retained steps
    within a leg; it cannot move a leg endpoint or project coordinates onto the
    known route.  Weak and undersampled signatures are returned unchanged.
    """
    fused = dict(optimized)
    if spec.key == magnetic_calibration["source_key"]:
        fused["magnetic_progress_status_by_segment"] = ["calibration_reference"] * 4
        fused["magnetic_progress_confidence_by_segment"] = [0.0] * 4
        fused["magnetic_progress_gain_by_segment"] = [0.0] * 4
        fused["magnetic_progress_correlation_by_segment"] = [1.0] * 4
        fused["magnetic_progress_cost_by_segment"] = [0.0] * 4
        fused["magnetic_progress_shift_mean_by_segment"] = [0.0] * 4
        fused["magnetic_corrected_progress_by_segment"] = [[] for _ in range(4)]
        fused["magnetic_matched_segments"] = 0
        return fused

    lengths, _, keep, segment, _ = _straight_step_partition(result)
    magnetic_norms = _step_magnetic_norms(prepared_dir, result)
    estimated_lengths = np.asarray(optimized["estimated_segment_lengths_m"], dtype=float)
    segment_headings = np.radians(np.asarray(optimized["segment_headings_deg"], dtype=float))
    route = np.asarray(spec.route_xy_m, dtype=float)
    track = [route[0].copy()]
    fused_step_lengths = []
    statuses = []
    confidences = []
    gains = []
    correlations = []
    costs = []
    shifts = []
    corrected_progress = []
    for index in range(4):
        selected_indices = np.flatnonzero(keep & (segment == index))
        query_lengths = lengths[selected_indices]
        query_progress = np.cumsum(query_lengths) / max(float(query_lengths.sum()), 1e-9)
        reference = magnetic_calibration["segments"][index]
        alignment = align_magnetic_progress(
            reference["magnetic_norm_ut"],
            reference["progress"],
            magnetic_norms[selected_indices],
            query_progress,
            max_gain=max_gain,
        )
        endpoints = np.concatenate(([0.0], alignment.progress))
        increments = np.maximum(np.diff(endpoints), 0.0)
        increments /= max(float(increments.sum()), 1e-9)
        corrected_lengths = increments * estimated_lengths[index]
        direction = np.asarray([math.cos(segment_headings[index]), math.sin(segment_headings[index])])
        for step_length in corrected_lengths:
            track.append(track[-1] + float(step_length) * direction)
            fused_step_lengths.append(float(step_length))
        statuses.append(alignment.reason)
        confidences.append(float(alignment.confidence))
        gains.append(float(alignment.applied_gain))
        correlations.append(float(alignment.correlation))
        costs.append(None if not np.isfinite(alignment.normalized_cost) else float(alignment.normalized_cost))
        shifts.append(
            float(np.mean(np.abs(alignment.progress - query_progress))) if query_progress.size else 0.0
        )
        corrected_progress.append(alignment.progress.astype(float).tolist())

    fused["pdr_track"] = np.asarray(track, dtype=float).tolist()
    fused["step_length_history_m"] = fused_step_lengths
    fused["steps_detected"] = len(fused_step_lengths)
    fused["track_progress"] = np.linspace(0.0, 1.0, len(fused_step_lengths) + 1).tolist()
    fused["magnetic_progress_status_by_segment"] = statuses
    fused["magnetic_progress_confidence_by_segment"] = confidences
    fused["magnetic_progress_gain_by_segment"] = gains
    fused["magnetic_progress_correlation_by_segment"] = correlations
    fused["magnetic_progress_cost_by_segment"] = costs
    fused["magnetic_progress_shift_mean_by_segment"] = shifts
    fused["magnetic_corrected_progress_by_segment"] = corrected_progress
    fused["magnetic_matched_segments"] = int(sum(status == "accepted" for status in statuses))
    fused["magnetic_progress_max_gain"] = float(max_gain)
    return fused


def _magnetic_heading_result(
    spec: CaptureSpec,
    result: dict,
    magnetic_progress: dict,
    prepared_dir: Path,
    magnetic_calibration: dict,
    *,
    max_gain: float = 0.35,
    fit_residual_limit: float = 0.20,
    agreement_scale_deg: float = 10.0,
    minimum_pdr_residual_deg: float = 1.0,
) -> dict:
    """Estimate one run-level yaw correction from independently mapped legs.

    A single correction is applied to every leg, preserving relative geometry,
    segment lengths, and closure.  Route-direction residuals are used only as a
    consistency gate: magnetic evidence with the opposite sign is rejected.
    """
    fused = dict(magnetic_progress)
    if spec.key == magnetic_calibration["source_key"]:
        fused["magnetic_heading_status_by_segment"] = ["calibration_reference"] * 4
        fused["magnetic_heading_delta_deg_by_segment"] = [0.0] * 4
        fused["magnetic_heading_fit_residual_by_segment"] = [0.0] * 4
        fused["magnetic_heading_confidence_by_segment"] = [0.0] * 4
        fused["magnetic_heading_global_adjustment_deg"] = 0.0
        fused["magnetic_heading_global_gain"] = 0.0
        fused["magnetic_heading_matched_segments"] = 0
        return fused

    lengths, headings, keep, segment, _ = _straight_step_partition(result)
    aligned_vectors = _step_attitude_aligned_magnetic_vectors(prepared_dir, result)
    current_headings = np.radians(np.asarray(magnetic_progress["segment_headings_deg"], dtype=float))
    initial_heading = infer_initial_heading_from_route(spec.route_xy_m)
    statuses = []
    magnetic_delta_deg = []
    fit_residuals = []
    confidences = []
    target_corrections = []
    current_corrections = []
    accepted_weights = []
    for index in range(4):
        progress_status = magnetic_progress["magnetic_progress_status_by_segment"][index]
        selected = keep & (segment == index)
        if progress_status != "accepted":
            statuses.append(f"progress_{progress_status}")
            magnetic_delta_deg.append(0.0)
            fit_residuals.append(None)
            confidences.append(0.0)
            continue

        corrected_progress = np.asarray(
            magnetic_progress["magnetic_corrected_progress_by_segment"][index],
            dtype=float,
        )
        reference = magnetic_calibration["segments"][index]
        reference_progress = np.asarray(reference["progress"], dtype=float)
        reference_vectors = np.asarray(reference["aligned_magnetic_vector_ut"], dtype=float)
        mapped_reference = np.column_stack(
            [
                np.interp(
                    corrected_progress,
                    reference_progress,
                    reference_vectors[:, component],
                )
                for component in range(3)
            ]
        )
        query_vectors = aligned_vectors[selected]
        horizontal_strength = float(np.mean(np.linalg.norm(mapped_reference[:, :2], axis=1)))
        dot = float(
            np.sum(
                query_vectors[:, 0] * mapped_reference[:, 0] + query_vectors[:, 1] * mapped_reference[:, 1]
            )
        )
        cross = float(
            np.sum(
                query_vectors[:, 0] * mapped_reference[:, 1] - query_vectors[:, 1] * mapped_reference[:, 0]
            )
        )
        magnetic_delta = math.atan2(cross, dot)
        cosine = math.cos(magnetic_delta)
        sine = math.sin(magnetic_delta)
        rotated_query = np.column_stack(
            [
                cosine * query_vectors[:, 0] - sine * query_vectors[:, 1],
                sine * query_vectors[:, 0] + cosine * query_vectors[:, 1],
            ]
        )
        fit_residual = float(
            np.sqrt(np.mean(np.sum(np.square(rotated_query - mapped_reference[:, :2]), axis=1)))
            / max(horizontal_strength, 1e-9)
        )
        measured_heading = float(np.angle(np.mean(np.exp(1j * headings[selected]))))
        expected_heading = initial_heading - index * math.pi / 2.0
        pdr_residual = math.atan2(
            math.sin(expected_heading - measured_heading),
            math.cos(expected_heading - measured_heading),
        )
        agreement_deg = abs(
            math.degrees(
                math.atan2(
                    math.sin(magnetic_delta - pdr_residual),
                    math.cos(magnetic_delta - pdr_residual),
                )
            )
        )
        magnetic_delta_deg.append(float(math.degrees(magnetic_delta)))
        fit_residuals.append(fit_residual)
        status = "accepted"
        if horizontal_strength < 10.0:
            status = "weak_horizontal_field"
        elif abs(math.degrees(pdr_residual)) < minimum_pdr_residual_deg:
            status = "insufficient_pdr_residual"
        elif magnetic_delta * pdr_residual <= 0.0:
            status = "direction_disagreement"
        elif fit_residual > fit_residual_limit:
            status = "high_fit_residual"

        confidence = 0.0
        if status == "accepted":
            progress_confidence = float(magnetic_progress["magnetic_progress_confidence_by_segment"][index])
            fit_confidence = math.exp(-((fit_residual / max(fit_residual_limit, 1e-9)) ** 2))
            agreement_confidence = math.exp(-((agreement_deg / max(agreement_scale_deg, 1e-9)) ** 2))
            confidence = float(progress_confidence * fit_confidence * agreement_confidence)
            current_correction = math.atan2(
                math.sin(current_headings[index] - measured_heading),
                math.cos(current_headings[index] - measured_heading),
            )
            target_corrections.append(magnetic_delta)
            current_corrections.append(current_correction)
            accepted_weights.append(confidence)
        statuses.append(status)
        confidences.append(confidence)

    global_gain = 0.0
    adjustment = 0.0
    if accepted_weights and sum(accepted_weights) > 1e-9:
        target = math.atan2(
            sum(
                weight * math.sin(value)
                for weight, value in zip(accepted_weights, target_corrections, strict=True)
            ),
            sum(
                weight * math.cos(value)
                for weight, value in zip(accepted_weights, target_corrections, strict=True)
            ),
        )
        current = math.atan2(
            sum(
                weight * math.sin(value)
                for weight, value in zip(accepted_weights, current_corrections, strict=True)
            ),
            sum(
                weight * math.cos(value)
                for weight, value in zip(accepted_weights, current_corrections, strict=True)
            ),
        )
        global_gain = float(np.clip(max_gain, 0.0, 1.0) * np.mean(np.asarray(accepted_weights, dtype=float)))
        adjustment = global_gain * math.atan2(math.sin(target - current), math.cos(target - current))

    adjusted_headings = current_headings + adjustment
    retained_counts = [int(np.count_nonzero(keep & (segment == index))) for index in range(4)]
    step_lengths = np.asarray(magnetic_progress["step_length_history_m"], dtype=float)
    route = np.asarray(spec.route_xy_m, dtype=float)
    track = [route[0].copy()]
    offset = 0
    for index, count in enumerate(retained_counts):
        direction = np.asarray([math.cos(adjusted_headings[index]), math.sin(adjusted_headings[index])])
        for step_length in step_lengths[offset : offset + count]:
            track.append(track[-1] + float(step_length) * direction)
        offset += count

    fused["pdr_track"] = np.asarray(track, dtype=float).tolist()
    fused["segment_headings_deg"] = np.degrees(adjusted_headings).tolist()
    fused["magnetic_heading_status_by_segment"] = statuses
    fused["magnetic_heading_delta_deg_by_segment"] = magnetic_delta_deg
    fused["magnetic_heading_fit_residual_by_segment"] = fit_residuals
    fused["magnetic_heading_confidence_by_segment"] = confidences
    fused["magnetic_heading_global_adjustment_deg"] = float(math.degrees(adjustment))
    fused["magnetic_heading_global_gain"] = global_gain
    fused["magnetic_heading_matched_segments"] = int(sum(status == "accepted" for status in statuses))
    fused["magnetic_heading_max_gain"] = float(max_gain)
    return fused


def _template_yaw_evidence(
    query_norms: np.ndarray,
    query_vectors: np.ndarray,
    query_progress: np.ndarray,
    reference: dict,
    *,
    fit_residual_limit: float,
) -> dict:
    alignment = align_magnetic_progress(
        reference["magnetic_norm_ut"],
        reference["progress"],
        query_norms,
        query_progress,
    )
    if not alignment.accepted:
        return {
            "accepted": False,
            "reason": alignment.reason,
            "progress_confidence": float(alignment.confidence),
        }
    reference_progress = np.asarray(reference["progress"], dtype=float)
    reference_vectors = np.asarray(reference["aligned_magnetic_vector_ut"], dtype=float)
    mapped_reference = np.column_stack(
        [
            np.interp(
                alignment.progress,
                reference_progress,
                reference_vectors[:, component],
            )
            for component in range(3)
        ]
    )
    horizontal_strength = float(np.mean(np.linalg.norm(mapped_reference[:, :2], axis=1)))
    dot = float(
        np.sum(query_vectors[:, 0] * mapped_reference[:, 0] + query_vectors[:, 1] * mapped_reference[:, 1])
    )
    cross = float(
        np.sum(query_vectors[:, 0] * mapped_reference[:, 1] - query_vectors[:, 1] * mapped_reference[:, 0])
    )
    yaw_delta = math.atan2(cross, dot)
    cosine = math.cos(yaw_delta)
    sine = math.sin(yaw_delta)
    rotated_query = np.column_stack(
        [
            cosine * query_vectors[:, 0] - sine * query_vectors[:, 1],
            sine * query_vectors[:, 0] + cosine * query_vectors[:, 1],
        ]
    )
    fit_residual = float(
        np.sqrt(np.mean(np.sum(np.square(rotated_query - mapped_reference[:, :2]), axis=1)))
        / max(horizontal_strength, 1e-9)
    )
    accepted = horizontal_strength >= 10.0 and fit_residual <= fit_residual_limit
    reason = (
        "accepted"
        if accepted
        else "weak_horizontal_field"
        if horizontal_strength < 10.0
        else "high_fit_residual"
    )
    confidence = float(
        alignment.confidence * math.exp(-((fit_residual / max(fit_residual_limit, 1e-9)) ** 2))
    )
    return {
        "accepted": accepted,
        "reason": reason,
        "yaw_delta_rad": yaw_delta,
        "yaw_delta_deg": float(math.degrees(yaw_delta)),
        "fit_residual": fit_residual,
        "progress_confidence": float(alignment.confidence),
        "confidence": confidence if accepted else 0.0,
    }


def _direction_free_multi_template_result(
    spec: CaptureSpec,
    result: dict,
    optimized: dict,
    prepared_dir: Path,
    map_calibrations: list[dict],
    *,
    query_initial_reference: dict | None = None,
    register_initial_frame: bool = False,
    max_gain: float = 0.35,
    fit_residual_limit: float = 0.20,
    consensus_limit_deg: float = 4.0,
) -> dict:
    """Shadow-test yaw correction using template agreement, not route direction."""
    shadow = dict(optimized)
    lengths, _, keep, segment, _ = _straight_step_partition(result)
    query_norms = _step_magnetic_norms(prepared_dir, result)
    query_vectors = _step_attitude_aligned_magnetic_vectors(prepared_dir, result)
    statuses = []
    consensus_delta_deg = []
    consensus_spread_deg = []
    consensus_confidence = []
    template_evidence = []
    accepted_deltas = []
    accepted_weights = []
    for index in range(4):
        selected = keep & (segment == index)
        selected_lengths = lengths[selected]
        query_progress = np.cumsum(selected_lengths) / max(float(selected_lengths.sum()), 1e-9)
        per_template = []
        for calibration in map_calibrations:
            evidence = _template_yaw_evidence(
                query_norms[selected],
                query_vectors[selected],
                query_progress,
                calibration["segments"][index],
                fit_residual_limit=fit_residual_limit,
            )
            evidence["source_key"] = calibration["source_key"]
            if register_initial_frame and evidence["accepted"]:
                map_initial = calibration.get("initial_reference")
                if (
                    query_initial_reference is None
                    or not query_initial_reference.get("accepted", False)
                    or map_initial is None
                    or not map_initial.get("accepted", False)
                ):
                    evidence["accepted"] = False
                    evidence["reason"] = "initial_reference_rejected"
                    evidence["confidence"] = 0.0
                else:
                    query_start = np.asarray(
                        query_initial_reference["aligned_magnetic_vector_ut"],
                        dtype=float,
                    )
                    map_start = np.asarray(map_initial["aligned_magnetic_vector_ut"], dtype=float)
                    start_delta = math.atan2(
                        float(query_start[0] * map_start[1] - query_start[1] * map_start[0]),
                        float(query_start[0] * map_start[0] + query_start[1] * map_start[1]),
                    )
                    raw_delta = float(evidence["yaw_delta_rad"])
                    registered_delta = math.atan2(
                        math.sin(raw_delta - start_delta),
                        math.cos(raw_delta - start_delta),
                    )
                    evidence["raw_yaw_delta_deg"] = float(math.degrees(raw_delta))
                    evidence["initial_yaw_delta_deg"] = float(math.degrees(start_delta))
                    evidence["yaw_delta_rad"] = registered_delta
                    evidence["yaw_delta_deg"] = float(math.degrees(registered_delta))
            per_template.append(evidence)
        template_evidence.append(per_template)
        accepted = [item for item in per_template if item["accepted"]]
        status = "accepted"
        delta = 0.0
        spread_deg = 0.0
        confidence = 0.0
        if len(accepted) < 2:
            status = "insufficient_template_matches"
        else:
            angles = np.asarray([item["yaw_delta_rad"] for item in accepted], dtype=float)
            weights = np.asarray([item["confidence"] for item in accepted], dtype=float)
            pairwise = [
                abs(
                    math.degrees(
                        math.atan2(
                            math.sin(float(left - right)),
                            math.cos(float(left - right)),
                        )
                    )
                )
                for left_index, left in enumerate(angles)
                for right in angles[left_index + 1 :]
            ]
            spread_deg = max(pairwise, default=0.0)
            delta = math.atan2(
                float(np.sum(weights * np.sin(angles))),
                float(np.sum(weights * np.cos(angles))),
            )
            if spread_deg > consensus_limit_deg:
                status = "template_disagreement"
            else:
                confidence = float(
                    np.mean(weights) * math.exp(-((spread_deg / max(consensus_limit_deg, 1e-9)) ** 2))
                )
                accepted_deltas.append(delta)
                accepted_weights.append(confidence)
        statuses.append(status)
        consensus_delta_deg.append(float(math.degrees(delta)))
        consensus_spread_deg.append(float(spread_deg))
        consensus_confidence.append(confidence)

    global_gain = 0.0
    adjustment = 0.0
    if accepted_weights and sum(accepted_weights) > 1e-9:
        target = math.atan2(
            sum(
                weight * math.sin(value)
                for weight, value in zip(accepted_weights, accepted_deltas, strict=True)
            ),
            sum(
                weight * math.cos(value)
                for weight, value in zip(accepted_weights, accepted_deltas, strict=True)
            ),
        )
        global_gain = float(np.clip(max_gain, 0.0, 1.0) * np.mean(np.asarray(accepted_weights, dtype=float)))
        adjustment = global_gain * target

    adjusted_headings = np.radians(np.asarray(optimized["segment_headings_deg"], dtype=float)) + adjustment
    retained_counts = [int(np.count_nonzero(keep & (segment == index))) for index in range(4)]
    step_lengths = np.asarray(optimized["step_length_history_m"], dtype=float)
    route = np.asarray(spec.route_xy_m, dtype=float)
    track = [route[0].copy()]
    offset = 0
    for index, count in enumerate(retained_counts):
        direction = np.asarray([math.cos(adjusted_headings[index]), math.sin(adjusted_headings[index])])
        for step_length in step_lengths[offset : offset + count]:
            track.append(track[-1] + float(step_length) * direction)
        offset += count

    shadow["pdr_track"] = np.asarray(track, dtype=float).tolist()
    shadow["segment_headings_deg"] = np.degrees(adjusted_headings).tolist()
    shadow["direction_free_status_by_segment"] = statuses
    shadow["direction_free_yaw_delta_deg_by_segment"] = consensus_delta_deg
    shadow["direction_free_template_spread_deg_by_segment"] = consensus_spread_deg
    shadow["direction_free_confidence_by_segment"] = consensus_confidence
    shadow["direction_free_template_evidence"] = template_evidence
    shadow["direction_free_global_adjustment_deg"] = float(math.degrees(adjustment))
    shadow["direction_free_global_gain"] = global_gain
    shadow["direction_free_matched_segments"] = int(sum(status == "accepted" for status in statuses))
    shadow["direction_free_map_keys"] = [calibration["source_key"] for calibration in map_calibrations]
    shadow["direction_free_route_direction_gate_used"] = False
    shadow["direction_free_initial_frame_registered"] = bool(register_initial_frame)
    shadow["direction_free_shadow_mode"] = True
    return shadow


def _magnetic_route_profile(
    prepared_dir: Path,
    spec: CaptureSpec,
    result: dict,
    samples: int = 500,
) -> np.ndarray:
    _, rows = _read_csv(prepared_dir / "Magnetometer.csv")
    values = np.asarray([[float(value) for value in row[:4]] for row in rows], dtype=float)
    times = values[:, 0]
    norms = np.linalg.norm(values[:, 1:4], axis=1)
    step_times = np.asarray(
        result.get(
            "capture_step_sensor_time_history_s",
            result["step_sensor_time_history_s"],
        ),
        dtype=float,
    )
    turns = result["detected_turns"][: len(spec.route_xy_m) - 1]
    if step_times.size < 2 or len(turns) < len(spec.route_xy_m) - 1:
        target = np.linspace(times[0], times[-1], samples)
        return np.interp(target, times, norms)

    median_step_interval = float(np.median(np.diff(step_times)))
    start_time = max(float(times[0]), float(step_times[0] - 0.5 * median_step_interval))
    turn_times = [
        float(step_times[min(int(turn["turn_start_step_index"]), step_times.size - 1)]) for turn in turns
    ]
    route = np.asarray(spec.route_xy_m, dtype=float)
    cumulative = np.concatenate(([0.0], np.cumsum(np.linalg.norm(np.diff(route, axis=0), axis=1))))
    route_progress_knots = cumulative / cumulative[-1]
    time_knots = np.asarray([start_time, *turn_times], dtype=float)
    time_knots = np.maximum.accumulate(time_knots)
    valid = (times >= time_knots[0]) & (times <= time_knots[-1])
    observation_progress = np.interp(times[valid], time_knots, route_progress_knots)
    target_progress = np.linspace(0.0, 1.0, samples)
    return np.interp(target_progress, observation_progress, norms[valid])


def _magnetic_repeatability(
    prepared_root: Path,
    baseline_results: dict[str, dict],
) -> list[dict]:
    output = []
    for group in ("route_13", "route_14", "route_15"):
        keys = [spec.key for spec in CAPTURES if spec.route_group == group]
        for left_index, left in enumerate(keys):
            for right in keys[left_index + 1 :]:
                left_spec = next(spec for spec in CAPTURES if spec.key == left)
                right_spec = next(spec for spec in CAPTURES if spec.key == right)
                a = _magnetic_route_profile(
                    prepared_root / left,
                    left_spec,
                    baseline_results[left],
                )
                b = _magnetic_route_profile(
                    prepared_root / right,
                    right_spec,
                    baseline_results[right],
                )
                output.append(
                    {
                        "route_group": group,
                        "left": left,
                        "right": right,
                        "correlation": float(np.corrcoef(a, b)[0, 1]),
                        "rmse_ut": float(np.sqrt(np.mean((a - b) ** 2))),
                    }
                )
    return output


def _plot_tracks(
    specs,
    metrics_by_key: dict[str, dict],
    output_path: Path,
    *,
    title_suffix="route-calibrated PDR",
) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.3), constrained_layout=True)
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        group_specs = [spec for spec in specs if spec.route_group == group]
        route = np.asarray(group_specs[0].route_xy_m, dtype=float)
        axis.plot(route[:, 0], route[:, 1], "w--", linewidth=2.5, label="Confirmed route")
        for spec in group_specs:
            track = np.asarray(metrics_by_key[spec.key]["track"], dtype=float)
            axis.plot(track[:, 0], track[:, 1], linewidth=1.8, label=spec.key)
        axis.scatter(route[0, 0], route[0, 1], s=55, color="lime", edgecolor="black", zorder=5)
        axis.set_title(f"{group}: {title_suffix}")
        axis.set_aspect("equal", adjustable="box")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=8)
        axis.set_xlabel("X (m)")
        axis.set_ylabel("Y (m)")
    figure.patch.set_facecolor("#17202a")
    for axis in axes:
        axis.set_facecolor("#17202a")
        axis.tick_params(colors="white")
        axis.xaxis.label.set_color("white")
        axis.yaxis.label.set_color("white")
        axis.title.set_color("white")
        for spine in axis.spines.values():
            spine.set_color("#aaaaaa")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output_path, dpi=180, facecolor=figure.get_facecolor())
    plt.close(figure)


def _plot_magnetic_progress_diagnostics(
    metrics_by_key: dict[str, dict],
    output_path: Path,
) -> None:
    keys = [spec.key for spec in CAPTURES if spec.key in VALIDATION_KEYS]
    confidence = np.asarray(
        [metrics_by_key[key]["magnetic_progress_confidence_by_segment"] for key in keys],
        dtype=float,
    )
    gain = np.asarray(
        [metrics_by_key[key]["magnetic_progress_gain_by_segment"] for key in keys],
        dtype=float,
    )
    figure, axes = plt.subplots(1, 2, figsize=(11.5, 4.6), constrained_layout=True)
    for axis, values, title, maximum in (
        (axes[0], confidence, "Magnetic match confidence", 1.0),
        (axes[1], gain, "Applied progress gain", 0.30),
    ):
        image = axis.imshow(values, cmap="viridis", vmin=0.0, vmax=maximum)
        axis.set_xticks(range(4), ["leg 1", "leg 2", "leg 3", "leg 4"])
        axis.set_yticks(range(len(keys)), keys)
        axis.set_title(title)
        for row in range(values.shape[0]):
            for column in range(values.shape[1]):
                axis.text(
                    column,
                    row,
                    f"{values[row, column]:.2f}",
                    ha="center",
                    va="center",
                    color="white" if values[row, column] < 0.55 * maximum else "black",
                    fontsize=8,
                )
        figure.colorbar(image, ax=axis, fraction=0.046, pad=0.04)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output_path, dpi=180)
    plt.close(figure)


def _plot_magnetic_heading_diagnostics(
    metrics_by_key: dict[str, dict],
    output_path: Path,
) -> None:
    keys = [spec.key for spec in CAPTURES if spec.key in VALIDATION_KEYS]
    confidence = np.asarray(
        [metrics_by_key[key]["magnetic_heading_confidence_by_segment"] for key in keys],
        dtype=float,
    )
    adjustment = np.asarray(
        [metrics_by_key[key]["magnetic_heading_global_adjustment_deg"] for key in keys],
        dtype=float,
    )
    figure, axes = plt.subplots(1, 2, figsize=(11.5, 4.6), constrained_layout=True)
    image = axes[0].imshow(confidence, cmap="viridis", vmin=0.0, vmax=1.0)
    axes[0].set_xticks(range(4), ["leg 1", "leg 2", "leg 3", "leg 4"])
    axes[0].set_yticks(range(len(keys)), keys)
    axes[0].set_title("Accepted magnetic yaw confidence")
    for row in range(confidence.shape[0]):
        for column in range(confidence.shape[1]):
            axes[0].text(
                column,
                row,
                f"{confidence[row, column]:.2f}",
                ha="center",
                va="center",
                color="white" if confidence[row, column] < 0.55 else "black",
                fontsize=8,
            )
    figure.colorbar(image, ax=axes[0], fraction=0.046, pad=0.04)
    colors = ["tab:blue" if value <= 0.0 else "tab:orange" for value in adjustment]
    axes[1].barh(keys, adjustment, color=colors)
    axes[1].axvline(0.0, color="black", linewidth=1.0)
    axes[1].set_title("Applied run-level yaw correction")
    axes[1].set_xlabel("Degrees")
    axes[1].set_xlim(
        min(float(np.min(adjustment)) - 0.12, -0.12),
        max(float(np.max(adjustment)) + 0.12, 0.12),
    )
    for row, value in enumerate(adjustment):
        if value < -1e-9:
            text_x, alignment, color = value + 0.03, "left", "white"
        elif value > 1e-9:
            text_x, alignment, color = value - 0.03, "right", "white"
        else:
            text_x, alignment, color = 0.02, "left", "black"
        axes[1].text(
            text_x,
            row,
            f"{value:.2f}°",
            ha=alignment,
            va="center",
            color=color,
            fontsize=9,
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output_path, dpi=180)
    plt.close(figure)


def _write_report(payload: dict, output_path: Path) -> None:
    release = payload["algorithm_release"]
    lines = [
        "# iPhone 闭合路线算法验证",
        "",
        "> route_13 为 1.8 m × 1.8 m，route_14 为 6.0 m × 0.6 m，route_15 为 12.0 m × 0.6 m；三条受控路线均已由采集者确认。",
        "",
        "## 算法封版状态",
        "",
        f"- 发布标识：`{release['release_id']}`；状态：`{release['status']}`。",
        f"- 当前推荐：`{release['recommended']['profile']}`，仅限受控闭合路线；"
        f"留出横向/闭合误差为 {release['recommended']['validation_cross_track_mean_m']:.3f} / "
        f"{release['recommended']['validation_closure_mean_m']:.3f} m。",
        f"- 无方向版本：`{release['direction_free_shadow']['deployment_status']}`，仍为 shadow，不进入正式结果。",
        f"- 自由路径：`{release['free_path_status']}`；旧磁图 PF：`{release['legacy_pf_status']}`。",
        "",
        "- 每条路线仅用第一次选定采集标定步长：route_13_1、route_14_2、route_15_1。",
        "- 留出验证：route_13_2、route_13_3、route_14_3、route_15_2、route_15_3。",
        "- 分路线步长比例："
        + "、".join(f"{key}=`{value:.4f}`" for key, value in payload["step_length_scales"].items()),
        "- 航向：使用 iPhone Core Motion 相对航向；90° 吸附仅作消融对照。",
        "- 优化：传感器识别的转弯区零平移；航向先验最低 10%，再根据圆方差、方向偏差和转角完整度逐段增强。",
        "- 距离：按四个直行段独立标定；先验最低 10%，再根据步数比例、单步波动和段长冲突逐段自适应增强。",
        "- 地磁进度：仅使用每条路线的独立标定采集建立模长模板；端点约束 DTW 只允许在直线段内部最多融合 30%，少于 5 个步峰、磁变化不足或相关性低的段自动拒绝。",
        "- 地磁航向：用四元数对齐后的磁向量估计整次采集的统一 yaw 偏置；只有磁进度已通过、旋转方向与 PDR 残差一致且拟合残差合格的长边参与，最大融合 35%。",
        "- 无方向 shadow：查询不读取路线方向，必须由两个独立磁模板在 4° 内达成 yaw 一致；若留出总体误差退化则自动标记为不部署。",
        "- 地磁 PF：未计入精度结论，因为新采集位置尚未与旧磁图完成空间注册。",
        "",
        "| 数据 | 角色 | 转弯分割 | 转弯平移步已移除 | 基线闭合→优化 | 基线横向→优化 | 优化四段估距 |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    optimized_by_key = {item["key"]: item for item in payload["optimized_runs"]}
    magnetic_fused_by_key = {item["key"]: item for item in payload["magnetic_fused_runs"]}
    magnetic_heading_by_key = {item["key"]: item for item in payload["magnetic_heading_runs"]}
    direction_free_by_key = {item["key"]: item for item in payload["direction_free_shadow_runs"]}
    registered_direction_free_by_key = {
        item["key"]: item for item in payload["registered_direction_free_shadow_runs"]
    }
    for item in payload["runs"]:
        optimized = optimized_by_key[item["key"]]
        role = (
            "标定"
            if item["key"] in CALIBRATION_KEYS
            else "验证"
            if item["key"] in VALIDATION_KEYS
            else "暂定诊断"
        )
        lines.append(
            f"| {item['key']} | {role} | "
            f"{optimized['turn_partition_method']} | "
            f"{optimized['turn_translation_steps_removed']} | "
            f"{item['closure_error_m']:.2f}→{optimized['closure_error_m']:.2f} m | "
            f"{item['cross_track_error_mean_m']:.2f}→{optimized['cross_track_error_mean_m']:.2f} m | "
            f"{'/'.join(f'{value:.2f}' for value in optimized['estimated_segment_lengths_m'])} m |"
        )
    lines.extend(
        [
            "",
            "## 地磁重复性（按转弯点对齐路线进度）",
            "",
            "| 路线 | 两次采集 | 相关系数 | RMSE |",
            "|---|---|---:|---:|",
        ]
    )
    for item in payload["magnetic_repeatability"]:
        lines.append(
            f"| {item['route_group']} | {item['left']} / {item['right']} | "
            f"{item['correlation']:.3f} | {item['rmse_ut']:.2f} µT |"
        )
    lines.extend(
        [
            "",
            "## 留出采集的分段磁进度门控",
            "",
            "| 数据 | 接受段 | 四段状态 | 接受段平均相关 | 接受段平均增益 | 平均实际进度修正 |",
            "|---|---:|---|---:|---:|---:|",
        ]
    )
    for key in sorted(VALIDATION_KEYS):
        item = magnetic_fused_by_key[key]
        accepted_indices = [
            index
            for index, status in enumerate(item["magnetic_progress_status_by_segment"])
            if status == "accepted"
        ]
        mean_correlation = (
            float(
                np.mean(
                    [item["magnetic_progress_correlation_by_segment"][index] for index in accepted_indices]
                )
            )
            if accepted_indices
            else 0.0
        )
        mean_gain = (
            float(np.mean([item["magnetic_progress_gain_by_segment"][index] for index in accepted_indices]))
            if accepted_indices
            else 0.0
        )
        mean_shift = float(np.mean(item["magnetic_progress_shift_mean_by_segment"]))
        status_text = "/".join(
            "接受" if status == "accepted" else "拒绝"
            for status in item["magnetic_progress_status_by_segment"]
        )
        lines.append(
            f"| {key} | {len(accepted_indices)}/4 | {status_text} | "
            f"{mean_correlation:.3f} | {mean_gain:.3f} | {mean_shift:.4f} |"
        )
    lines.extend(
        [
            "",
            "## 留出采集的磁航向门控",
            "",
            "| 数据 | 参与长边 | 四段状态 | 全局航向修正 | 横向误差（进度→航向） | 闭合误差（进度→航向） |",
            "|---|---:|---|---:|---:|---:|",
        ]
    )
    for key in sorted(VALIDATION_KEYS):
        progress_item = magnetic_fused_by_key[key]
        heading_item = magnetic_heading_by_key[key]
        status_text = "/".join(
            "接受" if status == "accepted" else "拒绝"
            for status in heading_item["magnetic_heading_status_by_segment"]
        )
        lines.append(
            f"| {key} | {heading_item['magnetic_heading_matched_segments']}/4 | "
            f"{status_text} | "
            f"{heading_item['magnetic_heading_global_adjustment_deg']:.2f}° | "
            f"{progress_item['cross_track_error_mean_m']:.3f}→"
            f"{heading_item['cross_track_error_mean_m']:.3f} m | "
            f"{progress_item['closure_error_m']:.3f}→"
            f"{heading_item['closure_error_m']:.3f} m |"
        )
    lines.extend(
        [
            "",
            "## 双模板无方向航向 shadow 消融",
            "",
            "| 数据 | 两个磁模板 | 未注册修正/误差 | 起始注册修正/误差 |",
            "|---|---|---:|---:|",
        ]
    )
    for key in sorted(VALIDATION_KEYS):
        item = direction_free_by_key[key]
        registered = registered_direction_free_by_key[key]
        lines.append(
            f"| {key} | {' / '.join(item['direction_free_map_keys'])} | "
            f"{item['direction_free_global_adjustment_deg']:.2f}° / "
            f"{item['cross_track_error_mean_m']:.3f} m | "
            f"{registered['direction_free_global_adjustment_deg']:.2f}° / "
            f"{registered['cross_track_error_mean_m']:.3f} m |"
        )
    snap = payload["route_14_2_snap_ablation"]
    lines.extend(
        [
            "",
            "## 90° 航向吸附消融",
            "",
            f"route_14_2 在未吸附时检测到 {snap['unsnapped_turns']} 个转弯；"
            f"启用 90° 吸附时检测到 {snap['snapped_turns']} 个。",
            "",
            "## 结论边界",
            "",
            "严格只看 5 次留出采集：平均横向误差由 "
            f"{payload['comparison_summary']['validation_baseline_cross_track_mean_m']:.3f} m，"
            f"经仅去除转弯平移后为 {payload['comparison_summary']['validation_turn_filtered_cross_track_mean_m']:.3f} m，"
            f"受控 90° 软先验优化后为 {payload['comparison_summary']['validation_optimized_cross_track_mean_m']:.3f} m；"
            "平均闭合误差依次为 "
            f"{payload['comparison_summary']['validation_baseline_closure_mean_m']:.3f} / "
            f"{payload['comparison_summary']['validation_turn_filtered_closure_mean_m']:.3f} / "
            f"{payload['comparison_summary']['validation_optimized_closure_mean_m']:.3f} m。",
            f"五次留出采集的逐段有效距离先验平均为 "
            f"{payload['comparison_summary']['validation_effective_distance_prior_mean']:.3f}，"
            "不再对所有路段固定施加 40% 先验。",
            f"逐段有效航向先验平均为 "
            f"{payload['comparison_summary']['validation_effective_heading_prior_mean']:.3f}，"
            "不再固定向 90° 方向融合 50%。",
            f"独立磁模板在 20 个留出直线段中接受了 "
            f"{payload['comparison_summary']['validation_magnetic_matched_segments']} 段；"
            "融合后平均横向/闭合误差为 "
            f"{payload['comparison_summary']['validation_magnetic_fused_cross_track_mean_m']:.3f} / "
            f"{payload['comparison_summary']['validation_magnetic_fused_closure_mean_m']:.3f} m。"
            "闭合误差保持不变是设计约束：本阶段只调整段内进度，不改变段长、航向或端点。",
            f"进一步的统一磁航向偏置在 20 个留出直线段中接受了 "
            f"{payload['comparison_summary']['validation_magnetic_heading_matched_segments']} 段；"
            "平均横向误差继续降为 "
            f"{payload['comparison_summary']['validation_magnetic_heading_cross_track_mean_m']:.3f} m，"
            "平均闭合误差为 "
            f"{payload['comparison_summary']['validation_magnetic_heading_closure_mean_m']:.3f} m。"
            "统一旋转保持轨迹形状，因此不会通过逐段扭曲来换取闭合指标。",
            "无路线方向门控的双模板 shadow 在严格留出集上的平均横向误差为 "
            f"{payload['comparison_summary']['validation_direction_free_cross_track_mean_m']:.3f} m，"
            f"只有 {payload['comparison_summary']['validation_direction_free_improved_runs']}/5 次优于受控优化；"
            "部署判定为 `"
            f"{payload['comparison_summary']['direction_free_deployment_status']}`。"
            "这表明模板间一致只能证明偏置可重复，不能证明其已经注册到地图绝对方向。",
            "用起始 2.5 s 手机姿态注册参考系后，无方向 shadow 的平均横向误差为 "
            f"{payload['comparison_summary']['validation_registered_direction_free_cross_track_mean_m']:.3f} m，"
            "部署状态为 `"
            f"{payload['comparison_summary']['registered_direction_free_deployment_status']}`。"
            "它不读取路线方向，但仍只属于小样本 shadow 证据。",
            "",
            "当前结果证明长边磁序列可作为路线内进度证据，但短边仍因有效样本不足而被门控拒绝。"
            "这仍是一维同路线匹配，不是二维自由路径定位，也不能当作任意路线精度。",
        ]
    )
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def validate(
    source_root: Path,
    output_root: Path,
    trim_s: float | None = None,
) -> dict:
    prepared_root = output_root / "prepared"
    preprocessing = {}
    baseline_results = {}
    for spec in CAPTURES:
        source = source_root / f"{spec.key}.geomagcapture"
        destination = prepared_root / spec.key
        applied_trim = spec.stationary_trim_s if trim_s is None else float(trim_s)
        preprocessing[spec.key] = prepare_capture(source, destination, spec.route_xy_m, trim_s=applied_trim)
        baseline_results[spec.key] = _run_motion_pipeline(spec, destination, snap_deg=0.0)

    map_only_preprocessing = {}
    map_only_results = {}
    for spec in MAGNETIC_MAP_ONLY_CAPTURES:
        source = source_root / f"{spec.key}.geomagcapture"
        destination = prepared_root / spec.key
        applied_trim = spec.stationary_trim_s if trim_s is None else float(trim_s)
        map_only_preprocessing[spec.key] = prepare_capture(
            source, destination, spec.route_xy_m, trim_s=applied_trim
        )
        map_only_results[spec.key] = _run_motion_pipeline(spec, destination, snap_deg=0.0)

    step_scales = {}
    for group in ("route_13", "route_14", "route_15"):
        calibration_spec = next(
            spec for spec in CAPTURES if spec.route_group == group and spec.key in CALIBRATION_KEYS
        )
        calibration_distance = float(np.sum(baseline_results[calibration_spec.key]["step_length_history_m"]))
        step_scales[group] = calibration_spec.route_length_m / calibration_distance

    metrics_by_key = {
        spec.key: _motion_metrics(
            spec,
            baseline_results[spec.key],
            step_scales[spec.route_group],
        )
        for spec in CAPTURES
    }
    segment_calibration = {}
    magnetic_segment_calibration = {}
    for group in ("route_13", "route_14", "route_15"):
        calibration_spec = next(
            spec for spec in CAPTURES if spec.route_group == group and spec.key in CALIBRATION_KEYS
        )
        segment_calibration[group] = _build_segment_calibration(
            calibration_spec, baseline_results[calibration_spec.key]
        )
        magnetic_segment_calibration[group] = _build_magnetic_segment_calibration(
            prepared_root / calibration_spec.key,
            baseline_results[calibration_spec.key],
            source_key=calibration_spec.key,
        )
    optimized_results = {
        spec.key: _optimized_motion_result(
            spec,
            baseline_results[spec.key],
            segment_calibration[spec.route_group],
        )
        for spec in CAPTURES
    }
    magnetic_fused_results = {
        spec.key: _magnetic_progress_result(
            spec,
            baseline_results[spec.key],
            optimized_results[spec.key],
            prepared_root / spec.key,
            magnetic_segment_calibration[spec.route_group],
        )
        for spec in CAPTURES
    }
    magnetic_heading_results = {
        spec.key: _magnetic_heading_result(
            spec,
            baseline_results[spec.key],
            magnetic_fused_results[spec.key],
            prepared_root / spec.key,
            magnetic_segment_calibration[spec.route_group],
        )
        for spec in CAPTURES
    }
    magnetic_calibration_by_key = {
        spec.key: _build_magnetic_segment_calibration(
            prepared_root / spec.key,
            (baseline_results[spec.key] if spec.key in baseline_results else map_only_results[spec.key]),
            source_key=spec.key,
        )
        for spec in (*CAPTURES, *MAGNETIC_MAP_ONLY_CAPTURES)
    }
    initial_reference_by_key = {
        spec.key: _initial_reference_frame(source_root / f"{spec.key}.geomagcapture")
        for spec in (*CAPTURES, *MAGNETIC_MAP_ONLY_CAPTURES)
    }
    for key, calibration in magnetic_calibration_by_key.items():
        calibration["initial_reference"] = initial_reference_by_key[key]
    direction_free_results = {}
    registered_direction_free_results = {}
    all_magnetic_specs = (*CAPTURES, *MAGNETIC_MAP_ONLY_CAPTURES)
    for spec in CAPTURES:
        map_keys = [
            candidate.key
            for candidate in all_magnetic_specs
            if candidate.route_group == spec.route_group and candidate.key != spec.key
        ]
        direction_free_results[spec.key] = _direction_free_multi_template_result(
            spec,
            baseline_results[spec.key],
            optimized_results[spec.key],
            prepared_root / spec.key,
            [magnetic_calibration_by_key[key] for key in map_keys],
        )
        registered_direction_free_results[spec.key] = _direction_free_multi_template_result(
            spec,
            baseline_results[spec.key],
            optimized_results[spec.key],
            prepared_root / spec.key,
            [magnetic_calibration_by_key[key] for key in map_keys],
            query_initial_reference=initial_reference_by_key[spec.key],
            register_initial_frame=True,
        )
    turn_filtered_results = {
        spec.key: _optimized_motion_result(
            spec,
            baseline_results[spec.key],
            segment_calibration[spec.route_group],
            distance_prior_floor=0.0,
            heading_prior_floor=0.0,
        )
        for spec in CAPTURES
    }
    optimized_metrics_by_key = {
        spec.key: _motion_metrics(spec, optimized_results[spec.key], 1.0) for spec in CAPTURES
    }
    magnetic_fused_metrics_by_key = {
        spec.key: _motion_metrics(spec, magnetic_fused_results[spec.key], 1.0) for spec in CAPTURES
    }
    magnetic_heading_metrics_by_key = {
        spec.key: _motion_metrics(spec, magnetic_heading_results[spec.key], 1.0) for spec in CAPTURES
    }
    direction_free_metrics_by_key = {
        spec.key: _motion_metrics(spec, direction_free_results[spec.key], 1.0) for spec in CAPTURES
    }
    registered_direction_free_metrics_by_key = {
        spec.key: _motion_metrics(spec, registered_direction_free_results[spec.key], 1.0) for spec in CAPTURES
    }
    turn_filtered_metrics_by_key = {
        spec.key: _motion_metrics(spec, turn_filtered_results[spec.key], 1.0) for spec in CAPTURES
    }
    baseline_metrics = list(metrics_by_key.values())
    optimized_metrics = list(optimized_metrics_by_key.values())
    comparison_summary = {
        "baseline_cross_track_mean_m": float(
            np.mean([item["cross_track_error_mean_m"] for item in baseline_metrics])
        ),
        "optimized_cross_track_mean_m": float(
            np.mean([item["cross_track_error_mean_m"] for item in optimized_metrics])
        ),
        "baseline_closure_mean_m": float(np.mean([item["closure_error_m"] for item in baseline_metrics])),
        "optimized_closure_mean_m": float(np.mean([item["closure_error_m"] for item in optimized_metrics])),
        "cross_track_improved_runs": int(
            sum(
                optimized_metrics_by_key[key]["cross_track_error_mean_m"]
                < metrics_by_key[key]["cross_track_error_mean_m"]
                for key in metrics_by_key
            )
        ),
        "closure_improved_runs": int(
            sum(
                optimized_metrics_by_key[key]["closure_error_m"] < metrics_by_key[key]["closure_error_m"]
                for key in metrics_by_key
            )
        ),
    }
    validation_keys = set(VALIDATION_KEYS)
    comparison_summary.update(
        {
            "validation_baseline_cross_track_mean_m": float(
                np.mean([metrics_by_key[key]["cross_track_error_mean_m"] for key in validation_keys])
            ),
            "validation_turn_filtered_cross_track_mean_m": float(
                np.mean(
                    [turn_filtered_metrics_by_key[key]["cross_track_error_mean_m"] for key in validation_keys]
                )
            ),
            "validation_optimized_cross_track_mean_m": float(
                np.mean(
                    [optimized_metrics_by_key[key]["cross_track_error_mean_m"] for key in validation_keys]
                )
            ),
            "validation_baseline_closure_mean_m": float(
                np.mean([metrics_by_key[key]["closure_error_m"] for key in validation_keys])
            ),
            "validation_turn_filtered_closure_mean_m": float(
                np.mean([turn_filtered_metrics_by_key[key]["closure_error_m"] for key in validation_keys])
            ),
            "validation_optimized_closure_mean_m": float(
                np.mean([optimized_metrics_by_key[key]["closure_error_m"] for key in validation_keys])
            ),
            "validation_magnetic_fused_cross_track_mean_m": float(
                np.mean(
                    [
                        magnetic_fused_metrics_by_key[key]["cross_track_error_mean_m"]
                        for key in validation_keys
                    ]
                )
            ),
            "validation_magnetic_fused_closure_mean_m": float(
                np.mean([magnetic_fused_metrics_by_key[key]["closure_error_m"] for key in validation_keys])
            ),
            "validation_magnetic_matched_segments": int(
                sum(
                    magnetic_fused_metrics_by_key[key]["magnetic_matched_segments"] for key in validation_keys
                )
            ),
            "validation_magnetic_heading_cross_track_mean_m": float(
                np.mean(
                    [
                        magnetic_heading_metrics_by_key[key]["cross_track_error_mean_m"]
                        for key in validation_keys
                    ]
                )
            ),
            "validation_magnetic_heading_closure_mean_m": float(
                np.mean([magnetic_heading_metrics_by_key[key]["closure_error_m"] for key in validation_keys])
            ),
            "validation_magnetic_heading_matched_segments": int(
                sum(
                    magnetic_heading_metrics_by_key[key]["magnetic_heading_matched_segments"]
                    for key in validation_keys
                )
            ),
            "validation_direction_free_cross_track_mean_m": float(
                np.mean(
                    [
                        direction_free_metrics_by_key[key]["cross_track_error_mean_m"]
                        for key in validation_keys
                    ]
                )
            ),
            "validation_direction_free_closure_mean_m": float(
                np.mean([direction_free_metrics_by_key[key]["closure_error_m"] for key in validation_keys])
            ),
            "validation_direction_free_matched_segments": int(
                sum(
                    direction_free_metrics_by_key[key]["direction_free_matched_segments"]
                    for key in validation_keys
                )
            ),
            "validation_direction_free_improved_runs": int(
                sum(
                    direction_free_metrics_by_key[key]["cross_track_error_mean_m"]
                    < optimized_metrics_by_key[key]["cross_track_error_mean_m"]
                    for key in validation_keys
                )
            ),
            "validation_registered_direction_free_cross_track_mean_m": float(
                np.mean(
                    [
                        registered_direction_free_metrics_by_key[key]["cross_track_error_mean_m"]
                        for key in validation_keys
                    ]
                )
            ),
            "validation_registered_direction_free_closure_mean_m": float(
                np.mean(
                    [
                        registered_direction_free_metrics_by_key[key]["closure_error_m"]
                        for key in validation_keys
                    ]
                )
            ),
            "validation_registered_direction_free_matched_segments": int(
                sum(
                    registered_direction_free_metrics_by_key[key]["direction_free_matched_segments"]
                    for key in validation_keys
                )
            ),
            "validation_registered_direction_free_improved_runs": int(
                sum(
                    registered_direction_free_metrics_by_key[key]["cross_track_error_mean_m"]
                    < optimized_metrics_by_key[key]["cross_track_error_mean_m"]
                    for key in validation_keys
                )
            ),
        }
    )
    direction_free_regressed = (
        comparison_summary["validation_direction_free_cross_track_mean_m"]
        > comparison_summary["validation_optimized_cross_track_mean_m"] + 1e-9
    )
    comparison_summary["direction_free_deployment_status"] = (
        "rejected_shadow_regression" if direction_free_regressed else "eligible_after_more_validation"
    )
    registered_direction_free_regressed = (
        comparison_summary["validation_registered_direction_free_cross_track_mean_m"]
        > comparison_summary["validation_optimized_cross_track_mean_m"] + 1e-9
    )
    comparison_summary["registered_direction_free_deployment_status"] = (
        "rejected_shadow_regression"
        if registered_direction_free_regressed
        else "promising_shadow_requires_more_routes"
    )
    comparison_summary["validation_effective_distance_prior_mean"] = float(
        np.mean(
            [
                prior
                for key in validation_keys
                for prior in optimized_metrics_by_key[key]["effective_distance_prior_by_segment"]
            ]
        )
    )
    comparison_summary["validation_effective_heading_prior_mean"] = float(
        np.mean(
            [
                prior
                for key in validation_keys
                for prior in optimized_metrics_by_key[key]["effective_heading_prior_by_segment"]
            ]
        )
    )
    snapped = _run_motion_pipeline(
        next(spec for spec in CAPTURES if spec.key == "route_14_2"),
        prepared_root / "route_14_2",
        snap_deg=90.0,
    )
    repeatability = _magnetic_repeatability(prepared_root, baseline_results)
    controlled_route_optimization = {
        "turn_translation": "zero",
        "distance_prior_floor": 0.10,
        "distance_conflict_scale": 0.35,
        "step_variability_scale": 0.50,
        "heading_prior_floor": 0.10,
        "heading_disagreement_scale_deg": 10.0,
        "heading_dispersion_scale_deg": 8.0,
        "turn_angle_error_scale_deg": 20.0,
        "magnetic_progress_max_gain": 0.30,
        "magnetic_progress_min_samples": 5,
        "magnetic_progress_min_span_ut": 1.0,
        "magnetic_progress_min_correlation": 0.75,
        "magnetic_heading_max_gain": 0.35,
        "magnetic_heading_fit_residual_limit": 0.20,
        "magnetic_heading_agreement_scale_deg": 10.0,
        "magnetic_heading_minimum_pdr_residual_deg": 1.0,
        "direction_free_shadow_max_gain": 0.35,
        "direction_free_template_consensus_limit_deg": 4.0,
        "direction_free_fit_residual_limit": 0.20,
        "direction_free_route_direction_gate_used": False,
        "direction_free_initial_reference_duration_s": 2.5,
        "direction_free_initial_rotation_median_limit_rad_s": 0.25,
        "direction_free_initial_acceleration_median_limit_mps2": 0.60,
        "direction_free_initial_magnetic_calibrated_ratio_min": 0.80,
    }
    algorithm_release = _algorithm_release_manifest(
        comparison_summary,
        controlled_route_optimization,
    )
    payload = {
        "algorithm_release": algorithm_release,
        "geometry_status": {
            "route_13": "operator_confirmed_closed_route",
            "route_14": "operator_confirmed_closed_route",
            "route_15": "recorded_closed_route",
        },
        "step_length_scales": {key: float(value) for key, value in step_scales.items()},
        "calibration_keys": sorted(CALIBRATION_KEYS),
        "validation_keys": sorted(VALIDATION_KEYS),
        "preprocessing": preprocessing,
        "map_only_preprocessing": map_only_preprocessing,
        "runs": [
            {"key": spec.key, "route_group": spec.route_group, **metrics_by_key[spec.key]}
            for spec in CAPTURES
        ],
        "optimized_runs": [
            {
                "key": spec.key,
                "route_group": spec.route_group,
                **optimized_metrics_by_key[spec.key],
            }
            for spec in CAPTURES
        ],
        "magnetic_fused_runs": [
            {
                "key": spec.key,
                "route_group": spec.route_group,
                **magnetic_fused_metrics_by_key[spec.key],
            }
            for spec in CAPTURES
        ],
        "magnetic_heading_runs": [
            {
                "key": spec.key,
                "route_group": spec.route_group,
                **magnetic_heading_metrics_by_key[spec.key],
            }
            for spec in CAPTURES
        ],
        "direction_free_shadow_runs": [
            {
                "key": spec.key,
                "route_group": spec.route_group,
                **direction_free_metrics_by_key[spec.key],
            }
            for spec in CAPTURES
        ],
        "registered_direction_free_shadow_runs": [
            {
                "key": spec.key,
                "route_group": spec.route_group,
                **registered_direction_free_metrics_by_key[spec.key],
            }
            for spec in CAPTURES
        ],
        "turn_filtered_runs": [
            {
                "key": spec.key,
                "route_group": spec.route_group,
                **turn_filtered_metrics_by_key[spec.key],
            }
            for spec in CAPTURES
        ],
        "segment_calibration": {
            group: {
                "source_key": value["source_key"],
                "reference_lengths_m": value["reference_lengths_m"].tolist(),
                "step_scale_by_segment": value["step_scale_by_segment"].tolist(),
                "step_counts": value["step_counts"].astype(int).tolist(),
                "turn_partition_method": value["turn_partition_method"],
            }
            for group, value in segment_calibration.items()
        },
        "magnetic_segment_calibration": {
            group: {
                "source_key": value["source_key"],
                "turn_partition_method": value["turn_partition_method"],
                "step_counts": [int(segment["step_count"]) for segment in value["segments"]],
                "magnetic_span_ut": [
                    float(np.ptp(segment["magnetic_norm_ut"])) for segment in value["segments"]
                ],
            }
            for group, value in magnetic_segment_calibration.items()
        },
        "magnetic_map_only_audit": {
            spec.key: {
                "geometry_status": spec.geometry_status,
                "detected_step_turns": int(len(map_only_results[spec.key]["detected_turns"])),
                "sample_level_turns": int(len(map_only_results[spec.key]["sample_level_turn_regions"])),
                "segment_step_counts": [
                    int(
                        np.count_nonzero(
                            _straight_step_partition(map_only_results[spec.key])[2]
                            & (_straight_step_partition(map_only_results[spec.key])[3] == index)
                        )
                    )
                    for index in range(4)
                ],
                "query_role": "excluded_map_only",
            }
            for spec in MAGNETIC_MAP_ONLY_CAPTURES
        },
        "initial_reference_quality": {
            key: {
                item_key: (
                    item_value.astype(float).tolist() if isinstance(item_value, np.ndarray) else item_value
                )
                for item_key, item_value in value.items()
            }
            for key, value in initial_reference_by_key.items()
        },
        "controlled_route_optimization": controlled_route_optimization,
        "comparison_summary": comparison_summary,
        "magnetic_repeatability": repeatability,
        "route_14_2_snap_ablation": {
            "unsnapped_turns": len(baseline_results["route_14_2"]["detected_turns"]),
            "snapped_turns": len(snapped["detected_turns"]),
        },
        "pf_evaluation_status": "excluded_unregistered_legacy_map",
    }
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (output_root / "algorithm_release.json").write_text(
        json.dumps(algorithm_release, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_report(payload, output_root / "report.md")
    _plot_tracks(CAPTURES, metrics_by_key, output_root / "pdr_tracks.png")
    _plot_tracks(
        CAPTURES,
        optimized_metrics_by_key,
        output_root / "pdr_tracks_optimized.png",
        title_suffix="optimized controlled PDR",
    )
    _plot_tracks(
        CAPTURES,
        magnetic_fused_metrics_by_key,
        output_root / "pdr_tracks_magnetic_fused.png",
        title_suffix="confidence-gated magnetic progress",
    )
    _plot_magnetic_progress_diagnostics(
        magnetic_fused_metrics_by_key,
        output_root / "magnetic_progress_diagnostics.png",
    )
    _plot_tracks(
        CAPTURES,
        magnetic_heading_metrics_by_key,
        output_root / "pdr_tracks_magnetic_heading_fused.png",
        title_suffix="gated magnetic yaw fusion",
    )
    _plot_magnetic_heading_diagnostics(
        magnetic_heading_metrics_by_key,
        output_root / "magnetic_heading_diagnostics.png",
    )
    _plot_tracks(
        CAPTURES,
        direction_free_metrics_by_key,
        output_root / "pdr_tracks_direction_free_shadow.png",
        title_suffix="direction-free magnetic shadow",
    )
    _plot_tracks(
        CAPTURES,
        registered_direction_free_metrics_by_key,
        output_root / "pdr_tracks_registered_direction_free_shadow.png",
        title_suffix="start-registered magnetic shadow",
    )
    _plot_tracks(
        CAPTURES,
        turn_filtered_metrics_by_key,
        output_root / "pdr_tracks_turn_filtered.png",
        title_suffix="turn-filtered PDR",
    )
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("/Users/xuminglei/dachuang/Geomag Capture"),
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("results/iphone_algorithm_validation"),
    )
    parser.add_argument(
        "--trim-s",
        type=float,
        default=None,
        help="Override each capture group's default stationary-tail trimming.",
    )
    args = parser.parse_args()
    result = validate(args.source_root, args.output_root, trim_s=args.trim_s)
    print(
        "step_length_scales="
        + ",".join(f"{key}:{value:.6f}" for key, value in result["step_length_scales"].items())
    )
    release = result["algorithm_release"]
    recommended = release["recommended"]
    shadow = release["direction_free_shadow"]
    print(f"algorithm_release={release['release_id']} status={release['status']}")
    print(
        f"recommended_profile={recommended['profile']} "
        f"scope={recommended['scope']} "
        f"cross_track_mean_m={recommended['validation_cross_track_mean_m']:.6f} "
        f"closure_mean_m={recommended['validation_closure_mean_m']:.6f}"
    )
    print(
        f"direction_free_shadow={shadow['profile']} "
        f"status={shadow['deployment_status']} "
        f"cross_track_mean_m={shadow['validation_cross_track_mean_m']:.6f}"
    )
    print(f"free_path_status={release['free_path_status']}")
    print(f"release_manifest={args.output_root / 'algorithm_release.json'}")
    print(f"report={args.output_root / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
