import math

import numpy as np
import pytest

from Geomag.attitude import QuaternionHeadingEstimator
from Geomag.blocks import HEADING_REGISTRY


def _sample(time_s, gyro, mag=(1.0, 0.0, 0.0), acc=(0.0, 0.0, 9.80665)):
    return [[list(acc), list(gyro), list(mag), float(time_s)]]


def test_quaternion_estimator_integrates_world_vertical_yaw():
    estimator = QuaternionHeadingEstimator(
        initial_heading_rad=0.0,
        max_dt_s=2.0,
        gravity_gain=1.5,
        calibrate_gyro_bias=False,
    )

    estimator.update(_sample(0.0, (0.0, 0.0, math.pi / 2.0)))
    heading = estimator.update(
        _sample(1.0, (0.0, 0.0, math.pi / 2.0))
    )

    assert math.degrees(heading) == pytest.approx(90.0)
    assert np.linalg.norm(estimator.quaternion) == pytest.approx(1.0)


def test_quaternion_estimator_uses_timestamps_without_replaying_samples():
    estimator = QuaternionHeadingEstimator(
        initial_heading_rad=0.0,
        max_dt_s=1.0,
        calibrate_gyro_bias=False,
    )
    sample0 = _sample(2.0, (0.0, 0.0, 1.0))
    sample1 = _sample(2.1, (0.0, 0.0, 1.0))

    estimator.update(sample0)
    once = estimator.update(sample1)
    replayed = estimator.update(sample1)

    assert once == pytest.approx(0.1)
    assert replayed == pytest.approx(once)


def test_quaternion_estimator_calibrates_all_three_gyro_bias_axes():
    estimator = QuaternionHeadingEstimator(
        initial_heading_rad=0.0,
        stationary_min_duration_s=0.0,
    )
    bias = (0.01, -0.02, 0.03)

    estimator.update(_sample(0.0, bias))
    estimator.update(_sample(0.01, bias))

    assert estimator.gyro_bias == pytest.approx(bias)
    assert estimator.diagnostics["gyro_bias_samples"] == 2


def test_quaternion_bias_rejects_short_stationary_fragments():
    estimator = QuaternionHeadingEstimator(
        initial_heading_rad=0.0,
        stationary_min_duration_s=0.25,
    )
    bias = (0.01, -0.02, 0.03)

    estimator.update(_sample(0.0, bias))
    estimator.update(
        _sample(
            0.01,
            (0.0, 0.0, 0.5),
            acc=(0.0, 0.0, 11.0),
        )
    )

    assert estimator.gyro_bias_samples == 0
    assert estimator.gyro_bias == pytest.approx((0.0, 0.0, 0.0))


def test_magnetic_yaw_correction_accepts_consistent_norm_and_rejects_anomaly():
    estimator = QuaternionHeadingEstimator(
        initial_heading_rad=0.0,
        use_magnetometer=True,
        magnetic_yaw_gain=1.0,
        magnetic_correction_limit_deg_s=90.0,
        max_dt_s=1.0,
        calibrate_gyro_bias=False,
    )
    estimator.update(_sample(0.0, (0.0, 0.0, 0.0)))
    angle = math.radians(20.0)
    consistent_mag = (math.cos(angle), -math.sin(angle), 0.0)

    corrected = estimator.update(
        _sample(0.1, (0.0, 0.0, 0.0), mag=consistent_mag)
    )
    assert estimator.diagnostics["magnetic_accepted"] is True
    assert corrected > 0.0

    before_anomaly = corrected
    anomalous_mag = tuple(100.0 * value for value in consistent_mag)
    after_anomaly = estimator.update(
        _sample(0.2, (0.0, 0.0, 0.0), mag=anomalous_mag)
    )
    assert estimator.diagnostics["magnetic_accepted"] is False
    assert after_anomaly == pytest.approx(before_anomaly)


def test_quaternion_heading_is_available_as_pipeline_block():
    block = HEADING_REGISTRY.build(
        "quaternion",
        initial_heading_rad=math.pi / 2.0,
    )

    heading = block.forward(_sample(0.0, (0.0, 0.0, 0.0)))

    assert heading == pytest.approx(math.pi / 2.0)
