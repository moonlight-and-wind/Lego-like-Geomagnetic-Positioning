"""Reconstruct the experimental three-axis own-data magnetic survey map."""

from __future__ import annotations

import argparse
import csv
import importlib.util
import io
import json
import zipfile
from pathlib import Path

import numpy as np


def _read_magnetometer_zip(path):
    with zipfile.ZipFile(path) as archive:
        rows = list(
            csv.DictReader(
                io.TextIOWrapper(
                    archive.open("Raw Data.csv"),
                    encoding="utf-8-sig",
                )
            )
        )
    if not rows:
        raise ValueError(f"Empty magnetometer archive: {path}")
    fieldnames = list(rows[0])
    time_col = next(name for name in fieldnames if "Time" in name)
    xyz_cols = [
        name
        for name in fieldnames
        if "Magnetic Field " in name and "Absolute" not in name
    ]
    if len(xyz_cols) != 3:
        raise ValueError(f"Expected three magnetic axes in {path}: {fieldnames}")
    time_s = np.asarray([float(row[time_col]) for row in rows], dtype=float)
    xyz = np.asarray(
        [[float(row[name]) for name in xyz_cols] for row in rows],
        dtype=float,
    )
    return time_s, xyz


def _load_processed_scalar_lines(path):
    spec = importlib.util.spec_from_file_location("own_scalar_lines", str(path))
    if spec is None or spec.loader is None:
        raise ImportError(f"Unable to load scalar survey lines: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    lines = np.asarray(module.data, dtype=float)
    if lines.ndim != 2 or lines.shape[0] == 0:
        raise ValueError(f"Invalid scalar survey-line matrix: {path}")
    return lines


def align_vector_line_to_scalar_reference(xyz, scalar_reference):
    """Resample one raw vector line and select the direction matching the scalar map."""
    xyz = np.asarray(xyz, dtype=float)
    reference = np.asarray(scalar_reference, dtype=float).reshape(-1)
    if xyz.ndim != 2 or xyz.shape[1] != 3 or xyz.shape[0] < 2:
        raise ValueError("xyz must have shape (N, 3), N >= 2")
    source_progress = np.linspace(0.0, 1.0, xyz.shape[0])
    target_progress = np.linspace(0.0, 1.0, reference.size)
    resampled = np.column_stack(
        [
            np.interp(target_progress, source_progress, xyz[:, axis])
            for axis in range(3)
        ]
    )
    magnitude = np.linalg.norm(resampled, axis=1)
    forward = float(np.corrcoef(reference, magnitude)[0, 1])
    reverse = float(np.corrcoef(reference, magnitude[::-1])[0, 1])
    reversed_line = bool(reverse > forward)
    aligned = resampled[::-1] if reversed_line else resampled
    return aligned, {
        "reversed": reversed_line,
        "forward_correlation": forward,
        "reverse_correlation": reverse,
        "selected_correlation": max(forward, reverse),
    }


def build_own_vector_map(
    raw_zip_dir="data/raw/raw_own",
    scalar_lines_path="data/own_data/magnetometer_map_own.py",
    output_npz="data/processed/own_vector_map.npz",
    output_json="data/processed/own_vector_map_meta.json",
):
    zip_paths = sorted(Path(raw_zip_dir).glob("*.zip"))
    scalar_lines = _load_processed_scalar_lines(scalar_lines_path)
    if len(zip_paths) < scalar_lines.shape[0]:
        raise ValueError(
            f"Need {scalar_lines.shape[0]} raw lines, found {len(zip_paths)}"
        )

    aligned_lines = []
    diagnostics = []
    # The processed scalar file contains the eight accepted survey lines in
    # acquisition order. Any later archive is an excluded/repeated line.
    used_paths = zip_paths[: scalar_lines.shape[0]]
    for index, (zip_path, reference) in enumerate(
        zip(used_paths, scalar_lines, strict=True)
    ):
        time_s, xyz = _read_magnetometer_zip(zip_path)
        aligned, item = align_vector_line_to_scalar_reference(xyz, reference)
        aligned_lines.append(aligned)
        diagnostics.append(
            {
                "line_index": index,
                "source_zip": str(zip_path),
                "sample_count": int(xyz.shape[0]),
                "duration_s": float(time_s[-1] - time_s[0]),
                **item,
            }
        )

    line_vectors = np.asarray(aligned_lines, dtype=float)
    magnitude_lines = np.linalg.norm(line_vectors, axis=2)
    output_path = Path(output_npz)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        output_path,
        line_vectors=line_vectors,
        magnitude_lines=magnitude_lines,
        x_line_positions_m=np.linspace(0.0, 6.72, line_vectors.shape[0]),
        y_sample_positions_m=np.linspace(
            0.0,
            8.074005934718102,
            line_vectors.shape[1],
        ),
        excluded_zip=np.asarray(
            [str(path) for path in zip_paths[scalar_lines.shape[0] :]]
        ),
    )
    metadata = {
        "format_version": "1.0",
        "output_npz": str(output_path),
        "source_scalar_lines": str(scalar_lines_path),
        "raw_zip_dir": str(raw_zip_dir),
        "shape_lines_samples_axes": list(line_vectors.shape),
        "bounds_xy_m": [0.0, 6.72, 0.0, 8.074005934718102],
        "used_zip_count": len(used_paths),
        "excluded_zips": [
            str(path) for path in zip_paths[scalar_lines.shape[0] :]
        ],
        "line_diagnostics": diagnostics,
        "limitations": [
            "Survey archives contain magnetometer only; no synchronized attitude.",
            "Vector axes are in the survey-phone frame and require per-run yaw alignment.",
            "The vector likelihood must remain optional with scalar fallback.",
        ],
    }
    metadata_path = Path(output_json)
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata["output_json"] = str(metadata_path)
    metadata_path.write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return metadata


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Rebuild the experimental own-data three-axis magnetic map."
    )
    parser.add_argument("--raw-zip-dir", default="data/raw/raw_own")
    parser.add_argument(
        "--scalar-lines-path",
        default="data/own_data/magnetometer_map_own.py",
    )
    parser.add_argument(
        "--output-npz",
        default="data/processed/own_vector_map.npz",
    )
    parser.add_argument(
        "--output-json",
        default="data/processed/own_vector_map_meta.json",
    )
    args = parser.parse_args(argv)
    metadata = build_own_vector_map(
        raw_zip_dir=args.raw_zip_dir,
        scalar_lines_path=args.scalar_lines_path,
        output_npz=args.output_npz,
        output_json=args.output_json,
    )
    print(
        f"Built vector map {metadata['shape_lines_samples_axes']} from "
        f"{metadata['used_zip_count']} accepted lines."
    )
    print(f"Saved: {metadata['output_npz']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
