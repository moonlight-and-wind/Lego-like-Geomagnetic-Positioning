"""Audit native iPhone ``.geomagcapture`` packages.

The iPhone capture format deliberately keeps both the raw hardware magnetic
stream and Core Motion's calibrated field.  This audit makes the distinction
explicit so an apparently complete package cannot silently feed a large raw
hard-iron offset into the positioning algorithm.
"""

from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
import re
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np

STREAM_FILES = {
    "accelerometer": "Accelerometer.csv",
    "gyroscope": "Gyroscope.csv",
    "magnetometer_raw": "Magnetometer.csv",
    "device_motion": "DeviceMotion.csv",
}
MAGNETIC_ACCURACY_LABELS = {-1: "uncalibrated", 0: "low", 1: "medium", 2: "high"}


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


def _load_numeric_csv(path: Path, minimum_columns: int) -> tuple[list[str], np.ndarray]:
    rows: list[list[float]] = []
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        try:
            headers = next(reader)
        except StopIteration:
            return [], np.empty((0, minimum_columns), dtype=float)
        for row in reader:
            if len(row) < minimum_columns:
                continue
            try:
                values = [float(token) for token in row]
            except ValueError:
                continue
            if len(values) >= minimum_columns:
                rows.append(values)
    if not rows:
        return headers, np.empty((0, max(minimum_columns, len(headers))), dtype=float)
    width = min(len(row) for row in rows)
    return headers[:width], np.asarray([row[:width] for row in rows], dtype=float)


def _stream_statistics(values: np.ndarray) -> dict[str, Any]:
    if values.shape[0] < 2:
        return {
            "sample_count": int(values.shape[0]),
            "finite_ratio": float(np.mean(np.isfinite(values))) if values.size else 0.0,
            "time_monotonic": False,
        }
    time_s = values[:, 0]
    deltas = np.diff(time_s)
    positive = deltas[deltas > 0]
    median_dt = float(np.median(positive)) if positive.size else None
    gap_threshold = max(0.05, 5 * median_dt) if median_dt else None
    return {
        "sample_count": int(values.shape[0]),
        "column_count": int(values.shape[1]),
        "start_time_s": float(time_s[0]),
        "end_time_s": float(time_s[-1]),
        "duration_s": float(time_s[-1] - time_s[0]),
        "finite_ratio": float(np.mean(np.isfinite(values))),
        "time_monotonic": bool(np.all(deltas > 0)),
        "non_positive_delta_count": int(np.count_nonzero(deltas <= 0)),
        "median_interval_s": median_dt,
        "sample_rate_hz": None if not median_dt else float(1 / median_dt),
        "p95_interval_s": float(np.percentile(positive, 95)) if positive.size else None,
        "max_interval_s": float(np.max(positive)) if positive.size else None,
        "gap_threshold_s": gap_threshold,
        "large_gap_count": (
            0 if gap_threshold is None else int(np.count_nonzero(positive > gap_threshold))
        ),
    }


def _window(values: np.ndarray, side: str, duration_s: float) -> np.ndarray:
    if values.shape[0] == 0:
        return values
    if side == "start":
        return values[values[:, 0] <= values[0, 0] + duration_s]
    return values[values[:, 0] >= values[-1, 0] - duration_s]


def _stationary_window(
    accelerometer: np.ndarray,
    gyroscope: np.ndarray,
    side: str,
    duration_s: float,
) -> dict[str, Any]:
    acc = _window(accelerometer, side, duration_s)
    gyro = _window(gyroscope, side, duration_s)
    if acc.shape[0] < 2 or gyro.shape[0] < 2:
        return {"stationary": False, "reason": "insufficient_samples"}
    acceleration_norm = np.linalg.norm(acc[:, 1:4], axis=1)
    angular_rate_norm = np.linalg.norm(gyro[:, 1:4], axis=1)
    acc_std = float(np.std(acceleration_norm))
    gyro_rms = float(np.sqrt(np.mean(np.square(angular_rate_norm))))
    return {
        "duration_s": float(duration_s),
        "accelerometer_samples": int(acc.shape[0]),
        "gyroscope_samples": int(gyro.shape[0]),
        "acceleration_norm_mean_mps2": float(np.mean(acceleration_norm)),
        "acceleration_norm_std_mps2": acc_std,
        "angular_rate_rms_radps": gyro_rms,
        "stationary": bool(acc_std <= 0.25 and gyro_rms <= 0.20),
    }


def _magnetic_statistics(vectors: np.ndarray) -> dict[str, Any]:
    magnitude = np.linalg.norm(vectors, axis=1)
    return {
        "sample_count": int(magnitude.size),
        "minimum_ut": float(np.min(magnitude)),
        "median_ut": float(np.median(magnitude)),
        "p95_ut": float(np.percentile(magnitude, 95)),
        "maximum_ut": float(np.max(magnitude)),
        "outside_20_to_100_ut_ratio": float(np.mean((magnitude < 20) | (magnitude > 100))),
    }


def _event(severity: str, code: str, message: str, **details: Any) -> dict[str, Any]:
    event: dict[str, Any] = {"severity": severity, "code": code, "message": message}
    if details:
        event["details"] = details
    return event


def audit_capture(package: str | Path, stationary_window_s: float = 3.0) -> dict[str, Any]:
    package_path = Path(package)
    events: list[dict[str, Any]] = []
    arrays: dict[str, np.ndarray] = {}
    headers: dict[str, list[str]] = {}
    stream_stats: dict[str, dict[str, Any]] = {}

    for name, filename in STREAM_FILES.items():
        if name == "magnetometer_raw" and (package_path / "MagnetometerRaw.csv").is_file():
            filename = "MagnetometerRaw.csv"
        path = package_path / filename
        minimum_columns = 21 if name == "device_motion" else 4
        if not path.is_file():
            events.append(_event("error", "missing_stream", f"缺少 {filename}"))
            continue
        try:
            header, values = _load_numeric_csv(path, minimum_columns)
        except OSError as exc:
            events.append(_event("error", "unreadable_stream", f"无法读取 {filename}", error=str(exc)))
            continue
        headers[name] = header
        arrays[name] = values
        stats = _stream_statistics(values)
        stream_stats[name] = stats
        if stats["sample_count"] < 20:
            events.append(_event("error", "insufficient_samples", f"{filename} 样本不足"))
        if not stats["time_monotonic"]:
            events.append(_event("error", "non_monotonic_time", f"{filename} 时间戳不严格递增"))
        if stats["finite_ratio"] < 0.999:
            events.append(_event("error", "non_finite_values", f"{filename} 含非有限数值"))
        if stats.get("large_gap_count", 0):
            events.append(
                _event(
                    "warning",
                    "sampling_gap",
                    f"{filename} 存在较大采样间隔",
                    count=stats["large_gap_count"],
                    maximum_s=stats.get("max_interval_s"),
                )
            )

    dataset_metadata: dict[str, Any] = {}
    capture_metadata: dict[str, Any] = {}
    for filename, destination in (
        ("geomag_dataset.json", dataset_metadata),
        ("capture_metadata.json", capture_metadata),
    ):
        try:
            destination.update(json.loads((package_path / filename).read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as exc:
            events.append(_event("error", "invalid_metadata", f"无法读取 {filename}", error=str(exc)))

    dataset_key = str(dataset_metadata.get("dataset_key") or package_path.stem)
    expected_name = f"{dataset_key}.geomagcapture"
    if package_path.name != expected_name:
        events.append(
            _event(
                "warning",
                "package_name_mismatch",
                "采集包文件名与 dataset_key 不一致",
                expected=expected_name,
                observed=package_path.name,
            )
        )

    stationary = None
    pose = None
    magnetic = None
    heading = None
    required_arrays = {"accelerometer", "gyroscope", "magnetometer_raw", "device_motion"}
    if required_arrays <= arrays.keys() and all(arrays[key].shape[0] >= 20 for key in required_arrays):
        acceleration = arrays["accelerometer"]
        gyroscope = arrays["gyroscope"]
        raw_magnetic = arrays["magnetometer_raw"]
        device_motion = arrays["device_motion"]

        stationary = {
            "start": _stationary_window(
                acceleration, gyroscope, "start", stationary_window_s
            ),
            "end": _stationary_window(
                acceleration, gyroscope, "end", stationary_window_s
            ),
        }
        for side, label in (("start", "开始"), ("end", "结束")):
            if not stationary[side]["stationary"]:
                events.append(
                    _event(
                        "warning",
                        f"{side}_not_stationary",
                        f"采集{label} {stationary_window_s:g} 秒未保持静止",
                        acceleration_std_mps2=stationary[side].get(
                            "acceleration_norm_std_mps2"
                        ),
                        angular_rate_rms_radps=stationary[side].get(
                            "angular_rate_rms_radps"
                        ),
                    )
                )

        gravity = device_motion[:, 8:11]
        gravity_horizontal = np.linalg.norm(gravity[:, :2], axis=1)
        tilt_deg = np.degrees(np.arctan2(gravity_horizontal, np.abs(gravity[:, 2])))
        quaternion_norm = np.linalg.norm(device_motion[:, 1:5], axis=1)
        pose = {
            "flat_within_15_deg_ratio": float(np.mean(tilt_deg <= 15)),
            "tilt_median_deg": float(np.median(tilt_deg)),
            "tilt_p95_deg": float(np.percentile(tilt_deg, 95)),
            "tilt_maximum_deg": float(np.max(tilt_deg)),
            "quaternion_norm_max_error": float(np.max(np.abs(quaternion_norm - 1))),
        }
        if pose["flat_within_15_deg_ratio"] < 0.95:
            events.append(
                _event(
                    "warning",
                    "phone_not_flat",
                    "手机有较多时间超出平放 15° 范围",
                    flat_ratio=pose["flat_within_15_deg_ratio"],
                )
            )
        if pose["quaternion_norm_max_error"] > 1e-3:
            events.append(_event("warning", "quaternion_norm_error", "四元数归一化偏差较大"))

        raw_stats = _magnetic_statistics(raw_magnetic[:, 1:4])
        calibrated_stats = _magnetic_statistics(device_motion[:, 17:20])
        accuracy_values = np.rint(device_motion[:, 20]).astype(int)
        accuracy_counts = Counter(int(value) for value in accuracy_values)
        accuracy_ratios = {
            MAGNETIC_ACCURACY_LABELS.get(value, str(value)): float(count / len(accuracy_values))
            for value, count in sorted(accuracy_counts.items())
        }
        magnetic = {
            "algorithm_source": "DeviceMotion.csv calibrated magnetic field",
            "raw": raw_stats,
            "calibrated": calibrated_stats,
            "accuracy_ratios": accuracy_ratios,
            "high_accuracy_ratio": float(np.mean(accuracy_values == 2)),
        }
        if raw_stats["outside_20_to_100_ut_ratio"] > 0.25 and calibrated_stats[
            "outside_20_to_100_ut_ratio"
        ] < 0.05:
            events.append(
                _event(
                    "info",
                    "raw_magnetometer_hard_iron_offset",
                    "原始磁力计存在大幅偏置，算法必须使用 DeviceMotion 校准磁场",
                    raw_median_ut=raw_stats["median_ut"],
                    calibrated_median_ut=calibrated_stats["median_ut"],
                )
            )
        elif calibrated_stats["outside_20_to_100_ut_ratio"] > 0.05:
            events.append(
                _event(
                    "warning",
                    "calibrated_magnetic_range_abnormal",
                    "校准后磁场仍有较多数值超出 20–100 µT",
                )
            )
        if magnetic["high_accuracy_ratio"] < 0.90:
            events.append(
                _event(
                    "warning",
                    "magnetic_calibration_low",
                    "Core Motion 高磁场校准占比低于 90%",
                    high_accuracy_ratio=magnetic["high_accuracy_ratio"],
                )
            )

        yaw_rad = np.unwrap(device_motion[:, 7])
        core_motion_delta_deg = float(math.degrees(yaw_rad[-1] - yaw_rad[0]))
        gyro_delta_rad = np.sum(
            0.5
            * (gyroscope[:-1, 3] + gyroscope[1:, 3])
            * np.diff(gyroscope[:, 0])
        )
        gyro_delta_deg = float(math.degrees(gyro_delta_rad))
        heading = {
            "reference_frame": "xArbitraryCorrectedZVertical",
            "core_motion_yaw_delta_deg": core_motion_delta_deg,
            "raw_gyro_z_integral_deg": gyro_delta_deg,
            "absolute_delta_difference_deg": float(abs(core_motion_delta_deg - gyro_delta_deg)),
            "interpretation": "relative heading only; not geographic north",
        }

    route_xy = dataset_metadata.get("route_xy_m")
    initial_heading = dataset_metadata.get("initial_heading_deg")
    route_geometry = None
    route_coordinates_present = bool(isinstance(route_xy, list) and len(route_xy) >= 2)
    if route_coordinates_present and "device_motion" in stream_stats:
        try:
            route_points = np.asarray(route_xy, dtype=float)
            route_length_m = float(np.sum(np.linalg.norm(np.diff(route_points, axis=0), axis=1)))
            capture_duration_s = float(stream_stats["device_motion"]["duration_s"])
            nominal_speed_mps = route_length_m / capture_duration_s if capture_duration_s > 0 else math.inf
            first_segments = np.diff(route_points, axis=0)
            first_nonzero = next(
                (segment for segment in first_segments if np.linalg.norm(segment) > 1e-9),
                None,
            )
            first_heading_deg = (
                None
                if first_nonzero is None
                else float(math.degrees(math.atan2(first_nonzero[1], first_nonzero[0])))
            )
            heading_error_deg = None
            if first_heading_deg is not None and isinstance(initial_heading, (int, float)):
                heading_error_deg = float(
                    abs((float(initial_heading) - first_heading_deg + 180) % 360 - 180)
                )
            route_geometry = {
                "length_m": route_length_m,
                "nominal_speed_mps_using_full_capture": nominal_speed_mps,
                "plausible_scale": bool(nominal_speed_mps <= 3.0),
                "first_segment_heading_deg": first_heading_deg,
                "initial_heading_error_deg": heading_error_deg,
            }
        except (TypeError, ValueError):
            route_coordinates_present = False
    ground_truth_ready = bool(
        route_coordinates_present
        and route_geometry is not None
        and route_geometry["plausible_scale"]
    )
    if route_coordinates_present and route_geometry is not None and not route_geometry["plausible_scale"]:
        events.append(
            _event(
                "warning",
                "implausible_route_coordinate_scale",
                "路线坐标标称为米，但与采集时长对应的速度不可能，很可能误填了厘米",
                route_length_m=route_geometry["length_m"],
                nominal_speed_mps=route_geometry["nominal_speed_mps_using_full_capture"],
            )
        )
    if (
        route_geometry is not None
        and route_geometry["initial_heading_error_deg"] is not None
        and route_geometry["initial_heading_error_deg"] > 20
    ):
        events.append(
            _event(
                "warning",
                "initial_heading_route_mismatch",
                "初始数学航向与路线首段方向不一致，建议留空并由路线自动推导",
                route_heading_deg=route_geometry["first_segment_heading_deg"],
                initial_heading_deg=initial_heading,
                absolute_error_deg=route_geometry["initial_heading_error_deg"],
            )
        )
    if not route_coordinates_present:
        events.append(
            _event(
                "info",
                "route_coordinates_missing",
                "未记录真实路线坐标，可做传感器和重复性分析，但不能计算定位误差",
            )
        )

    sensor_events = [
        event
        for event in events
        if event["code"]
        not in {
            "route_coordinates_missing",
            "implausible_route_coordinate_scale",
            "initial_heading_route_mismatch",
        }
    ]
    severities = {event["severity"] for event in sensor_events}
    sensor_status = "fail" if "error" in severities else "warning" if "warning" in severities else "pass"
    sensor_usable = sensor_status != "fail" and magnetic is not None and magnetic["high_accuracy_ratio"] >= 0.90
    return {
        "dataset_key": dataset_key,
        "package_path": str(package_path.resolve()),
        "sensor_status": sensor_status,
        "sensor_usable": bool(sensor_usable),
        "ground_truth_ready": ground_truth_ready,
        "route_xy_m": route_xy,
        "route_geometry": route_geometry,
        "initial_heading_deg": initial_heading,
        "capture_metadata": capture_metadata,
        "streams": stream_stats,
        "stationary_windows": stationary,
        "phone_pose": pose,
        "magnetic_field": magnetic,
        "heading": heading,
        "events": events,
    }


def _route_key(dataset_key: str) -> str:
    match = re.match(r"(.+)_run\d+$", dataset_key)
    if match:
        return match.group(1)
    numbered_repeat = re.match(r"(.+)_\d+$", dataset_key)
    return numbered_repeat.group(1) if numbered_repeat else dataset_key


def _normalized_signals(package_path: Path, points: int = 1000) -> dict[str, np.ndarray]:
    _, device_motion = _load_numeric_csv(package_path / "DeviceMotion.csv", 21)
    progress = (device_motion[:, 0] - device_motion[0, 0]) / (
        device_motion[-1, 0] - device_motion[0, 0]
    )
    target = np.linspace(0, 1, points)
    magnetic_norm = np.linalg.norm(device_motion[:, 17:20], axis=1)
    yaw_deg = np.degrees(np.unwrap(device_motion[:, 7]))
    yaw_deg -= yaw_deg[0]
    return {
        "progress": target,
        "magnetic_norm_ut": np.interp(target, progress, magnetic_norm),
        "relative_yaw_deg": np.interp(target, progress, yaw_deg),
    }


def compare_repeats(first: dict[str, Any], second: dict[str, Any]) -> dict[str, Any]:
    first_signals = _normalized_signals(Path(first["package_path"]))
    second_signals = _normalized_signals(Path(second["package_path"]))
    first_magnetic = first_signals["magnetic_norm_ut"]
    second_magnetic = second_signals["magnetic_norm_ut"]
    if np.std(first_magnetic) > 1e-9 and np.std(second_magnetic) > 1e-9:
        correlation = float(np.corrcoef(first_magnetic, second_magnetic)[0, 1])
    else:
        correlation = None
    magnetic_rmse = float(np.sqrt(np.mean(np.square(first_magnetic - second_magnetic))))
    first_yaw = first_signals["relative_yaw_deg"]
    second_yaw = second_signals["relative_yaw_deg"]
    yaw_rmse = float(np.sqrt(np.mean(np.square(first_yaw - second_yaw))))
    endpoint_yaw_difference = float(abs(first_yaw[-1] - second_yaw[-1]))
    first_duration = first["streams"]["device_motion"]["duration_s"]
    second_duration = second["streams"]["device_motion"]["duration_s"]
    duration_difference_ratio = float(abs(first_duration - second_duration) / max(first_duration, second_duration))
    if magnetic_rmse <= 3 and endpoint_yaw_difference <= 35:
        grade = "consistent"
    elif magnetic_rmse <= 6 and endpoint_yaw_difference <= 60:
        grade = "attention"
    else:
        grade = "inconsistent"
    return {
        "route_key": _route_key(first["dataset_key"]),
        "first": first["dataset_key"],
        "second": second["dataset_key"],
        "grade": grade,
        "duration_difference_ratio": duration_difference_ratio,
        "calibrated_magnetic_norm_correlation": correlation,
        "calibrated_magnetic_norm_rmse_ut": magnetic_rmse,
        "relative_yaw_profile_rmse_deg": yaw_rmse,
        "endpoint_yaw_difference_deg": endpoint_yaw_difference,
    }


def audit_capture_root(root: str | Path, stationary_window_s: float = 3.0) -> dict[str, Any]:
    root_path = Path(root)
    packages = sorted(
        root_path.glob("*.geomagcapture"),
        key=lambda path: [
            int(token) if token.isdigit() else token
            for token in re.split(r"(\d+)", path.name)
        ],
    )
    datasets = [audit_capture(path, stationary_window_s=stationary_window_s) for path in packages]
    groups: dict[str, list[dict[str, Any]]] = {}
    for dataset in datasets:
        groups.setdefault(_route_key(dataset["dataset_key"]), []).append(dataset)
    comparisons = [
        compare_repeats(first, second)
        for runs in groups.values()
        for first, second in itertools.combinations(runs, 2)
        if first["sensor_usable"] and second["sensor_usable"]
    ]
    return {
        "format_version": "1.0",
        "capture_root": str(root_path.resolve()),
        "summary": {
            "package_count": len(datasets),
            "sensor_usable_count": sum(item["sensor_usable"] for item in datasets),
            "sensor_failed_count": sum(item["sensor_status"] == "fail" for item in datasets),
            "both_stationary_count": sum(
                bool(item["stationary_windows"])
                and item["stationary_windows"]["start"]["stationary"]
                and item["stationary_windows"]["end"]["stationary"]
                for item in datasets
            ),
            "flat_capture_count": sum(
                bool(item["phone_pose"])
                and item["phone_pose"]["flat_within_15_deg_ratio"] >= 0.95
                for item in datasets
            ),
            "high_magnetic_calibration_count": sum(
                bool(item["magnetic_field"])
                and item["magnetic_field"]["high_accuracy_ratio"] >= 0.90
                for item in datasets
            ),
            "ground_truth_ready_count": sum(item["ground_truth_ready"] for item in datasets),
            "repeat_comparison_count": len(comparisons),
            "repeat_consistent_count": sum(item["grade"] == "consistent" for item in comparisons),
            "repeat_attention_count": sum(item["grade"] == "attention" for item in comparisons),
            "repeat_inconsistent_count": sum(item["grade"] == "inconsistent" for item in comparisons),
        },
        "datasets": {item["dataset_key"]: item for item in datasets},
        "repeat_comparisons": comparisons,
        "recommendations": [
            "旧采集包的定位算法必须使用 DeviceMotion.csv 第 18–20 列的校准磁场，不得直接使用当前 Magnetometer.csv。",
            "后续采集在点击开始后和点击停止前各保持至少 3 秒真静止。",
            "为每个 route 补充真实折线坐标与初始方向，否则只能评估重复性，不能评估米级定位误差。",
        ],
    }


def _format(value: Any, digits: int = 1) -> str:
    if value is None:
        return "—"
    return f"{float(value):.{digits}f}"


def markdown_report(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# iPhone 真机采集质量报告",
        "",
        f"- 采集包：{summary['package_count']} 组",
        f"- 传感器可用：{summary['sensor_usable_count']} 组",
        f"- 手机平放合格：{summary['flat_capture_count']} 组",
        f"- Core Motion 磁场高校准：{summary['high_magnetic_calibration_count']} 组",
        f"- 开始与结束均静止 3 秒：{summary['both_stationary_count']} 组",
        f"- 已有真实路线坐标：{summary['ground_truth_ready_count']} 组",
        "",
        "## 逐组结果",
        "",
        "| 数据集 | 时长(s) | DM Hz | 起点静止 | 终点静止 | 平放(%) | 高校准(%) | 校准磁场中位(µT) | 相对航向变化(°) | 可用 |",
        "| --- | ---: | ---: | :---: | :---: | ---: | ---: | ---: | ---: | :---: |",
    ]
    for key, item in report["datasets"].items():
        stationary = item["stationary_windows"]
        pose = item["phone_pose"]
        magnetic = item["magnetic_field"]
        heading = item["heading"]
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{key}`",
                    _format(item["streams"]["device_motion"].get("duration_s")),
                    _format(item["streams"]["device_motion"].get("sample_rate_hz")),
                    "是" if stationary and stationary["start"]["stationary"] else "否",
                    "是" if stationary and stationary["end"]["stationary"] else "否",
                    _format(pose["flat_within_15_deg_ratio"] * 100 if pose else None),
                    _format(magnetic["high_accuracy_ratio"] * 100 if magnetic else None),
                    _format(magnetic["calibrated"]["median_ut"] if magnetic else None),
                    _format(heading["core_motion_yaw_delta_deg"] if heading else None),
                    "是" if item["sensor_usable"] else "否",
                ]
            )
            + " |"
        )
    lines.extend(
        [
            "",
            "## 同路线重复性",
            "",
            "| 路线 | 对比 | 时长差(%) | 校准磁场相关 | 磁场 RMSE(µT) | 航向曲线 RMSE(°) | 终点航向差(°) | 结论 |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
    )
    for item in report["repeat_comparisons"]:
        lines.append(
            f"| `{item['route_key']}` | `{item['first']}` / `{item['second']}` | "
            f"{_format(item['duration_difference_ratio'] * 100)} | "
            f"{_format(item['calibrated_magnetic_norm_correlation'], 3)} | "
            f"{_format(item['calibrated_magnetic_norm_rmse_ut'], 2)} | "
            f"{_format(item['relative_yaw_profile_rmse_deg'], 1)} | "
            f"{_format(item['endpoint_yaw_difference_deg'], 1)} | {item['grade']} |"
        )
    lines.extend(["", "## 结论与下一步", ""])
    lines.extend(f"{index}. {item}" for index, item in enumerate(report["recommendations"], 1))
    lines.extend(
        [
            "",
            "> 重复性比较使用了归一化采集进度，它可以判断同路线两次信号是否相似，但不是同步位置真值。",
            "",
        ]
    )
    return "\n".join(lines)


def write_report(
    report: dict[str, Any],
    output_json: str | Path | None,
    output_markdown: str | Path | None,
) -> None:
    if output_json:
        json_path = Path(output_json)
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(
            json.dumps(_jsonable(report), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
    if output_markdown:
        markdown_path = Path(output_markdown)
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        markdown_path.write_text(markdown_report(report), encoding="utf-8")


def plot_repeat_signals(root: str | Path, output_png: str | Path) -> None:
    import matplotlib.pyplot as plt

    plt.rcParams["font.family"] = ["Arial Unicode MS", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    root_path = Path(root)
    groups: dict[str, list[Path]] = {}
    for path in root_path.glob("*.geomagcapture"):
        groups.setdefault(_route_key(path.stem), []).append(path)
    repeated = sorted(
        ((key, paths) for key, paths in groups.items() if len(paths) >= 2),
        key=lambda item: [
            int(token) if token.isdigit() else token
            for token in re.split(r"(\d+)", item[0])
        ],
    )
    figure, axes = plt.subplots(len(repeated), 2, figsize=(14, 3.1 * len(repeated)), squeeze=False)
    for row, (route, paths) in enumerate(repeated):
        for path in sorted(paths):
            signals = _normalized_signals(path)
            label = path.stem.split("_run")[-1]
            axes[row, 0].plot(signals["progress"], signals["magnetic_norm_ut"], label=f"run{label}")
            axes[row, 1].plot(signals["progress"], signals["relative_yaw_deg"], label=f"run{label}")
        axes[row, 0].set_ylabel(f"{route}\n磁场 (µT)")
        axes[row, 0].grid(alpha=0.25)
        axes[row, 1].set_ylabel("相对航向 (°)")
        axes[row, 1].grid(alpha=0.25)
        axes[row, 0].legend(loc="best")
        axes[row, 1].legend(loc="best")
    axes[0, 0].set_title("Core Motion 校准磁场模长")
    axes[0, 1].set_title("Core Motion 相对航向")
    axes[-1, 0].set_xlabel("归一化采集进度")
    axes[-1, 1].set_xlabel("归一化采集进度")
    figure.suptitle("iPhone 同路线多次采集重复性", fontsize=16)
    figure.tight_layout(rect=(0, 0, 1, 0.985))
    output_path = Path(output_png)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output_path, dpi=170)
    plt.close(figure)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Audit native iPhone .geomagcapture packages.")
    parser.add_argument("capture_root", help="Directory containing .geomagcapture packages")
    parser.add_argument("--stationary-window", type=float, default=3.0)
    parser.add_argument("--output-json", default="results/iphone_capture_audit/summary.json")
    parser.add_argument("--output-markdown", default="results/iphone_capture_audit/report.md")
    parser.add_argument("--output-plot", default="results/iphone_capture_audit/repeat_signals.png")
    args = parser.parse_args(argv)
    report = audit_capture_root(args.capture_root, stationary_window_s=args.stationary_window)
    write_report(report, args.output_json or None, args.output_markdown or None)
    if args.output_plot:
        plot_repeat_signals(args.capture_root, args.output_plot)
    summary = report["summary"]
    print(
        f"iPhone capture audit: {summary['package_count']} packages, "
        f"{summary['sensor_usable_count']} sensor-usable, "
        f"{summary['both_stationary_count']} with both stationary windows, "
        f"{summary['ground_truth_ready_count']} ground-truth-ready"
    )
    return 1 if summary["sensor_failed_count"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
