import csv
import json

import numpy as np

from Geomag.iphone_capture_audit import _route_key, audit_capture, audit_capture_root


def _write_csv(path, header, rows):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)


def _make_capture(root, key, magnetic_offset=0.0):
    package = root / f"{key}.geomagcapture"
    package.mkdir()
    times = np.linspace(0, 10, 1001)
    _write_csv(
        package / "Accelerometer.csv",
        ["Time (s)", "X (m/s^2)", "Y (m/s^2)", "Z (m/s^2)"],
        [[time, 0, 0, 9.80665] for time in times],
    )
    _write_csv(
        package / "Gyroscope.csv",
        ["Time (s)", "X (rad/s)", "Y (rad/s)", "Z (rad/s)"],
        [[time, 0, 0, 0] for time in times],
    )
    _write_csv(
        package / "Magnetometer.csv",
        ["Time (s)", "X (µT)", "Y (µT)", "Z (µT)"],
        [[time, 300, 100, 80] for time in times],
    )
    device_rows = []
    for time in times:
        magnetic_x = 30 + magnetic_offset + np.sin(time)
        device_rows.append(
            [time, 0, 0, 0, 1, 0, 0, 0, 0, 0, -9.80665, 0, 0, 0, 0, 0, 0,
             magnetic_x, 20, 35, 2]
        )
    _write_csv(
        package / "DeviceMotion.csv",
        [
            "Time (s)", "Quaternion X", "Quaternion Y", "Quaternion Z", "Quaternion W",
            "Roll (rad)", "Pitch (rad)", "Yaw (rad)", "Gravity X (m/s^2)",
            "Gravity Y (m/s^2)", "Gravity Z (m/s^2)", "User Acceleration X (m/s^2)",
            "User Acceleration Y (m/s^2)", "User Acceleration Z (m/s^2)",
            "Rotation Rate X (rad/s)", "Rotation Rate Y (rad/s)", "Rotation Rate Z (rad/s)",
            "Magnetic Field X (µT)", "Magnetic Field Y (µT)",
            "Magnetic Field Z (µT)", "Magnetic Accuracy",
        ],
        device_rows,
    )
    (package / "geomag_dataset.json").write_text(
        json.dumps({"dataset_key": key, "format_version": 1}), encoding="utf-8"
    )
    (package / "capture_metadata.json").write_text(
        json.dumps({"dataset_key": key, "format_version": 1}), encoding="utf-8"
    )
    return package


def test_audit_uses_calibrated_device_motion_field_and_detects_raw_offset(tmp_path):
    package = _make_capture(tmp_path, "route3_run1")

    report = audit_capture(package)

    assert report["sensor_usable"] is True
    assert report["stationary_windows"]["start"]["stationary"] is True
    assert report["stationary_windows"]["end"]["stationary"] is True
    assert report["phone_pose"]["flat_within_15_deg_ratio"] == 1.0
    assert report["magnetic_field"]["high_accuracy_ratio"] == 1.0
    assert report["magnetic_field"]["raw"]["median_ut"] > 300
    assert 40 < report["magnetic_field"]["calibrated"]["median_ut"] < 60
    assert "raw_magnetometer_hard_iron_offset" in {
        event["code"] for event in report["events"]
    }


def test_root_audit_compares_repeated_routes(tmp_path):
    _make_capture(tmp_path, "route3_run1")
    _make_capture(tmp_path, "route3_run2", magnetic_offset=0.2)

    report = audit_capture_root(tmp_path)

    assert report["summary"]["package_count"] == 2
    assert report["summary"]["sensor_usable_count"] == 2
    assert report["summary"]["repeat_comparison_count"] == 1
    comparison = report["repeat_comparisons"][0]
    assert comparison["grade"] == "consistent"
    assert comparison["calibrated_magnetic_norm_rmse_ut"] < 1


def test_route_key_accepts_run_and_numbered_repeat_names():
    assert _route_key("route3_run2") == "route3"
    assert _route_key("route_13_2") == "route_13"
