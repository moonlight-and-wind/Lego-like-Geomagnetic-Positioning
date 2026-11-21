"""Segment-distance estimation and soft rectangular topology priors."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from geomag_v2.motion import SegmentObservation


@dataclass(frozen=True)
class RidgeDistanceModel:
    feature_mean: np.ndarray
    feature_scale: np.ndarray
    coefficients: np.ndarray
    ridge: float

    @classmethod
    def fit(
        cls,
        observations: list[SegmentObservation],
        distances_m: np.ndarray,
        *,
        ridge: float = 0.3,
    ) -> RidgeDistanceModel:
        if len(observations) != len(distances_m) or len(observations) < 5:
            raise ValueError("Distance training requires aligned segment observations.")
        features = np.asarray([item.distance_features for item in observations])
        mean = features.mean(axis=0)
        scale = features.std(axis=0)
        scale[scale < 1e-9] = 1.0
        design = np.column_stack((np.ones(features.shape[0]), (features - mean) / scale))
        penalty = np.diag([0.0, *([float(ridge)] * features.shape[1])])
        coefficients = np.linalg.solve(
            design.T @ design + penalty,
            design.T @ np.asarray(distances_m, dtype=float),
        )
        return cls(mean, scale, coefficients, float(ridge))

    def predict(self, observations: list[SegmentObservation]) -> np.ndarray:
        features = np.asarray([item.distance_features for item in observations])
        design = np.column_stack((np.ones(features.shape[0]), (features - self.feature_mean) / self.feature_scale))
        return np.maximum(design @ self.coefficients, 0.15)


def equalize_opposite_sides(sensor_lengths_m: np.ndarray) -> np.ndarray:
    """Use only the controlled rectangle topology, without known edge lengths."""
    sensor = np.asarray(sensor_lengths_m, dtype=float)
    if sensor.shape != (4,):
        raise ValueError("A rectangular traversal must have four segment lengths.")
    long_pair = float(np.mean(sensor[[0, 2]]))
    short_pair = float(np.mean(sensor[[1, 3]]))
    return np.asarray([long_pair, short_pair, long_pair, short_pair])


def regularize_rectangle(
    sensor_lengths_m: np.ndarray,
    calibration_lengths_m: np.ndarray,
    *,
    calibration_weight: float = 0.70,
    sensor_confidence: np.ndarray | None = None,
) -> np.ndarray:
    """Apply a soft, auditable prior instead of projecting onto route coordinates.

    Opposite sides are equal because the current accuracy experiment deliberately
    walks rectangles with 90-degree turns.  The learned calibration dimensions
    receive a finite weight, so sensor disagreement remains visible in the output.
    """
    sensor = np.asarray(sensor_lengths_m, dtype=float)
    calibration = np.asarray(calibration_lengths_m, dtype=float)
    if sensor.shape != (4,) or calibration.shape != (4,):
        raise ValueError("A rectangular traversal must have four segment lengths.")
    if not 0.0 <= calibration_weight < 1.0:
        raise ValueError("calibration_weight must be in [0, 1).")
    if sensor_confidence is None:
        confidence = np.ones(4, dtype=float)
    else:
        confidence = np.asarray(sensor_confidence, dtype=float)
        if confidence.shape != (4,):
            raise ValueError("sensor_confidence must contain four values.")
        confidence = np.clip(confidence, 0.0, 1.0)
    paired = equalize_opposite_sides(sensor)
    pair_confidence = np.asarray(
        [
            np.mean(confidence[[0, 2]]),
            np.mean(confidence[[1, 3]]),
            np.mean(confidence[[0, 2]]),
            np.mean(confidence[[1, 3]]),
        ]
    )
    # A few detected peaks are not linearly informative: a segment with two
    # peaks is much less than 20% as reliable as one with ten.  Squaring the
    # normalized confidence prevents those short segments from dominating.
    effective_calibration_weight = 1.0 - (
        (1.0 - calibration_weight) * pair_confidence**2
    )
    return (
        effective_calibration_weight * calibration
        + (1.0 - effective_calibration_weight) * paired
    )
