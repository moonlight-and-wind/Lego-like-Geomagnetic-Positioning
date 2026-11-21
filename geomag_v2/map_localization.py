"""Magnetic-map correction for a free inertial track.

The localizer consumes only a known start position, inertial displacements and
magnetic observations.  Reference route coordinates are deliberately absent
from this API so held-out geometry cannot leak into the estimate.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from geomag_v2.capture import Capture
from geomag_v2.free_motion import FreeSegment
from geomag_v2.magnetic_map import (
    MagneticMap,
    merge_maps,
    rotate_device_magnetic_to_local,
)


@dataclass(frozen=True)
class ParticleFilterConfig:
    particle_count: int = 600
    magnetic_sigma_ut: float = 3.0
    map_distance_sigma_m: float = 0.20
    motion_sigma_m: float = 0.025
    motion_scale_sigma: float = 0.015
    initial_sigma_m: float = 0.08
    spatial_neighbors: int = 12
    neighbor_bandwidth_m: float = 0.12
    initial_step_scale_sigma: float = 0.10
    step_scale_random_walk: float = 0.004
    segment_step_scale_log_sigma: float = 0.28
    short_segment_threshold_m: float = 3.0
    segment_scale_reset_max_map_diagonal_m: float = 5.0
    minimum_step_scale: float = 0.40
    maximum_step_scale: float = 2.50
    initial_heading_bias_deg: float = 3.0
    heading_bias_random_walk_deg: float = 0.25
    segment_heading_jitter_deg: float = 0.0
    resample_ess_fraction: float = 0.55
    random_seed: int = 20260808


@dataclass(frozen=True)
class LocalizationResult:
    track_xy_m: np.ndarray
    effective_sample_size: np.ndarray
    resample_count: int
    mean_map_distance_m: float
    mean_magnetic_residual_ut: float
    mean_step_scale: float
    mean_heading_bias_deg: float
    observation_feature_offset_ut: np.ndarray


def magnetic_features(vectors_ut: np.ndarray) -> np.ndarray:
    """Return orientation-robust magnitude and vertical-field features."""
    vectors = np.asarray(vectors_ut, dtype=float)
    if vectors.ndim != 2 or vectors.shape[1] != 3:
        raise ValueError("Magnetic vectors must have shape (N, 3).")
    return np.column_stack((np.linalg.norm(vectors, axis=1), vectors[:, 2]))


def _path_anchor_positions(capture: Capture, segment_count: int) -> np.ndarray:
    positioned = [event for event in capture.spatial_events if event.has_position]
    unique: list[np.ndarray] = []
    for event in positioned:
        point = np.asarray([event.x_m, event.y_m], dtype=float)
        if unique and np.linalg.norm(point - unique[-1]) <= 1e-6:
            continue
        unique.append(point)
    if len(unique) != segment_count + 1:
        raise ValueError(
            f"{capture.dataset_key}: expected {segment_count + 1} distinct path anchors, "
            f"found {len(unique)}"
        )
    return np.asarray(unique)


def build_activity_anchored_map(
    capture: Capture,
    segments: list[FreeSegment],
    *,
    sample_stride: int = 4,
    samples_per_segment: int | None = None,
) -> MagneticMap:
    """Build a route-local map using walking activity rather than wall time.

    The format-3 anchors define each straight leg.  Samples within that leg are
    positioned by cumulative inertial activity, so stationary time before the
    first step does not smear magnetic samples along the route.
    """
    if capture.spatial_reference is None:
        raise ValueError(f"{capture.dataset_key}: spatial reference is required")
    anchors = _path_anchor_positions(capture, len(segments))
    stride = max(1, int(sample_stride))
    initial_heading = np.radians(capture.spatial_reference.initial_heading_deg)
    points = []
    vectors = []
    for index, segment in enumerate(segments):
        leg = anchors[index + 1] - anchors[index]
        positions = anchors[index] + segment.inertial_progress[:, None] * leg
        local_vectors = rotate_device_magnetic_to_local(
            segment.magnetic_field_ut,
            segment.relative_yaw_rad,
            initial_heading_rad=initial_heading,
        )
        if samples_per_segment is None:
            selection = np.arange(0, positions.shape[0], stride)
            points.append(positions[selection])
            vectors.append(local_vectors[selection])
        else:
            target = np.linspace(0.0, 1.0, max(3, int(samples_per_segment)))
            points.append(anchors[index] + target[:, None] * leg)
            vectors.append(
                np.column_stack(
                    [
                        np.interp(target, segment.inertial_progress, local_vectors[:, component])
                        for component in range(3)
                    ]
                )
            )
    return MagneticMap(
        points_xy_m=np.vstack(points),
        vectors_ut=np.vstack(vectors),
        coordinate_frame=capture.spatial_reference.coordinate_frame,
    )


def build_multi_activity_anchored_map(
    captures_and_segments: list[tuple[Capture, list[FreeSegment]]],
    *,
    samples_per_segment: int = 101,
) -> MagneticMap:
    """Merge repeat surveys after equal-progress spatial resampling.

    Equal sample counts prevent a longer recording from receiving more weight
    merely because it contains more stationary or high-rate samples.
    """
    if not captures_and_segments:
        raise ValueError("At least one capture is required for a magnetic map.")
    maps = [
        build_activity_anchored_map(
            capture,
            segments,
            samples_per_segment=samples_per_segment,
        )
        for capture, segments in captures_and_segments
    ]
    return merge_maps(maps)


def resample_magnetic_observations(
    capture: Capture,
    segments: list[FreeSegment],
    *,
    samples_per_segment: int = 30,
) -> np.ndarray:
    """Align magnetic observations with ``integrate_free_track`` samples."""
    if capture.spatial_reference is None:
        raise ValueError(f"{capture.dataset_key}: spatial reference is required")
    initial_heading = np.radians(capture.spatial_reference.initial_heading_deg)
    output = []
    target = np.linspace(0.0, 1.0, samples_per_segment + 1)
    for index, segment in enumerate(segments):
        local = rotate_device_magnetic_to_local(
            segment.magnetic_field_ut,
            segment.relative_yaw_rad,
            initial_heading_rad=initial_heading,
        )
        sampled = np.column_stack(
            [
                np.interp(target, segment.inertial_progress, local[:, component])
                for component in range(3)
            ]
        )
        output.append(sampled if index == 0 else sampled[1:])
    return np.vstack(output)


def _systematic_resample(weights: np.ndarray, generator: np.random.Generator) -> np.ndarray:
    positions = (generator.random() + np.arange(weights.size)) / weights.size
    return np.searchsorted(np.cumsum(weights), positions)


def _map_feature_prediction(
    positions_xy_m: np.ndarray,
    magnetic_map: MagneticMap,
    map_features: np.ndarray,
    settings: ParticleFilterConfig,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    squared_distance = np.sum(
        (positions_xy_m[:, None, :] - magnetic_map.points_xy_m[None, :, :]) ** 2,
        axis=2,
    )
    count = min(max(1, settings.spatial_neighbors), magnetic_map.points_xy_m.shape[0])
    nearest = np.argpartition(squared_distance, count - 1, axis=1)[:, :count]
    local_squared_distance = np.take_along_axis(squared_distance, nearest, axis=1)
    bandwidth = max(settings.neighbor_bandwidth_m, 1e-3)
    local_weights = np.exp(-0.5 * local_squared_distance / bandwidth**2)
    local_weights /= np.maximum(np.sum(local_weights, axis=1, keepdims=True), 1e-12)
    local_features = map_features[nearest]
    prediction = np.sum(local_weights[:, :, None] * local_features, axis=1)
    centered = local_features - prediction[:, None, :]
    variance = np.sum(local_weights[:, :, None] * centered * centered, axis=1)
    nearest_distance = np.sqrt(np.min(local_squared_distance, axis=1))
    return prediction, variance, nearest_distance


def localize_free_track(
    inertial_track_xy_m: np.ndarray,
    magnetic_observations_ut: np.ndarray,
    magnetic_map: MagneticMap,
    *,
    start_position_xy_m: tuple[float, float],
    segment_boundary_indices: np.ndarray | None = None,
    config: ParticleFilterConfig | None = None,
) -> LocalizationResult:
    """Correct a PDR track against a magnetic map with a position particle filter."""
    inertial = np.asarray(inertial_track_xy_m, dtype=float)
    observations = np.asarray(magnetic_observations_ut, dtype=float)
    if inertial.ndim != 2 or inertial.shape[1] != 2:
        raise ValueError("Inertial track must have shape (N, 2).")
    if observations.shape != (inertial.shape[0], 3):
        raise ValueError("Magnetic observations must align with the inertial track.")
    settings = config or ParticleFilterConfig()
    if settings.particle_count < 20:
        raise ValueError("Particle filter requires at least 20 particles.")

    generator = np.random.default_rng(settings.random_seed)
    boundaries = (
        set()
        if segment_boundary_indices is None
        else {int(value) for value in np.asarray(segment_boundary_indices, dtype=int)}
    )
    if any(value <= 0 or value >= inertial.shape[0] - 1 for value in boundaries):
        raise ValueError("Segment boundaries must be internal track indices.")
    ordered_boundaries = sorted(boundaries)
    start = np.asarray(start_position_xy_m, dtype=float)
    particles = start + generator.normal(
        0.0,
        settings.initial_sigma_m,
        size=(settings.particle_count, 2),
    )
    weights = np.full(settings.particle_count, 1.0 / settings.particle_count)
    step_scales = np.clip(
        generator.normal(1.0, settings.initial_step_scale_sigma, settings.particle_count),
        settings.minimum_step_scale,
        settings.maximum_step_scale,
    )
    heading_bias = generator.normal(
        0.0,
        np.radians(settings.initial_heading_bias_deg),
        settings.particle_count,
    )
    map_features = magnetic_features(magnetic_map.vectors_ut)
    map_diagonal = float(
        np.linalg.norm(
            np.ptp(np.asarray(magnetic_map.points_xy_m, dtype=float), axis=0)
        )
    )
    allow_segment_scale_reset = (
        map_diagonal <= settings.segment_scale_reset_max_map_diagonal_m
    )
    observation_features = magnetic_features(observations)
    start_prediction, _, _ = _map_feature_prediction(
        start[None, :], magnetic_map, map_features, settings
    )
    feature_offset = observation_features[0] - start_prediction[0]
    observation_features = observation_features - feature_offset
    track = [np.average(particles, axis=0, weights=weights)]
    effective_sizes = [float(settings.particle_count)]
    map_distances = []
    magnetic_residuals = []
    scale_estimates = [float(np.average(step_scales, weights=weights))]
    heading_estimates = [float(np.average(heading_bias, weights=weights))]
    resample_count = 0

    for sample_index in range(1, inertial.shape[0]):
        displacement = inertial[sample_index] - inertial[sample_index - 1]
        if allow_segment_scale_reset and sample_index - 1 in boundaries:
            next_boundaries = [value for value in ordered_boundaries if value > sample_index - 1]
            segment_end = next_boundaries[0] if next_boundaries else inertial.shape[0] - 1
            upcoming_distance = float(
                np.sum(
                    np.linalg.norm(
                        np.diff(inertial[sample_index - 1 : segment_end + 1], axis=0),
                        axis=1,
                    )
                )
            )
            if upcoming_distance < settings.short_segment_threshold_m:
                step_scales = np.clip(
                    generator.lognormal(
                        mean=0.0,
                        sigma=settings.segment_step_scale_log_sigma,
                        size=settings.particle_count,
                    ),
                    settings.minimum_step_scale,
                    settings.maximum_step_scale,
                )
            else:
                step_scales = np.clip(
                    generator.normal(
                        1.0,
                        settings.initial_step_scale_sigma,
                        settings.particle_count,
                    ),
                    settings.minimum_step_scale,
                    settings.maximum_step_scale,
                )
            heading_bias += generator.normal(
                0.0,
                np.radians(settings.segment_heading_jitter_deg),
                settings.particle_count,
            )
        step_scales = np.clip(
            step_scales
            + generator.normal(0.0, settings.step_scale_random_walk, settings.particle_count),
            settings.minimum_step_scale,
            settings.maximum_step_scale,
        )
        heading_bias += generator.normal(
            0.0,
            np.radians(settings.heading_bias_random_walk_deg),
            settings.particle_count,
        )
        cosine = np.cos(heading_bias)
        sine = np.sin(heading_bias)
        transformed = np.column_stack(
            (
                cosine * displacement[0] - sine * displacement[1],
                sine * displacement[0] + cosine * displacement[1],
            )
        )
        transformed *= step_scales[:, None]
        noise_sigma = settings.motion_sigma_m + settings.motion_scale_sigma * float(
            np.linalg.norm(displacement)
        )
        particles += transformed + generator.normal(
            0.0,
            noise_sigma,
            size=particles.shape,
        )
        prediction, feature_variance, nearest_distance = _map_feature_prediction(
            particles,
            magnetic_map,
            map_features,
            settings,
        )
        difference = prediction - observation_features[sample_index]
        feature_sigma_squared = settings.magnetic_sigma_ut**2 + feature_variance
        normalized_squared = np.sum(difference * difference / feature_sigma_squared, axis=1)
        residual = np.linalg.norm(difference, axis=1)
        log_likelihood = -0.5 * normalized_squared
        log_likelihood -= 0.5 * np.sum(np.log(feature_sigma_squared), axis=1)
        log_likelihood -= 0.5 * (nearest_distance / settings.map_distance_sigma_m) ** 2
        log_weight = np.log(np.maximum(weights, 1e-300)) + log_likelihood
        log_weight -= float(np.max(log_weight))
        weights = np.exp(log_weight)
        total = float(np.sum(weights))
        if not np.isfinite(total) or total <= 1e-300:
            weights.fill(1.0 / settings.particle_count)
        else:
            weights /= total

        estimate = np.average(particles, axis=0, weights=weights)
        track.append(estimate)
        scale_estimates.append(float(np.average(step_scales, weights=weights)))
        heading_estimates.append(float(np.average(heading_bias, weights=weights)))
        effective = float(1.0 / np.sum(weights * weights))
        effective_sizes.append(effective)
        map_distances.append(float(np.average(nearest_distance, weights=weights)))
        magnetic_residuals.append(float(np.average(residual, weights=weights)))
        if effective < settings.resample_ess_fraction * settings.particle_count:
            selection = _systematic_resample(weights, generator)
            particles = particles[selection]
            step_scales = step_scales[selection]
            heading_bias = heading_bias[selection]
            weights.fill(1.0 / settings.particle_count)
            resample_count += 1

    return LocalizationResult(
        track_xy_m=np.asarray(track),
        effective_sample_size=np.asarray(effective_sizes),
        resample_count=resample_count,
        mean_map_distance_m=float(np.mean(map_distances)) if map_distances else 0.0,
        mean_magnetic_residual_ut=(
            float(np.mean(magnetic_residuals)) if magnetic_residuals else 0.0
        ),
        mean_step_scale=float(np.mean(scale_estimates)),
        mean_heading_bias_deg=float(np.degrees(np.mean(heading_estimates))),
        observation_feature_offset_ut=feature_offset,
    )
