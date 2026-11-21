"""Quality checks for phone-based own-data captures.

The checker deliberately separates hard data-integrity failures from protocol
warnings.  Older captures can therefore remain usable for experiments while
making missing stationary windows or event annotations visible.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
from typing import Any

import numpy as np

REQUIRED_STREAMS = {
    "accelerometer": "Accelerometer.csv",
    "gyroscope": "Gyroscope.csv",
    "magnetometer": "Magnetometer.csv",
}
OPTIONAL_STREAMS = {"location": "Location.csv"}


def _jsonable(value: Any):
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


def _write_json(path, payload):
    if path is None:
        return None
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(_jsonable(payload), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return str(output_path)


def load_package_manifest(package_root=None):
    root = (
        Path(package_root)
        if package_root is not None
        else Path(__file__).resolve().parent.parent / "data" / "own_data_package"
    )
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Own-data manifest does not exist: {manifest_path}")
    with manifest_path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    if not isinstance(manifest.get("datasets"), dict):
        raise ValueError(f"Own-data manifest has no datasets object: {manifest_path}")
    return root.resolve(), manifest


def _load_numeric_stream(path, min_columns=4):
    rows = []
    headers = []
    with Path(path).open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        try:
            headers = next(reader)
        except StopIteration:
            return headers, np.empty((0, min_columns), dtype=float)
        for row in reader:
            if len(row) < min_columns:
                continue
            try:
                rows.append([float(value) for value in row])
            except ValueError:
                continue
    if not rows:
        return headers, np.empty((0, max(min_columns, len(headers))), dtype=float)
    width = min(len(row) for row in rows)
    return headers[:width], np.asarray([row[:width] for row in rows], dtype=float)


def _stream_statistics(path):
    headers, values = _load_numeric_stream(path)
    if values.shape[0] == 0:
        return {
            "path": str(Path(path)),
            "headers": headers,
            "sample_count": 0,
            "finite_ratio": 0.0,
            "time_monotonic": False,
        }

    time_s = values[:, 0]
    delta_s = np.diff(time_s)
    positive_delta_s = delta_s[delta_s > 0.0]
    median_dt_s = (
        float(np.median(positive_delta_s)) if positive_delta_s.size else None
    )
    gap_threshold_s = (
        max(0.1, 3.0 * median_dt_s) if median_dt_s is not None else None
    )
    duration_s = float(time_s[-1] - time_s[0])
    return {
        "path": str(Path(path)),
        "headers": headers,
        "sample_count": int(values.shape[0]),
        "column_count": int(values.shape[1]),
        "start_time_s": float(time_s[0]),
        "end_time_s": float(time_s[-1]),
        "duration_s": duration_s,
        "finite_ratio": float(np.mean(np.isfinite(values))),
        "time_monotonic": bool(np.all(delta_s > 0.0)),
        "non_positive_delta_count": int(np.count_nonzero(delta_s <= 0.0)),
        "median_dt_s": median_dt_s,
        "sample_rate_hz": (
            None if median_dt_s in {None, 0.0} else float(1.0 / median_dt_s)
        ),
        "p95_gap_s": (
            None if positive_delta_s.size == 0 else float(np.percentile(positive_delta_s, 95))
        ),
        "max_gap_s": (
            None if positive_delta_s.size == 0 else float(np.max(positive_delta_s))
        ),
        "large_gap_threshold_s": gap_threshold_s,
        "large_gap_count": (
            0
            if gap_threshold_s is None
            else int(np.count_nonzero(positive_delta_s > gap_threshold_s))
        ),
    }


def _window(values, side, duration_s):
    if values.shape[0] == 0:
        return values
    time_s = values[:, 0]
    if side == "start":
        return values[time_s <= time_s[0] + duration_s]
    return values[time_s >= time_s[-1] - duration_s]


def _stationary_statistics(accelerometer, gyroscope, side, duration_s):
    acc_window = _window(accelerometer, side, duration_s)
    gyro_window = _window(gyroscope, side, duration_s)
    if acc_window.shape[0] < 2 or gyro_window.shape[0] < 2:
        return {
            "duration_s": float(duration_s),
            "stationary": False,
            "reason": "not_enough_samples",
        }

    acc_norm = np.linalg.norm(acc_window[:, 1:4], axis=1)
    gyro_norm = np.linalg.norm(gyro_window[:, 1:4], axis=1)
    acc_norm_std = float(np.std(acc_norm))
    gyro_norm_rms = float(np.sqrt(np.mean(np.square(gyro_norm))))
    # These conservative thresholds are intended to recognize a phone resting
    # in the hand, not merely smooth walking.
    stationary = acc_norm_std <= 0.25 and gyro_norm_rms <= 0.20
    return {
        "duration_s": float(duration_s),
        "acc_sample_count": int(acc_window.shape[0]),
        "gyro_sample_count": int(gyro_window.shape[0]),
        "acc_norm_mean_mps2": float(np.mean(acc_norm)),
        "acc_norm_std_mps2": acc_norm_std,
        "gyro_norm_rms_radps": gyro_norm_rms,
        "stationary": bool(stationary),
    }


def _route_geometry(manifest, dataset):
    route_label = dataset.get("route_label")
    route_key = dataset.get("route_key", f"{route_label}_tile_vertices")
    vertices = manifest.get("routes", {}).get(route_key)
    if not vertices or len(vertices) < 2:
        return None

    tile_size_x_m = float(manifest.get("map", {}).get("tile_size_x_m", 1.0))
    tile_size_y_m = float(manifest.get("map", {}).get("tile_size_y_m", 1.0))
    points = np.asarray(
        [
            [float(vertex[0]) * tile_size_x_m, float(vertex[1]) * tile_size_y_m]
            for vertex in vertices
        ],
        dtype=float,
    )
    segments = np.diff(points, axis=0)
    headings = np.arctan2(segments[:, 1], segments[:, 0])
    turns = []
    for previous, current in zip(headings[:-1], headings[1:], strict=False):
        turns.append(
            math.degrees(math.atan2(math.sin(current - previous), math.cos(current - previous)))
        )
    return {
        "route_key": route_key,
        "vertices": [[float(x), float(y)] for x, y in points],
        "length_m": float(np.sum(np.linalg.norm(segments, axis=1))),
        "expected_turn_count": int(len(turns)),
        "expected_turns_deg": [float(value) for value in turns],
        "expected_signed_yaw_deg": float(sum(turns)),
    }


def _event(severity, code, message, **details):
    item = {"severity": severity, "code": code, "message": message}
    if details:
        item["details"] = details
    return item


def audit_dataset(dataset_key, package_root=None, stationary_window_s=None):
    root, manifest = load_package_manifest(package_root)
    if dataset_key not in manifest["datasets"]:
        raise ValueError(
            f"Unknown own dataset key: {dataset_key}. "
            f"Available keys: {sorted(manifest['datasets'])}"
        )

    dataset = dict(manifest["datasets"][dataset_key])
    dataset_dir = root / dataset.get(
        "dataset_path", dataset.get("folder_name", dataset_key)
    )
    protocol = dict(manifest.get("capture_protocol", {}))
    duration_s = float(
        stationary_window_s
        if stationary_window_s is not None
        else protocol.get("stationary_window_s", 3.0)
    )
    events = []
    streams = {}
    arrays = {}
    metadata_path = dataset_dir / dataset.get(
        "capture_metadata_file", "capture_metadata.json"
    )
    metadata_source = "manifest"
    metadata = dict(dataset.get("capture_metadata", {}))
    if metadata_path.is_file():
        metadata_source = str(metadata_path.resolve())
        try:
            with metadata_path.open(encoding="utf-8") as handle:
                metadata = json.load(handle)
        except (json.JSONDecodeError, OSError) as exc:
            metadata = {}
            events.append(
                _event(
                    "error",
                    "invalid_capture_metadata",
                    "采集元信息文件无法读取",
                    path=str(metadata_path),
                    error=str(exc),
                )
            )
    if not metadata:
        events.append(
            _event(
                "error",
                "missing_capture_metadata",
                "缺少采集元信息；请从 capture_metadata.template.json 创建",
            )
        )
    elif metadata.get("recording_status") != "legacy_unannotated":
        required_metadata = {
            "dataset_key",
            "route_label",
            "device_pose",
            "start_stationary_s",
            "end_stationary_s",
            "finish_behavior",
            "turn_events",
        }
        missing_fields = sorted(required_metadata - metadata.keys())
        if missing_fields:
            events.append(
                _event(
                    "error",
                    "incomplete_capture_metadata",
                    "采集元信息缺少必需字段",
                    missing_fields=missing_fields,
                )
            )
        if metadata.get("dataset_key") not in {None, dataset_key}:
            events.append(
                _event(
                    "error",
                    "metadata_dataset_key_mismatch",
                    "采集元信息中的 dataset_key 与目录注册不一致",
                    observed=metadata.get("dataset_key"),
                    expected=dataset_key,
                )
            )
        if metadata.get("route_label") not in {None, dataset.get("route_label")}:
            events.append(
                _event(
                    "error",
                    "metadata_route_label_mismatch",
                    "采集元信息中的 route_label 与注册路线不一致",
                    observed=metadata.get("route_label"),
                    expected=dataset.get("route_label"),
                )
            )
        for field in ("start_stationary_s", "end_stationary_s"):
            observed = metadata.get(field)
            if isinstance(observed, (int, float)) and float(observed) < duration_s:
                events.append(
                    _event(
                        "warning",
                        "declared_stationary_window_too_short",
                        f"{field} 小于协议要求的 {duration_s:g} 秒",
                        field=field,
                        observed_s=float(observed),
                    )
                )

    for stream_name, filename in {**REQUIRED_STREAMS, **OPTIONAL_STREAMS}.items():
        path = dataset_dir / filename
        if not path.is_file():
            if stream_name in REQUIRED_STREAMS:
                events.append(
                    _event("error", "missing_stream", f"缺少必需传感器文件 {filename}")
                )
            continue
        stats = _stream_statistics(path)
        streams[stream_name] = stats
        if stream_name in REQUIRED_STREAMS:
            _, arrays[stream_name] = _load_numeric_stream(path)
            if stats["sample_count"] < 2:
                events.append(
                    _event("error", "empty_stream", f"{filename} 没有足够的有效数据")
                )
            if not stats["time_monotonic"]:
                events.append(
                    _event("error", "non_monotonic_time", f"{filename} 时间戳不严格递增")
                )
            if stats["finite_ratio"] < 0.999:
                events.append(
                    _event(
                        "warning",
                        "non_finite_values",
                        f"{filename} 含有非有限值",
                        finite_ratio=stats["finite_ratio"],
                    )
                )
            if stats.get("large_gap_count", 0) > 0:
                events.append(
                    _event(
                        "warning",
                        "large_time_gap",
                        f"{filename} 出现异常采样间隔",
                        count=stats["large_gap_count"],
                        max_gap_s=stats.get("max_gap_s"),
                    )
                )

    overlap = None
    stationary = None
    yaw = None
    route = _route_geometry(manifest, dataset)
    if all(name in arrays and arrays[name].shape[0] >= 2 for name in REQUIRED_STREAMS):
        required_stats = [streams[name] for name in REQUIRED_STREAMS]
        overlap_start_s = max(item["start_time_s"] for item in required_stats)
        overlap_end_s = min(item["end_time_s"] for item in required_stats)
        union_start_s = min(item["start_time_s"] for item in required_stats)
        union_end_s = max(item["end_time_s"] for item in required_stats)
        overlap_duration_s = max(0.0, overlap_end_s - overlap_start_s)
        union_duration_s = max(0.0, union_end_s - union_start_s)
        overlap_ratio = overlap_duration_s / union_duration_s if union_duration_s else 0.0
        overlap = {
            "start_time_s": float(overlap_start_s),
            "end_time_s": float(overlap_end_s),
            "duration_s": float(overlap_duration_s),
            "ratio": float(overlap_ratio),
        }
        if overlap_ratio < 0.98:
            events.append(
                _event(
                    "error",
                    "insufficient_stream_overlap",
                    "加速度计、陀螺仪和磁力计的有效时间重叠不足",
                    overlap_ratio=overlap_ratio,
                )
            )

        stationary = {
            "start": _stationary_statistics(
                arrays["accelerometer"], arrays["gyroscope"], "start", duration_s
            ),
            "end": _stationary_statistics(
                arrays["accelerometer"], arrays["gyroscope"], "end", duration_s
            ),
        }
        for side, label in (("start", "开始"), ("end", "结束")):
            if not stationary[side]["stationary"]:
                events.append(
                    _event(
                        "warning",
                        f"{side}_not_stationary",
                        f"记录{label}的 {duration_s:g} 秒不满足静止标定条件",
                        acc_norm_std_mps2=stationary[side].get("acc_norm_std_mps2"),
                        gyro_norm_rms_radps=stationary[side].get("gyro_norm_rms_radps"),
                    )
                )

        gyro = arrays["gyroscope"]
        integrated_z_rad = float(
            np.sum(
                0.5
                * (gyro[:-1, 3] + gyro[1:, 3])
                * np.diff(gyro[:, 0])
            )
        )
        integrated_z_deg = float(math.degrees(integrated_z_rad))
        yaw = {"integrated_device_z_deg": integrated_z_deg}
        if route is not None:
            expected_yaw_deg = route["expected_signed_yaw_deg"]
            yaw_error_deg = abs(integrated_z_deg - expected_yaw_deg)
            yaw.update(
                {
                    "expected_route_yaw_deg": expected_yaw_deg,
                    "absolute_error_deg": float(yaw_error_deg),
                    "interpretation": "diagnostic_only_device_z",
                }
            )
            if yaw_error_deg > 45.0:
                events.append(
                    _event(
                        "warning",
                        "route_yaw_mismatch",
                        "设备 Z 轴累计转角与注册路线差异较大，需核对路线或手机姿态",
                        expected_deg=expected_yaw_deg,
                        observed_deg=integrated_z_deg,
                        absolute_error_deg=yaw_error_deg,
                    )
                )

        if route is not None and overlap_duration_s > 0.0:
            nominal_speed_mps = route["length_m"] / overlap_duration_s
            route["nominal_speed_mps"] = float(nominal_speed_mps)
            if not 0.3 <= nominal_speed_mps <= 2.0:
                events.append(
                    _event(
                        "warning",
                        "implausible_nominal_speed",
                        "注册路线长度与采集时长得到的名义速度异常",
                        nominal_speed_mps=nominal_speed_mps,
                    )
                )

    evaluation_enabled = bool(dataset.get("evaluation_enabled", True))
    evaluation_tier = str(
        dataset.get(
            "evaluation_tier",
            "confirmed" if evaluation_enabled else "excluded",
        )
    ).lower()
    if not evaluation_enabled:
        events.append(
            _event(
                "error",
                "evaluation_disabled",
                dataset.get("data_issue") or "该数据集已被人工排除在路线评测之外",
            )
        )
    elif evaluation_tier == "provisional":
        events.append(
            _event(
                "warning",
                "provisional_route_assignment",
                dataset.get("data_issue")
                or "该数据集的路线身份尚未得到采集者确认，只能单独报告",
            )
        )

    if not metadata.get("turn_events"):
        constant_speed = metadata.get("walking_speed_profile") in {
            "approximately_constant",
            "controlled_constant",
        }
        events.append(
            _event(
                "info" if constant_speed else "warning",
                "turn_events_missing",
                (
                    "没有人工转弯时间；本受控数据将按有效行走时间和路线距离比例对齐"
                    if constant_speed
                    else "没有记录人工转弯时间；无法精确评估转弯时刻"
                ),
            )
        )
    if metadata.get("recording_status") == "legacy_unannotated":
        events.append(
            _event(
                "warning",
                "legacy_metadata",
                "这是旧格式采集，部分协议字段只能标记为未知",
            )
        )

    severities = {event["severity"] for event in events}
    status = (
        "fail"
        if "error" in severities
        else "warning"
        if "warning" in severities
        else "pass"
    )
    return {
        "dataset_key": dataset_key,
        "dataset_dir": str(dataset_dir.resolve()),
        "status": status,
        "evaluation_enabled": evaluation_enabled,
        "evaluation_tier": evaluation_tier,
        "route_label": dataset.get("route_label"),
        "assignment_confidence": dataset.get("assignment_confidence"),
        "capture_metadata": metadata,
        "capture_metadata_source": metadata_source,
        "streams": streams,
        "stream_overlap": overlap,
        "stationary_windows": stationary,
        "route": route,
        "yaw_check": yaw,
        "events": events,
    }


def audit_package(dataset_keys=None, package_root=None, output_json=None):
    root, manifest = load_package_manifest(package_root)
    keys = sorted(manifest["datasets"]) if dataset_keys is None else list(dataset_keys)
    reports = [audit_dataset(key, package_root=root) for key in keys]
    summary = {
        "dataset_count": len(reports),
        "pass_count": sum(report["status"] == "pass" for report in reports),
        "warning_count": sum(report["status"] == "warning" for report in reports),
        "fail_count": sum(report["status"] == "fail" for report in reports),
        "blocking_fail_count": sum(
            report["status"] == "fail"
            and report["evaluation_enabled"]
            and report["evaluation_tier"] == "confirmed"
            for report in reports
        ),
        "evaluable_keys": [
            report["dataset_key"]
            for report in reports
            if report["evaluation_enabled"]
            and report["evaluation_tier"] == "confirmed"
            and report["status"] != "fail"
        ],
        "provisional_keys": [
            report["dataset_key"]
            for report in reports
            if report["evaluation_enabled"]
            and report["evaluation_tier"] == "provisional"
            and report["status"] != "fail"
        ],
    }
    payload = {
        "format_version": "1.0",
        "package_root": str(root),
        "manifest_format_version": manifest.get("format_version"),
        "summary": summary,
        "datasets": {report["dataset_key"]: report for report in reports},
    }
    payload["output_json"] = (
        None if output_json is None else str(Path(output_json))
    )
    _write_json(output_json, payload)
    return payload


def print_audit_summary(report):
    summary = report["summary"]
    print(
        "Data quality: "
        f"{summary['dataset_count']} datasets, "
        f"{summary['fail_count']} failed, "
        f"{summary['blocking_fail_count']} blocking, "
        f"{summary['warning_count']} with warnings, "
        f"{summary['pass_count']} passed"
    )
    for key, item in report["datasets"].items():
        codes = ", ".join(event["code"] for event in item["events"]) or "none"
        print(f"- {key}: {item['status']} ({codes})")
    if report.get("output_json"):
        print(f"Saved report: {report['output_json']}")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Audit own-data sensor integrity and capture protocol."
    )
    parser.add_argument(
        "datasets",
        nargs="*",
        help="Dataset keys. Omit to audit every dataset in the package.",
    )
    parser.add_argument(
        "--package-root",
        default=None,
        help="Directory containing manifest.json and dataset folders.",
    )
    parser.add_argument(
        "--output-json",
        default="results/own_data_quality.json",
        help="Quality report path. Use an empty value to disable writing.",
    )
    args = parser.parse_args(argv)
    report = audit_package(
        dataset_keys=args.datasets or None,
        package_root=args.package_root,
        output_json=args.output_json or None,
    )
    print_audit_summary(report)
    return 1 if report["summary"]["blocking_fail_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
