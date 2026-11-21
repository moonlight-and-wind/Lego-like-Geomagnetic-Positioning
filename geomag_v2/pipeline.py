"""End-to-end V2 validation using only route 13, 14, and 15."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from geomag_v2.capture import load_capture
from geomag_v2.catalog import CALIBRATION_KEYS, RECENT_ROUTES, RouteSpec
from geomag_v2.distance import (
    RidgeDistanceModel,
    equalize_opposite_sides,
    regularize_rectangle,
)
from geomag_v2.magnetic import bounded_magnetic_progress
from geomag_v2.motion import SegmentObservation, segment_capture


def _initial_heading(spec: RouteSpec) -> float:
    first = np.asarray(spec.points_m[1]) - np.asarray(spec.points_m[0])
    return float(math.atan2(first[1], first[0]))


def _turn_direction(spec: RouteSpec) -> float:
    points = np.asarray(spec.points_m, dtype=float)
    first = points[1] - points[0]
    second = points[2] - points[1]
    cross = first[0] * second[1] - first[1] * second[0]
    return 1.0 if cross >= 0.0 else -1.0


def _track(
    spec: RouteSpec,
    segments: list[SegmentObservation],
    lengths_m: np.ndarray,
    templates: list[np.ndarray] | None,
) -> np.ndarray:
    points = [np.asarray(spec.points_m[0], dtype=float)]
    initial = _initial_heading(spec)
    turn_direction = _turn_direction(spec)
    for index, (segment, length) in enumerate(zip(segments, lengths_m, strict=True)):
        progress = segment.inertial_progress
        if templates is not None:
            progress = bounded_magnetic_progress(
                templates[index],
                segment.magnetic_field_ut,
                segment.inertial_progress,
            )
        sampled = np.linspace(0.0, 1.0, 31)
        progress = np.maximum.accumulate(progress)
        sample_progress = np.interp(
            sampled,
            np.linspace(0.0, 1.0, progress.size),
            progress,
        )
        heading = initial + turn_direction * index * math.pi / 2.0
        direction = np.asarray([math.cos(heading), math.sin(heading)])
        start = points[-1]
        points.extend(start + value * float(length) * direction for value in sample_progress[1:])
    return np.asarray(points)


def _cross_track_error(track: np.ndarray, route: np.ndarray) -> np.ndarray:
    starts = route[:-1]
    vectors = np.diff(route, axis=0)
    squared = np.sum(vectors * vectors, axis=1)
    output = []
    for point in track:
        fraction = np.clip(np.sum((point - starts) * vectors, axis=1) / squared, 0.0, 1.0)
        projections = starts + fraction[:, None] * vectors
        output.append(float(np.min(np.linalg.norm(projections - point, axis=1))))
    return np.asarray(output)


def run_validation(capture_root: Path, output_root: Path) -> dict:
    capture_root = Path(capture_root)
    output_root = Path(output_root)
    loaded: dict[str, dict] = {}
    for spec in RECENT_ROUTES:
        capture = load_capture(capture_root / f"{spec.key}.geomagcapture")
        turns, segments = segment_capture(capture)
        loaded[spec.key] = {"capture": capture, "turns": turns, "segments": segments}

    training_observations: list[SegmentObservation] = []
    training_distances = []
    templates_by_group: dict[str, list[np.ndarray]] = {}
    calibration_lengths_by_group: dict[str, np.ndarray] = {}
    for spec in RECENT_ROUTES:
        if spec.key not in CALIBRATION_KEYS:
            continue
        segments = loaded[spec.key]["segments"]
        training_observations.extend(segments)
        training_distances.extend(spec.segment_lengths_m)
        templates_by_group[spec.group] = [segment.magnetic_field_ut for segment in segments]
        calibration_lengths_by_group[spec.group] = spec.segment_lengths_m

    distance_model = RidgeDistanceModel.fit(
        training_observations,
        np.asarray(training_distances),
    )
    runs = []
    plot_data = {}
    for spec in RECENT_ROUTES:
        segments = loaded[spec.key]["segments"]
        sensor_lengths = distance_model.predict(segments)
        fused_lengths = regularize_rectangle(
            sensor_lengths,
            calibration_lengths_by_group[spec.group],
            sensor_confidence=np.asarray(
                [min(1.0, segment.step_count / 10.0) for segment in segments]
            ),
        )
        sensor_track = _track(spec, segments, sensor_lengths, None)
        fused_track = _track(spec, segments, fused_lengths, templates_by_group[spec.group])
        route = np.asarray(spec.points_m, dtype=float)
        sensor_cross = _cross_track_error(sensor_track, route)
        fused_cross = _cross_track_error(fused_track, route)
        corner_indices = np.asarray([0, 30, 60, 90, 120])
        corner_error = np.linalg.norm(fused_track[corner_indices] - route, axis=1)
        runs.append(
            {
                "key": spec.key,
                "group": spec.group,
                "role": "calibration" if spec.key in CALIBRATION_KEYS else "validation",
                "geometry_status": spec.geometry_status,
                "turn_count": len(loaded[spec.key]["turns"]),
                "step_counts": [segment.step_count for segment in segments],
                "sensor_segment_lengths_m": sensor_lengths.tolist(),
                "fused_segment_lengths_m": fused_lengths.tolist(),
                "reference_segment_lengths_m": spec.segment_lengths_m.tolist(),
                "sensor_segment_mae_m": float(np.mean(np.abs(sensor_lengths - spec.segment_lengths_m))),
                "fused_segment_mae_m": float(np.mean(np.abs(fused_lengths - spec.segment_lengths_m))),
                "sensor_cross_track_mean_m": float(sensor_cross.mean()),
                "fused_cross_track_mean_m": float(fused_cross.mean()),
                "fused_corner_error_mean_m": float(corner_error.mean()),
                "fused_corner_error_max_m": float(corner_error.max()),
                "fused_closure_error_m": float(np.linalg.norm(fused_track[-1] - fused_track[0])),
            }
        )
        plot_data[spec.key] = {"sensor": sensor_track, "fused": fused_track}

    validation = [run for run in runs if run["role"] == "validation"]
    blind_payload, blind_plot_data = _cross_route_generalization(loaded)
    payload = {
        "format_version": "2.0",
        "engine": "geomag_v2",
        "data_policy": "route_13_14_15_only",
        "training_keys": sorted(CALIBRATION_KEYS),
        "validation_keys": [run["key"] for run in validation],
        "geometry_prior": {
            "type": "soft_rectangular_opposite-side_and_calibration",
            "calibration_weight": 0.70,
            "hard_coordinate_projection": False,
        },
        "magnetic_progress": {
            "maximum_correction_fraction": 0.15,
            "magnetic_weight": 0.35,
        },
        "validation_summary": {
            "sensor_segment_mae_m": float(np.mean([run["sensor_segment_mae_m"] for run in validation])),
            "fused_segment_mae_m": float(np.mean([run["fused_segment_mae_m"] for run in validation])),
            "fused_cross_track_mean_m": float(np.mean([run["fused_cross_track_mean_m"] for run in validation])),
            "fused_corner_error_mean_m": float(np.mean([run["fused_corner_error_mean_m"] for run in validation])),
            "fused_corner_error_max_m": float(max(run["fused_corner_error_max_m"] for run in validation)),
        },
        "cross_route_generalization": blind_payload,
        "runs": runs,
    }
    output_root.mkdir(parents=True, exist_ok=True)
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_report(payload, output_root / "report.md")
    _write_plot(plot_data, output_root / "tracks.png")
    _write_sensor_plot(plot_data, output_root / "sensor_diagnostics.png")
    _write_blind_report(blind_payload, output_root / "blind_report.md")
    _write_blind_plot(blind_plot_data, output_root / "blind_tracks.png")
    return payload


def _cross_route_generalization(loaded: dict[str, dict]) -> tuple[dict, dict]:
    """Hold out an entire route group, including all of its calibration data."""
    runs = []
    plot_data = {}
    for held_group in ("route_13", "route_14", "route_15"):
        training_specs = [
            spec
            for spec in RECENT_ROUTES
            if spec.key in CALIBRATION_KEYS and spec.group != held_group
        ]
        training_observations = [
            observation
            for spec in training_specs
            for observation in loaded[spec.key]["segments"]
        ]
        training_distances = np.concatenate(
            [spec.segment_lengths_m for spec in training_specs]
        )
        model = RidgeDistanceModel.fit(training_observations, training_distances)
        for spec in [item for item in RECENT_ROUTES if item.group == held_group]:
            segments = loaded[spec.key]["segments"]
            raw_lengths = model.predict(segments)
            blind_lengths = equalize_opposite_sides(raw_lengths)
            blind_track = _track(spec, segments, blind_lengths, None)
            route = np.asarray(spec.points_m, dtype=float)
            cross_track = _cross_track_error(blind_track, route)
            corner_indices = np.asarray([0, 30, 60, 90, 120])
            corner_error = np.linalg.norm(blind_track[corner_indices] - route, axis=1)
            runs.append(
                {
                    "key": spec.key,
                    "held_out_group": held_group,
                    "training_keys": [item.key for item in training_specs],
                    "raw_segment_lengths_m": raw_lengths.tolist(),
                    "blind_segment_lengths_m": blind_lengths.tolist(),
                    "reference_segment_lengths_m": spec.segment_lengths_m.tolist(),
                    "segment_mae_m": float(
                        np.mean(np.abs(blind_lengths - spec.segment_lengths_m))
                    ),
                    "cross_track_mean_m": float(cross_track.mean()),
                    "corner_error_mean_m": float(corner_error.mean()),
                    "corner_error_max_m": float(corner_error.max()),
                }
            )
            plot_data[spec.key] = blind_track
    payload = {
        "protocol": "leave_one_route_group_out",
        "uses_held_out_route_lengths_for_estimation": False,
        "uses_held_out_magnetic_template": False,
        "uses_rectangle_topology": True,
        "initial_heading_source": "reference_frame_alignment_for_evaluation_only",
        "summary": {
            "segment_mae_m": float(np.mean([run["segment_mae_m"] for run in runs])),
            "cross_track_mean_m": float(
                np.mean([run["cross_track_mean_m"] for run in runs])
            ),
            "corner_error_mean_m": float(
                np.mean([run["corner_error_mean_m"] for run in runs])
            ),
            "corner_error_max_m": float(
                max(run["corner_error_max_m"] for run in runs)
            ),
        },
        "runs": runs,
    }
    return payload, plot_data


def _write_report(payload: dict, path: Path) -> None:
    summary = payload["validation_summary"]
    lines = [
        "# Geomag V2 recent-only 验证",
        "",
        "V2 是独立新核心，不读取旧数据注册表、旧地磁图或旧粒子滤波状态。",
        "",
        "- 训练：route_13_1、route_14_2、route_15_1。",
        "- 留出验证：route_13_2/3、route_14_3、route_15_2/3。",
        "- 运动：Core Motion 转弯分段；转弯期间零平移；直行段整体估距。",
        "- 几何：90° 矩形与标定边长作置信度软先验；有效峰越少，越不信任短段惯导估距。",
        "- 坐标不会硬投影到白线；纯传感器轨迹和误差完整保存在 sensor_diagnostics.png 与表格中。",
        "- 地磁：只校正段内进度，最大 15%，不修改边长、不瞬移到地图。",
        "",
        f"留出集传感器边长 MAE：{summary['sensor_segment_mae_m']:.3f} m；"
        f"软融合后：{summary['fused_segment_mae_m']:.3f} m。",
        "",
        "| 数据 | 角色 | 四段有效峰数 | 传感器四边 (m) | 融合四边 (m) | 边长 MAE | 横向误差 | 角点均值/最大 | 闭合误差 |",
        "|---|---|---|---|---|---:|---:|---:|---:|",
    ]
    for run in payload["runs"]:
        counts = "/".join(str(value) for value in run["step_counts"])
        sensor = "/".join(f"{value:.2f}" for value in run["sensor_segment_lengths_m"])
        fused = "/".join(f"{value:.2f}" for value in run["fused_segment_lengths_m"])
        lines.append(
            f"| {run['key']} | {run['role']} | {counts} | {sensor} | {fused} | "
            f"{run['fused_segment_mae_m']:.2f} | {run['fused_cross_track_mean_m']:.2f} | "
            f"{run['fused_corner_error_mean_m']:.2f}/{run['fused_corner_error_max_m']:.2f} | "
            f"{run['fused_closure_error_m']:.2f} |"
        )
    lines.extend(
        [
            "",
            "",
            "route_14 的 6.0 m × 0.6 m 已由采集者确认。跨路线盲测结果见 "
            "`blind_report.md`，不得用同路线标定精度代替泛化精度。",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_plot(plot_data: dict, path: Path) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    colors = plt.get_cmap("tab10")
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [spec for spec in RECENT_ROUTES if spec.group == group]
        reference = np.asarray(specs[0].points_m)
        axis.plot(reference[:, 0], reference[:, 1], "w--", linewidth=2.4, label="reference")
        for index, spec in enumerate(specs):
            data = plot_data[spec.key]
            axis.plot(
                data["fused"][:, 0],
                data["fused"][:, 1],
                color=colors(index),
                linewidth=2.2,
                label=f"{spec.key} V2",
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
    figure.savefig(path, dpi=180, facecolor=figure.get_facecolor())
    plt.close(figure)


def _write_sensor_plot(plot_data: dict, path: Path) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    colors = plt.get_cmap("tab10")
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [spec for spec in RECENT_ROUTES if spec.group == group]
        reference = np.asarray(specs[0].points_m)
        axis.plot(reference[:, 0], reference[:, 1], "k--", linewidth=2.4, label="reference")
        for index, spec in enumerate(specs):
            data = plot_data[spec.key]
            axis.plot(
                data["sensor"][:, 0],
                data["sensor"][:, 1],
                color=colors(index),
                linewidth=1.8,
                label=f"{spec.key} sensor-only",
            )
        axis.set_title(f"{group} sensor-only diagnostics")
        axis.set_aspect("equal", adjustable="box")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=7)
        axis.set_xlabel("X (m)")
        axis.set_ylabel("Y (m)")
    figure.savefig(path, dpi=180)
    plt.close(figure)


def _write_blind_report(payload: dict, path: Path) -> None:
    summary = payload["summary"]
    lines = [
        "# Geomag V2 跨路线盲测",
        "",
        "每次完整排除一个路线组，包括该路线的标定采集、已知边长和地磁模板；",
        "估计器只使用另外两条路线的首轮数据训练。矩形相对边相等仍作为受控实验拓扑，",
        "初始朝向只用于把局部轨迹对齐到评估坐标系。",
        "",
        f"整体边长 MAE：{summary['segment_mae_m']:.3f} m；平均横向误差："
        f"{summary['cross_track_mean_m']:.3f} m；最大角点误差："
        f"{summary['corner_error_max_m']:.3f} m。",
        "",
        "| 盲测数据 | 训练数据 | 盲测四边 (m) | 真实四边 (m) | 边长 MAE | 横向误差 | 角点均值/最大 |",
        "|---|---|---|---|---:|---:|---:|",
    ]
    for run in payload["runs"]:
        training = ", ".join(run["training_keys"])
        blind = "/".join(f"{value:.2f}" for value in run["blind_segment_lengths_m"])
        reference = "/".join(
            f"{value:.2f}" for value in run["reference_segment_lengths_m"]
        )
        lines.append(
            f"| {run['key']} | {training} | {blind} | {reference} | "
            f"{run['segment_mae_m']:.2f} | {run['cross_track_mean_m']:.2f} | "
            f"{run['corner_error_mean_m']:.2f}/{run['corner_error_max_m']:.2f} |"
        )
    lines.extend(
        [
            "",
            "该结果才代表当前 V2 遇到未标定新路线时的能力。它不使用地磁模板，因此是下一阶段",
            "任意路线模式的惯导基线，而不是最终地磁定位精度。",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_blind_plot(plot_data: dict, path: Path) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    colors = plt.get_cmap("tab10")
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [spec for spec in RECENT_ROUTES if spec.group == group]
        reference = np.asarray(specs[0].points_m)
        axis.plot(reference[:, 0], reference[:, 1], "k--", linewidth=2.4, label="reference")
        for index, spec in enumerate(specs):
            track = plot_data[spec.key]
            axis.plot(
                track[:, 0],
                track[:, 1],
                color=colors(index),
                linewidth=2.0,
                label=f"{spec.key} blind",
            )
        axis.set_title(f"{group} held out")
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
    parser.add_argument("--output-root", type=Path, default=Path("results/geomag_v2"))
    args = parser.parse_args()
    payload = run_validation(args.capture_root, args.output_root)
    print(json.dumps(payload["validation_summary"], ensure_ascii=False, indent=2))
    print(f"report={args.output_root / 'report.md'}")
    print(f"plot={args.output_root / 'tracks.png'}")
    print(f"sensor_diagnostics={args.output_root / 'sensor_diagnostics.png'}")
    print(f"blind_report={args.output_root / 'blind_report.md'}")
    print(f"blind_plot={args.output_root / 'blind_tracks.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
