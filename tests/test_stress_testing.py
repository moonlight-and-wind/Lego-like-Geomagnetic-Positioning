import numpy as np
import pytest

from Geomag.branching import (
    apply_own_sensor_fault,
    prepare_own_fault_injection,
)
from Geomag.stress_testing import evaluate_stress_result


def test_fault_spec_resolves_reproducible_frame_window():
    fault = prepare_own_fault_injection(
        {
            "kind": "magnetic_noise",
            "start_fraction": 0.25,
            "end_fraction": 0.50,
            "seed": 7,
        },
        total_frames=100,
    )

    assert fault["start_frame"] == 25
    assert fault["end_frame_exclusive"] == 50
    assert fault["affected_sensor_frames"] == 25
    assert fault["seed"] == 7


def test_magnetic_fault_does_not_mutate_original_sensor_vector():
    mag = np.asarray([10.0, 20.0, 30.0])
    fault = prepare_own_fault_injection(
        {
            "kind": "magnetic_bias",
            "start_fraction": 0.20,
            "end_fraction": 0.80,
            "magnitude": 10.0,
        },
        total_frames=10,
    )

    changed, _, _, active = apply_own_sensor_fault(
        mag,
        np.zeros(3),
        np.zeros(3),
        frame_idx=4,
        fault=fault,
        rng=np.random.default_rng(1),
    )

    assert active is True
    assert changed == pytest.approx([20.0, 14.5, 33.0])
    assert mag == pytest.approx([10.0, 20.0, 30.0])


def test_fault_is_inactive_outside_configured_window():
    fault = prepare_own_fault_injection(
        {
            "kind": "gyro_bias",
            "start_fraction": 0.20,
            "end_fraction": 0.40,
            "magnitude": 1.0,
        },
        total_frames=10,
    )

    _, _, gyro, active = apply_own_sensor_fault(
        np.ones(3),
        np.ones(3),
        np.ones(3),
        frame_idx=8,
        fault=fault,
        rng=np.random.default_rng(1),
    )

    assert active is False
    assert gyro == pytest.approx([1.0, 1.0, 1.0])


def test_stress_evaluator_reports_detection_recovery_and_error_phases():
    health = [
        {"step_index": 0, "status": "healthy"},
        {"step_index": 1, "status": "healthy"},
        {"step_index": 2, "status": "ambiguous"},
        {"step_index": 3, "status": "lost"},
        {"step_index": 4, "status": "recovering"},
        {"step_index": 5, "status": "healthy"},
        {"step_index": 6, "status": "healthy"},
        {"step_index": 7, "status": "healthy"},
        {"step_index": 8, "status": "healthy"},
    ]
    payload = {
        "dataset_key": "synthetic",
        "steps_detected": 8,
        "fault_injection": {"name": "noise", "kind": "magnetic_noise"},
        "fault_active_step_history": [
            False,
            False,
            True,
            True,
            True,
            False,
            False,
            False,
            False,
        ],
        "localization_health_history": health,
        "localization_recovery_events": [
            {"step_index": 3, "action": "expand_search"}
        ],
        "pf_error_series": [0.2, 0.3, 1.0, 2.0, 1.5, 0.8, 0.5, 0.4, 0.3],
    }
    baseline = {
        "pf_error_series": [0.2, 0.3, 0.3, 0.4, 0.4, 0.5, 0.4, 0.3, 0.3]
    }

    result = evaluate_stress_result(payload, baseline_payload=baseline)

    assert result["anomaly_detected"] is True
    assert result["warning_delay_steps"] == 0
    assert result["recovery_action_delay_steps"] == 1
    assert result["recovered_step"] == 5
    assert result["recovery_delay_steps"] == 1
    assert result["false_recovery"] is False
    assert result["error_during_fault"]["mean_m"] == pytest.approx(1.5)
    assert result["error_after_fault"]["mean_m"] == pytest.approx(0.5)
    assert result["error_improvement_after_fault_m"] == pytest.approx(1.0)
    assert result["final_reconverged"] is True


def test_stress_evaluator_flags_pre_fault_recovery_as_false_alarm():
    payload = {
        "dataset_key": "synthetic",
        "fault_injection": {"name": "dropout", "kind": "magnetic_dropout"},
        "fault_active_step_history": [False, False, True, True, False, False],
        "localization_health_history": [
            {"status": "ambiguous"},
            {"status": "healthy"},
            {"status": "lost"},
            {"status": "recovering"},
            {"status": "healthy"},
            {"status": "healthy"},
        ],
        "localization_recovery_events": [
            {"step_index": 0, "action": "expand_search"}
        ],
        "pf_error_series": [0.2, 0.2, 1.0, 1.2, 0.5, 0.4],
    }

    result = evaluate_stress_result(
        payload,
        recovery_confirmation_steps=2,
    )

    assert result["false_recovery"] is True
    assert result["false_recovery_action_steps_before_fault"] == [0]


def test_stress_evaluator_does_not_count_post_fault_warning_as_detection():
    payload = {
        "dataset_key": "synthetic",
        "fault_injection": {"name": "bias", "kind": "magnetic_bias"},
        "fault_active_step_history": [False, True, True, False, False],
        "localization_health_history": [
            {"status": "healthy"},
            {"status": "healthy"},
            {"status": "healthy"},
            {"status": "ambiguous"},
            {"status": "healthy"},
        ],
        "localization_recovery_events": [],
        "pf_error_series": [0.2, 0.3, 0.4, 0.5, 0.4],
    }

    result = evaluate_stress_result(
        payload,
        recovery_confirmation_steps=1,
    )

    assert result["anomaly_detected"] is False
    assert result["first_warning_step"] is None
    assert result["late_warning_only"] is True
    assert result["late_warning_step"] == 3
    assert result["recovered"] is False


def test_stress_evaluator_recognizes_specialized_reinitialization():
    payload = {
        "dataset_key": "synthetic",
        "fault_injection": {"name": "offset", "kind": "initial_position_offset"},
        "fault_active_step_history": [True, False, False],
        "localization_health_history": [
            {"status": "recovering"},
            {"status": "healthy"},
            {"status": "healthy"},
        ],
        "localization_recovery_events": [
            {"step_index": 0, "action": "reinitialize_anchor"}
        ],
        "pf_error_series": [1.5, 0.3, 0.2],
    }

    result = evaluate_stress_result(
        payload,
        recovery_confirmation_steps=1,
    )

    assert result["first_reinitialize_step"] == 0
    assert result["recovery_action_delay_steps"] == 0


def test_invalid_fault_interval_is_rejected():
    with pytest.raises(ValueError, match="0 <= start < end <= 1"):
        prepare_own_fault_injection(
            {
                "kind": "magnetic_bias",
                "start_fraction": 0.8,
                "end_fraction": 0.2,
            },
            total_frames=100,
        )
