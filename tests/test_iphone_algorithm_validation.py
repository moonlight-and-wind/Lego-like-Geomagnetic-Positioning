import numpy as np

from Geomag.iphone_algorithm_validation import (
    CaptureSpec,
    _algorithm_release_manifest,
    _build_segment_calibration,
    _initial_reference_frame,
    _magnetic_progress_result,
    _optimized_motion_result,
    _sample_level_turn_regions,
    _step_attitude_aligned_magnetic_vectors,
    _straight_step_partition,
    _template_yaw_evidence,
)


def test_algorithm_release_manifest_keeps_shadow_out_of_recommended_result():
    comparison = {
        "validation_magnetic_heading_cross_track_mean_m": 0.123,
        "validation_magnetic_heading_closure_mean_m": 0.161,
        "registered_direction_free_deployment_status": ("promising_shadow_requires_more_routes"),
        "validation_registered_direction_free_cross_track_mean_m": 0.132,
        "validation_registered_direction_free_closure_mean_m": 0.161,
        "direction_free_deployment_status": "rejected_shadow_regression",
        "validation_direction_free_cross_track_mean_m": 0.142,
    }

    release = _algorithm_release_manifest(comparison, {"heading_prior_floor": 0.1})

    assert release["status"] == "frozen_for_native_integration"
    assert release["recommended"]["result_key"] == "magnetic_heading_runs"
    assert release["direction_free_shadow"]["result_key"] == ("registered_direction_free_shadow_runs")
    assert release["direction_free_shadow"]["deployment_status"] == ("promising_shadow_requires_more_routes")
    assert release["rejected_shadow"]["deployment_status"] == ("rejected_shadow_regression")
    assert release["free_path_status"] == "not_validated"


def _synthetic_result():
    headings = [
        90,
        90,
        90,
        45,
        0,
        0,
        0,
        -45,
        -90,
        -90,
        -90,
        -135,
        -180,
        -180,
        -180,
    ]
    return {
        "step_length_history_m": [0.5] * 14,
        "heading_history_deg": headings,
        "detected_turns": [
            {"turn_start_step_index": 2, "step_index": 4},
            {"turn_start_step_index": 6, "step_index": 8},
            {"turn_start_step_index": 10, "step_index": 12},
        ],
        "pdr_track": [[0.0, 0.0]] * 15,
        "track_progress": np.linspace(0.0, 1.0, 15).tolist(),
        "steps_detected": 14,
        "step_sensor_time_history_s": np.arange(14, dtype=float).tolist(),
    }


def test_straight_partition_removes_turn_translation_steps():
    _, _, keep, segment, method = _straight_step_partition(_synthetic_result())

    assert method == "step_level_fallback"
    assert np.flatnonzero(~keep).tolist() == [2, 3, 6, 7, 10, 11]
    assert [np.count_nonzero(keep & (segment == index)) for index in range(4)] == [
        2,
        2,
        2,
        2,
    ]


def test_controlled_optimization_closes_square_without_turn_translation():
    spec = CaptureSpec(
        "square_1",
        "square",
        ((0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)),
        0.0,
        "confirmed",
    )
    result = _synthetic_result()
    calibration = _build_segment_calibration(spec, result)

    optimized = _optimized_motion_result(
        spec,
        result,
        calibration,
        distance_prior_floor=0.1,
        heading_prior_floor=0.1,
    )

    assert optimized["turn_translation_steps_removed"] == 6
    assert optimized["estimated_segment_lengths_m"] == [1.0, 1.0, 1.0, 1.0]
    np.testing.assert_allclose(optimized["pdr_track"][-1], [0.0, 0.0], atol=1e-12)


def test_sample_level_partition_uses_variable_turn_widths():
    result = _synthetic_result()
    result["sample_level_turn_regions"] = [
        {"onset_time_s": 2.0, "completion_time_s": 2.0},
        {"onset_time_s": 6.0, "completion_time_s": 7.0},
        {"onset_time_s": 10.0, "completion_time_s": 10.0},
    ]

    _, _, keep, segment, method = _straight_step_partition(result)

    assert method == "sample_level"
    assert np.flatnonzero(~keep).tolist() == [2, 6, 7, 10]
    assert [np.count_nonzero(keep & (segment == index)) for index in range(4)] == [
        2,
        3,
        2,
        3,
    ]


def test_sample_level_turn_detector_finds_four_yaw_transitions(tmp_path):
    time_s = np.arange(0.0, 10.0, 0.01)
    yaw_deg = np.interp(
        time_s,
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [0, 0, -90, -90, -180, -180, -270, -270, -360, -360],
    )
    path = tmp_path / "DeviceMotion.csv"
    rows = ["Time (s),Yaw (rad)"]
    rows.extend(f"{time:.3f},{yaw:.9f}" for time, yaw in zip(time_s, np.radians(yaw_deg), strict=True))
    path.write_text("\n".join(rows) + "\n", encoding="utf-8")

    regions = _sample_level_turn_regions(path)

    assert len(regions) == 4
    assert all(region["onset_time_s"] < region["completion_time_s"] for region in regions)
    assert all(-105.0 < region["signed_angle_deg"] < -75.0 for region in regions)


def test_attitude_aligned_magnetic_vectors_use_named_xyz_columns(tmp_path):
    header = (
        "Time (s),Quaternion X,Quaternion Y,Quaternion Z,Quaternion W,"
        "Magnetic Field X (µT),Magnetic Field Y (µT),Magnetic Field Z (µT),"
        "Magnetic Accuracy"
    )
    rows = [
        header,
        "0,0,0,0,1,10,20,30,2",
        "1,0,0,0,1,20,30,40,1",
    ]
    (tmp_path / "DeviceMotion.csv").write_text("\n".join(rows) + "\n", encoding="utf-8")

    vectors = _step_attitude_aligned_magnetic_vectors(
        tmp_path,
        {"step_sensor_time_history_s": [0.0, 0.5, 1.0]},
    )

    np.testing.assert_allclose(
        vectors,
        [[10.0, 20.0, 30.0], [15.0, 25.0, 35.0], [20.0, 30.0, 40.0]],
    )


def test_initial_reference_frame_accepts_stationary_calibrated_window(tmp_path):
    header = (
        "Time (s),Quaternion X,Quaternion Y,Quaternion Z,Quaternion W,"
        "User Acceleration X (m/s^2),User Acceleration Y (m/s^2),"
        "User Acceleration Z (m/s^2),Rotation Rate X (rad/s),"
        "Rotation Rate Y (rad/s),Rotation Rate Z (rad/s),"
        "Magnetic Field X (µT),Magnetic Field Y (µT),Magnetic Field Z (µT),"
        "Magnetic Accuracy"
    )
    rows = [header]
    rows.extend(f"{index / 100:.2f},0,0,0,1,0.01,0.01,0.01,0.01,0.01,0.01,20,5,-40,2" for index in range(100))
    (tmp_path / "DeviceMotion.csv").write_text("\n".join(rows) + "\n", encoding="utf-8")

    reference = _initial_reference_frame(tmp_path)

    assert reference["accepted"]
    assert reference["sample_count"] == 100
    np.testing.assert_allclose(reference["aligned_magnetic_vector_ut"], [20.0, 5.0, -40.0])


def test_template_yaw_evidence_recovers_rotation_without_route_direction():
    progress = np.linspace(0.2, 1.0, 6)
    reference_vectors = np.column_stack(
        [
            [20.0, 25.0, 22.0, 31.0, 28.0, 40.0],
            [8.0, 6.0, 9.0, 4.0, 7.0, 3.0],
            [-42.0, -40.0, -41.0, -39.0, -40.0, -38.0],
        ]
    )
    angle = np.radians(5.0)
    query_vectors = reference_vectors.copy()
    query_vectors[:, 0] = np.cos(angle) * reference_vectors[:, 0] - np.sin(angle) * reference_vectors[:, 1]
    query_vectors[:, 1] = np.sin(angle) * reference_vectors[:, 0] + np.cos(angle) * reference_vectors[:, 1]
    reference = {
        "magnetic_norm_ut": np.linalg.norm(reference_vectors, axis=1),
        "aligned_magnetic_vector_ut": reference_vectors,
        "progress": progress,
    }

    evidence = _template_yaw_evidence(
        np.linalg.norm(query_vectors, axis=1),
        query_vectors,
        progress,
        reference,
        fit_residual_limit=0.2,
    )

    assert evidence["accepted"]
    assert np.isclose(evidence["yaw_delta_deg"], -5.0, atol=0.1)


def test_distance_prior_increases_for_conflicting_segment():
    spec = CaptureSpec(
        "square_2",
        "square",
        ((0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)),
        0.0,
        "confirmed",
    )
    calibration_result = _synthetic_result()
    calibration = _build_segment_calibration(spec, calibration_result)
    query = _synthetic_result()
    query["step_length_history_m"][4:6] = [1.5, 1.5]

    optimized = _optimized_motion_result(spec, query, calibration)

    priors = optimized["effective_distance_prior_by_segment"]
    assert priors[1] > 0.95
    assert priors[1] > priors[0]


def test_heading_prior_increases_for_inconsistent_segment():
    spec = CaptureSpec(
        "square_3",
        "square",
        ((0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)),
        0.0,
        "confirmed",
    )
    calibration_result = _synthetic_result()
    calibration = _build_segment_calibration(spec, calibration_result)
    query = _synthetic_result()
    query["heading_history_deg"][5:7] = [30.0, 30.0]

    optimized = _optimized_motion_result(spec, query, calibration)

    priors = optimized["effective_heading_prior_by_segment"]
    assert priors[1] > 0.95
    assert priors[1] > priors[0]


def test_magnetic_progress_cannot_move_segment_endpoints(tmp_path):
    spec = CaptureSpec(
        "square_query",
        "square",
        ((0.0, 0.0), (0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)),
        0.0,
        "confirmed",
    )
    headings = [90.0] * 5 + [0.0] * 5 + [-90.0] * 5 + [-180.0] * 5
    result = {
        "step_length_history_m": [0.2] * 20,
        "heading_history_deg": [90.0, *headings],
        "detected_turns": [
            {"turn_start_step_index": 5, "step_index": 5},
            {"turn_start_step_index": 10, "step_index": 10},
            {"turn_start_step_index": 15, "step_index": 15},
        ],
        "step_sensor_time_history_s": np.arange(20, dtype=float).tolist(),
    }
    profile = [40.0, 42.0, 41.0, 45.0, 44.0]
    rows = ["Time (s),X (µT),Y (µT),Z (µT)"]
    rows.extend(f"{index},{value},0,0" for index, value in enumerate(profile * 4))
    (tmp_path / "Magnetometer.csv").write_text("\n".join(rows) + "\n", encoding="utf-8")
    optimized = {
        "pdr_track": [[0.0, 0.0], [0.0, 0.0]],
        "step_length_history_m": [0.2] * 20,
        "steps_detected": 20,
        "track_progress": np.linspace(0.0, 1.0, 21).tolist(),
        "estimated_segment_lengths_m": [1.0] * 4,
        "segment_headings_deg": [90.0, 0.0, -90.0, -180.0],
    }
    magnetic_calibration = {
        "source_key": "square_map",
        "segments": [
            {
                "magnetic_norm_ut": np.asarray(profile),
                "progress": np.linspace(0.2, 1.0, 5),
                "step_count": 5,
            }
            for _ in range(4)
        ],
    }

    fused = _magnetic_progress_result(
        spec,
        result,
        optimized,
        tmp_path,
        magnetic_calibration,
    )

    assert fused["magnetic_matched_segments"] == 4
    np.testing.assert_allclose(fused["pdr_track"][-1], [0.0, 0.0], atol=1e-12)
    for segment in range(4):
        start = segment * 5
        assert np.isclose(sum(fused["step_length_history_m"][start : start + 5]), 1.0)
