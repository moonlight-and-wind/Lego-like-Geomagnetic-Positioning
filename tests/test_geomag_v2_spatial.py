import json

import numpy as np
import pytest

from geomag_v2.capture import (
    Capture,
    SpatialEvent,
    SpatialReference,
    load_capture,
)
from geomag_v2.magnetic_map import build_anchored_magnetic_map
from geomag_v2.map_builder import build_map_from_root


def _write_format_three_package(package, anchors):
    package.mkdir()
    metadata = {
        "format_version": 3,
        "dataset_key": package.stem,
        "device_pose": "face_up_front_forward",
        "algorithm_magnetic_field_file": "Magnetometer.csv",
        "spatial_events_file": "SpatialEvents.csv",
        "spatial_reference": {
            "coordinate_frame": "building-a-floor-1",
            "unit": "m",
            "start_position_xy_m": [anchors[0][1], anchors[0][2]],
            "initial_heading_deg": 90.0,
        },
    }
    (package / "capture_metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
    event_rows = "".join(
        f'{time},anchor,"a{index}",{x},{y},90,0\n'
        for index, (time, x, y) in enumerate(anchors)
    )
    (package / "SpatialEvents.csv").write_text(
        "Time (s),Type,Label,X (m),Y (m),Heading (deg),Device Yaw (deg)\n"
        + event_rows,
        encoding="utf-8",
    )
    header = (
        "Time (s),Yaw (rad),User Acceleration X (m/s^2),"
        "User Acceleration Y (m/s^2),User Acceleration Z (m/s^2),"
        "Rotation Rate X (rad/s),Rotation Rate Y (rad/s),Rotation Rate Z (rad/s),"
        "Magnetic Field X (µT),Magnetic Field Y (µT),Magnetic Field Z (µT)\n"
    )
    rows = "".join(f"{index / 99},0,0,0,0,0,0,0,20,30,40\n" for index in range(100))
    (package / "DeviceMotion.csv").write_text(header + rows, encoding="utf-8")


def _anchored_capture(
    key: str,
    anchors: list[tuple[float, float, float]],
    *,
    frame: str = "building-a-floor-1",
) -> Capture:
    time_s = np.linspace(0.0, 1.0, 101)
    yaw = np.linspace(0.0, np.pi / 2.0, time_s.size)
    events = tuple(
        SpatialEvent(time, "anchor", f"a{index}", x, y, None, None)
        for index, (time, x, y) in enumerate(anchors)
    )
    return Capture(
        dataset_key=key,
        time_s=time_s,
        yaw_rad=yaw,
        user_acceleration_mps2=np.zeros((time_s.size, 3)),
        rotation_rate_radps=np.zeros((time_s.size, 3)),
        magnetic_field_ut=np.column_stack(
            (20.0 + time_s, 30.0 + time_s, 40.0 - time_s)
        ),
        format_version=3,
        spatial_reference=SpatialReference(frame, (anchors[0][1], anchors[0][2]), 0.0),
        spatial_events=events,
    )


def test_anchored_map_builds_in_one_shared_frame():
    first = _anchored_capture("first", [(0.0, 0.0, 0.0), (0.5, 1.0, 0.0), (1.0, 1.0, 1.0)])
    second = _anchored_capture("second", [(0.0, 0.0, 0.0), (0.5, 0.0, 1.0), (1.0, 1.0, 1.0)])

    magnetic_map = build_anchored_magnetic_map([first, second], sample_stride=5)
    prediction, distance = magnetic_map.query(np.asarray([1.0, 1.0]))

    assert magnetic_map.coordinate_frame == "building-a-floor-1"
    assert magnetic_map.points_xy_m.shape[0] > 20
    assert prediction.shape == (3,)
    assert distance < 0.1


def test_anchored_map_rejects_collinear_coverage():
    capture = _anchored_capture(
        "straight",
        [(0.0, 0.0, 0.0), (0.5, 1.0, 0.0), (1.0, 2.0, 0.0)],
    )

    with pytest.raises(ValueError, match="non-collinear"):
        build_anchored_magnetic_map([capture])


def test_format_three_loader_reads_spatial_reference_and_events(tmp_path):
    package = tmp_path / "spatial.geomagcapture"
    _write_format_three_package(package, [(0.0, 2.0, 3.0), (1.0, 2.0, 4.0)])

    capture = load_capture(package)

    assert capture.format_version == 3
    assert capture.spatial_reference is not None
    assert capture.spatial_reference.coordinate_frame == "building-a-floor-1"
    assert len(capture.spatial_events) == 2
    assert capture.spatial_events[1].has_position


def test_map_builder_runs_end_to_end_on_format_three_package(tmp_path):
    capture_root = tmp_path / "captures"
    capture_root.mkdir()
    _write_format_three_package(
        capture_root / "survey.geomagcapture",
        [(0.0, 0.0, 0.0), (0.5, 1.0, 0.0), (1.0, 1.0, 1.0)],
    )

    payload = build_map_from_root(
        capture_root,
        tmp_path / "map",
        coordinate_frame="building-a-floor-1",
        sample_stride=5,
    )

    assert payload["coordinate_frame"] == "building-a-floor-1"
    assert payload["map_samples"] >= 20
    assert (tmp_path / "map" / "magnetic_map.npz").exists()
    assert (tmp_path / "map" / "summary.json").exists()
    assert (tmp_path / "map" / "preview.png").exists()
