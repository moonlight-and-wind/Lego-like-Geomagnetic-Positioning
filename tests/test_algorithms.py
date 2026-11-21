import math

import numpy as np
import pytest

from Geomag import algorithms


def test_three_column_own_array_is_a_grid_unless_point_cloud_is_explicit():
    grid = np.asarray([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]])

    result = algorithms.get_map(source="own", own_grid_array=grid)

    assert result["point_cloud_mode"] == "tile_matrix"
    assert result["point_cloud_shape"] == [6, 3]


def test_explicit_point_cloud_input_keeps_xyz_rows():
    points = np.asarray([[0.0, 0.0, 40.0], [1.0, 0.0, 41.0], [0.0, 1.0, 42.0]])

    result = algorithms.get_map(
        source="own",
        own_grid_array=points,
        own_grid_format="point_cloud",
        own_grid_meta={"grid_step_m": 0.5},
    )

    assert result["point_cloud_mode"] == "point_cloud"
    assert result["point_cloud_shape"] == [3, 3]


def test_bilinear_upsample_uses_subcell_centres_without_stretching():
    result = algorithms._bilinear_upsample(
        np.asarray([[0.0, 10.0], [20.0, 30.0]]), factor=2
    )

    assert result.shape == (4, 4)
    assert result[0, 0] == pytest.approx(0.0)
    assert result[1, 1] == pytest.approx(7.5)
    assert result[-1, -1] == pytest.approx(30.0)


def test_corner_anchored_grid_bounds_span_intervals_not_sample_count():
    result = algorithms.get_map(
        source="own",
        own_grid_array=np.ones((3, 4)),
        own_grid_meta={
            "tile_size_x_m": 0.5,
            "tile_size_y_m": 0.25,
            "anchor": "corner",
            "flip_y": False,
        },
    )

    assert result["rangex_min"] == pytest.approx(0.0)
    assert result["rangex_max"] == pytest.approx(1.5)
    assert result["rangey_min"] == pytest.approx(0.0)
    assert result["rangey_max"] == pytest.approx(0.5)


def test_own_grid_can_load_from_csv_path(tmp_path):
    path = tmp_path / "grid.csv"
    np.savetxt(path, [[1.0, 2.0], [3.0, 4.0]], delimiter=",")

    result = algorithms.get_map(
        source="own",
        own_grid_map_path=path,
        own_grid_format="csv_matrix",
    )

    assert result["point_cloud_mode"] == "tile_matrix"
    assert result["point_cloud_shape"] == [4, 3]


def test_step_detector_rejects_duplicate_peak_inside_cooldown(monkeypatch):
    magnitudes = [9.0] * 10 + [10.756, 9.889, 9.044, 10.736, 10.612]
    samples = [
        [[value, 0.0, 0.0], [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]]
        for value in magnitudes
    ]
    kwargs = {
        "method": "peak_dynamic",
        "peak_sigma": 0.1,
        "peak_prominence": 0.1,
        "min_samples_per_step": 4,
        "min_step_interval_s": 0.4,
    }
    monkeypatch.setitem(algorithms._ALGO_STATE, "last_step_time", None)

    monkeypatch.setitem(algorithms._ALGO_STATE, "last_sensor_frame", {"time": 1.0})
    assert algorithms.judge_step(samples, **kwargs)

    monkeypatch.setitem(algorithms._ALGO_STATE, "last_sensor_frame", {"time": 1.2})
    assert not algorithms.judge_step(samples, **kwargs)

    monkeypatch.setitem(algorithms._ALGO_STATE, "last_sensor_frame", {"time": 1.5})
    assert algorithms.judge_step(samples, **kwargs)


def test_own_compass_is_aligned_from_known_initial_heading(monkeypatch):
    samples = [
        [[0.0, 0.0, 9.80665], [0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]
        for _ in range(10)
    ]
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {"source": "own", "gyro_mode": "angular_rate_rad_s"},
    )
    monkeypatch.setitem(algorithms._ALGO_STATE, "heading_rad", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "is_heading_initialized", False)
    monkeypatch.setitem(algorithms._ALGO_STATE, "compass_alignment_rad", None)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_z", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_samples", 0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_sum", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_pending_sum", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_pending_samples", 0)
    monkeypatch.setitem(
        algorithms._ALGO_STATE, "gyro_bias_pending_start_time", None
    )
    monkeypatch.setitem(
        algorithms._ALGO_STATE, "gyro_bias_stationary_confirmed", False
    )

    heading = algorithms.get_heading_angle(
        samples,
        method="q_fused",
        dt=0.01,
        alpha=0.9,
        initial_heading_rad=math.pi / 2.0,
    )
    diagnostics = algorithms.get_heading_diagnostics()

    assert heading == pytest.approx(math.pi / 2.0)
    assert diagnostics["compass_start_calibrated"] is True
    assert diagnostics["compass_innovation_deg"] == pytest.approx(0.0)


def test_core_motion_heading_preserves_relative_yaw_from_route_anchor(monkeypatch):
    samples = [
        [[0.0, 0.0, 9.80665], [0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 0.0]
    ]
    for key, value in {
        "heading_rad": 0.0,
        "is_heading_initialized": False,
        "core_motion_yaw_origin_rad": None,
    }.items():
        monkeypatch.setitem(algorithms._ALGO_STATE, key, value)
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {
            "source": "own",
            "gyro_mode": "angular_rate_rad_s",
            "core_motion_yaw_rad": 0.2,
        },
    )

    first = algorithms.get_heading_angle(
        samples,
        method="core_motion",
        initial_heading_rad=1.0,
        calibrate_gyro_bias=False,
    )
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {
            "source": "own",
            "gyro_mode": "angular_rate_rad_s",
            "core_motion_yaw_rad": 0.7,
        },
    )
    second = algorithms.get_heading_angle(
        samples,
        method="core_motion",
        initial_heading_rad=1.0,
        calibrate_gyro_bias=False,
    )

    assert first == pytest.approx(1.0)
    assert second == pytest.approx(1.5)
    assert algorithms.get_heading_diagnostics()["method"] == "core_motion"


def test_stationary_samples_calibrate_gyro_z_bias(monkeypatch):
    samples = [
        [[0.0, 0.0, 9.80665], [0.0, 0.0, 0.05], [1.0, 0.0, 0.0]]
        for _ in range(20)
    ]
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {"source": "own", "gyro_mode": "angular_rate_rad_s"},
    )
    monkeypatch.setitem(algorithms._ALGO_STATE, "heading_rad", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "is_heading_initialized", False)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_z", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_samples", 0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_sum", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_pending_sum", 0.0)
    monkeypatch.setitem(algorithms._ALGO_STATE, "gyro_bias_pending_samples", 0)
    monkeypatch.setitem(
        algorithms._ALGO_STATE, "gyro_bias_pending_start_time", None
    )
    monkeypatch.setitem(
        algorithms._ALGO_STATE, "gyro_bias_stationary_confirmed", False
    )

    heading = algorithms.get_heading_angle(
        samples,
        method="gyro",
        dt=0.01,
        initial_heading_rad=0.0,
        calibrate_gyro_bias=True,
        stationary_min_duration_s=0.0,
    )

    assert heading == pytest.approx(0.0)
    assert algorithms.get_heading_diagnostics()["gyro_bias_z_rad_s"] == pytest.approx(0.05)


def test_isolated_stationary_candidate_does_not_calibrate_gyro_bias(monkeypatch):
    for key, value in {
        "heading_rad": 0.0,
        "is_heading_initialized": False,
        "gyro_bias_z": 0.0,
        "gyro_bias_samples": 0,
        "gyro_bias_sum": 0.0,
        "gyro_bias_pending_sum": 0.0,
        "gyro_bias_pending_samples": 0,
        "gyro_bias_pending_start_time": None,
        "gyro_bias_stationary_confirmed": False,
        "last_heading_time": None,
        "last_yaw_rate_rad_s": None,
    }.items():
        monkeypatch.setitem(algorithms._ALGO_STATE, key, value)
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {"source": "own", "gyro_mode": "angular_rate_rad_s"},
    )

    algorithms.get_heading_angle(
        [[[0.0, 0.0, 9.80665], [0.0, 0.0, 0.05], [1.0, 0.0, 0.0], 0.0]],
        method="gyro",
        initial_heading_rad=0.0,
    )
    algorithms.get_heading_angle(
        [[[0.0, 0.0, 11.0], [0.0, 0.0, 0.5], [1.0, 0.0, 0.0], 0.01]],
        method="gyro",
        initial_heading_rad=0.0,
    )

    diagnostics = algorithms.get_heading_diagnostics()
    assert diagnostics["gyro_bias_samples"] == 0
    assert diagnostics["gyro_bias_z_rad_s"] == pytest.approx(0.0)


def test_adaptive_step_length_exposes_trainable_features():
    samples = [
        [[9.0, 0.0, 0.0], [0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 1.0],
        [[11.0, 0.0, 0.0], [0.0, 0.0, 0.0], [1.0, 0.0, 0.0], 1.5],
    ]

    length = algorithms.get_step_len(
        samples,
        method="adaptive",
        weinberg_k=0.3,
        intercept_m=0.1,
        cadence_weight=0.05,
        cadence_reference_hz=1.0,
    )
    diagnostics = algorithms.get_step_length_diagnostics()

    expected_base = 0.3 * (2.0**0.25)
    assert length == pytest.approx(0.1 + expected_base + 0.05)
    assert diagnostics["cadence_hz"] == pytest.approx(2.0)


def test_continuous_heading_uses_timestamps_and_gravity_projection(monkeypatch):
    for key, value in {
        "heading_rad": 0.0,
        "is_heading_initialized": False,
        "gyro_bias_z": 0.0,
        "gyro_bias_samples": 0,
        "gyro_bias_sum": 0.0,
        "last_heading_time": None,
        "last_yaw_rate_rad_s": None,
        "gravity_vector": None,
    }.items():
        monkeypatch.setitem(algorithms._ALGO_STATE, key, value)
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {"source": "own", "gyro_mode": "angular_rate_rad_s"},
    )
    frame0 = [[[9.80665, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 0.0], 2.0]]
    frame1 = [[[9.80665, 0.0, 0.0], [1.0, 0.0, 0.0], [1.0, 0.0, 0.0], 2.1]]

    first = algorithms.get_heading_angle(
        frame0,
        method="gyro",
        initial_heading_rad=0.0,
        calibrate_gyro_bias=False,
    )
    second = algorithms.get_heading_angle(
        frame1,
        method="gyro",
        initial_heading_rad=0.0,
        calibrate_gyro_bias=False,
    )

    assert first == pytest.approx(0.0)
    assert second == pytest.approx(0.1)


def test_continuous_heading_applies_rate_scale_after_bias(monkeypatch):
    for key, value in {
        "heading_rad": 0.0,
        "is_heading_initialized": False,
        "gyro_bias_z": 0.2,
        "gyro_bias_samples": 1,
        "gyro_bias_sum": 0.2,
        "last_heading_time": None,
        "last_yaw_rate_rad_s": None,
        "gravity_vector": None,
    }.items():
        monkeypatch.setitem(algorithms._ALGO_STATE, key, value)
    monkeypatch.setitem(
        algorithms._ALGO_STATE,
        "last_sensor_frame",
        {"source": "own", "gyro_mode": "angular_rate_rad_s"},
    )
    frame0 = [[[0.0, 0.0, 9.80665], [0.0, 0.0, 1.2], [1.0, 0.0, 0.0], 3.0]]
    frame1 = [[[0.0, 0.0, 9.80665], [0.0, 0.0, 1.2], [1.0, 0.0, 0.0], 3.1]]

    algorithms.get_heading_angle(
        frame0,
        method="gyro",
        initial_heading_rad=0.0,
        calibrate_gyro_bias=False,
        project_gyro_to_gravity=False,
        gyro_rate_scale=0.5,
    )
    heading = algorithms.get_heading_angle(
        frame1,
        method="gyro",
        initial_heading_rad=0.0,
        calibrate_gyro_bias=False,
        project_gyro_to_gravity=False,
        gyro_rate_scale=0.5,
    )

    assert heading == pytest.approx(0.05)
    assert algorithms.get_heading_diagnostics()["gyro_rate_scale"] == pytest.approx(0.5)
