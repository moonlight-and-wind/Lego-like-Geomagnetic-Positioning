"""Free-path V2 validation without rectangle or known-edge inference priors."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from geomag_v2.capture import load_capture
from geomag_v2.catalog import CALIBRATION_KEYS, RECENT_ROUTES, RouteSpec
from geomag_v2.distance import RidgeDistanceModel
from geomag_v2.free_motion import FreeSegment, integrate_free_track, segment_free_motion


def _initial_heading(spec: RouteSpec) -> float:
    vector = np.asarray(spec.points_m[1]) - np.asarray(spec.points_m[0])
    return float(math.atan2(vector[1], vector[0]))


def _cross_track_error(track: np.ndarray, route: np.ndarray) -> np.ndarray:
    starts = route[:-1]
    vectors = np.diff(route, axis=0)
    squared = np.sum(vectors * vectors, axis=1)
    output = []
    for point in track:
        fraction = np.clip(np.sum((point - starts) * vectors, axis=1) / squared, 0.0, 1.0)
        projection = starts + fraction[:, None] * vectors
        output.append(float(np.min(np.linalg.norm(projection - point, axis=1))))
    return np.asarray(output)


def _fit_model(loaded: dict[str, dict], excluded_group: str | None = None) -> RidgeDistanceModel:
    training_specs = [
        spec
        for spec in RECENT_ROUTES
        if spec.key in CALIBRATION_KEYS and spec.group != excluded_group
    ]
    observations: list[FreeSegment] = []
    distances = []
    for spec in training_specs:
        segments = loaded[spec.key]["segments"]
        if len(segments) != len(spec.segment_lengths_m):
            raise ValueError(f"{spec.key}: free-motion/reference segment count mismatch")
        observations.extend(segments)
        distances.extend(spec.segment_lengths_m)
    return RidgeDistanceModel.fit(observations, np.asarray(distances))


def _evaluate_run(spec: RouteSpec, item: dict, model: RidgeDistanceModel) -> tuple[dict, np.ndarray]:
    segments = item["segments"]
    lengths = model.predict(segments)
    track, corner_indices = integrate_free_track(
        segments,
        lengths,
        initial_heading_rad=_initial_heading(spec),
    )
    route = np.asarray(spec.points_m, dtype=float)
    cross_track = _cross_track_error(track, route)
    if corner_indices.size == route.shape[0]:
        corner_error = np.linalg.norm(track[corner_indices] - route, axis=1)
        segment_mae = float(np.mean(np.abs(lengths - spec.segment_lengths_m)))
    else:
        corner_error = np.asarray([np.nan])
        segment_mae = float("nan")
    result = {
        "key": spec.key,
        "group": spec.group,
        "turn_count": len(item["turns"]),
        "turn_angles_deg": [turn.signed_angle_deg for turn in item["turns"]],
        "segment_count": len(segments),
        "step_counts": [segment.step_count for segment in segments],
        "estimated_segment_lengths_m": lengths.tolist(),
        "reference_segment_lengths_m": spec.segment_lengths_m.tolist(),
        "segment_mae_m": segment_mae,
        "cross_track_mean_m": float(cross_track.mean()),
        "endpoint_error_m": float(np.linalg.norm(track[-1] - route[-1])),
        "corner_error_mean_m": float(np.nanmean(corner_error)),
        "corner_error_max_m": float(np.nanmax(corner_error)),
    }
    return result, track


def run_free_validation(capture_root: Path, output_root: Path) -> dict:
    capture_root = Path(capture_root)
    output_root = Path(output_root)
    loaded = {}
    for spec in RECENT_ROUTES:
        capture = load_capture(capture_root / f"{spec.key}.geomagcapture")
        # The operator confirmed that these closed-loop captures stop walking
        # at the fourth turn and only keep recording afterward.
        turns, segments = segment_free_motion(capture, include_trailing_segment=False)
        loaded[spec.key] = {"turns": turns, "segments": segments}

    same_route_model = _fit_model(loaded)
    same_route_runs = []
    same_route_tracks = {}
    for spec in RECENT_ROUTES:
        run, track = _evaluate_run(spec, loaded[spec.key], same_route_model)
        run["role"] = "calibration" if spec.key in CALIBRATION_KEYS else "validation"
        same_route_runs.append(run)
        same_route_tracks[spec.key] = track

    blind_runs = []
    blind_tracks = {}
    for group in ("route_13", "route_14", "route_15"):
        model = _fit_model(loaded, excluded_group=group)
        for spec in [item for item in RECENT_ROUTES if item.group == group]:
            run, track = _evaluate_run(spec, loaded[spec.key], model)
            run["training_groups"] = [
                candidate.group
                for candidate in RECENT_ROUTES
                if candidate.key in CALIBRATION_KEYS and candidate.group != group
            ]
            blind_runs.append(run)
            blind_tracks[spec.key] = track

    validation_runs = [run for run in same_route_runs if run["role"] == "validation"]
    payload = {
        "format_version": "2.1-free-path",
        "data_policy": "route_13_14_15_only",
        "motion_model": {
            "turn_count_fixed": False,
            "turn_angle_fixed": False,
            "heading_snap": False,
            "turn_translation": False,
            "rectangle_equal_side_prior": False,
            "known_test_edge_length_prior": False,
            "straight_heading": "core_motion_circular_mean",
            "initial_heading": "first_walking_segment_zeroed_then_evaluation_frame_alignment",
        },
        "magnetic_map": {
            "status": "disabled_missing_shared_spatial_coordinate_frame",
            "reason": (
                "route_13/14/15 coordinates are route-local; combining their magnetic samples "
                "would create a false map. MagneticMap is ready but requires surveyed global anchors."
            ),
        },
        "same_route_training_summary": _summary(validation_runs),
        "cross_route_blind_summary": _summary(blind_runs),
        "same_route_runs": same_route_runs,
        "cross_route_blind_runs": blind_runs,
    }
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    _write_report(payload, output_root / "report.md")
    _write_plot(same_route_tracks, output_root / "free_tracks.png", "free path")
    _write_plot(blind_tracks, output_root / "blind_free_tracks.png", "cross-route blind")
    return payload


def _summary(runs: list[dict]) -> dict:
    return {
        "segment_mae_m": float(np.mean([run["segment_mae_m"] for run in runs])),
        "cross_track_mean_m": float(np.mean([run["cross_track_mean_m"] for run in runs])),
        "endpoint_error_mean_m": float(np.mean([run["endpoint_error_m"] for run in runs])),
        "corner_error_max_m": float(max(run["corner_error_max_m"] for run in runs)),
    }


def _write_report(payload: dict, path: Path) -> None:
    same = payload["same_route_training_summary"]
    blind = payload["cross_route_blind_summary"]
    lines = [
        "# Geomag V2 自由路径验证",
        "",
        "该模式不固定转弯数量或角度，不作 90° 航向吸附，不使用矩形相对边相等，",
        "也不读取待测路线边长。每段方向来自 Core Motion 圆均值，不吸附到固定角度；",
        "直行段内抑制手持航向抖动，转弯状态零平移。",
        "",
        f"同路线独立训练的留出边长 MAE：{same['segment_mae_m']:.3f} m；横向误差："
        f"{same['cross_track_mean_m']:.3f} m；平均终点误差：{same['endpoint_error_mean_m']:.3f} m。",
        f"完整跨路线盲测边长 MAE：{blind['segment_mae_m']:.3f} m；横向误差："
        f"{blind['cross_track_mean_m']:.3f} m；平均终点误差：{blind['endpoint_error_mean_m']:.3f} m。",
        "",
        "| 数据 | 模式 | 转角 (deg) | 估计四段 (m) | 边长 MAE | 横向误差 | 终点误差 |",
        "|---|---|---|---|---:|---:|---:|",
    ]
    for mode, runs in (
        ("same-route", payload["same_route_runs"]),
        ("cross-route-blind", payload["cross_route_blind_runs"]),
    ):
        for run in runs:
            angles = "/".join(f"{value:.0f}" for value in run["turn_angles_deg"])
            lengths = "/".join(f"{value:.2f}" for value in run["estimated_segment_lengths_m"])
            lines.append(
                f"| {run['key']} | {mode} | {angles} | {lengths} | "
                f"{run['segment_mae_m']:.2f} | {run['cross_track_mean_m']:.2f} | "
                f"{run['endpoint_error_m']:.2f} |"
            )
    lines.extend(
        [
            "",
            "## 地磁地图状态",
            "",
            "自由路径地磁接口已经实现，但本次未启用。三条路线目前都是各自以 (0, 0) 开始的",
            "局部坐标，缺少它们在同一楼层坐标系中的平移、旋转和锚点；直接合并会生成错误磁图。",
            "下一步需要给采集包加入统一空间坐标或至少三个不共线锚点。",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_plot(tracks: dict[str, np.ndarray], path: Path, suffix: str) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    colors = plt.get_cmap("tab10")
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [spec for spec in RECENT_ROUTES if spec.group == group]
        reference = np.asarray(specs[0].points_m)
        axis.plot(reference[:, 0], reference[:, 1], "k--", linewidth=2.4, label="reference")
        for index, spec in enumerate(specs):
            track = tracks[spec.key]
            axis.plot(
                track[:, 0],
                track[:, 1],
                color=colors(index),
                linewidth=2.0,
                label=spec.key,
            )
        axis.set_title(f"{group} {suffix}")
        axis.set_aspect("equal", adjustable="box")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=7)
        axis.set_xlabel("X (m)")
        axis.set_ylabel("Y (m)")
    figure.savefig(path, dpi=180)
    plt.close(figure)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--capture-root",
        type=Path,
        default=Path("/Users/xuminglei/dachuang/Geomag Capture"),
    )
    parser.add_argument("--output-root", type=Path, default=Path("results/geomag_v2_free"))
    args = parser.parse_args()
    payload = run_free_validation(args.capture_root, args.output_root)
    print(json.dumps(payload["same_route_training_summary"], ensure_ascii=False, indent=2))
    print(json.dumps(payload["cross_route_blind_summary"], ensure_ascii=False, indent=2))
    print(f"report={args.output_root / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
