import numpy as np
import pytest

from geomag_v2.capture import Capture
from geomag_v2.free_motion import (
    FreeSegment,
    detect_turn_regions,
    integrate_free_track,
)
from geomag_v2.magnetic_map import MagneticMap, merge_maps, rotate_device_magnetic_to_local


def _capture_with_arbitrary_turns() -> Capture:
    time_s = np.linspace(0.0, 12.0, 1201)
    yaw_deg = np.interp(
        time_s,
        [0.0, 3.0, 4.0, 7.0, 8.0, 12.0],
        [0.0, 0.0, 60.0, 60.0, -50.0, -50.0],
    )
    zeros = np.zeros((time_s.size, 3))
    return Capture(
        dataset_key="synthetic",
        time_s=time_s,
        yaw_rad=np.radians(yaw_deg),
        user_acceleration_mps2=zeros,
        rotation_rate_radps=zeros,
        magnetic_field_ut=np.tile([20.0, 30.0, 40.0], (time_s.size, 1)),
    )


def _free_segment(index: int, heading_rad: float) -> FreeSegment:
    axis = np.linspace(0.0, 1.0, 101)
    return FreeSegment(
        index=index,
        start_index=0,
        end_index=100,
        duration_s=1.0,
        step_count=2,
        sqrt_prominence_sum=2.0,
        prominence_sum_mps2=2.0,
        acceleration_rms_mps2=1.0,
        relative_yaw_rad=np.full(axis.size, heading_rad),
        time_s=axis,
        magnetic_field_ut=np.tile([20.0, 30.0, 40.0], (axis.size, 1)),
        inertial_progress=axis,
    )


def test_generic_turn_detector_preserves_arbitrary_angles():
    turns = detect_turn_regions(_capture_with_arbitrary_turns())

    assert len(turns) == 2
    assert turns[0].signed_angle_deg == pytest.approx(60.0, abs=5.0)
    assert turns[1].signed_angle_deg == pytest.approx(-110.0, abs=5.0)


def test_free_track_integrates_heading_without_ninety_degree_snap():
    segments = [_free_segment(0, 0.0), _free_segment(1, np.pi / 3.0)]

    track, corners = integrate_free_track(segments, np.asarray([2.0, 1.0]))

    np.testing.assert_allclose(track[corners[1]], [2.0, 0.0], atol=1e-9)
    np.testing.assert_allclose(track[-1], [2.5, np.sqrt(3.0) / 2.0], atol=1e-9)


def test_magnetic_map_rejects_mixed_spatial_frames():
    points = np.asarray([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]])
    vectors = np.asarray([[20.0, 30.0, 40.0], [21.0, 30.0, 40.0], [20.0, 31.0, 40.0]])
    first = MagneticMap(points, vectors, "floor-a-survey")
    second = MagneticMap(points, vectors, "route-local")

    with pytest.raises(ValueError, match="different coordinate frames"):
        merge_maps([first, second])


def test_magnetic_map_query_and_heading_rotation():
    points = np.asarray([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]])
    vectors = np.asarray([[20.0, 30.0, 40.0], [22.0, 30.0, 40.0], [20.0, 32.0, 40.0]])
    magnetic_map = MagneticMap(points, vectors, "floor-a-survey")

    prediction, distance = magnetic_map.query(np.asarray([0.05, 0.05]))
    rotated = rotate_device_magnetic_to_local(
        np.asarray([[1.0, 0.0, 2.0]]),
        np.asarray([np.pi / 2.0]),
    )

    assert prediction.shape == (3,)
    assert distance < 0.1
    np.testing.assert_allclose(rotated, [[0.0, 1.0, 2.0]], atol=1e-9)
