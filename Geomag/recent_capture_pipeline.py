"""Positioning pipeline built only for the recent iPhone captures.

The implementation intentionally does not read the historical own-data
registry or legacy magnetic map.  It combines:

* Core Motion yaw for relative heading;
* gravity-free vertical acceleration for periodic step detection;
* an explicit straight/turn state machine that gives turns zero translation;
* a route-topology-constrained online magnetic progress matcher.

The first selected capture of each route is used as its template/calibration
run.  Every reported validation metric comes from a different capture.
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

from Geomag.progress_matching import OnlineMagneticProgressMatcher


@dataclass(frozen=True)
class RecentRouteSpec:
    key: str
    route_group: str
    route_xy_m: tuple[tuple[float, float], ...]
    geometry_status: str

    @property
    def length_m(self) -> float:
        points = np.asarray(self.route_xy_m, dtype=float)
        return float(np.linalg.norm(np.diff(points, axis=0), axis=1).sum())


@dataclass(frozen=True)
class TurnEvent:
    index: int
    onset_time_s: float
    completion_time_s: float
    signed_angle_deg: float


@dataclass(frozen=True)
class StepEvent:
    time_s: float
    prominence_mps2: float
    heading_rad: float
    magnetic_vector_ut: tuple[float, float, float]
    segment_index: int


@dataclass
class CaptureStreams:
    time_s: np.ndarray
    yaw_unwrapped_rad: np.ndarray
    user_acceleration_mps2: np.ndarray
    rotation_rate_radps: np.ndarray
    magnetic_field_ut: np.ndarray


ROUTE_13 = ((0.0, 0.0), (0.0, 1.8), (1.8, 1.8), (1.8, 0.0), (0.0, 0.0))
ROUTE_14 = ((0.0, 0.0), (0.0, -6.0), (-0.6, -6.0), (-0.6, 0.0), (0.0, 0.0))
ROUTE_15 = ((0.0, 0.0), (-12.0, 0.0), (-12.0, 0.6), (0.0, 0.6), (0.0, 0.0))

RECENT_CAPTURES = (
    RecentRouteSpec("route_13_1", "route_13", ROUTE_13, "operator_confirmed"),
    RecentRouteSpec("route_13_2", "route_13", ROUTE_13, "operator_confirmed"),
    RecentRouteSpec("route_13_3", "route_13", ROUTE_13, "operator_confirmed"),
    RecentRouteSpec("route_14_2", "route_14", ROUTE_14, "operator_confirmed"),
    RecentRouteSpec("route_14_3", "route_14", ROUTE_14, "operator_confirmed"),
    RecentRouteSpec("route_15_1", "route_15", ROUTE_15, "recorded"),
    RecentRouteSpec("route_15_2", "route_15", ROUTE_15, "recorded"),
    RecentRouteSpec("route_15_3", "route_15", ROUTE_15, "recorded"),
)
CALIBRATION_BY_GROUP = {
    "route_13": "route_13_1",
    "route_14": "route_14_2",
    "route_15": "route_15_1",
}


def _normalized_header(name: str) -> str:
    return "".join(character.lower() for character in name if character.isalnum())


def _load_device_motion(path: Path) -> CaptureStreams:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"DeviceMotion CSV has no header: {path}")
        names = {_normalized_header(name): name for name in reader.fieldnames}

        def column(*candidates: str) -> str:
            for candidate in candidates:
                found = names.get(_normalized_header(candidate))
                if found is not None:
                    return found
            raise ValueError(f"DeviceMotion CSV lacks {candidates}: {path}")

        selected = {
            "time": column("Time (s)", "time"),
            "yaw": column("Yaw (rad)", "yaw"),
            "uax": column("User Acceleration X (m/s^2)"),
            "uay": column("User Acceleration Y (m/s^2)"),
            "uaz": column("User Acceleration Z (m/s^2)"),
            "rrx": column("Rotation Rate X (rad/s)"),
            "rry": column("Rotation Rate Y (rad/s)"),
            "rrz": column("Rotation Rate Z (rad/s)"),
            "mx": column("Magnetic Field X (µT)"),
            "my": column("Magnetic Field Y (µT)"),
            "mz": column("Magnetic Field Z (µT)"),
        }
        rows = []
        for row in reader:
            try:
                rows.append([float(row[selected[key]]) for key in selected])
            except (TypeError, ValueError):
                continue
    values = np.asarray(rows, dtype=float)
    if values.ndim != 2 or values.shape[0] < 100:
        raise ValueError(f"DeviceMotion CSV has too few numeric rows: {path}")
    order = np.argsort(values[:, 0])
    values = values[order]
    unique_time, unique_index = np.unique(values[:, 0], return_index=True)
    values = values[unique_index]
    return CaptureStreams(
        time_s=unique_time,
        yaw_unwrapped_rad=np.unwrap(values[:, 1]),
        user_acceleration_mps2=values[:, 2:5],
        rotation_rate_radps=values[:, 5:8],
        magnetic_field_ut=values[:, 8:11],
    )


def load_recent_capture(package_path: Path) -> CaptureStreams:
    package_path = Path(package_path)
    metadata_path = package_path / "capture_metadata.json"
    if not metadata_path.exists():
        raise FileNotFoundError(f"Recent capture metadata not found: {metadata_path}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if int(metadata.get("format_version", 0)) < 2:
        raise ValueError(
            f"Recent pipeline requires capture format 2: {package_path}"
        )
    if metadata.get("algorithm_magnetic_field_file") != "Magnetometer.csv":
        raise ValueError(
            f"Recent capture does not declare calibrated magnetic input: {package_path}"
        )
    return _load_device_motion(package_path / "DeviceMotion.csv")


def detect_quarter_turns(
    time_s: np.ndarray,
    yaw_unwrapped_rad: np.ndarray,
    *,
    turn_count: int = 4,
    departure_deg: float = 15.0,
    completion_tolerance_deg: float = 15.0,
) -> list[TurnEvent]:
    """Detect ordered quarter turns from cumulative Core Motion yaw."""
    time_s = np.asarray(time_s, dtype=float)
    yaw = np.asarray(yaw_unwrapped_rad, dtype=float)
    if time_s.size != yaw.size or time_s.size < 2:
        raise ValueError("time and yaw must contain at least two aligned samples.")
    relative_deg = np.degrees(yaw - yaw[0])
    direction = -1.0 if float(np.median(relative_deg[-max(10, yaw.size // 20) :])) < 0.0 else 1.0
    directed = direction * relative_deg
    events = []
    cursor = 0
    indices = np.arange(time_s.size)
    for turn_index in range(1, int(turn_count) + 1):
        previous_level = float((turn_index - 1) * 90.0)
        target_level = float(turn_index * 90.0)
        onset_candidates = np.flatnonzero(
            (indices >= cursor) & (directed >= previous_level + departure_deg)
        )
        if onset_candidates.size == 0:
            break
        onset = int(onset_candidates[0])
        completion_candidates = np.flatnonzero(
            (indices >= onset)
            & (directed >= target_level - completion_tolerance_deg)
        )
        if completion_candidates.size == 0:
            break
        completion = int(completion_candidates[0])
        signed_angle = float(relative_deg[completion] - relative_deg[onset])
        events.append(
            TurnEvent(
                index=turn_index,
                onset_time_s=float(time_s[onset]),
                completion_time_s=float(time_s[completion]),
                signed_angle_deg=signed_angle,
            )
        )
        cursor = completion + 1
    return events


def _moving_average(values: np.ndarray, samples: int) -> np.ndarray:
    values = np.asarray(values, dtype=float)
    width = max(1, int(samples))
    if width == 1:
        return values.copy()
    kernel = np.ones(width, dtype=float) / float(width)
    return np.convolve(values, kernel, mode="same")


def _peak_candidates(
    signal: np.ndarray,
    *,
    prominence: float,
    prominence_window_samples: int,
    min_distance_samples: int,
) -> list[tuple[int, float]]:
    signal = np.asarray(signal, dtype=float)
    radius = max(2, int(prominence_window_samples))
    candidates = []
    for index in range(1, signal.size - 1):
        if not (signal[index] > signal[index - 1] and signal[index] >= signal[index + 1]):
            continue
        left = signal[max(0, index - radius) : index + 1]
        right = signal[index : min(signal.size, index + radius + 1)]
        local_prominence = float(
            signal[index] - max(float(np.min(left)), float(np.min(right)))
        )
        if local_prominence >= float(prominence):
            candidates.append((index, local_prominence))

    accepted: list[tuple[int, float]] = []
    gap = max(1, int(min_distance_samples))
    for candidate in candidates:
        if not accepted or candidate[0] - accepted[-1][0] >= gap:
            accepted.append(candidate)
        elif candidate[1] > accepted[-1][1]:
            accepted[-1] = candidate
    return accepted


def _segment_for_time(time_s: float, turns: list[TurnEvent]) -> int:
    return min(sum(time_s >= event.completion_time_s for event in turns), 3)


def detect_recent_steps(
    streams: CaptureStreams,
    turns: list[TurnEvent],
    *,
    min_step_interval_s: float = 0.55,
    turn_padding_s: float = 0.10,
) -> tuple[list[StepEvent], dict]:
    """Detect periodic walking peaks from gravity-free vertical acceleration."""
    time_s = streams.time_s
    positive_dt = np.diff(time_s)
    positive_dt = positive_dt[positive_dt > 0.0]
    if positive_dt.size == 0:
        raise ValueError("DeviceMotion timestamps are not increasing.")
    sample_rate_hz = 1.0 / float(np.median(positive_dt))
    vertical = streams.user_acceleration_mps2[:, 2]
    detrended = vertical - _moving_average(vertical, round(0.8 * sample_rate_hz))
    filtered = _moving_average(detrended, round(0.06 * sample_rate_hz))
    endpoint_time = turns[3].onset_time_s if len(turns) >= 4 else float(time_s[-1])
    analysis_mask = time_s <= endpoint_time
    centered = filtered[analysis_mask] - float(np.median(filtered[analysis_mask]))
    robust_sigma = float(1.4826 * np.median(np.abs(centered)))
    minimum_prominence = max(0.18, 1.6 * robust_sigma)
    candidates = _peak_candidates(
        filtered,
        prominence=minimum_prominence,
        prominence_window_samples=round(0.35 * sample_rate_hz),
        min_distance_samples=round(min_step_interval_s * sample_rate_hz),
    )

    initial_yaw = float(streams.yaw_unwrapped_rad[0])
    steps = []
    turn_rejections = 0
    endpoint_rejections = 0
    for index, peak_prominence in candidates:
        event_time = float(time_s[index])
        if event_time > endpoint_time:
            endpoint_rejections += 1
            continue
        in_turn = any(
            event.onset_time_s - turn_padding_s
            <= event_time
            <= event.completion_time_s + turn_padding_s
            for event in turns
        )
        if in_turn:
            turn_rejections += 1
            continue
        heading = float(streams.yaw_unwrapped_rad[index] - initial_yaw)
        steps.append(
            StepEvent(
                time_s=event_time,
                prominence_mps2=float(peak_prominence),
                heading_rad=heading,
                magnetic_vector_ut=tuple(
                    map(float, streams.magnetic_field_ut[index])
                ),
                segment_index=_segment_for_time(event_time, turns),
            )
        )
    return steps, {
        "sample_rate_hz": sample_rate_hz,
        "robust_sigma_mps2": robust_sigma,
        "minimum_prominence_mps2": minimum_prominence,
        "candidate_count": len(candidates),
        "turn_peak_rejections": turn_rejections,
        "post_endpoint_peak_rejections": endpoint_rejections,
    }


def _route_geometry(route_xy_m) -> tuple[np.ndarray, np.ndarray, float]:
    points = np.asarray(route_xy_m, dtype=float)
    lengths = np.linalg.norm(np.diff(points, axis=0), axis=1)
    cumulative = np.concatenate(([0.0], np.cumsum(lengths)))
    return points, cumulative, float(cumulative[-1])


def route_position(route_xy_m, progress) -> np.ndarray:
    points, cumulative, total = _route_geometry(route_xy_m)
    progress = np.asarray(progress, dtype=float)
    distance = np.clip(progress, 0.0, 1.0) * total
    return np.column_stack(
        (
            np.interp(distance, cumulative, points[:, 0]),
            np.interp(distance, cumulative, points[:, 1]),
        )
    )


def reference_progress(
    steps: list[StepEvent],
    turns: list[TurnEvent],
    route_xy_m,
) -> np.ndarray:
    """Build evaluation/template labels from independently known corners."""
    _, cumulative, total = _route_geometry(route_xy_m)
    corner_progress = cumulative / total
    if not steps:
        return np.asarray([], dtype=float)
    step_times = np.asarray([step.time_s for step in steps], dtype=float)
    median_interval = (
        float(np.median(np.diff(step_times))) if step_times.size > 1 else 0.7
    )
    start_time = float(step_times[0] - 0.5 * median_interval)
    corner_times = [event.onset_time_s for event in turns[:4]]
    if len(corner_times) < 4:
        corner_times.extend(
            [float(step_times[-1])] * (4 - len(corner_times))
        )
    knots_time = np.maximum.accumulate(
        np.asarray([start_time, *corner_times], dtype=float)
    )
    return np.interp(step_times, knots_time, corner_progress)


def _step_length_weights(steps: list[StepEvent]) -> np.ndarray:
    if not steps:
        return np.asarray([], dtype=float)
    prominence = np.asarray([step.prominence_mps2 for step in steps], dtype=float)
    return np.power(np.maximum(prominence, 1e-6), 0.25)


def pdr_track(
    steps: list[StepEvent],
    route_xy_m,
    step_scale_m: float,
) -> tuple[np.ndarray, np.ndarray]:
    initial_heading = math.atan2(
        route_xy_m[1][1] - route_xy_m[0][1],
        route_xy_m[1][0] - route_xy_m[0][0],
    )
    weights = _step_length_weights(steps)
    lengths = weights * float(step_scale_m)
    track = [np.asarray(route_xy_m[0], dtype=float)]
    for step, length in zip(steps, lengths, strict=True):
        heading = initial_heading + float(step.heading_rad)
        track.append(
            track[-1]
            + float(length)
            * np.asarray([math.cos(heading), math.sin(heading)], dtype=float)
        )
    return np.asarray(track, dtype=float), lengths


def _segment_progress_bounds(route_xy_m) -> np.ndarray:
    _, cumulative, total = _route_geometry(route_xy_m)
    return cumulative / total


def magnetic_progress_track(
    steps: list[StepEvent],
    matcher: OnlineMagneticProgressMatcher,
    route_xy_m,
) -> tuple[np.ndarray, np.ndarray, list[dict]]:
    """Fuse causal magnetic progress with the observed turn/segment state."""
    bounds = _segment_progress_bounds(route_xy_m)
    progress = []
    diagnostics = []
    committed = 0.0
    for step in steps:
        match = matcher.update(step.magnetic_vector_ut)
        segment = min(max(int(step.segment_index), 0), len(bounds) - 2)
        constrained = float(
            np.clip(match.progress, bounds[segment], bounds[segment + 1])
        )
        committed = max(committed, constrained)
        progress.append(committed)
        diagnostics.append(
            {
                **match.as_dict(),
                "segment_index": segment,
                "constrained_progress": committed,
            }
        )
    positions = route_position(route_xy_m, progress) if progress else np.empty((0, 2))
    return positions, np.asarray(progress, dtype=float), diagnostics


def _display_route_track(
    steps: list[StepEvent],
    positions: np.ndarray,
    route_xy_m,
) -> np.ndarray:
    """Insert crossed corners so plotting never draws false diagonals."""
    route = np.asarray(route_xy_m, dtype=float)
    output = [route[0]]
    previous_segment = 0
    for step, position in zip(steps, positions, strict=True):
        segment = int(step.segment_index)
        for crossed_segment in range(previous_segment + 1, segment + 1):
            output.append(route[crossed_segment])
        output.append(np.asarray(position, dtype=float))
        previous_segment = segment
    output.append(route[-1])
    return np.asarray(output, dtype=float)


def _cross_track_error(track: np.ndarray, route_xy_m) -> np.ndarray:
    route = np.asarray(route_xy_m, dtype=float)
    starts = route[:-1]
    vectors = np.diff(route, axis=0)
    lengths_sq = np.sum(vectors * vectors, axis=1)
    output = []
    for point in np.asarray(track, dtype=float):
        relative = point - starts
        fraction = np.clip(
            np.sum(relative * vectors, axis=1) / lengths_sq, 0.0, 1.0
        )
        projection = starts + fraction[:, None] * vectors
        output.append(float(np.min(np.linalg.norm(projection - point, axis=1))))
    return np.asarray(output, dtype=float)


def _short_edge_lengths(
    steps: list[StepEvent],
    step_lengths: np.ndarray,
) -> list[float]:
    output = []
    for segment_index in (1, 3):
        output.append(
            float(
                sum(
                    length
                    for step, length in zip(steps, step_lengths, strict=True)
                    if step.segment_index == segment_index
                )
            )
        )
    return output


def _magnetic_vectors(steps: list[StepEvent]) -> np.ndarray:
    return np.asarray([step.magnetic_vector_ut for step in steps], dtype=float)


def run_recent_validation(
    capture_root: Path,
    output_root: Path,
) -> dict:
    capture_root = Path(capture_root)
    output_root = Path(output_root)
    loaded = {}
    for spec in RECENT_CAPTURES:
        package = capture_root / f"{spec.key}.geomagcapture"
        streams = load_recent_capture(package)
        turns = detect_quarter_turns(streams.time_s, streams.yaw_unwrapped_rad)
        if len(turns) != 4:
            raise ValueError(f"{spec.key} does not contain four quarter turns.")
        steps, step_diagnostics = detect_recent_steps(streams, turns)
        loaded[spec.key] = {
            "spec": spec,
            "streams": streams,
            "turns": turns,
            "steps": steps,
            "step_diagnostics": step_diagnostics,
            "reference_progress": reference_progress(
                steps, turns, spec.route_xy_m
            ),
        }

    calibration = {}
    for group, key in CALIBRATION_BY_GROUP.items():
        item = loaded[key]
        weights = _step_length_weights(item["steps"])
        calibration[group] = {
            "key": key,
            "step_scale_m": float(item["spec"].length_m / weights.sum()),
            "template_vectors": _magnetic_vectors(item["steps"]),
            "template_progress": item["reference_progress"],
        }

    runs = []
    plot_data = {}
    for spec in RECENT_CAPTURES:
        item = loaded[spec.key]
        calibrated = calibration[spec.route_group]
        raw_pdr, step_lengths = pdr_track(
            item["steps"], spec.route_xy_m, calibrated["step_scale_m"]
        )
        matcher = OnlineMagneticProgressMatcher(
            calibrated["template_vectors"],
            calibrated["template_progress"],
            max_advance=3,
            transition_penalty=0.5,
            expected_advance=1.0,
        )
        magnetic_track, estimated_progress, match_diagnostics = magnetic_progress_track(
            item["steps"], matcher, spec.route_xy_m
        )
        truth_progress = item["reference_progress"]
        truth_positions = route_position(spec.route_xy_m, truth_progress)
        position_error = np.linalg.norm(magnetic_track - truth_positions, axis=1)
        pdr_cross_track = _cross_track_error(raw_pdr, spec.route_xy_m)
        pdr_closure = float(np.linalg.norm(raw_pdr[-1] - raw_pdr[0]))
        short_edges = _short_edge_lengths(item["steps"], step_lengths)
        role = (
            "calibration"
            if CALIBRATION_BY_GROUP[spec.route_group] == spec.key
            else "validation"
        )
        runs.append(
            {
                "key": spec.key,
                "route_group": spec.route_group,
                "role": role,
                "geometry_status": spec.geometry_status,
                "step_count": len(item["steps"]),
                "turn_count": len(item["turns"]),
                "step_diagnostics": item["step_diagnostics"],
                "pdr_distance_m": float(step_lengths.sum()),
                "route_length_m": spec.length_m,
                "pdr_distance_error_pct": float(
                    100.0 * (step_lengths.sum() / spec.length_m - 1.0)
                ),
                "pdr_closure_error_m": pdr_closure,
                "pdr_cross_track_mean_m": float(np.mean(pdr_cross_track)),
                "pdr_short_edge_lengths_m": short_edges,
                "expected_short_edge_lengths_m": [
                    float(np.linalg.norm(np.subtract(spec.route_xy_m[2], spec.route_xy_m[1]))),
                    float(np.linalg.norm(np.subtract(spec.route_xy_m[4], spec.route_xy_m[3]))),
                ],
                "magnetic_position_error_mean_m": float(np.mean(position_error)),
                "magnetic_position_error_p95_m": float(
                    np.percentile(position_error, 95)
                ),
                "magnetic_endpoint_error_m": float(position_error[-1]),
                "estimated_progress": estimated_progress.tolist(),
                "reference_progress": truth_progress.tolist(),
                "match_diagnostics": match_diagnostics,
            }
        )
        plot_data[spec.key] = {
            "pdr": raw_pdr,
            "magnetic": _display_route_track(
                item["steps"], magnetic_track, spec.route_xy_m
            ),
        }

    payload = {
        "format_version": "1.0",
        "data_policy": "recent_route_13_14_15_only",
        "capture_root": str(capture_root.resolve()),
        "calibration_by_group": {
            group: {
                "key": value["key"],
                "step_scale_m": value["step_scale_m"],
            }
            for group, value in calibration.items()
        },
        "runs": runs,
    }
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_report(payload, output_root / "report.md")
    _write_plot(plot_data, output_root / "recent_pipeline_tracks.png")
    return payload


def _write_report(payload: dict, path: Path) -> None:
    lines = [
        "# Recent-capture 新算法验证",
        "",
        "- 数据策略：仅使用 route_13、route_14、route_15。",
        "- 航向：Core Motion 相对航向。",
        "- 计步：去重力垂直加速度周期峰。",
        "- 转弯：转弯状态不产生平移。",
        "- 地磁：每条路线首轮建模板，其余轮次留出验证。",
        "- 约束：地磁进度被限制在 Core Motion 识别出的当前路线边。",
        "",
        "| 数据 | 角色 | 有效步数 | PDR 距离误差 | PDR 闭合误差 | 两条短边 PDR | 地磁平均误差 | 地磁 P95 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for run in payload["runs"]:
        short_edges = "/".join(
            f"{value:.2f}" for value in run["pdr_short_edge_lengths_m"]
        )
        lines.append(
            f"| {run['key']} | {run['role']} | {run['step_count']} | "
            f"{run['pdr_distance_error_pct']:+.1f}% | "
            f"{run['pdr_closure_error_m']:.2f} m | {short_edges} m | "
            f"{run['magnetic_position_error_mean_m']:.2f} m | "
            f"{run['magnetic_position_error_p95_m']:.2f} m |"
        )
    lines.extend(
        [
            "",
            "> route_14 的 6.0 m × 0.6 m 几何已由采集者确认。",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_plot(plot_data: dict, path: Path) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [spec for spec in RECENT_CAPTURES if spec.route_group == group]
        route = np.asarray(specs[0].route_xy_m, dtype=float)
        axis.plot(route[:, 0], route[:, 1], "w--", linewidth=2.6, label="route constraint")
        for spec in specs:
            data = plot_data[spec.key]
            axis.plot(data["pdr"][:, 0], data["pdr"][:, 1], alpha=0.55, label=f"{spec.key} PDR")
            axis.plot(
                data["magnetic"][:, 0],
                data["magnetic"][:, 1],
                linewidth=2.0,
                label=f"{spec.key} fused",
            )
        axis.set_title(group)
        axis.set_aspect("equal", adjustable="box")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=7)
        axis.set_xlabel("X (m)")
        axis.set_ylabel("Y (m)")
        axis.set_facecolor("#17202a")
        axis.tick_params(colors="white")
        axis.xaxis.label.set_color("white")
        axis.yaxis.label.set_color("white")
        axis.title.set_color("white")
    figure.patch.set_facecolor("#17202a")
    path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(path, dpi=180, facecolor=figure.get_facecolor())
    plt.close(figure)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--capture-root",
        type=Path,
        default=Path("/Users/xuminglei/dachuang/Geomag Capture"),
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("results/recent_capture_pipeline"),
    )
    args = parser.parse_args()
    result = run_recent_validation(args.capture_root, args.output_root)
    validation = [run for run in result["runs"] if run["role"] == "validation"]
    print(
        "validation magnetic mean error: "
        f"{np.mean([run['magnetic_position_error_mean_m'] for run in validation]):.3f} m"
    )
    print(f"report={args.output_root / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
