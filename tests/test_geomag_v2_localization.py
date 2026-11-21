import numpy as np

from geomag_v2.magnetic_map import MagneticMap
from geomag_v2.map_localization import (
    ParticleFilterConfig,
    localize_free_track,
    magnetic_features,
)


def test_magnetic_features_are_magnitude_and_vertical_component():
    vectors = np.asarray([[3.0, 4.0, 12.0], [0.0, 0.0, -2.0]])

    features = magnetic_features(vectors)

    assert np.allclose(features, [[13.0, 12.0], [2.0, -2.0]])


def test_particle_filter_corrects_overlong_inertial_track():
    true_x = np.linspace(0.0, 4.0, 81)
    map_vectors = np.column_stack((20.0 + 3.0 * true_x, np.full(81, 30.0), np.full(81, 40.0)))
    magnetic_map = MagneticMap(
        points_xy_m=np.column_stack((true_x, np.zeros_like(true_x))),
        vectors_ut=map_vectors,
        coordinate_frame="test-local",
    )
    inertial_x = np.linspace(0.0, 5.0, 81)
    inertial_track = np.column_stack((inertial_x, np.zeros_like(inertial_x)))
    observations = map_vectors.copy()

    result = localize_free_track(
        inertial_track,
        observations,
        magnetic_map,
        start_position_xy_m=(0.0, 0.0),
        config=ParticleFilterConfig(
            particle_count=300,
            magnetic_sigma_ut=1.0,
            random_seed=7,
        ),
    )

    assert result.track_xy_m.shape == inertial_track.shape
    assert abs(result.track_xy_m[-1, 0] - 4.0) < abs(inertial_track[-1, 0] - 4.0)
    assert result.resample_count > 0
