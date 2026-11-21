"""Personal step-length calibration from an independent known-distance walk."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def estimate_step_length_scale(
    known_distance_m,
    step_lengths_m,
    *,
    min_scale=0.50,
    max_scale=1.80,
):
    lengths = np.asarray(step_lengths_m, dtype=float).reshape(-1)
    lengths = lengths[np.isfinite(lengths) & (lengths > 0.0)]
    distance = float(known_distance_m)
    if distance <= 0.0:
        raise ValueError("known_distance_m must be positive.")
    if lengths.size == 0:
        raise ValueError("At least one positive finite step length is required.")
    estimated_distance = float(np.sum(lengths))
    raw_scale = float(distance / estimated_distance)
    scale = float(np.clip(raw_scale, float(min_scale), float(max_scale)))
    return {
        "known_distance_m": distance,
        "detected_step_count": int(lengths.size),
        "unscaled_estimated_distance_m": estimated_distance,
        "raw_recommended_scale": raw_scale,
        "recommended_scale": scale,
        "scale_was_clipped": bool(abs(scale - raw_scale) > 1e-12),
        "calibrated_mean_step_length_m": float(
            scale * estimated_distance / lengths.size
        ),
    }


def calibrate_from_result(
    result_json,
    known_distance_m,
    *,
    output_json=None,
):
    result_path = Path(result_json)
    payload = json.loads(result_path.read_text(encoding="utf-8"))
    diagnostics = list(payload.get("step_length_diagnostic_history", []))[1:]
    unscaled = [
        item.get("unscaled_step_length_m")
        for item in diagnostics
        if item.get("unscaled_step_length_m") is not None
    ]
    if not unscaled:
        history = list(payload.get("step_length_history_m", []))[1:]
        applied_scale = float(payload.get("step_length_scale", 1.0) or 1.0)
        unscaled = [float(value) / applied_scale for value in history]
    report = estimate_step_length_scale(known_distance_m, unscaled)
    report.update(
        {
            "format_version": "1.0",
            "source_result_json": str(result_path),
            "dataset_key": payload.get("dataset_key"),
            "usage": (
                "Apply to a later independent capture with "
                "`--own-step-length-scale` or `--step-length-scale`."
            ),
            "validity_warning": (
                "Do not calibrate and evaluate on the same walk; that would "
                "leak the known route distance into the positioning result."
            ),
        }
    )
    report["output_json"] = (
        None if output_json is None else str(Path(output_json))
    )
    if output_json is not None:
        output_path = Path(output_json)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(
            json.dumps(report, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Estimate a personal step-length scale from a separate "
            "known-distance calibration walk."
        )
    )
    parser.add_argument("result_json")
    parser.add_argument("--known-distance-m", type=float, required=True)
    parser.add_argument("--output-json", default=None)
    args = parser.parse_args(argv)
    report = calibrate_from_result(
        args.result_json,
        args.known_distance_m,
        output_json=args.output_json,
    )
    print(
        f"steps={report['detected_step_count']}, "
        f"estimated={report['unscaled_estimated_distance_m']:.3f} m, "
        f"scale={report['recommended_scale']:.4f}"
    )
    print(report["validity_warning"])
    if report["output_json"]:
        print(f"Saved: {report['output_json']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
