"""Tests for Geomag.models — Particle, PFState, RunContext."""

import math

import numpy as np
import pytest

from Geomag.models import (
    LocalizationHealthMonitor,
    Particle,
    PFState,
    RunContext,
)


class TestParticle:
    def test_default_creation(self):
        p = Particle()
        assert p.x == 0.0
        assert p.y == 0.0
        assert p.alive is True
        assert p.weight == 1.0
        assert p.mag_hist == []

    def test_custom_creation(self):
        p = Particle(x=1.5, y=2.5, theta=1.0, weight=0.5)
        assert p.x == 1.5
        assert p.y == 2.5
        assert p.theta == 1.0
        assert p.weight == 0.5

    def test_mag_hist(self):
        p = Particle(mag_hist=[45.0, 46.0])
        assert p.mag_hist == [45.0, 46.0]


class TestRunContext:
    def test_default_creation(self):
        ctx = RunContext(num_runs=3, window_size=400, geomag_map={"source": "uji"})
        assert ctx.num_runs == 3
        assert ctx.window_size == 400
        assert ctx.route_source == "uji"
        assert ctx.sensor_source == "uji"


class TestPFStateInit:
    def test_basic_creation(self, simple_mag_map):
        state = PFState(
            init_pos=[1.0, 1.0],
            mag_map=simple_mag_map,
            num_particles=1200,
            min_particles=50,
            seed=42,
        )
        assert len(state.particles) == 1200
        assert state.x0 == 1.0
        assert state.y0 == 1.0

    def test_particle_count_clamped(self, simple_mag_map):
        state = PFState(
            init_pos=[0, 0],
            mag_map=simple_mag_map,
            num_particles=10,
            min_particles=100,
            max_particles=500,
        )
        assert len(state.particles) == 100  # clamped up to min

    def test_particles_within_bounds(self, simple_mag_map):
        state = PFState(
            init_pos=[1.0, 1.0],
            mag_map=simple_mag_map,
            num_particles=200,
            seed=42,
        )
        for p in state.particles:
            assert state.in_strict_map_bounds(p.x, p.y), f"particle ({p.x}, {p.y}) out of bounds"

    def test_estimate_initialized(self, simple_mag_map):
        state = PFState(init_pos=[1.0, 1.0], mag_map=simple_mag_map, num_particles=100)
        ex, ey = state.get_pos()
        assert math.isfinite(ex)
        assert math.isfinite(ey)
        assert 0.0 <= ex <= 2.0
        assert 0.0 <= ey <= 2.0


class TestPFStateNormalization:
    def test_weights_sum_to_one(self, pf_state):
        pf_state._normalize_weights()
        total = sum(p.weight for p in pf_state.particles if p.alive)
        assert total == pytest.approx(1.0, abs=1e-6)

    def test_dead_particle_zero_weight(self, pf_state):
        pf_state.particles[0].weight = 0.5
        pf_state.kill_particle(pf_state.particles[0])
        assert pf_state.particles[0].alive is False
        assert pf_state.particles[0].weight == 0.0

    def test_normalization_respawns_on_zero_weights(self, pf_state):
        for p in pf_state.particles:
            p.weight = 0.0
        pf_state._normalize_weights()
        # Should have respawned particles
        assert len(pf_state.particles) >= pf_state.min_particles
        total = sum(p.weight for p in pf_state.particles)
        assert total == pytest.approx(1.0, abs=1e-6)


class TestPFStateBounds:
    def test_strict_bounds(self, simple_mag_map):
        state = PFState(init_pos=[1, 1], mag_map=simple_mag_map, num_particles=10)
        assert state.in_strict_map_bounds(1.0, 1.0) is True
        assert state.in_strict_map_bounds(100.0, 100.0) is False

    def test_clamp_to_map(self, simple_mag_map):
        state = PFState(init_pos=[1, 1], mag_map=simple_mag_map, num_particles=10)
        x, y = state.clamp_to_map(100.0, -50.0)
        # With pad=0.4: map bounds are [0, 2] → padded to [-0.4, 2.4]
        assert 0.0 - 0.4 <= x <= 2.0 + 0.4
        assert 0.0 - 0.4 <= y <= 2.0 + 0.4

    def test_clamp_to_strict_map(self, simple_mag_map):
        state = PFState(init_pos=[1, 1], mag_map=simple_mag_map, num_particles=10)
        x, y = state.clamp_to_strict_map(100.0, -50.0)
        assert 0.0 <= x <= 2.0
        assert 0.0 <= y <= 2.0


class TestPFStateMapMagnitude:
    def test_returns_float(self, pf_state):
        mag = pf_state.map_magnitude(1.0, 1.0)
        assert isinstance(mag, float)
        assert math.isfinite(mag)

    def test_out_of_bounds_returns_nan(self, pf_state):
        mag = pf_state.map_magnitude(100.0, 100.0)
        assert not math.isfinite(mag)

    def test_near_point_interpolation(self, pf_state):
        # At a known map point, should return close to the stored value
        mag = pf_state.map_magnitude(0.0, 0.0)
        assert 40.0 <= mag <= 50.0  # map point at (0,0) has z=45.0

    def test_regular_own_grid_uses_bilinear_interpolation(self):
        mag_map = {
            "source": "own",
            "grid_array": np.asarray([[0.0, 10.0], [20.0, 30.0]]),
            "map_points": np.asarray(
                [[0.0, 0.0, 0.0], [1.0, 0.0, 10.0], [0.0, 1.0, 20.0], [1.0, 1.0, 30.0]]
            ),
            "grid_map_contract": {
                "meta": {
                    "origin_xy_m": [0.0, 0.0],
                    "tile_size_x_m": 1.0,
                    "tile_size_y_m": 1.0,
                    "anchor": "corner",
                    "flip_y": False,
                }
            },
            "rangex_min": 0.0,
            "rangex_max": 1.0,
            "rangey_min": 0.0,
            "rangey_max": 1.0,
        }
        state = PFState(
            init_pos=[0.5, 0.5],
            mag_map=mag_map,
            num_particles=1,
            min_particles=1,
            max_particles=1,
            init_position_std=0.0,
        )

        assert state.map_magnitude(0.5, 0.5) == pytest.approx(15.0)


class TestPFStateMapVector:
    def test_regular_vector_grid_uses_bilinear_interpolation(self):
        mag_map = {
            "source": "own",
            "grid_array": np.asarray([[40.0, 40.0], [40.0, 40.0]]),
            "map_points": np.asarray(
                [[0.0, 0.0, 40.0], [1.0, 0.0, 40.0],
                 [0.0, 1.0, 40.0], [1.0, 1.0, 40.0]]
            ),
            "grid_map_contract": {
                "meta": {
                    "origin_xy_m": [0.0, 0.0],
                    "tile_size_x_m": 1.0,
                    "tile_size_y_m": 1.0,
                    "anchor": "corner",
                    "flip_y": False,
                }
            },
            "vector_grid": np.asarray(
                [
                    [[0.0, 0.0, 0.0], [2.0, 0.0, 2.0]],
                    [[0.0, 2.0, 2.0], [2.0, 2.0, 4.0]],
                ]
            ),
            "vector_grid_meta": {
                "origin_xy_m": [0.0, 0.0],
                "spacing_x_m": 1.0,
                "spacing_y_m": 1.0,
                "anchor": "corner",
                "flip_y": False,
            },
            "rangex_min": 0.0,
            "rangex_max": 1.0,
            "rangey_min": 0.0,
            "rangey_max": 1.0,
        }
        state = PFState(
            init_pos=[0.5, 0.5],
            mag_map=mag_map,
            num_particles=1,
            min_particles=1,
            max_particles=1,
            init_position_std=0.0,
        )

        assert state.map_vector(0.5, 0.5) == pytest.approx(
            np.asarray([1.0, 1.0, 2.0])
        )
        assert np.all(np.isnan(state.map_vector(5.0, 5.0)))


class TestPFStateEffectiveSampleSize:
    def test_uniform_weights(self, pf_state):
        for p in pf_state.particles:
            if p.alive:
                p.weight = 1.0 / len(pf_state.particles)
        pf_state._normalize_weights()
        ess = pf_state.effective_sample_size()
        n = len([p for p in pf_state.particles if p.alive])
        assert ess == pytest.approx(n, rel=0.01)

    def test_degenerate_weights(self, pf_state):
        for p in pf_state.particles:
            p.weight = 0.0
        pf_state.particles[0].weight = 1.0
        ess = pf_state.effective_sample_size()
        assert ess == pytest.approx(1.0, abs=0.1)


class TestPFStatePositionUncertainty:
    def test_concentrated_particles_report_high_confidence(self, pf_state):
        for particle in pf_state.particles:
            particle.x = 1.0
            particle.y = 1.0
            particle.weight = 1.0 / len(pf_state.particles)

        uncertainty = pf_state.position_uncertainty()

        assert uncertainty["radius95_m"] == pytest.approx(0.0)
        assert uncertainty["sigma_major_m"] == pytest.approx(0.0)
        assert uncertainty["ess_ratio"] == pytest.approx(1.0)
        assert uncertainty["level"] == "high"

    def test_spread_particles_report_finite_radius(self, pf_state):
        count = len(pf_state.particles)
        for index, particle in enumerate(pf_state.particles):
            particle.x = float(index) / max(count - 1, 1) * 2.0
            particle.y = 1.0
            particle.weight = 1.0 / count

        uncertainty = pf_state.position_uncertainty()

        assert uncertainty["radius95_m"] > 0.5
        assert uncertainty["core_radius80_m"] <= uncertainty["radius95_m"]
        assert math.isfinite(uncertainty["sigma_major_m"])
        assert 0.0 <= uncertainty["score"] <= 1.0

    def test_magnetic_information_changes_calibrated_score(self, pf_state):
        for particle in pf_state.particles:
            particle.x = 1.0
            particle.y = 1.0
            particle.weight = 1.0 / len(pf_state.particles)

        pf_state.last_weight_diagnostics = {"information_score": 0.0}
        weak = pf_state.position_uncertainty()
        pf_state.last_weight_diagnostics = {"information_score": 1.0}
        informative = pf_state.position_uncertainty()

        assert weak["measurement_information"] == pytest.approx(0.0)
        assert informative["score"] > weak["score"]


class TestLocalizationHealthMonitor:
    @staticmethod
    def low_sample():
        return {
            "score": 0.05,
            "level": "low",
            "core_radius80_m": 2.5,
            "measurement_information": 0.05,
            "ess_ratio": 0.7,
        }

    def test_warns_before_recovery(self):
        monitor = LocalizationHealthMonitor()

        first = monitor.update(self.low_sample(), step_index=1)
        second = monitor.update(self.low_sample(), step_index=2)

        assert first["status"] == "healthy"
        assert second["status"] == "lost"
        assert second["action"] == "none"

    def test_expands_then_reinitializes_after_persistent_loss(self):
        monitor = LocalizationHealthMonitor()
        samples = [
            monitor.update(self.low_sample(), step_index=index)
            for index in range(1, 9)
        ]

        assert samples[3]["action"] == "expand_search"
        assert samples[-1]["action"] == "reinitialize"
        assert samples[-1]["recovery_count"] == 2

    def test_invalid_magnetometer_is_degraded_without_particle_reset(self):
        monitor = LocalizationHealthMonitor()

        sample = monitor.update(
            self.low_sample(),
            step_index=3,
            integrity={"magnetometer_valid": False},
        )

        assert sample["status"] == "degraded"
        assert sample["action"] == "none"
        assert "magnetometer_invalid" in sample["reason_codes"]

    def test_integrity_events_select_dedicated_recovery_actions(self):
        monitor = LocalizationHealthMonitor()

        anchor = monitor.update(
            self.low_sample(),
            step_index=0,
            integrity={"initial_anchor_mismatch": True},
        )
        heading = monitor.update(
            self.low_sample(),
            step_index=1,
            integrity={
                "heading_fault": True,
                "heading_fault_started": True,
            },
        )
        cleared = monitor.update(
            self.low_sample(),
            step_index=2,
            integrity={"heading_fault_cleared": True},
        )

        assert anchor["action"] == "reinitialize_anchor"
        assert "initial_anchor_mismatch" in anchor["reason_codes"]
        assert heading["action"] == "reinitialize_heading"
        assert "gyro_heading_inconsistent" in heading["reason_codes"]
        assert cleared["action"] == "concentrate_heading"


class TestPFStateRecovery:
    def test_reinitialize_builds_bounded_normalized_cloud(self, pf_state):
        pf_state.reinitialize_for_recovery(
            anchor_xy=(1.0, 1.0),
            pdr_hint_xy=(1.8, 0.2),
            heading_angle=math.pi / 2.0,
        )

        assert len(pf_state.particles) == pf_state.n_particles
        assert sum(p.weight for p in pf_state.particles) == pytest.approx(1.0)
        assert all(
            pf_state.in_strict_map_bounds(p.x, p.y)
            for p in pf_state.particles
        )

    def test_trusted_anchor_reset_is_tight_and_updates_estimate(self, pf_state):
        pf_state.reinitialize_at_anchor(
            (0.5, 1.5),
            heading_angle=math.pi / 2.0,
            position_std=0.05,
        )

        assert np.linalg.norm(np.asarray(pf_state.estimate) - [0.5, 1.5]) < 0.1
        assert pf_state.mean_particle_heading() == pytest.approx(
            math.pi / 2.0,
            abs=0.05,
        )


class TestPFStateKLD:
    def test_returns_int(self, pf_state):
        n = pf_state.adapt_particle_count_kld()
        assert isinstance(n, int)
        assert pf_state.min_particles <= n <= pf_state.max_particles

    def test_respects_bounds(self, pf_state):
        n = pf_state.adapt_particle_count_kld(epsilon=0.5)
        assert pf_state.min_particles <= n <= pf_state.max_particles


class TestPFStateCSOResample:
    def test_maintains_particle_count(self, pf_state):
        original_n = len(pf_state.particles)
        pf_state.cso_resample(target_count=original_n)
        assert len(pf_state.particles) == original_n

    def test_respects_target_count(self, pf_state):
        # Note: min_particles default (1000) may clamp target_count up
        target = max(60, pf_state.min_particles)
        pf_state.cso_resample(target_count=target)
        assert len(pf_state.particles) == target

    def test_weights_normalized_after_resample(self, pf_state):
        pf_state.cso_resample(target_count=80)
        total = sum(p.weight for p in pf_state.particles if p.alive)
        assert total == pytest.approx(1.0, abs=1e-6)

    def test_particles_in_bounds_after_resample(self, pf_state):
        pf_state.cso_resample(target_count=80)
        for p in pf_state.particles:
            assert pf_state.in_strict_map_bounds(p.x, p.y), \
                f"resampled particle ({p.x:.2f}, {p.y:.2f}) out of bounds"


class TestPFStateSystematicResample:
    def test_zero_injection_ratio_is_supported(self, pf_state):
        original_history = [41.0, 42.0]
        expected_count = len(pf_state.particles)
        for particle in pf_state.particles:
            particle.mag_hist = list(original_history)

        pf_state.systematic_resample(
            target_count=len(pf_state.particles),
            inject_ratio=0.0,
            noise_scale=0.0,
        )

        assert len(pf_state.particles) == expected_count
        assert all(p.mag_hist == original_history for p in pf_state.particles)

    def test_full_injection_ratio_does_not_divide_by_zero(self, pf_state):
        pf_state.systematic_resample(
            target_count=len(pf_state.particles),
            inject_ratio=1.0,
            noise_scale=0.0,
        )

        assert len(pf_state.particles) >= pf_state.min_particles
        assert sum(p.weight for p in pf_state.particles) == pytest.approx(1.0)


class TestPFStateSpawn:
    def test_spawn_respects_count(self, pf_state):
        particles = pf_state._spawn_particles(25)
        assert len(particles) == 25
        assert all(isinstance(p, Particle) for p in particles)

    def test_spawned_particles_in_bounds(self, pf_state):
        particles = pf_state._spawn_particles(100)
        for p in particles:
            assert pf_state.in_strict_map_bounds(p.x, p.y)

    def test_spawn_around_center(self, pf_state):
        particles = pf_state._spawn_particles(200, center=[0.5, 0.5])
        xs = [p.x for p in particles]
        ys = [p.y for p in particles]
        mean_x = float(np.mean(xs))
        mean_y = float(np.mean(ys))
        # Center of spawn should be near (0.5, 0.5)
        assert abs(mean_x - 0.5) < 1.0
        assert abs(mean_y - 0.5) < 1.0
