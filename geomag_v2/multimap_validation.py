"""Leave-one-capture-out validation of repeat-survey magnetic maps."""

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
    build_multi_activity_anchored_map,
    localize_free_track,
    resample_magnetic_observations,
)


def _fit_without(loaded: dict[str, dict], excluded_key: str) -> RidgeDistanceModel:
    observations: list[FreeSegment] = []
    distances = []
    for spec in RECENT_ROUTES:
        if spec.key == excluded_key:
            continue
        observations.extend(loaded[spec.key]["segments"])
        distances.extend(spec.segment_lengths_m)
    return RidgeDistanceModel.fit(observations, np.asarray(distances))


def _metrics(track: np.ndarray, route: np.ndarray, corners: np.ndarray) -> dict:
    cross_track = _cross_track_error(track, route)
    corner_error = np.linalg.norm(track[corners] - route, axis=1)
    return {
        "cross_track_mean_m": float(np.mean(cross_track)),
        "cross_track_p95_m": float(np.percentile(cross_track, 95)),
        "endpoint_error_m": float(np.linalg.norm(track[-1] - route[-1])),
        "corner_error_mean_m": float(np.mean(corner_error)),
        "corner_error_max_m": float(np.max(corner_error)),
    }


def _seed(key: str) -> int:
    return 20260808 + sum((index + 1) * ord(value) for index, value in enumerate(key))


def run_multimap_validation(capture_root: Path, output_root: Path) -> dict:
    capture_root = Path(capture_root)
    output_root = Path(output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    map_root = output_root / "maps"
    map_root.mkdir(exist_ok=True)
    loaded = {}
    for spec in RECENT_ROUTES:
        capture = load_capture(capture_root / f"{spec.key}.geomagcapture")
        _, segments = segment_free_motion(capture, include_trailing_segment=False)
        loaded[spec.key] = {"capture": capture, "segments": segments}

    runs = []
    tracks = {}
    for test_spec in RECENT_ROUTES:
        calibration_specs = [
            spec
            for spec in RECENT_ROUTES
            if spec.group == test_spec.group and spec.key != test_spec.key
        ]
        magnetic_map = build_multi_activity_anchored_map(
            [
                (loaded[spec.key]["capture"], loaded[spec.key]["segments"])
                for spec in calibration_specs
            ]
        )
        magnetic_map.save(map_root / f"without_{test_spec.key}.npz")
        model = _fit_without(loaded, test_spec.key)
        item = loaded[test_spec.key]
        capture = item["capture"]
        segments = item["segments"]
        assert capture.spatial_reference is not None
        lengths = model.predict(segments)
        inertial, corners = integrate_free_track(
            segments,
            lengths,
            initial_heading_rad=np.radians(capture.spatial_reference.initial_heading_deg),
        )
        start = np.asarray(capture.spatial_reference.start_position_xy_m)
        baseline = inertial + start
        localization = localize_free_track(
            inertial,
            resample_magnetic_observations(capture, segments),
            magnetic_map,
            start_position_xy_m=capture.spatial_reference.start_position_xy_m,
            segment_boundary_indices=corners[1:-1],
            config=ParticleFilterConfig(random_seed=_seed(test_spec.key)),
        )
        route = np.asarray(test_spec.points_m, dtype=float)
        run = {
            "key": test_spec.key,
            "group": test_spec.group,
            "role": "leave_one_capture_out_test",
            "map_calibration_captures": [spec.key for spec in calibration_specs],
            "map_repeat_count": len(calibration_specs),
            "distance_training_captures": [
                spec.key for spec in RECENT_ROUTES if spec.key != test_spec.key
            ],
            "test_capture_used_for_map_or_distance_training": False,
            "test_intermediate_coordinates_used_by_localizer": False,
            "estimated_segment_lengths_m": lengths.tolist(),
            "baseline": _metrics(baseline, route, corners),
            "magnetic_fused": _metrics(localization.track_xy_m, route, corners),
            "particle_filter": {
                "resample_count": localization.resample_count,
                "mean_map_distance_m": localization.mean_map_distance_m,
                "mean_magnetic_residual_ut": localization.mean_magnetic_residual_ut,
                "mean_step_scale": localization.mean_step_scale,
                "mean_heading_bias_deg": localization.mean_heading_bias_deg,
                "observation_feature_offset_ut": (
                    localization.observation_feature_offset_ut.tolist()
                ),
            },
        }
        run["cross_track_improvement_m"] = (
            run["baseline"]["cross_track_mean_m"]
            - run["magnetic_fused"]["cross_track_mean_m"]
        )
        run["endpoint_improvement_m"] = (
            run["baseline"]["endpoint_error_m"]
            - run["magnetic_fused"]["endpoint_error_m"]
        )
        runs.append(run)
        tracks[test_spec.key] = (baseline, localization.track_xy_m)
        _write_csv(output_root / f"{test_spec.key}_track.csv", baseline, localization.track_xy_m)

    original_validation = [run for run in runs if run["key"] not in CALIBRATION_KEYS]
    payload = {
        "format_version": "geomag-v2-repeat-map-loocv-1",
        "data_policy": "recent_route_13_14_15_only",
        "protocol": {
            "method": "leave_one_capture_out",
            "test_capture_excluded_from_its_map": True,
            "test_capture_excluded_from_distance_training": True,
            "reference_coordinates": "evaluation_only_after_localization",
            "magnetic_features": ["magnitude", "vertical_component"],
            "known_start_feature_offset_calibration": True,
            "particle_states": ["position", "step_scale", "heading_bias"],
        },
        "all_eight_summary": _summary(runs),
        "original_five_summary": _summary(original_validation),
        "runs": runs,
    }
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_report(payload, output_root / "report.md")
    _write_plot(tracks, output_root / "leave_one_out_tracks.png")
    return payload


def _summary(runs: list[dict]) -> dict:
    return {
        "run_count": len(runs),
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


def _write_csv(path: Path, baseline: np.ndarray, fused: np.ndarray) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["sample", "pdr_x_m", "pdr_y_m", "fused_x_m", "fused_y_m"])
        for index, (pdr, corrected) in enumerate(zip(baseline, fused, strict=True)):
            writer.writerow([index, pdr[0], pdr[1], corrected[0], corrected[1]])


def _write_report(payload: dict, path: Path) -> None:
    summary = payload["all_eight_summary"]
    lines = [
        "# 多次建图逐次留一验证",
        "",
        "每次都将待测采集从磁图和距离训练中完全排除。同路线其余采集经过等进度",
        "重采样后共同建图；route13/15 每折使用两次建图，route14 因仅有两组数据，",
        "每折仍只能使用一次建图。测试路线坐标只在定位结束后用于计算误差。",
        "",
        f"全部 8 折平均横向误差：PDR {summary['baseline_cross_track_mean_m']:.3f} m，"
        f"磁融合 {summary['fused_cross_track_mean_m']:.3f} m；平均终点误差："
        f"PDR {summary['baseline_endpoint_mean_m']:.3f} m，"
        f"磁融合 {summary['fused_endpoint_mean_m']:.3f} m。",
        "",
        "| 测试数据 | 建图数据 | PDR 横向 | 融合横向 | PDR 终点 | 融合终点 |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for run in payload["runs"]:
        lines.append(
            f"| {run['key']} | {', '.join(run['map_calibration_captures'])} | "
            f"{run['baseline']['cross_track_mean_m']:.3f} | "
            f"{run['magnetic_fused']['cross_track_mean_m']:.3f} | "
            f"{run['baseline']['endpoint_error_m']:.3f} | "
            f"{run['magnetic_fused']['endpoint_error_m']:.3f} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_plot(tracks: dict[str, tuple[np.ndarray, np.ndarray]], path: Path) -> None:
    figure, axes = plt.subplots(1, 3, figsize=(16, 5.4), constrained_layout=True)
    for axis, group in zip(axes, ("route_13", "route_14", "route_15"), strict=True):
        specs = [spec for spec in RECENT_ROUTES if spec.group == group]
        route = np.asarray(specs[0].points_m)
        axis.plot(route[:, 0], route[:, 1], "k--", linewidth=2.4, label="reference")
        for spec in specs:
            baseline, fused = tracks[spec.key]
            axis.plot(baseline[:, 0], baseline[:, 1], ":", linewidth=1.3, label=f"{spec.key} PDR")
            axis.plot(fused[:, 0], fused[:, 1], linewidth=1.9, label=f"{spec.key} fused")
        axis.set_title(f"{group} leave-one-out")
        axis.set_xlabel("X (m)")
        axis.set_ylabel("Y (m)")
        axis.set_aspect("equal", adjustable="box")
        axis.grid(alpha=0.25)
        axis.legend(fontsize=6.5)
    figure.savefig(path, dpi=180)
    plt.close(figure)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--capture-root", type=Path, default=Path("results/geomag_v3_retrofit")
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("results/geomag_v3_multimap_validation"),
    )
    args = parser.parse_args()
    payload = run_multimap_validation(args.capture_root, args.output_root)
    print(json.dumps(payload["all_eight_summary"], ensure_ascii=False, indent=2))
    print(f"report={args.output_root / 'report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
