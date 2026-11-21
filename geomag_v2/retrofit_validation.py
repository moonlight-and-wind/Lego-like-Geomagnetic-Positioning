"""Calibrate route-local maps and evaluate held-out retrofit captures."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from geomag_v2.capture import load_capture
from geomag_v2.catalog import CALIBRATION_KEYS, RECENT_ROUTES
from geomag_v2.distance import RidgeDistanceModel
from geomag_v2.free_motion import FreeSegment, integrate_free_track, segment_free_motion
from geomag_v2.free_path import _cross_track_error
from geomag_v2.map_localization import (
    ParticleFilterConfig,
    build_activity_anchored_map,
    localize_free_track,
    resample_magnetic_observations,
)


def _fit_calibration_distance_model(loaded: dict[str, dict]) -> RidgeDistanceModel:
    segments: list[FreeSegment] = []
    distances = []
    for spec in RECENT_ROUTES:
        if spec.key not in CALIBRATION_KEYS:
            continue
        segments.extend(loaded[spec.key]["segments"])
        distances.extend(spec.segment_lengths_m)
    return RidgeDistanceModel.fit(segments, np.asarray(distances))


def _metrics(track: np.ndarray, route: np.ndarray, corner_indices: np.ndarray) -> dict:
    cross_track = _cross_track_error(track, route)
    corner_error = np.linalg.norm(track[corner_indices] - route, axis=1)
    return {
        "cross_track_mean_m": float(np.mean(cross_track)),
        "cross_track_p95_m": float(np.percentile(cross_track, 95)),
        "endpoint_error_m": float(np.linalg.norm(track[-1] - route[-1])),
        "corner_error_mean_m": float(np.mean(corner_error)),
        "corner_error_max_m": float(np.max(corner_error)),
    }


def _seed_for_key(key: str) -> int:
    return 20260808 + sum((index + 1) * ord(value) for index, value in enumerate(key))


def run_retrofit_validation(capture_root: Path, output_root: Path) -> dict:
    """Use first-run maps to localize the remaining runs without test geometry input."""
    capture_root = Path(capture_root)
    output_root = Path(output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    loaded = {}
    for spec in RECENT_ROUTES:
        capture = load_capture(capture_root / f"{spec.key}.geomagcapture")
        _, segments = segment_free_motion(capture, include_trailing_segment=False)
        if len(segments) != 4:
            raise ValueError(f"{spec.key}: expected four walking segments")
        loaded[spec.key] = {"capture": capture, "segments": segments}

    distance_model = _fit_calibration_distance_model(loaded)
    maps = {}
    calibration_by_group = {}
    map_root = output_root / "maps"
    map_root.mkdir(exist_ok=True)
    for group in ("route_13", "route_14", "route_15"):
        spec = next(
            item for item in RECENT_ROUTES if item.group == group and item.key in CALIBRATION_KEYS
        )
        item = loaded[spec.key]
        magnetic_map = build_activity_anchored_map(item["capture"], item["segments"])
        magnetic_map.save(map_root / f"{group}.npz")
        maps[group] = magnetic_map
        calibration_by_group[group] = spec.key

    runs = []
    plot_tracks = {}
    for spec in RECENT_ROUTES:
        if spec.key in CALIBRATION_KEYS:
            continue
        item = loaded[spec.key]
        capture = item["capture"]
        segments = item["segments"]
        assert capture.spatial_reference is not None
        lengths = distance_model.predict(segments)
        inertial, corner_indices = integrate_free_track(
            segments,
            lengths,
            initial_heading_rad=np.radians(capture.spatial_reference.initial_heading_deg),
        )
        observations = resample_magnetic_observations(capture, segments)
        localization = localize_free_track(
            inertial,
            observations,
            maps[spec.group],
            start_position_xy_m=capture.spatial_reference.start_position_xy_m,
            segment_boundary_indices=corner_indices[1:-1],
            config=ParticleFilterConfig(random_seed=_seed_for_key(spec.key)),
        )
        route = np.asarray(spec.points_m, dtype=float)
        inertial_global = inertial + np.asarray(capture.spatial_reference.start_position_xy_m)
        baseline = _metrics(inertial_global, route, corner_indices)
        fused = _metrics(localization.track_xy_m, route, corner_indices)
        run = {
            "key": spec.key,
            "group": spec.group,
            "role": "held_out_validation",
            "calibration_capture": calibration_by_group[spec.group],
            "coordinate_frame": capture.spatial_reference.coordinate_frame,
            "localizer_inputs": [
                "known_start_position",
                "format3_initial_heading",
                "core_motion_inertial_displacements",
                "test_magnetic_observations",
                "calibration_capture_magnetic_map",
            ],
            "test_intermediate_anchor_coordinates_used_by_localizer": False,
            "estimated_segment_lengths_m": lengths.tolist(),
            "baseline": baseline,
            "magnetic_fused": fused,
            "cross_track_improvement_m": (
                baseline["cross_track_mean_m"] - fused["cross_track_mean_m"]
            ),
            "endpoint_improvement_m": (
                baseline["endpoint_error_m"] - fused["endpoint_error_m"]
            ),
            "particle_filter": {
                "resample_count": localization.resample_count,
                "mean_effective_sample_size": float(
                    np.mean(localization.effective_sample_size)
                ),
                "mean_map_distance_m": localization.mean_map_distance_m,
                "mean_magnetic_residual_ut": localization.mean_magnetic_residual_ut,
            },
        }
        runs.append(run)
        plot_tracks[spec.key] = (inertial_global, localization.track_xy_m)
        _write_track_csv(
            output_root / f"{spec.key}_track.csv",
            inertial_global,
            localization.track_xy_m,
        )

    payload = {
        "format_version": "geomag-v2-retrofit-validation-1",
        "data_policy": "recent_route_13_14_15_only",
        "provenance": {
            "spatial_annotations": "derived_from_known_controlled_routes",
            "manual_ground_truth": False,
            "claim_scope": "pipeline_integration_and_route_local_held_out_validation",
        },
        "evaluation_protocol": {
            "calibration_by_group": calibration_by_group,
            "validation_keys": [run["key"] for run in runs],
            "distance_model_training": sorted(CALIBRATION_KEYS),
            "test_route_coordinates": "metrics_and_plot_only_after_localization",
            "loop_closure_prior": False,
            "known_test_edge_lengths": False,
        },
        "summary": _summary(runs),
        "runs": runs,
    }
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_report(payload, output_root / "report.md")
    _write_plot(plot_tracks, output_root / "held_out_tracks.png")
    return payload


def _summary(runs: list[dict]) -> dict:
    return {
        "validation_run_count": len(runs),
        "baseline_cross_track_mean_m": float(
            np.mean([run["baseline"]["cross_track_mean_m"] for run in runs])
        ),
        "fused_cross_track_mean_m": float(
            np.mean([run["magnetic_fused"]["cross_track_mean_m"] for run in runs])
        ),
        "baseline_endpoint_mean_m": float(
            np.mean([run["baseline"]["endpoint_error_m"] for run in runs])
        ),
        "fused_endpoint_mean_m": float(
            np.mean([run["magnetic_fused"]["endpoint_error_m"] for run in runs])
        ),
        "cross_track_improved_runs": sum(
            run["cross_track_improvement_m"] > 0.0 for run in runs
        ),
        "endpoint_improved_runs": sum(run["endpoint_improvement_m"] > 0.0 for run in runs),
    }


def _write_track_csv(path: Path, baseline: np.ndarray, fused: np.ndarray) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["sample", "pdr_x_m", "pdr_y_m", "fused_x_m", "fused_y_m"])
        for index, (pdr, corrected) in enumerate(zip(baseline, fused, strict=True)):
            writer.writerow([index, pdr[0], pdr[1], corrected[0], corrected[1]])


def _write_report(payload: dict, path: Path) -> None:
    summary = payload["summary"]
    lines = [
        "# 派生 format-3 留出磁定位验证",
        "",
        "本验证只使用 route13/14/15 的最近数据。每条路线首组负责距离校准和局部磁图，",
        "其余采集作为留出测试。定位器只接收已知起点、初始航向、惯性位移、测试磁观测",
        "和首组磁图；测试路线的中间锚点坐标仅在定位完成后用于计算误差和绘图。",
        "",
        "> 注意：这些 format-3 锚点由已知实验路线和转弯检测派生，并非现场手工测量锚点。",
        "> 结果可验证软件链路和路线内重复性，不能替代新采集的独立空间真值实验。",
        "",
        f"5 组留出测试的平均横向误差：PDR {summary['baseline_cross_track_mean_m']:.3f} m，"
        f"磁融合 {summary['fused_cross_track_mean_m']:.3f} m；",
        f"平均终点误差：PDR {summary['baseline_endpoint_mean_m']:.3f} m，"
        f"磁融合 {summary['fused_endpoint_mean_m']:.3f} m。",
        "",
        "| 数据 | 校准磁图 | PDR 横向 | 融合横向 | PDR 终点 | 融合终点 |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for run in payload["runs"]:
        lines.append(
            f"| {run['key']} | {run['calibration_capture']} | "
            f"{run['baseline']['cross_track_mean_m']:.3f} | "
            f"{run['magnetic_fused']['cross_track_mean_m']:.3f} | "
            f"{run['baseline']['endpoint_error_m']:.3f} | "
            f"{run['magnetic_fused']['endpoint_error_m']:.3f} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_plot(tracks: dict[str, tuple[np.ndarray, np.ndarray]], path: Path) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [item for item in RECENT_ROUTES if item.group == group]
        route = np.asarray(specs[0].points_m)
        axis.plot(route[:, 0], route[:, 1], "k--", linewidth=2.4, label="reference")
        for spec in specs:
            if spec.key not in tracks:
                continue
            baseline, fused = tracks[spec.key]
            axis.plot(baseline[:, 0], baseline[:, 1], ":", linewidth=1.6, label=f"{spec.key} PDR")
            axis.plot(fused[:, 0], fused[:, 1], linewidth=2.0, label=f"{spec.key} fused")
        axis.set_title(f"{group} held-out")
        axis.set_xlabel("X (m)")
        axis.set_ylabel("Y (m)")
        axis.set_aspect("equal", adjustable="box")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=7)
    figure.savefig(path, dpi=180)
    plt.close(figure)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--capture-root",
        type=Path,
        default=Path("results/geomag_v3_retrofit"),
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("results/geomag_v3_retrofit_validation"),
    )
    args = parser.parse_args()
    payload = run_retrofit_validation(args.capture_root, args.output_root)
    print(json.dumps(payload["summary"], ensure_ascii=False, indent=2))
    print(f"report={args.output_root / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
