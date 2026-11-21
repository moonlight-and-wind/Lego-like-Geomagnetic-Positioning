"""Build a shared-coordinate V2 magnetic map from format-3 iPhone captures."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

from geomag_v2.capture import Capture, load_capture
from geomag_v2.magnetic_map import build_anchored_magnetic_map


def discover_anchored_captures(
    capture_root: Path,
    *,
    coordinate_frame: str | None = None,
) -> list[tuple[Path, Capture]]:
    packages = sorted(Path(capture_root).glob("*.geomagcapture"))
    output = []
    for package in packages:
        capture = load_capture(package)
        if capture.spatial_reference is None:
            continue
        if coordinate_frame is not None and capture.spatial_reference.coordinate_frame != coordinate_frame:
            continue
        output.append((package, capture))
    return output


def build_map_from_root(
    capture_root: Path,
    output_root: Path,
    *,
    coordinate_frame: str | None = None,
    sample_stride: int = 10,
) -> dict:
    discovered = discover_anchored_captures(
        capture_root,
        coordinate_frame=coordinate_frame,
    )
    if not discovered:
        suffix = f" for coordinate frame {coordinate_frame!r}" if coordinate_frame else ""
        raise ValueError(f"No format-3 anchored captures found{suffix}.")
    frames = {
        capture.spatial_reference.coordinate_frame
        for _, capture in discovered
        if capture.spatial_reference is not None
    }
    if len(frames) != 1:
        raise ValueError(
            "Capture root contains multiple coordinate frames; pass --coordinate-frame explicitly."
        )
    magnetic_map = build_anchored_magnetic_map(
        [capture for _, capture in discovered],
        sample_stride=sample_stride,
    )
    output_root = Path(output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    map_path = output_root / "magnetic_map.npz"
    magnetic_map.save(map_path)
    magnitude = np.linalg.norm(magnetic_map.vectors_ut, axis=1)
    payload = {
        "format_version": "geomag-v2-map-1",
        "coordinate_frame": magnetic_map.coordinate_frame,
        "capture_keys": [capture.dataset_key for _, capture in discovered],
        "capture_packages": [str(path.resolve()) for path, _ in discovered],
        "map_samples": int(magnetic_map.points_xy_m.shape[0]),
        "sample_stride": int(sample_stride),
        "bounds_xy_m": {
            "minimum": magnetic_map.points_xy_m.min(axis=0).tolist(),
            "maximum": magnetic_map.points_xy_m.max(axis=0).tolist(),
        },
        "magnetic_magnitude_ut": {
            "minimum": float(magnitude.min()),
            "median": float(np.median(magnitude)),
            "maximum": float(magnitude.max()),
        },
        "map_file": str(map_path.resolve()),
    }
    (output_root / "summary.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    _write_preview(magnetic_map.points_xy_m, magnitude, output_root / "preview.png")
    return payload


def _write_preview(points: np.ndarray, magnitude: np.ndarray, path: Path) -> None:
    figure, axis = plt.subplots(figsize=(8, 7), constrained_layout=True)
    scatter = axis.scatter(points[:, 0], points[:, 1], c=magnitude, s=12, cmap="viridis")
    figure.colorbar(scatter, ax=axis, label="Magnetic magnitude (µT)")
    axis.set_title("Geomag V2 anchored magnetic map")
    axis.set_xlabel("X (m)")
    axis.set_ylabel("Y (m)")
    axis.set_aspect("equal", adjustable="box")
    axis.grid(alpha=0.25)
    figure.savefig(path, dpi=180)
    plt.close(figure)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_root", type=Path)
    parser.add_argument("--coordinate-frame")
    parser.add_argument("--sample-stride", type=int, default=10)
    parser.add_argument("--output-root", type=Path, default=Path("results/geomag_v2_map"))
    args = parser.parse_args()
    payload = build_map_from_root(
        args.capture_root,
        args.output_root,
        coordinate_frame=args.coordinate_frame,
        sample_stride=args.sample_stride,
    )
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
