"""Strict reader for format-2 iPhone capture packages."""

from __future__ import annotations

import csv
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class SpatialReference:
    coordinate_frame: str
    start_position_xy_m: tuple[float, float]
    initial_heading_deg: float
    unit: str = "m"


@dataclass(frozen=True)
class SpatialEvent:
    time_s: float
    type: str
    label: str
    x_m: float | None
    y_m: float | None
    heading_deg: float | None
    device_yaw_deg: float | None

    @property
    def has_position(self) -> bool:
        return self.x_m is not None and self.y_m is not None


@dataclass(frozen=True)
class Capture:
    dataset_key: str
    time_s: np.ndarray
    yaw_rad: np.ndarray
    user_acceleration_mps2: np.ndarray
    rotation_rate_radps: np.ndarray
    magnetic_field_ut: np.ndarray
    format_version: int = 2
    spatial_reference: SpatialReference | None = None
    spatial_events: tuple[SpatialEvent, ...] = ()


def _normalized(name: str) -> str:
    return "".join(character.lower() for character in name if character.isalnum())


def load_capture(package: Path) -> Capture:
    package = Path(package)
    metadata_path = package / "capture_metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    format_version = int(metadata.get("format_version", 0))
    if format_version < 2:
        raise ValueError(f"V2 requires capture format 2 or newer: {package}")
    if metadata.get("device_pose") != "face_up_front_forward":
        raise ValueError(f"Unsupported phone pose: {package}")
    if metadata.get("algorithm_magnetic_field_file") != "Magnetometer.csv":
        raise ValueError(f"Capture does not select calibrated magnetic data: {package}")

    csv_path = package / "DeviceMotion.csv"
    with csv_path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"DeviceMotion CSV has no header: {csv_path}")
        names = {_normalized(name): name for name in reader.fieldnames}

        def field(*candidates: str) -> str:
            for candidate in candidates:
                found = names.get(_normalized(candidate))
                if found is not None:
                    return found
            raise ValueError(f"DeviceMotion CSV lacks {candidates}: {csv_path}")

        columns = [
            field("Time (s)", "time"),
            field("Yaw (rad)", "yaw"),
            field("User Acceleration X (m/s^2)"),
            field("User Acceleration Y (m/s^2)"),
            field("User Acceleration Z (m/s^2)"),
            field("Rotation Rate X (rad/s)"),
            field("Rotation Rate Y (rad/s)"),
            field("Rotation Rate Z (rad/s)"),
            field("Magnetic Field X (µT)"),
            field("Magnetic Field Y (µT)"),
            field("Magnetic Field Z (µT)"),
        ]
        rows = []
        for row in reader:
            try:
                rows.append([float(row[column]) for column in columns])
            except (TypeError, ValueError):
                continue

    values = np.asarray(rows, dtype=float)
    if values.ndim != 2 or values.shape[0] < 100:
        raise ValueError(f"DeviceMotion CSV has too few numeric rows: {csv_path}")
    values = values[np.argsort(values[:, 0])]
    _, unique = np.unique(values[:, 0], return_index=True)
    values = values[np.sort(unique)]
    spatial_reference = _spatial_reference(metadata, package)
    spatial_events = _spatial_events(metadata, package)
    if format_version >= 3:
        if spatial_reference is None:
            raise ValueError(f"Format-3 capture lacks spatial_reference: {package}")
        positioned = [event for event in spatial_events if event.has_position]
        if not positioned:
            raise ValueError(f"Format-3 capture contains no positioned anchor: {package}")
        start = np.asarray(spatial_reference.start_position_xy_m)
        first = np.asarray([positioned[0].x_m, positioned[0].y_m], dtype=float)
        if np.linalg.norm(start - first) > 0.25:
            raise ValueError(f"Start anchor disagrees with spatial_reference: {package}")
    return Capture(
        dataset_key=str(metadata.get("dataset_key", package.stem)),
        time_s=values[:, 0],
        yaw_rad=np.unwrap(values[:, 1]),
        user_acceleration_mps2=values[:, 2:5],
        rotation_rate_radps=values[:, 5:8],
        magnetic_field_ut=values[:, 8:11],
        format_version=format_version,
        spatial_reference=spatial_reference,
        spatial_events=spatial_events,
    )


def _spatial_reference(metadata: dict, package: Path) -> SpatialReference | None:
    value = metadata.get("spatial_reference")
    if value is None:
        return None
    try:
        frame = str(value["coordinate_frame"]).strip()
        unit = str(value.get("unit", "m"))
        start = tuple(map(float, value["start_position_xy_m"]))
        heading = float(value["initial_heading_deg"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(f"Invalid spatial_reference: {package}") from error
    if not frame or unit != "m" or len(start) != 2 or not np.all(np.isfinite(start)):
        raise ValueError(f"Invalid spatial_reference: {package}")
    if not np.isfinite(heading):
        raise ValueError(f"Invalid initial heading: {package}")
    return SpatialReference(frame, (start[0], start[1]), heading, unit)


def _optional_float(value: str | None) -> float | None:
    if value is None or not value.strip():
        return None
    parsed = float(value)
    return parsed if np.isfinite(parsed) else None


def _spatial_events(metadata: dict, package: Path) -> tuple[SpatialEvent, ...]:
    filename = metadata.get("spatial_events_file")
    if filename is None:
        return ()
    path = package / str(filename)
    if not path.exists():
        raise FileNotFoundError(f"Spatial event file not found: {path}")
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"Spatial event CSV has no header: {path}")
        names = {_normalized(name): name for name in reader.fieldnames}

        def field(name: str) -> str:
            found = names.get(_normalized(name))
            if found is None:
                raise ValueError(f"Spatial event CSV lacks {name}: {path}")
            return found

        columns = {
            "time": field("Time (s)"),
            "type": field("Type"),
            "label": field("Label"),
            "x": field("X (m)"),
            "y": field("Y (m)"),
            "heading": field("Heading (deg)"),
            "yaw": field("Device Yaw (deg)"),
        }
        events = []
        for row in reader:
            try:
                event = SpatialEvent(
                    time_s=float(row[columns["time"]]),
                    type=str(row[columns["type"]]).strip(),
                    label=str(row[columns["label"]]).strip(),
                    x_m=_optional_float(row[columns["x"]]),
                    y_m=_optional_float(row[columns["y"]]),
                    heading_deg=_optional_float(row[columns["heading"]]),
                    device_yaw_deg=_optional_float(row[columns["yaw"]]),
                )
            except (TypeError, ValueError) as error:
                raise ValueError(f"Invalid spatial event row: {path}") from error
            if not np.isfinite(event.time_s) or not event.type:
                raise ValueError(f"Invalid spatial event row: {path}")
            if (event.x_m is None) != (event.y_m is None):
                raise ValueError(f"Spatial anchor must contain both x and y: {path}")
            events.append(event)
    events.sort(key=lambda event: event.time_s)
    return tuple(events)
