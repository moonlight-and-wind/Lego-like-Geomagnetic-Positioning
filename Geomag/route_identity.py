"""Cross-check repeated own-data route assignments from sensor fingerprints."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np

from Geomag.data_quality import _load_numeric_stream
from Geomag.distance import _ddtw_distance
from Geomag.own_dataset_registry import get_own_dataset_spec


def _load_stream(dataset_dir, filename):
    _, values = _load_numeric_stream(Path(dataset_dir) / filename)
    if values.ndim != 2 or values.shape[0] < 2 or values.shape[1] < 4:
        raise ValueError(f"Invalid sensor stream: {Path(dataset_dir) / filename}")
    return np.asarray(values[:, :4], dtype=float)


def _resample_unit_progress(values, count=256):
    values = np.asarray(values, dtype=float).reshape(-1)
    if values.size < 2:
        return values
    source = np.linspace(0.0, 1.0, values.size)
    target = np.linspace(0.0, 1.0, int(count))
    return np.interp(target, source, values)


def _dominant_cadence_hz(accelerometer):
    time_s = accelerometer[:, 0]
    positive_dt = np.diff(time_s)
    positive_dt = positive_dt[positive_dt > 0.0]
    if positive_dt.size == 0:
        return None
    dt_s = float(np.median(positive_dt))
    signal = np.linalg.norm(accelerometer[:, 1:4], axis=1)
    signal = signal - float(np.mean(signal))
    frequencies = np.fft.rfftfreq(signal.size, dt_s)
    power = np.abs(np.fft.rfft(signal)) ** 2
    walking_band = (frequencies >= 0.5) & (frequencies <= 3.0)
    if not np.any(walking_band):
        return None
    band_frequencies = frequencies[walking_band]
    return float(band_frequencies[int(np.argmax(power[walking_band]))])


def _expected_signed_yaw_deg(route_xy_m):
    route = np.asarray(route_xy_m, dtype=float)
    segments = np.diff(route[:, :2], axis=0)
    headings = np.arctan2(segments[:, 1], segments[:, 0])
    turns = [
        math.degrees(
            math.atan2(
                math.sin(float(current - previous)),
                math.cos(float(current - previous)),
            )
        )
        for previous, current in zip(headings[:-1], headings[1:], strict=False)
    ]
    return float(sum(turns)), [float(turn) for turn in turns]


def sensor_fingerprint(dataset_key):
    spec = get_own_dataset_spec(dataset_key)
    accelerometer = _load_stream(spec["dataset_dir"], "Accelerometer.csv")
    gyroscope = _load_stream(spec["dataset_dir"], "Gyroscope.csv")
    magnetometer = _load_stream(spec["dataset_dir"], "Magnetometer.csv")

    mag_norm = np.linalg.norm(magnetometer[:, 1:4], axis=1)
    gyro_z_yaw_deg = float(
        math.degrees(
            np.sum(
                0.5
                * (gyroscope[:-1, 3] + gyroscope[1:, 3])
                * np.diff(gyroscope[:, 0])
            )
        )
    )
    expected_yaw_deg, expected_turns_deg = _expected_signed_yaw_deg(
        spec["route_xy_m"]
    )
    return {
        "dataset_key": dataset_key,
        "dataset_dir": spec["dataset_dir"],
        "route_label": spec["route_label"],
        "assignment_confidence": spec["assignment_confidence"],
        "evaluation_tier": spec["evaluation_tier"],
        "route_confirmation": dict(spec.get("route_confirmation", {})),
        "duration_s": float(accelerometer[-1, 0] - accelerometer[0, 0]),
        "sample_count": int(accelerometer.shape[0]),
        "dominant_cadence_hz": _dominant_cadence_hz(accelerometer),
        "integrated_device_z_yaw_deg": gyro_z_yaw_deg,
        "expected_route_yaw_deg": expected_yaw_deg,
        "expected_turns_deg": expected_turns_deg,
        "yaw_absolute_error_deg": float(abs(gyro_z_yaw_deg - expected_yaw_deg)),
        "magnetic_norm_mean_ut": float(np.mean(mag_norm)),
        "magnetic_norm_std_ut": float(np.std(mag_norm)),
        "magnetic_norm_progress": _resample_unit_progress(mag_norm).tolist(),
    }


def _safe_correlation(left, right):
    left = np.asarray(left, dtype=float)
    right = np.asarray(right, dtype=float)
    if left.size != right.size or left.size < 2:
        return None
    if float(np.std(left)) < 1e-12 or float(np.std(right)) < 1e-12:
        return None
    value = float(np.corrcoef(left, right)[0, 1])
    return value if math.isfinite(value) else None


def compare_route_assignments(reference_key="route2_run1", candidate_key="route2_run2"):
    reference = sensor_fingerprint(reference_key)
    candidate = sensor_fingerprint(candidate_key)
    reference_mag = np.asarray(reference.pop("magnetic_norm_progress"), dtype=float)
    candidate_mag = np.asarray(candidate.pop("magnetic_norm_progress"), dtype=float)

    forward_correlation = _safe_correlation(reference_mag, candidate_mag)
    reverse_correlation = _safe_correlation(reference_mag, candidate_mag[::-1])
    cadence_delta_hz = (
        None
        if reference["dominant_cadence_hz"] is None
        or candidate["dominant_cadence_hz"] is None
        else abs(
            float(reference["dominant_cadence_hz"])
            - float(candidate["dominant_cadence_hz"])
        )
    )
    yaw_support = candidate["yaw_absolute_error_deg"] <= 25.0
    cadence_support = cadence_delta_hz is not None and cadence_delta_hz <= 0.4
    magnetic_direction_support = (
        forward_correlation is not None
        and reverse_correlation is not None
        and forward_correlation >= reverse_correlation + 0.10
    )
    sensor_supports_label = bool(
        yaw_support and cadence_support and magnetic_direction_support
    )
    operator_confirmed = (
        candidate.get("route_confirmation", {}).get("status")
        == "operator_confirmed"
    )
    supports_label = bool(operator_confirmed or sensor_supports_label)

    return {
        "format_version": "1.0",
        "reference": reference,
        "candidate": candidate,
        "comparison": {
            "duration_ratio_candidate_over_reference": float(
                candidate["duration_s"] / reference["duration_s"]
            ),
            "cadence_delta_hz": cadence_delta_hz,
            "magnetic_norm_mean_offset_ut": float(
                candidate["magnetic_norm_mean_ut"]
                - reference["magnetic_norm_mean_ut"]
            ),
            "magnetic_forward_correlation": forward_correlation,
            "magnetic_reverse_correlation": reverse_correlation,
            "magnetic_forward_ddtw": float(
                _ddtw_distance(reference_mag, candidate_mag)
            ),
            "magnetic_reverse_ddtw": float(
                _ddtw_distance(reference_mag, candidate_mag[::-1])
            ),
        },
        "evidence": {
            "operator_confirmed_same_route": bool(operator_confirmed),
            "candidate_yaw_supports_registered_route": bool(yaw_support),
            "walking_cadence_is_compatible": bool(cadence_support),
            "magnetic_sequence_prefers_forward_route": bool(
                magnetic_direction_support
            ),
        },
        "conclusion": {
            "supports_historical_route_label": supports_label,
            "recommended_assignment_confidence": (
                "high"
                if operator_confirmed
                else "medium"
                if supports_label
                else "low"
            ),
            "route_assignment_ready": bool(operator_confirmed),
            "official_ground_truth_ready": False,
            "reason": (
                "The operator confirmed this as an independent capture of the "
                "same route as route2_run1; synchronized trajectory truth is "
                "still unavailable."
                if operator_confirmed
                else "Sensor evidence supports the historical route2 label, "
                "but no operator-confirmed or synchronized trajectory truth exists."
                if supports_label
                else "The available sensor fingerprint is insufficient to confirm the route."
            ),
        },
    }


def write_route_identity_report(
    output_json="results/route_identity_audit.json",
    reference_key="route2_run1",
    candidate_key="route2_run2",
):
    report = compare_route_assignments(reference_key, candidate_key)
    output_path = Path(output_json)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    report["output_json"] = str(output_path)
    output_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Compare two independent captures of a registered route."
    )
    parser.add_argument("--reference", default="route2_run1")
    parser.add_argument("--candidate", default="route2_run2")
    parser.add_argument(
        "--output-json",
        default="results/route_identity_audit.json",
    )
    args = parser.parse_args(argv)
    report = write_route_identity_report(
        output_json=args.output_json,
        reference_key=args.reference,
        candidate_key=args.candidate,
    )
    conclusion = report["conclusion"]
    print(
        f"{args.candidate}: confidence="
        f"{conclusion['recommended_assignment_confidence']}, "
        f"official_ground_truth_ready={conclusion['official_ground_truth_ready']}"
    )
    print(f"Saved report: {report['output_json']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
