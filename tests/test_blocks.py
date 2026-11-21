"""Tests for Geomag.blocks — Registry and block implementations."""

import math

import numpy as np
import pytest

from Geomag.blocks import (
    AlwaysTrigger,
    DDTWWeight,
    GaussianMotion,
    Registry,
    describe_callable_params,
)
from Geomag.models import Particle, PFState


class TestRegistry:
    def test_register_and_build(self):
        reg = Registry("test")

        @reg.register("my_block")
        def _build_my_block(**kwargs):
            return {"type": "my_block", "kwargs": kwargs}

        result = reg.build("my_block", param_a=1, param_b=2)
        assert result == {"type": "my_block", "kwargs": {"param_a": 1, "param_b": 2}}

    def test_unknown_key_raises(self):
        reg = Registry("test")
        with pytest.raises(ValueError, match="Unknown test block"):
            reg.build("nonexistent")

    def test_keys(self):
        reg = Registry("test")

        @reg.register("alpha")
        def _alpha():
            pass

        @reg.register("beta")
        def _beta():
            pass

        assert reg.keys() == ["alpha", "beta"]

    def test_describe(self):
        reg = Registry("test")

        @reg.register("my_block", param_docs={"x": "param x"})
        def _my_block(x=1):
            pass

        desc = reg.describe()
        assert "my_block" in desc
        assert desc["my_block"]["params"] == {"x": "param x"}

    def test_case_insensitive_key(self):
        reg = Registry("test")

        @reg.register("MyBlock")
        def _my_block():
            return 42

        assert reg.build("myblock") == 42
        assert reg.build("MYBLOCK") == 42

    def test_decorator_returns_builder(self):
        reg = Registry("test")

        @reg.register("block")
        def _block():
            return "ok"

        # The decorator should return the original function
        assert _block() == "ok"


class TestDescribeCallableParams:
    def test_simple_function(self):
        def fn(a, b=10, c="hello"):
            pass

        params = describe_callable_params(fn)
        assert params == {"a": None, "b": 10, "c": "hello"}

    def test_method_skips_self(self):
        class Foo:
            def method(self, x, y=5):
                pass

        params = describe_callable_params(Foo().method)
        assert params == {"x": None, "y": 5}
        assert "self" not in params


class TestAlwaysTrigger:
    def test_always_true(self):
        trigger = AlwaysTrigger()
        assert trigger.should_resample(None, target_count=100) is True
        assert trigger.should_resample(None, target_count=0) is True


class TestGaussianMotion:
    def test_turn_uses_larger_heading_noise(self, pf_state):
        pf_state.last_motion_heading = 0.0
        motion = GaussianMotion(
            heading_noise_std=0.01,
            turn_heading_noise_std=0.20,
            turn_threshold_rad=0.10,
        )

        motion.forward(pf_state, step_len=0.0, heading_angle=0.5)

        assert pf_state.last_motion_diagnostics["is_turning"] is True
        assert pf_state.last_motion_diagnostics["heading_noise_std"] == pytest.approx(0.20)

    def test_particle_scale_and_heading_bias_modify_motion(self, pf_state):
        pf_state.particles = [
            Particle(
                x=1.0,
                y=1.0,
                weight=1.0,
                step_scale=2.0,
                heading_bias=1.5707963267948966,
            )
        ]
        pf_state.max_step_scale = 2.0
        motion = GaussianMotion(heading_noise_std=0.0, step_noise_std=0.0)

        motion.forward(pf_state, step_len=0.4, heading_angle=0.0)

        assert pf_state.particles[0].x == pytest.approx(1.0)
        assert pf_state.particles[0].y == pytest.approx(1.8)


class TestHybridMagneticWeight:
    def test_calibrates_constant_observation_bias(self, pf_state):
        estimate = pf_state.get_pos()
        expected_map_mag = pf_state.map_magnitude(*estimate)
        weight = DDTWWeight(
            sigma=1.0,
            accumulate=False,
            level_sigma=1.0,
            level_weight=1.0,
            calibrate_bias=True,
        )

        weight.forward(pf_state, geomag_seq=[expected_map_mag + 2.0])

        assert pf_state.mag_bias == pytest.approx(2.0)
        assert pf_state.last_weight_diagnostics["mag_bias"] == pytest.approx(2.0)

    def test_robust_bias_calibration_uses_median_of_initial_updates(self, pf_state):
        estimate = pf_state.get_pos()
        expected = pf_state.map_magnitude(*estimate)
        weight = DDTWWeight(
            sigma=1.0,
            accumulate=False,
            calibrate_bias=True,
            bias_calibration_updates=3,
        )

        for offset in (10.0, 2.0, 4.0):
            weight.forward(pf_state, geomag_seq=[expected + offset])

        assert pf_state.mag_bias == pytest.approx(4.0)
        assert pf_state.last_weight_diagnostics[
            "mag_bias_calibration_samples"
        ] == 3
        assert pf_state.last_weight_diagnostics[
            "mag_bias_calibration_complete"
        ] is True

    @staticmethod
    def _vector_state():
        mag_map = {
            "source": "own",
            "grid_array": np.full((2, 2), 40.0),
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
                    [[20.0, 0.0, 35.0], [20.0, 0.0, 35.0]],
                    [[20.0, 0.0, 35.0], [20.0, 0.0, 35.0]],
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
            num_particles=2,
            min_particles=1,
            max_particles=2,
            init_position_std=0.0,
        )
        state.particles = [
            Particle(x=0.5, y=0.5, theta=0.0, weight=0.5),
            Particle(x=0.5, y=0.5, theta=math.pi / 2.0, weight=0.5),
        ]
        state.current_mag_vector = np.asarray([20.0, 0.0, 35.0])
        state.current_heading_angle = 0.0
        return state

    def test_vector_likelihood_prefers_heading_consistent_particle(self):
        state = self._vector_state()
        weight = DDTWWeight(
            sigma=1.0,
            shape_weight=0.0,
            accumulate=False,
            vector_weight=1.0,
            vector_angle_sigma_deg=20.0,
            vector_reject_deg=60.0,
        )

        weight.forward(state, geomag_seq=[40.0])

        assert state.particles[0].weight > state.particles[1].weight
        assert state.last_weight_diagnostics["vector_applied"] is True
        assert (
            state.last_weight_diagnostics["vector_particle_usage_ratio"]
            == pytest.approx(1.0)
        )

    def test_vector_likelihood_falls_back_when_map_is_absent(self, pf_state):
        pf_state.current_mag_vector = np.asarray([20.0, 0.0, 35.0])
        pf_state.current_heading_angle = 0.0
        weight = DDTWWeight(vector_weight=1.0)

        weight.forward(pf_state, geomag_seq=[45.0])

        assert pf_state.last_weight_diagnostics["vector_applied"] is False
        assert (
            pf_state.last_weight_diagnostics["vector_reason"]
            == "map_unavailable"
        )
