"""Batch evaluation entry point for registered own-data captures."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from Geomag.branching import BranchConfig, run_own_branch
from Geomag.data_quality import audit_package
from Geomag.own_dataset_registry import (
    available_own_dataset_keys,
    default_own_evaluation_keys,
    get_own_dataset_spec,
)


def _metric(payload, *path):
    value = payload
    for key in path:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return None if value is None else float(value)


def _result_summary(payload):
    return {
        "steps_detected": int(payload["steps_detected"]),
        "pf_aligned_mean_m": _metric(payload, "pf_error_stats", "mean"),
        "pf_aligned_p95_m": _metric(payload, "pf_error_stats", "p95"),
        "pf_cross_track_mean_m": _metric(
            payload, "pf_cross_track_error_stats", "mean"
        ),
        "pf_endpoint_error_m": _metric(payload, "pf_endpoint_error_m"),
        "pf_raw_aligned_mean_m": _metric(payload, "pf_raw_error_stats", "mean"),
        "pf_raw_cross_track_mean_m": _metric(
            payload, "pf_raw_cross_track_error_stats", "mean"
        ),
        "pf_raw_endpoint_error_m": _metric(payload, "pf_raw_endpoint_error_m"),
        "pdr_aligned_mean_m": _metric(payload, "pdr_error_stats", "mean"),
        "pdr_cross_track_mean_m": _metric(
            payload, "pdr_cross_track_error_stats", "mean"
        ),
        "pdr_endpoint_error_m": _metric(payload, "pdr_endpoint_error_m"),
        "trajectory_png": payload.get("output_png"),
        "diagnostic_png": payload.get("diagnostic_png"),
        "result_json": payload.get("output_json"),
    }


def _aggregate(rows):
    metric_names = [
        "pf_aligned_mean_m",
        "pf_aligned_p95_m",
        "pf_cross_track_mean_m",
        "pf_endpoint_error_m",
        "pf_raw_aligned_mean_m",
        "pf_raw_cross_track_mean_m",
        "pf_raw_endpoint_error_m",
        "pdr_aligned_mean_m",
        "pdr_cross_track_mean_m",
        "pdr_endpoint_error_m",
    ]
    aggregate = {}
    for metric_name in metric_names:
        values = [
            row[metric_name]
            for row in rows.values()
            if row.get(metric_name) is not None
        ]
        aggregate[metric_name] = (
            None if not values else float(np.mean(np.asarray(values, dtype=float)))
        )
    return aggregate


def run_batch_evaluation(
    dataset_keys=None,
    output_dir="results/own_batch",
    include_provisional=False,
    map_profile="auto",
    map_offset_x_m=0.0,
    map_offset_y_m=0.0,
    heading_snap_deg=0.0,
    step_length_scale=1.0,
    progress_template_json=None,
    progress_correction_gain=0.0,
    smoothing_alpha=0.3,
    smoothing_mode="ema",
    vector_map_enabled=False,
    vector_map_path="data/processed/own_vector_map.npz",
    vector_weight=0.10,
    vector_angle_sigma_deg=25.0,
    vector_reject_deg=60.0,
    vector_norm_tolerance_ratio=0.35,
    alignment_mode="active_walk_uniform_speed",
    heading_method="gyro",
    quaternion_use_magnetometer=False,
    gyro_bias_stationary_min_duration_s=0.0,
    gyro_rate_scale=1.0,
    generate_plots=True,
):
    if dataset_keys is not None:
        keys = list(dataset_keys)
        selection_source = "explicit"
    elif include_provisional:
        keys = available_own_dataset_keys(
            evaluation_only=True,
            include_provisional=True,
        )
        selection_source = "all_evaluable"
    else:
        keys = default_own_evaluation_keys()
        selection_source = "manifest_default"
    output_root = Path(output_dir)
    output_root.mkdir(parents=True, exist_ok=True)
    quality = audit_package(
        dataset_keys=keys,
        output_json=output_root / "data_quality.json",
    )
    rows = {}
    skipped = {}
    for key in keys:
        quality_item = quality["datasets"][key]
        if quality_item["status"] == "fail":
            skipped[key] = [
                event["code"]
                for event in quality_item["events"]
                if event["severity"] == "error"
            ]
            continue

        spec = get_own_dataset_spec(key)
        result_json = output_root / f"{key}.json"
        result_png = output_root / f"{key}.png" if generate_plots else None
        payload = run_own_branch(
            BranchConfig(
                branch="own",
                own_profile="package",
                own_dataset_key=key,
                own_data_dir=spec["dataset_dir"],
                own_map_profile=str(map_profile),
                own_map_offset_x_m=float(map_offset_x_m),
                own_map_offset_y_m=float(map_offset_y_m),
                own_pf_smoothing_alpha=float(smoothing_alpha),
                own_pf_smoothing_mode=str(smoothing_mode),
                own_vector_map_enabled=bool(vector_map_enabled),
                own_vector_map_path=str(vector_map_path),
                own_vector_weight=float(vector_weight),
                own_vector_angle_sigma_deg=float(vector_angle_sigma_deg),
                own_vector_reject_deg=float(vector_reject_deg),
                own_vector_norm_tolerance_ratio=float(
                    vector_norm_tolerance_ratio
                ),
                own_alignment_mode=str(alignment_mode),
                own_heading_method=str(heading_method),
                own_quaternion_use_magnetometer=bool(
                    quaternion_use_magnetometer
                ),
                own_gyro_bias_stationary_min_duration_s=float(
                    gyro_bias_stationary_min_duration_s
                ),
                own_gyro_rate_scale=float(gyro_rate_scale),
                own_heading_snap_deg=float(heading_snap_deg),
                own_step_length_scale=float(step_length_scale),
                own_progress_template_json=progress_template_json,
                own_progress_correction_gain=float(progress_correction_gain),
                show=False,
                write_outputs=False,
                output_json=str(result_json),
                output_png=None if result_png is None else str(result_png),
            )
        )
        rows[key] = _result_summary(payload)

    confirmed_rows = {
        key: row
        for key, row in rows.items()
        if get_own_dataset_spec(key).get("evaluation_tier", "confirmed")
        == "confirmed"
    }
    provisional_rows = {
        key: row
        for key, row in rows.items()
        if get_own_dataset_spec(key).get("evaluation_tier", "confirmed")
        == "provisional"
    }
    report = {
        "format_version": "1.0",
        "configuration": {
            "dataset_keys": keys,
            "dataset_selection_source": selection_source,
            "include_provisional": bool(include_provisional),
            "map_profile": str(map_profile),
            "map_offset_xy_m": [
                float(map_offset_x_m),
                float(map_offset_y_m),
            ],
            "heading_snap_deg": float(heading_snap_deg),
            "step_length_scale": float(step_length_scale),
            "progress_template_json": progress_template_json,
            "progress_correction_gain": float(progress_correction_gain),
            "pf_smoothing_alpha": float(smoothing_alpha),
            "pf_smoothing_mode": str(smoothing_mode),
            "vector_map_enabled": bool(vector_map_enabled),
            "vector_map_path": str(vector_map_path),
            "vector_weight": float(vector_weight),
            "vector_angle_sigma_deg": float(vector_angle_sigma_deg),
            "vector_reject_deg": float(vector_reject_deg),
            "vector_norm_tolerance_ratio": float(
                vector_norm_tolerance_ratio
            ),
            "alignment_mode": str(alignment_mode),
            "heading_method": str(heading_method),
            "quaternion_use_magnetometer": bool(
                quaternion_use_magnetometer
            ),
            "gyro_bias_stationary_min_duration_s": float(
                gyro_bias_stationary_min_duration_s
            ),
            "gyro_rate_scale": float(gyro_rate_scale),
            "generate_plots": bool(generate_plots),
        },
        "quality_report": quality["output_json"],
        "evaluated": rows,
        "evaluated_confirmed": confirmed_rows,
        "evaluated_provisional": provisional_rows,
        "skipped": skipped,
        "aggregate_mean": _aggregate(confirmed_rows),
        "provisional_aggregate_mean": _aggregate(provisional_rows),
    }
    report_path = output_root / "summary.json"
    report["output_json"] = str(report_path)
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return report


def print_batch_summary(report):
    print(
        f"Batch evaluation: {len(report['evaluated'])} evaluated, "
        f"{len(report['skipped'])} skipped"
    )
    for key, row in report["evaluated"].items():
        print(
            f"- {key}: aligned={row['pf_aligned_mean_m']:.3f} m, "
            f"cross-track={row['pf_cross_track_mean_m']:.3f} m, "
            f"endpoint={row['pf_endpoint_error_m']:.3f} m"
        )
    for key, reasons in report["skipped"].items():
        print(f"- {key}: skipped ({', '.join(reasons)})")
    print(f"Saved summary: {report['output_json']}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Quality-gated batch evaluation for registered own data."
    )
    parser.add_argument(
        "datasets",
        nargs="*",
        help="Evaluable dataset keys. Omit to run all enabled datasets.",
    )
    parser.add_argument("--output-dir", default="results/own_batch")
    parser.add_argument(
        "--include-provisional",
        "--all-evaluable",
        dest="include_provisional",
        action="store_true",
        help=(
            "Run every evaluable capture instead of only the "
            "manifest-selected primary datasets."
        ),
    )
    parser.add_argument(
        "--map-profile",
        choices=["auto", "survey_kriging", "tile_manifest"],
        default="auto",
    )
    parser.add_argument("--map-offset-x-m", type=float, default=0.0)
    parser.add_argument("--map-offset-y-m", type=float, default=0.0)
    parser.add_argument("--heading-snap-deg", type=float, default=0.0)
    parser.add_argument("--step-length-scale", type=float, default=1.0)
    parser.add_argument("--progress-template-json", default=None)
    parser.add_argument("--progress-correction-gain", type=float, default=0.0)
    parser.add_argument("--smoothing-alpha", type=float, default=0.3)
    parser.add_argument(
        "--smoothing-mode",
        choices=["none", "ema", "motion_adaptive"],
        default="ema",
    )
    parser.add_argument(
        "--vector-map",
        action="store_true",
        help="Enable the experimental yaw-aligned three-axis likelihood.",
    )
    parser.add_argument(
        "--vector-map-path",
        default="data/processed/own_vector_map.npz",
    )
    parser.add_argument("--vector-weight", type=float, default=0.10)
    parser.add_argument("--vector-angle-sigma-deg", type=float, default=25.0)
    parser.add_argument("--vector-reject-deg", type=float, default=60.0)
    parser.add_argument(
        "--vector-norm-tolerance-ratio",
        type=float,
        default=0.35,
    )
    parser.add_argument(
        "--alignment-mode",
        choices=["active_walk_uniform_speed", "capture_time"],
        default="active_walk_uniform_speed",
    )
    parser.add_argument(
        "--heading-method",
        choices=["gyro", "quaternion", "q_fused", "tilt_compass"],
        default="gyro",
    )
    parser.add_argument(
        "--quaternion-use-magnetometer",
        action="store_true",
    )
    parser.add_argument(
        "--gyro-bias-stationary-min-duration-s",
        type=float,
        default=0.0,
    )
    parser.add_argument("--gyro-rate-scale", type=float, default=1.0)
    parser.add_argument(
        "--no-plots",
        action="store_true",
        help="Write JSON metrics only.",
    )
    args = parser.parse_args(argv)
    report = run_batch_evaluation(
        dataset_keys=args.datasets or None,
        output_dir=args.output_dir,
        include_provisional=args.include_provisional,
        map_profile=args.map_profile,
        map_offset_x_m=args.map_offset_x_m,
        map_offset_y_m=args.map_offset_y_m,
        heading_snap_deg=args.heading_snap_deg,
        step_length_scale=args.step_length_scale,
        progress_template_json=args.progress_template_json,
        progress_correction_gain=args.progress_correction_gain,
        smoothing_alpha=args.smoothing_alpha,
        smoothing_mode=args.smoothing_mode,
        vector_map_enabled=args.vector_map,
        vector_map_path=args.vector_map_path,
        vector_weight=args.vector_weight,
        vector_angle_sigma_deg=args.vector_angle_sigma_deg,
        vector_reject_deg=args.vector_reject_deg,
        vector_norm_tolerance_ratio=args.vector_norm_tolerance_ratio,
        alignment_mode=args.alignment_mode,
        heading_method=args.heading_method,
        quaternion_use_magnetometer=args.quaternion_use_magnetometer,
        gyro_bias_stationary_min_duration_s=(
            args.gyro_bias_stationary_min_duration_s
        ),
        gyro_rate_scale=args.gyro_rate_scale,
        generate_plots=not args.no_plots,
    )
    print_batch_summary(report)
    return 0 if report["evaluated"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
