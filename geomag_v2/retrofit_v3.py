"""Create provenance-marked format-3 derivatives from the recent format-2 data."""

from __future__ import annotations

import argparse
import csv
import json
import math
import shutil
from dataclasses import asdict
from pathlib import Path

import numpy as np

from geomag_v2.capture import Capture, SpatialEvent, SpatialReference, load_capture
from geomag_v2.catalog import RECENT_ROUTES, RouteSpec
from geomag_v2.free_motion import segment_free_motion
from geomag_v2.motion import detect_quarter_turns


def _initial_heading_deg(spec: RouteSpec) -> float:
    vector = np.asarray(spec.points_m[1]) - np.asarray(spec.points_m[0])
    return float(np.degrees(math.atan2(vector[1], vector[0])))


def _event_heading(capture: Capture, time_s: float, initial_heading_deg: float) -> tuple[float, float]:
    index = int(np.argmin(np.abs(capture.time_s - time_s)))
    device_yaw = float(np.degrees(capture.yaw_rad[index]))
    relative_yaw = float(np.degrees(capture.yaw_rad[index] - capture.yaw_rad[0]))
    return initial_heading_deg + relative_yaw, device_yaw


def derive_spatial_annotation(
    capture: Capture,
    spec: RouteSpec,
) -> tuple[SpatialReference, tuple[SpatialEvent, ...]]:
    turns = detect_quarter_turns(capture)
    _, free_segments = segment_free_motion(capture, include_trailing_segment=False)
    if len(turns) != 4 or len(free_segments) != 4:
        raise ValueError(f"{spec.key}: expected four controlled straight segments")
    initial_heading = _initial_heading_deg(spec)
    frame = f"retrofit-{spec.group.replace('_', '-')}-local"
    start = tuple(map(float, spec.points_m[0]))
    reference = SpatialReference(frame, start, initial_heading)
    events = [
        SpatialEvent(0.0, "anchor", "recording-start", start[0], start[1], initial_heading, None)
    ]
    departure_time = float(free_segments[0].time_s[0])
    departure_heading, departure_yaw = _event_heading(capture, departure_time, initial_heading)
    if departure_time > 0.05:
        events.append(
            SpatialEvent(
                departure_time,
                "anchor",
                "walking-start",
                start[0],
                start[1],
                departure_heading,
                departure_yaw,
            )
        )
    for index, turn in enumerate(turns, start=1):
        time_s = float(capture.time_s[turn.onset_index])
        heading, device_yaw = _event_heading(capture, time_s, initial_heading)
        x, y = map(float, spec.points_m[index])
        label = "finish" if index == 4 else f"corner-{index}"
        events.append(SpatialEvent(time_s, "anchor", label, x, y, heading, device_yaw))
    stop_time = float(capture.time_s[-1])
    stop_heading, stop_yaw = _event_heading(capture, stop_time, initial_heading)
    events.append(
        SpatialEvent(stop_time, "recording_stop", "stop", None, None, stop_heading, stop_yaw)
    )
    return reference, tuple(sorted(events, key=lambda event: event.time_s))


def retrofit_package(source: Path, destination: Path, spec: RouteSpec) -> dict:
    source = Path(source)
    destination = Path(destination)
    if destination.exists():
        raise FileExistsError(f"Derived package already exists: {destination}")
    capture = load_capture(source)
    reference, events = derive_spatial_annotation(capture, spec)
    shutil.copytree(source, destination)

    metadata_path = destination / "capture_metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata.update(
        {
            "format_version": 3,
            "spatial_events_file": "SpatialEvents.csv",
            "spatial_reference": {
                "coordinate_frame": reference.coordinate_frame,
                "unit": reference.unit,
                "start_position_xy_m": list(reference.start_position_xy_m),
                "initial_heading_deg": reference.initial_heading_deg,
            },
            "spatial_annotation_provenance": {
                "source": "derived_from_known_route_and_core_motion_turn_detection",
                "source_capture": str(source.resolve()),
                "manual_ground_truth": False,
                "allowed_use": "pipeline_integration_and_route_local_held_out_validation",
                "forbidden_claim": "independent_manual_anchor_ground_truth",
            },
        }
    )
    metadata.setdefault("streams", {})["spatial_events"] = {
        "file": "SpatialEvents.csv",
        "samples": len(events),
        "observed_rate_hz": 0,
    }
    metadata_path.write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    dataset_path = destination / "geomag_dataset.json"
    dataset = json.loads(dataset_path.read_text(encoding="utf-8")) if dataset_path.exists() else {}
    dataset.update(
        {
            "format_version": 2,
            "dataset_key": spec.key,
            "route_xy_m": [list(point) for point in spec.points_m],
            "initial_heading_deg": reference.initial_heading_deg,
            "spatial_events_file": "SpatialEvents.csv",
            "spatial_reference": {
                "coordinate_frame": reference.coordinate_frame,
                "unit": reference.unit,
                "start_position_xy_m": list(reference.start_position_xy_m),
                "initial_heading_deg": reference.initial_heading_deg,
            },
        }
    )
    dataset_path.write_text(
        json.dumps(dataset, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_events(destination / "SpatialEvents.csv", events)
    return {
        "key": spec.key,
        "source": str(source.resolve()),
        "destination": str(destination.resolve()),
        "coordinate_frame": reference.coordinate_frame,
        "event_count": len(events),
        "events": [asdict(event) for event in events],
    }


def _write_events(path: Path, events: tuple[SpatialEvent, ...]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "Time (s)",
                "Type",
                "Label",
                "X (m)",
                "Y (m)",
                "Heading (deg)",
                "Device Yaw (deg)",
            ]
        )
        for event in events:
            writer.writerow(
                [
                    event.time_s,
                    event.type,
                    event.label,
                    "" if event.x_m is None else event.x_m,
                    "" if event.y_m is None else event.y_m,
                    "" if event.heading_deg is None else event.heading_deg,
                    "" if event.device_yaw_deg is None else event.device_yaw_deg,
                ]
            )


def retrofit_recent_captures(source_root: Path, output_root: Path) -> dict:
    source_root = Path(source_root)
    output_root = Path(output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    packages = []
    for spec in RECENT_ROUTES:
        packages.append(
            retrofit_package(
                source_root / f"{spec.key}.geomagcapture",
                output_root / f"{spec.key}.geomagcapture",
                spec,
            )
        )
    payload = {
        "format_version": "retrofit-manifest-1",
        "source_data_unchanged": True,
        "manual_ground_truth": False,
        "coordinate_policy": "independent_route_local_frames",
        "packages": packages,
    }
    (output_root / "retrofit_manifest.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("/Users/xuminglei/dachuang/Geomag Capture"),
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path("results/geomag_v3_retrofit"),
    )
    args = parser.parse_args()
    payload = retrofit_recent_captures(args.source_root, args.output_root)
    print(f"derived_packages={len(payload['packages'])}")
    print(f"manifest={args.output_root / 'retrofit_manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
