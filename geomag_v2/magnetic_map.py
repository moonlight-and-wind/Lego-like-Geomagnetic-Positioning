"""Coordinate-safe magnetic-map interface for free-path localization."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from geomag_v2.capture import Capture


@dataclass(frozen=True)
class MagneticMap:
    points_xy_m: np.ndarray
    vectors_ut: np.ndarray
    coordinate_frame: str

    def __post_init__(self) -> None:
        points = np.asarray(self.points_xy_m, dtype=float)
        vectors = np.asarray(self.vectors_ut, dtype=float)
        if points.ndim != 2 or points.shape[1] != 2:
            raise ValueError("Magnetic-map points must have shape (N, 2).")
        if vectors.shape != (points.shape[0], 3):
            raise ValueError("Magnetic-map vectors must have shape (N, 3).")
        if points.shape[0] < 3:
            raise ValueError("A magnetic map requires at least three samples.")
        if not self.coordinate_frame.strip():
            raise ValueError("A magnetic map requires an explicit coordinate frame.")

    def query(self, position_xy_m: np.ndarray, *, neighbors: int = 6) -> tuple[np.ndarray, float]:
        position = np.asarray(position_xy_m, dtype=float)
        if position.shape != (2,):
            raise ValueError("Map query position must contain x and y.")
        distance = np.linalg.norm(self.points_xy_m - position, axis=1)
        count = min(max(1, int(neighbors)), distance.size)
        nearest = np.argpartition(distance, count - 1)[:count]
        nearest_distance = distance[nearest]
        weights = 1.0 / np.maximum(nearest_distance, 0.05) ** 2
        prediction = np.average(self.vectors_ut[nearest], axis=0, weights=weights)
        return prediction, float(nearest_distance.min())

    def save(self, path: Path) -> None:
        np.savez_compressed(
            path,
            points_xy_m=np.asarray(self.points_xy_m),
            vectors_ut=np.asarray(self.vectors_ut),
            coordinate_frame=np.asarray(self.coordinate_frame),
        )

    @classmethod
    def load(cls, path: Path) -> MagneticMap:
        with np.load(path, allow_pickle=False) as payload:
            return cls(
                points_xy_m=payload["points_xy_m"],
                vectors_ut=payload["vectors_ut"],
                coordinate_frame=str(payload["coordinate_frame"].item()),
            )


def merge_maps(maps: list[MagneticMap]) -> MagneticMap:
    if not maps:
        raise ValueError("At least one magnetic map is required.")
    frames = {item.coordinate_frame for item in maps}
    if len(frames) != 1:
        raise ValueError(
            "Magnetic maps use different coordinate frames; add surveyed global anchors before merging."
        )
    return MagneticMap(
        points_xy_m=np.vstack([item.points_xy_m for item in maps]),
        vectors_ut=np.vstack([item.vectors_ut for item in maps]),
        coordinate_frame=maps[0].coordinate_frame,
    )


def rotate_device_magnetic_to_local(
    vectors_ut: np.ndarray,
    relative_yaw_rad: np.ndarray,
    *,
    initial_heading_rad: float = 0.0,
) -> np.ndarray:
    vectors = np.asarray(vectors_ut, dtype=float)
    yaw = np.asarray(relative_yaw_rad, dtype=float)
    if vectors.shape != (yaw.size, 3):
        raise ValueError("Magnetic vectors and yaw samples are misaligned.")
    angle = initial_heading_rad + yaw
    cosine = np.cos(angle)
    sine = np.sin(angle)
    output = vectors.copy()
    output[:, 0] = cosine * vectors[:, 0] - sine * vectors[:, 1]
    output[:, 1] = sine * vectors[:, 0] + cosine * vectors[:, 1]
    return output


def build_anchored_magnetic_map(
    captures: list[Capture],
    *,
    sample_stride: int = 10,
    require_two_dimensional_coverage: bool = True,
) -> MagneticMap:
    """Build a shared-frame magnetic map from manually positioned anchors.

    Positions between consecutive anchors are interpolated by timestamp.  This
    is appropriate for straight, approximately constant-speed survey legs; a
    turn or change of direction should therefore be marked with another
    positioned anchor.
    """
    if not captures:
        raise ValueError("At least one anchored capture is required.")
    stride = max(1, int(sample_stride))
    frames = {
        capture.spatial_reference.coordinate_frame
        for capture in captures
        if capture.spatial_reference is not None
    }
    if len(frames) != 1 or any(capture.spatial_reference is None for capture in captures):
        raise ValueError("All captures must use one explicit shared spatial coordinate frame.")

    map_points = []
    map_vectors = []
    anchor_points = []
    for capture in captures:
        reference = capture.spatial_reference
        assert reference is not None
        anchors = [event for event in capture.spatial_events if event.has_position]
        if len(anchors) < 2:
            raise ValueError(
                f"{capture.dataset_key}: at least two positioned anchors are required."
            )
        anchor_time = np.asarray([event.time_s for event in anchors], dtype=float)
        if np.any(np.diff(anchor_time) <= 0.0):
            raise ValueError(f"{capture.dataset_key}: anchor timestamps must be increasing.")
        anchor_xy = np.asarray([[event.x_m, event.y_m] for event in anchors], dtype=float)
        anchor_points.append(anchor_xy)
        mask = (capture.time_s >= anchor_time[0]) & (capture.time_s <= anchor_time[-1])
        indices = np.flatnonzero(mask)[::stride]
        if indices.size < 3:
            raise ValueError(f"{capture.dataset_key}: too few samples between anchors.")
        sample_time = capture.time_s[indices]
        positions = np.column_stack(
            (
                np.interp(sample_time, anchor_time, anchor_xy[:, 0]),
                np.interp(sample_time, anchor_time, anchor_xy[:, 1]),
            )
        )
        initial_yaw = float(capture.yaw_rad[indices[0]])
        vectors = rotate_device_magnetic_to_local(
            capture.magnetic_field_ut[indices],
            capture.yaw_rad[indices] - initial_yaw,
            initial_heading_rad=np.radians(reference.initial_heading_deg),
        )
        map_points.append(positions)
        map_vectors.append(vectors)

    surveyed_anchors = np.vstack(anchor_points)
    if require_two_dimensional_coverage:
        centered = surveyed_anchors - surveyed_anchors.mean(axis=0)
        if np.linalg.matrix_rank(centered, tol=1e-6) < 2:
            raise ValueError(
                "Anchors are collinear; at least three non-collinear shared-frame anchors "
                "are required for a two-dimensional magnetic map."
            )
    return MagneticMap(
        points_xy_m=np.vstack(map_points),
        vectors_ut=np.vstack(map_vectors),
        coordinate_frame=next(iter(frames)),
    )
