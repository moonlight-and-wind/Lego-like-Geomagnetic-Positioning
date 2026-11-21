import math
from pathlib import Path

import numpy as np
import pytest

from Geomag.branching import (
    BranchConfig,
    build_own_geomag_map,
    build_own_package_configs,
    resolve_own_data_source,
    resolve_own_selection,
    run_own_branch,
    smooth_pf_output,
    validate_own_route_bounds,
)
from Geomag.own_dataset_registry import (
    assert_own_dataset_evaluable,
    available_own_dataset_keys,
    default_own_evaluation_keys,
    get_own_dataset_spec,
    independent_repeat_keys,
)


def test_registry_excludes_known_bad_capture_from_evaluation_list():
    assert "route1_run1" in available_own_dataset_keys()
    assert "route1_run1" not in available_own_dataset_keys(evaluation_only=True)
    assert get_own_dataset_spec("route1_run1")["evaluation_enabled"] is False
    assert get_own_dataset_spec("route1_run1")["evaluation_tier"] == "excluded"


def test_known_bad_capture_fails_before_loading_sensor_data():
    selection = resolve_own_selection("route1_run1")
    config = BranchConfig(
        branch="own",
        own_profile=selection["own_profile"],
        own_dataset_key=selection["own_dataset_key"],
        own_data_dir=selection["own_data_dir"],
        show=False,
    )

    with pytest.raises(ValueError, match="excluded from evaluation"):
        run_own_branch(config)


def test_valid_captures_remain_evaluable():
    assert assert_own_dataset_evaluable("route1_run2")["evaluation_enabled"] is True
    assert assert_own_dataset_evaluable("route2_run1")["evaluation_enabled"] is True


def test_data_source_is_independent_from_optimized_algorithm_profile():
    config = BranchConfig(
        own_profile="package",
        own_data_source="directory",
        own_data_dir="/tmp/external-capture",
    )

    assert resolve_own_data_source(config) == "directory"


def test_selection_sets_an_explicit_data_source():
    assert resolve_own_selection("route1_run2")["own_data_source"] == "registry"
    assert resolve_own_selection("/tmp/external-capture")["own_data_source"] == "directory"


def test_route_outside_map_bounds_fails_early():
    geomag_map = build_own_geomag_map(
        BranchConfig(own_profile="package", own_map_profile="survey_kriging")
    )

    with pytest.raises(ValueError, match="incompatible coordinates"):
        validate_own_route_bounds([[1.44, 0.55], [1.44, 8.25]], geomag_map)


def test_route2_run2_is_confirmed_primary_independent_capture():
    assert "route2_run2" in available_own_dataset_keys()
    assert "route2_run2" in available_own_dataset_keys(evaluation_only=True)
    spec = assert_own_dataset_evaluable("route2_run2")
    assert spec["evaluation_tier"] == "confirmed"
    assert spec["evaluation_role"] == "primary"
    assert spec["route_confirmation"]["independent_capture"] is True
    assert Path(spec["dataset_dir"]).parts[-3:] == (
        "data",
        "own_data",
        "Geomagnetic Navigation 2026-03-19 20-10-45",
    )


def test_manifest_default_uses_selected_independent_captures():
    assert default_own_evaluation_keys() == [
        "route1_run2",
        "route2_run2",
    ]
    assert get_own_dataset_spec("route2_run1")["evaluation_role"] == (
        "secondary_repeat"
    )


def test_repeat_lookup_excludes_query_and_route_mismatch():
    assert independent_repeat_keys("route2_run2") == ["route2_run1"]
    assert independent_repeat_keys("route2_run1") == ["route2_run2"]
    assert independent_repeat_keys("route1_run2") == []


def test_own_branch_uses_low_lag_ema_default():
    config = BranchConfig()

    assert config.own_pf_smoothing_mode == "ema"
    assert config.own_pf_smoothing_alpha == pytest.approx(0.3)


def test_package_step_detector_rejects_close_secondary_peaks():
    pdr_config, _ = build_own_package_configs()

    assert pdr_config.step_judge_params["peak_prominence"] == pytest.approx(0.30)
    assert pdr_config.step_judge_params["min_step_interval_s"] == pytest.approx(0.40)


def test_survey_map_profile_preserves_measured_npz_bounds():
    geomag_map = build_own_geomag_map(
        BranchConfig(
            own_profile="package",
            own_map_profile="survey_kriging",
        )
    )

    assert geomag_map["own_map_profile"] == "survey_kriging"
    assert geomag_map["rangex_min"] == pytest.approx(0.0)
    assert geomag_map["rangex_max"] == pytest.approx(6.72)
    assert geomag_map["rangey_min"] == pytest.approx(0.0)
    assert geomag_map["rangey_max"] == pytest.approx(8.074005934718102)


def test_tile_map_profile_applies_explicit_registration_offset():
    geomag_map = build_own_geomag_map(
        BranchConfig(
            own_profile="package",
            own_map_profile="tile_manifest",
            own_map_offset_x_m=0.25,
            own_map_offset_y_m=-0.40,
        )
    )

    assert geomag_map["rangex_min"] == pytest.approx(0.25)
    assert geomag_map["rangey_min"] == pytest.approx(-0.40)


def test_survey_vector_map_attaches_with_physical_axis_order(tmp_path):
    line_vectors = np.arange(8 * 5 * 3, dtype=float).reshape(8, 5, 3)
    vector_map_path = tmp_path / "own_vector_map.npz"
    np.savez_compressed(
        vector_map_path,
        line_vectors=line_vectors,
        x_line_positions_m=np.linspace(0.0, 6.72, 8),
        y_sample_positions_m=np.linspace(0.0, 8.074005934718102, 5),
    )
    geomag_map = build_own_geomag_map(
        BranchConfig(
            own_profile="package",
            own_map_profile="survey_kriging",
            own_vector_map_enabled=True,
            own_vector_map_path=str(vector_map_path),
        )
    )

    assert geomag_map["vector_grid"].shape == (5, 8, 3)
    assert geomag_map["vector_grid"][2, 3] == pytest.approx(
        line_vectors[3, 2]
    )
    assert geomag_map["vector_grid_meta"]["flip_y"] is False
    assert geomag_map["vector_grid_meta"]["spacing_x_m"] == pytest.approx(0.96)


def test_motion_adaptive_smoothing_does_not_lag_expected_motion():
    output, diagnostics = smooth_pf_output(
        (0.0, 0.0),
        (1.0, 0.0),
        mode="motion_adaptive",
        alpha=0.7,
        step_len=1.0,
        heading_angle=0.0,
        weight_diagnostics={"ess_ratio": 1.0},
        motion_diagnostics={"heading_delta_rad": 0.0},
    )

    assert output == pytest.approx((1.0, 0.0))
    assert diagnostics["correction_gain"] == pytest.approx(0.3)


def test_motion_adaptive_smoothing_raises_correction_gain_on_turns():
    _, straight = smooth_pf_output(
        (0.0, 0.0),
        (0.8, 0.2),
        mode="motion_adaptive",
        alpha=0.7,
        step_len=1.0,
        heading_angle=0.0,
        motion_diagnostics={"heading_delta_rad": 0.0},
    )
    _, turn = smooth_pf_output(
        (0.0, 0.0),
        (0.8, 0.2),
        mode="motion_adaptive",
        alpha=0.7,
        step_len=1.0,
        heading_angle=0.0,
        motion_diagnostics={"heading_delta_rad": math.pi / 2.0},
    )

    assert turn["correction_gain"] > straight["correction_gain"]
