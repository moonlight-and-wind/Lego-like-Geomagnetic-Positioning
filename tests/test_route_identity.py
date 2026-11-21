import csv
import math

import numpy as np

from Geomag import route_identity


def _write_stream(path, header, rows):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)


def _make_capture(root, duration_s, yaw_deg, phase=0.0):
    root.mkdir()
    time_s = np.linspace(0.0, duration_s, 401)
    cadence_hz = 1.7
    acc_signal = 9.80665 + 0.8 * np.sin(2.0 * np.pi * cadence_hz * time_s)
    yaw_rate = math.radians(yaw_deg) / duration_s
    mag_signal = 44.0 + np.sin(2.0 * np.pi * time_s / duration_s + phase)
    _write_stream(
        root / "Accelerometer.csv",
        ["Time (s)", "X", "Y", "Z"],
        [[t, 0.0, 0.0, a] for t, a in zip(time_s, acc_signal, strict=True)],
    )
    _write_stream(
        root / "Gyroscope.csv",
        ["Time (s)", "X", "Y", "Z"],
        [[t, 0.0, 0.0, yaw_rate] for t in time_s],
    )
    _write_stream(
        root / "Magnetometer.csv",
        ["Time (s)", "X", "Y", "Z"],
        [[t, m, 0.0, 0.0] for t, m in zip(time_s, mag_signal, strict=True)],
    )


def test_route_identity_supports_compatible_provisional_capture(monkeypatch, tmp_path):
    reference = tmp_path / "reference"
    candidate = tmp_path / "candidate"
    _make_capture(reference, 10.0, -88.0)
    _make_capture(candidate, 8.0, -93.0)

    def fake_spec(key):
        return {
            "dataset_dir": str(reference if key == "reference" else candidate),
            "route_label": "route2",
            "route_xy_m": [[0.0, 0.0], [0.0, 5.0], [3.0, 5.0]],
            "assignment_confidence": "high" if key == "reference" else "medium",
            "evaluation_tier": "confirmed" if key == "reference" else "provisional",
        }

    monkeypatch.setattr(route_identity, "get_own_dataset_spec", fake_spec)
    report = route_identity.compare_route_assignments("reference", "candidate")

    assert report["evidence"]["candidate_yaw_supports_registered_route"] is True
    assert report["evidence"]["walking_cadence_is_compatible"] is True
    assert report["evidence"]["magnetic_sequence_prefers_forward_route"] is True
    assert report["conclusion"]["supports_historical_route_label"] is True
    assert report["conclusion"]["official_ground_truth_ready"] is False
