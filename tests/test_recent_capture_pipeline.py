import math

import numpy as np
import pytest

from Geomag.recent_capture_pipeline import (
    RECENT_CAPTURES,
    CaptureStreams,
    StepEvent,
    TurnEvent,
    _display_route_track,
    detect_quarter_turns,
    detect_recent_steps,
    route_position,
)


def test_recent_pipeline_references_only_new_capture_groups():
    assert {spec.route_group for spec in RECENT_CAPTURES} == {
        "route_13",
        "route_14",
        "route_15",
    }
    assert all(spec.key.startswith("route_1") for spec in RECENT_CAPTURES)


def test_quarter_turn_detector_splits_back_to_back_turns():
    time_s = np.linspace(0.0, 8.0, 801)
    yaw_deg = np.interp(
        time_s,
        [0.0, 1.0, 2.0, 2.2, 3.2, 4.0, 5.0, 6.0, 7.0, 8.0],
        [0.0, 0.0, -90.0, -90.0, -180.0, -180.0, -270.0, -270.0, -360.0, -360.0],
    )

    turns = detect_quarter_turns(time_s, np.radians(yaw_deg))

    assert len(turns) == 4
    assert turns[0].onset_time_s < turns[0].completion_time_s
    assert turns[1].onset_time_s < turns[1].completion_time_s
    assert turns[0].completion_time_s < turns[1].completion_time_s


def test_step_detector_rejects_turn_and_post_endpoint_peaks():
    sample_rate_hz = 100.0
    time_s = np.arange(0.0, 10.0, 1.0 / sample_rate_hz)
    vertical = 1.2 * np.sin(2.0 * math.pi * 1.5 * time_s)
    yaw = np.zeros_like(time_s)
    streams = CaptureStreams(
        time_s=time_s,
        yaw_unwrapped_rad=yaw,
        user_acceleration_mps2=np.column_stack(
            (np.zeros_like(time_s), np.zeros_like(time_s), vertical)
        ),
        rotation_rate_radps=np.zeros((time_s.size, 3)),
        magnetic_field_ut=np.tile([20.0, 30.0, 40.0], (time_s.size, 1)),
    )
    turns = [
        TurnEvent(1, 2.0, 2.8, -90.0),
        TurnEvent(2, 4.0, 4.8, -90.0),
        TurnEvent(3, 6.0, 6.8, -90.0),
        TurnEvent(4, 8.0, 8.8, -90.0),
    ]

    steps, diagnostics = detect_recent_steps(streams, turns)

    assert steps
    assert all(step.time_s <= 8.0 for step in steps)
    assert all(
        not any(
            turn.onset_time_s - 0.1
            <= step.time_s
            <= turn.completion_time_s + 0.1
            for turn in turns
        )
        for step in steps
    )
    assert diagnostics["turn_peak_rejections"] > 0


def test_route_position_follows_short_edges_exactly():
    route = ((0.0, 0.0), (0.0, -6.0), (-0.6, -6.0), (-0.6, 0.0), (0.0, 0.0))
    progress = np.asarray([0.0, 6.0 / 13.2, 6.6 / 13.2, 12.6 / 13.2, 1.0])

    positions = route_position(route, progress)

    np.testing.assert_allclose(positions, route, atol=1e-9)


def test_display_track_inserts_corner_instead_of_diagonal():
    route = ((0.0, 0.0), (0.0, 2.0), (1.0, 2.0), (1.0, 0.0), (0.0, 0.0))
    steps = [
        StepEvent(1.0, 1.0, 0.0, (1.0, 2.0, 3.0), 0),
        StepEvent(2.0, 1.0, 0.0, (1.0, 2.0, 3.0), 1),
    ]
    positions = np.asarray([[0.0, 1.5], [0.5, 2.0]])

    display = _display_route_track(steps, positions, route)

    assert any(np.allclose(point, route[1]) for point in display)
    assert display[-1] == pytest.approx(route[-1])
