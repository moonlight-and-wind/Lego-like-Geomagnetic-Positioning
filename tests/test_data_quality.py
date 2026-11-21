import csv
import json

import pytest

from Geomag import batch_evaluation
from Geomag.data_quality import audit_dataset, audit_package


def _write_stream(path, rows):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Time (s)", "X", "Y", "Z"])
        writer.writerows(rows)


def _make_package(tmp_path, include_magnetometer=True):
    package = tmp_path / "package"
    dataset = package / "test_run"
    dataset.mkdir(parents=True)
    manifest = {
        "format_version": "2.0",
        "capture_protocol": {"stationary_window_s": 1.0},
        "map": {"tile_size_x_m": 1.0, "tile_size_y_m": 1.0},
        "datasets": {
            "test_run": {
                "folder_name": "test_run",
                "route_label": "route",
                "route_key": "route_tile_vertices",
                "evaluation_enabled": True,
                "assignment_confidence": "high",
                "capture_metadata": {
                    "dataset_key": "test_run",
                    "route_label": "route",
                    "device_pose": "face_up_front_forward",
                    "start_stationary_s": 1.0,
                    "end_stationary_s": 1.0,
                    "finish_behavior": "stationary_until_recording_stops",
                    "turn_events": [{"time_s": 1.0, "turn_deg": -90.0}],
                },
            }
        },
        "routes": {"route_tile_vertices": [[0, 0], [0, 1], [1, 1]]},
    }
    (package / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    times = [index * 0.1 for index in range(21)]
    _write_stream(
        dataset / "Accelerometer.csv",
        [[time_s, 0.0, 0.0, 9.80665] for time_s in times],
    )
    _write_stream(
        dataset / "Gyroscope.csv",
        [[time_s, 0.0, 0.0, 0.0] for time_s in times],
    )
    if include_magnetometer:
        _write_stream(
            dataset / "Magnetometer.csv",
            [[time_s, 20.0, 30.0, 40.0] for time_s in times],
        )
    return package


def test_audit_detects_stationary_windows_and_stream_integrity(tmp_path):
    package = _make_package(tmp_path)

    report = audit_dataset("test_run", package_root=package)

    assert report["stream_overlap"]["ratio"] == pytest.approx(1.0)
    assert report["stationary_windows"]["start"]["stationary"] is True
    assert report["stationary_windows"]["end"]["stationary"] is True
    assert report["streams"]["accelerometer"]["sample_rate_hz"] == pytest.approx(10.0)
    assert report["status"] == "warning"
    assert {event["code"] for event in report["events"]} == {"route_yaw_mismatch"}


def test_audit_marks_missing_required_stream_as_failure(tmp_path):
    package = _make_package(tmp_path, include_magnetometer=False)

    report = audit_dataset("test_run", package_root=package)

    assert report["status"] == "fail"
    assert "missing_stream" in {event["code"] for event in report["events"]}


def test_real_package_blocks_known_bad_capture_and_keeps_valid_ones():
    report = audit_package(
        dataset_keys=[
            "route1_run1",
            "route1_run2",
            "route2_run1",
            "route2_run2",
        ]
    )

    assert report["datasets"]["route1_run1"]["status"] == "fail"
    assert report["datasets"]["route1_run2"]["status"] == "warning"
    assert report["datasets"]["route2_run1"]["status"] == "warning"
    assert report["datasets"]["route2_run2"]["status"] == "warning"
    assert report["summary"]["evaluable_keys"] == [
        "route1_run2",
        "route2_run1",
        "route2_run2",
    ]
    assert report["summary"]["provisional_keys"] == []
    assert report["summary"]["blocking_fail_count"] == 0


def test_batch_evaluation_quality_gates_and_aggregates(monkeypatch, tmp_path):
    quality_payload = {
        "output_json": str(tmp_path / "quality.json"),
        "datasets": {
            "good": {"status": "warning", "events": []},
            "provisional": {"status": "warning", "events": []},
            "bad": {
                "status": "fail",
                "events": [{"severity": "error", "code": "missing_stream"}],
            },
        },
    }
    monkeypatch.setattr(
        batch_evaluation,
        "audit_package",
        lambda **kwargs: quality_payload,
    )
    monkeypatch.setattr(
        batch_evaluation,
        "get_own_dataset_spec",
        lambda key: {
            "dataset_dir": str(tmp_path / key),
            "evaluation_tier": (
                "provisional" if key == "provisional" else "confirmed"
            ),
        },
    )

    def fake_run(config):
        pf_mean = 5.0 if config.own_dataset_key == "provisional" else 1.0
        return {
            "steps_detected": 10,
            "pf_error_stats": {"mean": pf_mean, "p95": 2.0},
            "pf_cross_track_error_stats": {"mean": 0.5},
            "pf_endpoint_error_m": 0.7,
            "pf_raw_error_stats": {"mean": 0.8},
            "pf_raw_cross_track_error_stats": {"mean": 0.4},
            "pf_raw_endpoint_error_m": 0.6,
            "pdr_error_stats": {"mean": 1.2},
            "pdr_cross_track_error_stats": {"mean": 0.9},
            "pdr_endpoint_error_m": 1.1,
            "output_png": None,
            "diagnostic_png": None,
            "output_json": config.output_json,
        }

    monkeypatch.setattr(batch_evaluation, "run_own_branch", fake_run)

    report = batch_evaluation.run_batch_evaluation(
        dataset_keys=["good", "provisional", "bad"],
        output_dir=tmp_path / "results",
        generate_plots=False,
    )

    assert list(report["evaluated"]) == ["good", "provisional"]
    assert list(report["evaluated_confirmed"]) == ["good"]
    assert list(report["evaluated_provisional"]) == ["provisional"]
    assert report["skipped"] == {"bad": ["missing_stream"]}
    assert report["aggregate_mean"]["pf_aligned_mean_m"] == pytest.approx(1.0)
    assert report["provisional_aggregate_mean"]["pf_aligned_mean_m"] == pytest.approx(5.0)
    assert (tmp_path / "results" / "summary.json").is_file()
