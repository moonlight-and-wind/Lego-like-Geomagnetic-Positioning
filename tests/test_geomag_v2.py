import numpy as np

from geomag_v2.catalog import CALIBRATION_KEYS, RECENT_ROUTES
from geomag_v2.distance import (
    RidgeDistanceModel,
    equalize_opposite_sides,
    regularize_rectangle,
)
from geomag_v2.magnetic import bounded_magnetic_progress
from geomag_v2.motion import SegmentObservation


def _observation(index: int, feature: float) -> SegmentObservation:
    samples = np.linspace(0.0, 1.0, 32)
    return SegmentObservation(
        index=index,
        start_index=0,
        end_index=31,
        duration_s=feature,
        active_duration_s=feature,
        step_count=max(1, round(feature)),
        sqrt_prominence_sum=feature * 1.5,
        prominence_sum_mps2=feature * 2.0,
        acceleration_rms_mps2=1.0,
        heading_delta_rad=index * np.pi / 2.0,
        time_s=samples,
        magnetic_field_ut=np.column_stack((samples, samples**2, -samples)),
        inertial_progress=samples,
    )


def test_v2_catalog_has_only_recent_routes_and_strict_holdout():
    assert {spec.group for spec in RECENT_ROUTES} == {"route_13", "route_14", "route_15"}
    assert CALIBRATION_KEYS == {"route_13_1", "route_14_2", "route_15_1"}
    assert all(spec.key.startswith(("route_13_", "route_14_", "route_15_")) for spec in RECENT_ROUTES)


def test_segment_ridge_model_predicts_positive_distance():
    observations = [_observation(index % 4, float(index + 1)) for index in range(8)]
    distance = np.linspace(0.6, 8.0, 8)
    model = RidgeDistanceModel.fit(observations, distance)

    prediction = model.predict([_observation(0, 3.5)])

    assert prediction.shape == (1,)
    assert prediction[0] > 0.0


def test_rectangle_prior_is_soft_and_equalizes_opposite_sides():
    sensor = np.asarray([5.0, 1.8, 7.0, 1.2])
    calibration = np.asarray([6.0, 0.6, 6.0, 0.6])

    fused = regularize_rectangle(sensor, calibration, calibration_weight=0.7)

    assert fused[0] == fused[2]
    assert fused[1] == fused[3]
    assert not np.allclose(fused, calibration)
    assert not np.allclose(fused, sensor)


def test_low_step_confidence_reduces_short_edge_drift():
    sensor = np.asarray([12.5, 2.5, 12.0, 1.7])
    calibration = np.asarray([12.0, 0.6, 12.0, 0.6])

    regular = regularize_rectangle(sensor, calibration, calibration_weight=0.7)
    confidence_weighted = regularize_rectangle(
        sensor,
        calibration,
        calibration_weight=0.7,
        sensor_confidence=np.asarray([1.0, 0.2, 1.0, 0.3]),
    )

    assert abs(confidence_weighted[1] - 0.6) < abs(regular[1] - 0.6)


def test_blind_rectangle_equalization_does_not_need_reference_lengths():
    equalized = equalize_opposite_sides(np.asarray([5.0, 0.4, 7.0, 0.8]))

    np.testing.assert_allclose(equalized, [6.0, 0.6, 6.0, 0.6])


def test_magnetic_progress_is_monotonic_and_bounded():
    progress = np.linspace(0.0, 1.0, 80)
    template = np.column_stack((20.0 + progress, 30.0 + progress**2, 40.0 - progress))
    query_progress = progress**1.3
    query = np.column_stack(
        (20.0 + query_progress, 30.0 + query_progress**2, 40.0 - query_progress)
    )

    fused = bounded_magnetic_progress(template, query, progress)

    assert np.all(np.diff(fused) >= -1e-12)
    assert np.max(np.abs(fused - progress)) <= 0.15 + 1e-12
    assert fused[0] == 0.0
    assert fused[-1] == 1.0
