import numpy as np
import pytest

from Geomag.branching import (
    build_uniform_walk_progress,
    endpoint_error,
    infer_active_walk_interval,
    slice_route_controls,
    snap_heading_to_grid,
    summarize_corner_errors,
    update_grid_heading_state,
    update_heading_integrity,
)
from Geomag.nn import Module
from Geomag.pipeline import GeomagPipeline, PFModule


def test_error_series_can_align_track_by_sensor_progress():
    route_x = np.linspace(0.0, 10.0, 101)
    route_y = np.zeros_like(route_x)
    track = [(0.0, 0.0), (2.0, 0.0), (9.0, 0.0)]

    error = GeomagPipeline._compute_error_series(
        track,
        route_x,
        route_y,
        progress=[0.0, 0.2, 0.9],
    )

    assert error == pytest.approx([0.0, 0.0, 0.0])


def test_active_walk_interval_excludes_stationary_recording_tails():
    interval = infer_active_walk_interval(
        step_times=[5.0, 7.0, 9.0, 11.0, 13.0],
        capture_start_time=0.0,
        capture_end_time=20.0,
    )

    assert interval["start_time"] == pytest.approx(4.0)
    assert interval["end_time"] == pytest.approx(14.0)
    assert interval["head_excluded"] == pytest.approx(4.0)
    assert interval["tail_excluded"] == pytest.approx(6.0)
    assert interval["confidence"] == "high"


def test_uniform_walk_progress_uses_active_interval_not_full_recording():
    progress, interval = build_uniform_walk_progress(
        step_times=[5.0, 7.0, 9.0, 11.0, 13.0],
        capture_start_time=0.0,
        capture_end_time=20.0,
    )
    legacy_progress, _ = build_uniform_walk_progress(
        step_times=[5.0, 7.0, 9.0, 11.0, 13.0],
        capture_start_time=0.0,
        capture_end_time=20.0,
        mode="capture_time",
    )

    assert progress == pytest.approx([0.1, 0.3, 0.5, 0.7, 0.9])
    assert legacy_progress == pytest.approx([0.25, 0.35, 0.45, 0.55, 0.65])
    assert interval["reason"] == "step_event_envelope"


def test_active_walk_interval_falls_back_when_steps_are_insufficient():
    interval = infer_active_walk_interval(
        step_times=[5.0],
        capture_start_time=0.0,
        capture_end_time=20.0,
    )

    assert interval["start_time"] == pytest.approx(0.0)
    assert interval["end_time"] == pytest.approx(20.0)
    assert interval["confidence"] == "low"


def test_error_series_rejects_mismatched_progress_length():
    with pytest.raises(ValueError, match="same length"):
        GeomagPipeline._compute_error_series(
            [(0.0, 0.0), (1.0, 0.0)],
            [0.0, 1.0],
            [0.0, 0.0],
            progress=[0.0],
        )


def test_error_series_aligns_by_polyline_distance_not_control_point_index():
    route_x = [0.0, 9.0, 10.0]
    route_y = [0.0, 0.0, 0.0]
    track = [(0.0, 0.0), (5.0, 0.0), (10.0, 0.0)]

    error = GeomagPipeline._compute_error_series(
        track, route_x, route_y, progress=[0.0, 0.5, 1.0]
    )

    assert error == pytest.approx([0.0, 0.0, 0.0])


def test_cross_track_error_uses_nearest_point_on_segment():
    error = GeomagPipeline._compute_cross_track_error_series(
        [(5.0, 2.0), (12.0, 0.0)],
        [0.0, 10.0],
        [0.0, 0.0],
    )

    assert error == pytest.approx([2.0, 2.0])


def test_pf_module_returns_posterior_estimate_before_resampling(pf_state):
    class PosteriorThenResample(Module):
        def forward(self, ctx):
            ctx["posterior_pos"] = (1.25, 1.75)
            for particle in ctx["pf_state"].particles:
                particle.x = 0.0
                particle.y = 0.0
            return ctx

    module = PFModule(stages=PosteriorThenResample())

    result = module.step(
        pf_state=pf_state,
        step_len=0.0,
        heading_angle=0.0,
        geomag_seq=[],
    )

    assert result == pytest.approx((1.25, 1.75))


def test_grid_heading_snap_uses_known_orthogonal_walk_prior():
    anchor = np.pi / 2.0

    assert snap_heading_to_grid(np.radians(28.0), anchor, 90.0) == pytest.approx(0.0)
    assert snap_heading_to_grid(np.radians(62.0), anchor, 90.0) == pytest.approx(
        np.pi / 2.0
    )
    assert snap_heading_to_grid(np.radians(28.0), anchor, 0.0) == pytest.approx(
        np.radians(28.0)
    )


def test_grid_heading_state_commits_sustained_turn_before_half_interval():
    heading = np.pi / 2.0
    count = 0
    direction = 0
    for measured_deg in [75.6, 73.3, 61.4]:
        heading, count, direction = update_grid_heading_state(
            np.radians(measured_deg),
            heading,
            interval_deg=90.0,
            departure_count=count,
            departure_direction=direction,
        )

    assert heading == pytest.approx(0.0)
    assert count == 0
    assert direction == 0


def test_grid_heading_state_rejects_isolated_straight_line_noise():
    heading = np.pi / 2.0
    count = 0
    direction = 0
    for measured_deg in [75.0, 85.0]:
        heading, count, direction = update_grid_heading_state(
            np.radians(measured_deg),
            heading,
            interval_deg=90.0,
            departure_count=count,
            departure_direction=direction,
        )

    assert heading == pytest.approx(np.pi / 2.0)


def test_heading_integrity_detects_sustained_yaw_but_not_single_right_turn():
    right_turn = update_heading_integrity(
        np.radians([0.0, 0.0, 90.0, 0.0, 0.0]),
    )
    sustained_bias = update_heading_integrity(
        np.radians([28.0, 28.0, 28.0, 28.0, 28.0]),
    )

    assert right_turn["fault_started"] is False
    assert sustained_bias["fault_started"] is True
    assert sustained_bias["fault_active"] is True


def test_heading_integrity_clears_only_after_sustained_small_deltas():
    history = list(np.radians([28.0] * 5))
    clear_streak = 0
    result = {"fault_active": True}
    for _ in range(5):
        history.append(0.0)
        result = update_heading_integrity(
            history,
            fault_active=True,
            clear_streak=clear_streak,
        )
        clear_streak = result["clear_streak"]

    assert result["fault_active"] is False


def test_corner_and_endpoint_metrics_use_event_positions():
    route = [(0.0, 0.0), (0.0, 5.0), (3.0, 5.0)]
    track = [(0.0, 0.0), (0.2, 4.8), (2.5, 5.1)]
    turns = [{"step_index": 1, "progress": 0.6}]

    matches, stats = summarize_corner_errors(track, route, turns)

    assert matches[0]["error_m"] == pytest.approx(np.hypot(0.2, 0.2))
    assert stats["mean"] == pytest.approx(np.hypot(0.2, 0.2))
    assert endpoint_error(track, route) == pytest.approx(np.hypot(0.5, 0.1))


def test_slice_route_controls_keeps_only_corners_in_active_capture():
    route = [(0.0, 0.0), (0.0, 8.0), (4.0, 8.0), (4.0, 0.0)]

    active = slice_route_controls(route, start_frac=0.25, end_frac=0.75)

    np.testing.assert_allclose(
        active, [(0.0, 5.0), (0.0, 8.0), (4.0, 8.0), (4.0, 5.0)]
    )
