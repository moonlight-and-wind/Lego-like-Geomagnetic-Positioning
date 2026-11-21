"""Tests for independent known-distance step calibration."""

import json

import pytest

from Geomag.step_calibration import (
    calibrate_from_result,
    estimate_step_length_scale,
)


def test_estimate_step_length_scale_matches_known_distance():
    report = estimate_step_length_scale(6.0, [0.4] * 12)

    assert report["unscaled_estimated_distance_m"] == pytest.approx(4.8)
    assert report["recommended_scale"] == pytest.approx(1.25)
    assert report["calibrated_mean_step_length_m"] == pytest.approx(0.5)


def test_calibrate_from_result_prefers_unscaled_diagnostics(tmp_path):
    result_path = tmp_path / "capture.json"
    output_path = tmp_path / "calibration.json"
    result_path.write_text(
        json.dumps(
            {
                "dataset_key": "calibration_walk",
                "step_length_scale": 1.5,
                "step_length_history_m": [0.0, 0.75, 0.75],
                "step_length_diagnostic_history": [
                    {},
                    {"unscaled_step_length_m": 0.5},
                    {"unscaled_step_length_m": 0.5},
                ],
            }
        ),
        encoding="utf-8",
    )

    report = calibrate_from_result(
        result_path,
        known_distance_m=1.2,
        output_json=output_path,
    )

    assert report["recommended_scale"] == pytest.approx(1.2)
    assert report["dataset_key"] == "calibration_walk"
    assert output_path.is_file()


def test_step_calibration_rejects_empty_steps():
    with pytest.raises(ValueError, match="positive finite"):
        estimate_step_length_scale(5.0, [])
