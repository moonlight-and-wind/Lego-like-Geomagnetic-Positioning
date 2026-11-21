import inspect
import math
from abc import ABC, abstractmethod
from collections.abc import Callable
from typing import Any

import numpy as np

from Geomag import algorithms
from Geomag.attitude import QuaternionHeadingEstimator
from Geomag.distance import _ddtw_distance, _wrap_angle_pi


class Registry:
    """Generic name→builder registry (inspired by PyTorch's optimizer registry)."""

    def __init__(self, name: str) -> None:
        self.name = name
        self._builders: dict[str, Callable[..., object]] = {}
        self._param_docs: dict[str, dict[str, object]] = {}

    def register(self, key: str, param_docs: dict | None = None) -> Callable:
        key = str(key).lower()

        def decorator(builder: Callable[..., object]) -> Callable[..., object]:
            self._builders[key] = builder
            self._param_docs[key] = dict(param_docs or {})
            return builder

        return decorator

    def build(self, key: str, **kwargs: Any) -> object:
        token = str(key).lower()
        if token not in self._builders:
            available = ", ".join(sorted(self._builders))
            raise ValueError(f"Unknown {self.name} block '{key}'. Available: [{available}]")
        return self._builders[token](**kwargs)

    def keys(self) -> list[str]:
        return sorted(self._builders.keys())

    def describe(self) -> dict[str, dict[str, dict]]:
        return {
            key: {
                "params": self._param_docs.get(key, {}),
            }
            for key in self.keys()
        }


def describe_callable_params(callable_obj: Callable) -> dict[str, Any]:
    signature = inspect.signature(callable_obj)
    params = {}
    for name, param in signature.parameters.items():
        if name == "self":
            continue
        if param.kind in (inspect.Parameter.VAR_POSITIONAL, inspect.Parameter.VAR_KEYWORD):
            continue
        default = None if param.default is inspect.Parameter.empty else param.default
        params[name] = default
    return params


class StepJudgeBlock(ABC):
    """Detect whether a buffered sample window contains a completed step."""

    @abstractmethod
    def forward(self, samples: list[list[float]]) -> bool:
        raise NotImplementedError


class StepLengthBlock(ABC):
    """Estimate step length from buffered samples (metres)."""

    @abstractmethod
    def forward(self, samples: list[list[float]]) -> float:
        raise NotImplementedError


class HeadingBlock(ABC):
    """Estimate heading angle from buffered samples (radians)."""

    @abstractmethod
    def forward(self, samples: list[list[float]]) -> float:
        raise NotImplementedError


class MagBlock(ABC):
    """Extract a scalar magnetic feature from the current sensor frame."""

    @abstractmethod
    def forward(self) -> float:
        raise NotImplementedError


class MotionBlock(ABC):
    """Apply a motion model to each particle."""

    @abstractmethod
    def forward(self, pf_state: Any, step_len: float, heading_angle: float) -> None:
        raise NotImplementedError


class WeightBlock(ABC):
    """Update particle weights based on magnetic observation."""

    @abstractmethod
    def forward(self, pf_state: Any, geomag_seq: list[float]) -> None:
        raise NotImplementedError


class ResampleBlock(ABC):
    """Resample the particle set."""

    @abstractmethod
    def forward(self, pf_state: Any, target_count: int) -> None:
        raise NotImplementedError


class ParticleSizeBlock(ABC):
    """Determine the desired number of particles."""

    @abstractmethod
    def forward(self, pf_state: Any) -> int:
        raise NotImplementedError


class ResampleTriggerBlock(ABC):
    """Decide whether resampling should occur."""

    @abstractmethod
    def should_resample(self, pf_state: Any, target_count: int, **kwargs: Any) -> bool:
        raise NotImplementedError


class AlgoStepJudge(StepJudgeBlock):
    def __init__(self, method: str = "peak_dynamic", **kwargs: Any) -> None:
        self.method = method
        self.kwargs = kwargs

    def forward(self, samples: list[list[float]]) -> bool:
        return bool(algorithms.judge_step(samples, method=self.method, **self.kwargs))


class AlgoStepLength(StepLengthBlock):
    def __init__(self, method: str = "weinberg", **kwargs: Any) -> None:
        self.method = method
        self.kwargs = kwargs

    def forward(self, samples: list[list[float]]) -> float:
        return float(algorithms.get_step_len(samples, method=self.method, **self.kwargs))


class AlgoHeading(HeadingBlock):
    def __init__(self, method: str = "q_fused", **kwargs: Any) -> None:
        self.method = method
        self.kwargs = kwargs

    def forward(self, samples: list[list[float]]) -> float:
        return float(algorithms.get_heading_angle(samples, method=self.method, **self.kwargs))


class QuaternionHeading(HeadingBlock):
    def __init__(self, **kwargs: Any) -> None:
        self.estimator = QuaternionHeadingEstimator(**kwargs)

    def forward(self, samples: list[list[float]]) -> float:
        heading = float(self.estimator.update(samples))
        algorithms._ALGO_STATE["heading_rad"] = heading
        algorithms._ALGO_STATE["is_heading_initialized"] = True
        algorithms._ALGO_STATE["heading_debug"] = dict(
            self.estimator.diagnostics
        )
        return heading


class AlgoMag(MagBlock):
    def __init__(self, method: str = "norm_mean") -> None:
        self.method = method

    def forward(self) -> float:
        return float(algorithms.get_mag(method=self.method))



class GaussianMotion(MotionBlock):
    """Gaussian motion model with configurable boundary handling.

    Parameters
    ----------
    boundary_handling : str
        ``"kill"`` — particles outside strict bounds are killed (legacy).
        ``"clamp"`` — particles are soft-clamped to the nearest boundary.
    """

    def __init__(
        self,
        heading_noise_std: float = 0.12,
        step_noise_std: float = 0.22,
        boundary_handling: str = "kill",
        turn_heading_noise_std: float | None = None,
        turn_threshold_rad: float = 0.14,
        step_scale_random_walk_std: float = 0.0,
        heading_bias_random_walk_std: float = 0.0,
    ) -> None:
        self.heading_noise_std = float(heading_noise_std)
        self.step_noise_std = float(step_noise_std)
        self.boundary_handling = str(boundary_handling).lower()
        self.turn_heading_noise_std = (
            self.heading_noise_std
            if turn_heading_noise_std is None
            else float(turn_heading_noise_std)
        )
        self.turn_threshold_rad = float(max(0.0, turn_threshold_rad))
        self.step_scale_random_walk_std = float(max(0.0, step_scale_random_walk_std))
        self.heading_bias_random_walk_std = float(
            max(0.0, heading_bias_random_walk_std)
        )

    def forward(self, pf_state: Any, step_len: float, heading_angle: float) -> None:
        rng = getattr(pf_state, "rng", np.random.default_rng(42))
        latent_rng = getattr(pf_state, "calibration_rng", rng)
        previous_heading = getattr(pf_state, "last_motion_heading", None)
        heading_delta = (
            0.0
            if previous_heading is None
            else _wrap_angle_pi(float(heading_angle) - float(previous_heading))
        )
        override = getattr(pf_state, "motion_heading_delta_override", None)
        applied_heading_delta = (
            float(heading_delta) if override is None else float(override)
        )
        relative_heading_mode = bool(
            getattr(pf_state, "heading_recovery_mode", False)
        )
        is_turning = bool(abs(heading_delta) >= self.turn_threshold_rad)
        heading_noise_std = (
            self.turn_heading_noise_std if is_turning else self.heading_noise_std
        )
        for p in pf_state.particles:
            if not getattr(p, "alive", True):
                continue
            p.step_scale = float(
                np.clip(
                    float(getattr(p, "step_scale", 1.0))
                    + (
                        float(
                            latent_rng.normal(0.0, self.step_scale_random_walk_std)
                        )
                        if self.step_scale_random_walk_std > 0.0
                        else 0.0
                    ),
                    float(getattr(pf_state, "min_step_scale", 0.65)),
                    float(getattr(pf_state, "max_step_scale", 1.35)),
                )
            )
            p.heading_bias = _wrap_angle_pi(
                float(getattr(p, "heading_bias", 0.0))
                + (
                    float(
                        latent_rng.normal(0.0, self.heading_bias_random_walk_std)
                    )
                    if self.heading_bias_random_walk_std > 0.0
                    else 0.0
                )
            )
            if relative_heading_mode:
                theta = _wrap_angle_pi(
                    float(p.theta)
                    + applied_heading_delta
                    + float(rng.normal(0.0, heading_noise_std))
                )
            else:
                theta = _wrap_angle_pi(
                    float(heading_angle)
                    + float(p.heading_bias)
                    + float(rng.normal(0.0, heading_noise_std))
                )
            dist = max(
                0.0,
                float(step_len) * float(p.step_scale)
                + float(rng.normal(0.0, self.step_noise_std)),
            )
            p.theta = theta
            nx = float(p.x + dist * math.cos(theta))
            ny = float(p.y + dist * math.sin(theta))
            if not pf_state.in_strict_map_bounds(nx, ny):
                if self.boundary_handling == "clamp":
                    nx, ny = pf_state.clamp_to_strict_map(nx, ny)
                else:
                    pf_state.kill_particle(p)
                    continue
            p.x, p.y = float(nx), float(ny)
        pf_state.last_motion_heading = float(heading_angle)
        pf_state.last_motion_diagnostics = {
            "heading_delta_rad": float(heading_delta),
            "heading_delta_deg": float(math.degrees(heading_delta)),
            "applied_heading_delta_rad": float(applied_heading_delta),
            "relative_heading_mode": relative_heading_mode,
            "is_turning": bool(is_turning),
            "heading_noise_std": float(heading_noise_std),
            "step_scale_mean": float(
                np.mean([p.step_scale for p in pf_state.particles])
            ),
            "heading_bias_mean_deg": float(
                math.degrees(
                    np.mean([p.heading_bias for p in pf_state.particles])
                )
            ),
        }


class DDTWWeight(WeightBlock):
    """DDTW-based particle weight update.

    Parameters
    ----------
    accumulate_mode : str
        ``"multiply"`` — multiplicative accumulation (legacy).
        ``"average"`` — EMA: ``w = alpha*prior + (1-alpha)*current``.
        ``"max"`` — ``w = max(prior, current)`` (forgiving).
    alpha : float
        EMA smoothing factor (only used when ``accumulate_mode="average"``).
    """

    def __init__(
        self,
        sigma: float | None = None,
        max_hist: int = 100,
        window_ratio: float = 0.25,
        instant_sigma: float | None = None,
        accumulate: bool = True,
        accumulate_mode: str = "multiply",
        alpha: float = 0.7,
        shape_weight: float = 1.0,
        level_sigma: float | None = None,
        level_weight: float = 0.0,
        gradient_sigma: float | None = None,
        gradient_weight: float = 0.0,
        calibrate_bias: bool = False,
        bias_calibration_updates: int = 1,
        min_shape_history: int = 4,
        vector_weight: float = 0.0,
        vector_angle_sigma_deg: float = 25.0,
        vector_reject_deg: float = 60.0,
        vector_norm_tolerance_ratio: float = 0.35,
        vector_min_horizontal_ut: float = 3.0,
    ) -> None:
        self.sigma = sigma
        self.max_hist = int(max_hist)
        self.window_ratio = float(window_ratio)
        self.instant_sigma = instant_sigma
        self.accumulate = bool(accumulate)
        self.accumulate_mode = str(accumulate_mode).lower()
        self.alpha = float(np.clip(alpha, 0.0, 1.0))
        self.shape_weight = float(max(0.0, shape_weight))
        self.level_sigma = None if level_sigma is None else float(level_sigma)
        self.level_weight = float(max(0.0, level_weight))
        self.gradient_sigma = None if gradient_sigma is None else float(gradient_sigma)
        self.gradient_weight = float(max(0.0, gradient_weight))
        self.calibrate_bias = bool(calibrate_bias)
        self.bias_calibration_updates = int(max(1, bias_calibration_updates))
        self.min_shape_history = int(max(2, min_shape_history))
        self.vector_weight = float(max(0.0, vector_weight))
        self.vector_angle_sigma = math.radians(
            float(max(1e-6, vector_angle_sigma_deg))
        )
        self.vector_reject_angle = math.radians(
            float(max(1e-6, vector_reject_deg))
        )
        self.vector_norm_tolerance_ratio = float(
            max(0.0, vector_norm_tolerance_ratio)
        )
        self.vector_min_horizontal_ut = float(
            max(0.0, vector_min_horizontal_ut)
        )

    @staticmethod
    def _wrapped_angle(angle):
        return float(math.atan2(math.sin(float(angle)), math.cos(float(angle))))

    def _prepare_vector_context(self, pf_state):
        if self.vector_weight <= 0.0:
            return None, "disabled"
        if getattr(pf_state, "vector_grid_interpolator", None) is None:
            return None, "map_unavailable"
        obs = np.asarray(
            getattr(pf_state, "current_mag_vector", []),
            dtype=float,
        ).reshape(-1)
        heading = getattr(pf_state, "current_heading_angle", None)
        if (
            obs.size != 3
            or not np.all(np.isfinite(obs))
            or heading is None
            or not math.isfinite(float(heading))
        ):
            return None, "observation_unavailable"
        estimate = pf_state.get_pos()
        map_vector = np.asarray(
            pf_state.map_vector(estimate[0], estimate[1]),
            dtype=float,
        )
        if map_vector.size != 3 or not np.all(np.isfinite(map_vector)):
            return None, "map_lookup_failed"

        obs_horizontal = float(np.linalg.norm(obs[:2]))
        map_horizontal = float(np.linalg.norm(map_vector[:2]))
        obs_norm = float(np.linalg.norm(obs))
        map_norm = float(np.linalg.norm(map_vector))
        if (
            obs_horizontal < self.vector_min_horizontal_ut
            or map_horizontal < self.vector_min_horizontal_ut
            or obs_norm <= 1e-8
            or map_norm <= 1e-8
        ):
            return None, "horizontal_field_too_small"

        obs_angle = float(math.atan2(obs[1], obs[0]))
        map_angle = float(math.atan2(map_vector[1], map_vector[0]))
        if getattr(pf_state, "vector_alignment_offset", None) is None:
            pf_state.vector_alignment_offset = self._wrapped_angle(
                obs_angle - map_angle + float(heading)
            )
            pf_state.vector_norm_scale = float(obs_norm / map_norm)

        alignment = float(pf_state.vector_alignment_offset)
        scale = float(getattr(pf_state, "vector_norm_scale", 1.0) or 1.0)
        expected_angle = map_angle + alignment - float(heading)
        gate_innovation = self._wrapped_angle(obs_angle - expected_angle)
        expected_norm = max(1e-8, map_norm * scale)
        norm_residual_ratio = float(
            abs(obs_norm - expected_norm) / expected_norm
        )
        if norm_residual_ratio > self.vector_norm_tolerance_ratio:
            return (
                {
                    "alignment": alignment,
                    "gate_innovation": gate_innovation,
                    "norm_residual_ratio": norm_residual_ratio,
                },
                "norm_gate",
            )
        if abs(gate_innovation) > self.vector_reject_angle:
            return (
                {
                    "alignment": alignment,
                    "gate_innovation": gate_innovation,
                    "norm_residual_ratio": norm_residual_ratio,
                },
                "direction_gate",
            )
        return (
            {
                "obs_angle": obs_angle,
                "alignment": alignment,
                "gate_innovation": gate_innovation,
                "norm_residual_ratio": norm_residual_ratio,
            },
            "applied",
        )

    def forward(self, pf_state: Any, geomag_seq: list[float]) -> None:
        obs = np.asarray(list(geomag_seq), dtype=float).reshape(-1)
        sigma = float(self.sigma if self.sigma is not None else getattr(pf_state, "weight_sigma", 8.0))
        instant_sigma = (
            float(self.instant_sigma)
            if self.instant_sigma is not None
            else None
        )

        bias_residuals = getattr(pf_state, "mag_bias_residuals", None)
        if bias_residuals is None:
            bias_residuals = []
            pf_state.mag_bias_residuals = bias_residuals
        if (
            self.calibrate_bias
            and obs.size
            and len(bias_residuals) < self.bias_calibration_updates
        ):
            estimate = pf_state.get_pos()
            initial_map_mag = float(pf_state.map_magnitude(estimate[0], estimate[1]))
            if math.isfinite(initial_map_mag):
                bias_residuals.append(float(obs[-1] - initial_map_mag))
                pf_state.mag_bias = float(np.median(bias_residuals))
        mag_bias = float(getattr(pf_state, "mag_bias", 0.0) or 0.0)
        calibrated_obs = obs - mag_bias
        vector_context, vector_reason = self._prepare_vector_context(pf_state)
        vector_applied = vector_reason == "applied"

        shape_distances = []
        level_residuals = []
        gradient_residuals = []
        likelihoods = []
        vector_innovations = []
        for p in pf_state.particles:
            if not getattr(p, "alive", True):
                p.weight = 0.0
                continue
            prior_weight = float(max(p.weight, 1e-12)) if self.accumulate else 1.0
            pred_mag = float(pf_state.map_magnitude(p.x, p.y))
            if not math.isfinite(pred_mag):
                pf_state.kill_particle(p)
                continue
            p.mag_hist.append(pred_mag)
            hist_len = int(max(1, min(len(obs), self.max_hist)))
            pred_seq = np.asarray(p.mag_hist[-hist_len:], dtype=float)
            obs_seq = (
                calibrated_obs[-hist_len:]
                if calibrated_obs.size
                else np.asarray([pred_mag], dtype=float)
            )
            if obs_seq.size >= self.min_shape_history:
                d = _ddtw_distance(obs_seq, pred_seq, window_ratio=self.window_ratio)
            else:
                d = 0.0
            log_likelihood = -self.shape_weight * (
                (d * d) / (2.0 * sigma * sigma + 1e-12)
            )
            if instant_sigma is not None and instant_sigma > 1e-8 and obs_seq.size > 0:
                residual = float(abs(pred_mag - float(obs_seq[-1])))
                log_likelihood -= (
                    residual * residual
                ) / (2.0 * instant_sigma * instant_sigma + 1e-12)

            level_residual = (
                float(pred_mag - obs_seq[-1]) if obs_seq.size else 0.0
            )
            if (
                self.level_weight > 0.0
                and self.level_sigma is not None
                and self.level_sigma > 1e-8
            ):
                log_likelihood -= self.level_weight * (
                    (level_residual * level_residual)
                    / (2.0 * self.level_sigma * self.level_sigma + 1e-12)
                )

            gradient_residual = 0.0
            if obs_seq.size >= 2 and pred_seq.size >= 2:
                gradient_residual = float(
                    (pred_seq[-1] - pred_seq[-2]) - (obs_seq[-1] - obs_seq[-2])
                )
                if (
                    self.gradient_weight > 0.0
                    and self.gradient_sigma is not None
                    and self.gradient_sigma > 1e-8
                ):
                    log_likelihood -= self.gradient_weight * (
                        (gradient_residual * gradient_residual)
                        / (2.0 * self.gradient_sigma * self.gradient_sigma + 1e-12)
                    )

            if vector_applied:
                map_vector = np.asarray(
                    pf_state.map_vector(p.x, p.y),
                    dtype=float,
                )
                map_horizontal = (
                    float(np.linalg.norm(map_vector[:2]))
                    if map_vector.size == 3 and np.all(np.isfinite(map_vector))
                    else 0.0
                )
                if map_horizontal >= self.vector_min_horizontal_ut:
                    predicted_angle = (
                        math.atan2(map_vector[1], map_vector[0])
                        + vector_context["alignment"]
                        - float(p.theta)
                    )
                    innovation = self._wrapped_angle(
                        vector_context["obs_angle"] - predicted_angle
                    )
                    robust_innovation = float(
                        np.clip(
                            innovation,
                            -self.vector_reject_angle,
                            self.vector_reject_angle,
                        )
                    )
                    log_likelihood -= self.vector_weight * (
                        (robust_innovation * robust_innovation)
                        / (2.0 * self.vector_angle_sigma**2 + 1e-12)
                    )
                    vector_innovations.append(abs(float(innovation)))

            weight = float(max(1e-12, math.exp(max(-60.0, log_likelihood))))
            shape_distances.append(float(d))
            level_residuals.append(abs(level_residual))
            gradient_residuals.append(abs(gradient_residual))
            likelihoods.append(weight)

            if not self.accumulate:
                p.weight = weight
            elif self.accumulate_mode == "average":
                p.weight = float(self.alpha * prior_weight + (1.0 - self.alpha) * weight)
            elif self.accumulate_mode == "max":
                p.weight = float(max(prior_weight, weight))
            else:  # "multiply" (legacy)
                p.weight = float(max(1e-12, prior_weight * weight))
        pf_state._normalize_weights()
        particle_count = max(1, len(pf_state.particles))
        posterior_weights = np.asarray(
            [max(float(p.weight), 0.0) for p in pf_state.particles],
            dtype=float,
        )
        posterior_total = float(np.sum(posterior_weights))
        if posterior_total > 1e-12:
            posterior_weights /= posterior_total
        else:
            posterior_weights.fill(1.0 / particle_count)
        positive_weights = posterior_weights[posterior_weights > 0.0]
        entropy = float(
            -np.sum(positive_weights * np.log(positive_weights))
        )
        entropy_ratio = (
            entropy / math.log(particle_count)
            if particle_count > 1
            else 0.0
        )
        top_count = max(1, int(math.ceil(0.10 * particle_count)))
        top_mass_10pct = float(
            np.sum(np.partition(posterior_weights, -top_count)[-top_count:])
        )
        information_score = float(
            np.clip((top_mass_10pct - 0.10) / 0.35, 0.0, 1.0)
        )
        posterior_step_scale = float(
            sum(
                float(p.weight) * float(getattr(p, "step_scale", 1.0))
                for p in pf_state.particles
            )
        )
        bias_sin = float(
            sum(
                float(p.weight) * math.sin(float(getattr(p, "heading_bias", 0.0)))
                for p in pf_state.particles
            )
        )
        bias_cos = float(
            sum(
                float(p.weight) * math.cos(float(getattr(p, "heading_bias", 0.0)))
                for p in pf_state.particles
            )
        )
        pf_state.last_weight_diagnostics = {
            "mag_bias": float(mag_bias),
            "mag_bias_calibration_samples": int(len(bias_residuals)),
            "mag_bias_calibration_complete": bool(
                len(bias_residuals) >= self.bias_calibration_updates
            ),
            "shape_distance_mean": float(np.mean(shape_distances)) if shape_distances else 0.0,
            "level_residual_abs_mean": (
                float(np.mean(level_residuals)) if level_residuals else 0.0
            ),
            "gradient_residual_abs_mean": (
                float(np.mean(gradient_residuals)) if gradient_residuals else 0.0
            ),
            "likelihood_mean": float(np.mean(likelihoods)) if likelihoods else 0.0,
            "ess_ratio": float(pf_state.effective_sample_size()) / float(particle_count),
            "weight_entropy_ratio": float(np.clip(entropy_ratio, 0.0, 1.0)),
            "top_weight_mass_10pct": top_mass_10pct,
            "information_score": information_score,
            "history_length": int(min(obs.size, self.max_hist)),
            "posterior_step_scale": posterior_step_scale,
            "posterior_heading_bias_deg": float(
                math.degrees(math.atan2(bias_sin, bias_cos))
            ),
            "vector_enabled": bool(self.vector_weight > 0.0),
            "vector_applied": bool(vector_applied),
            "vector_reason": vector_reason,
            "vector_weight": float(self.vector_weight),
            "vector_alignment_deg": (
                None
                if vector_context is None
                else float(math.degrees(vector_context["alignment"]))
            ),
            "vector_gate_innovation_deg": (
                None
                if vector_context is None
                else float(
                    math.degrees(abs(vector_context["gate_innovation"]))
                )
            ),
            "vector_norm_residual_ratio": (
                None
                if vector_context is None
                else float(vector_context["norm_residual_ratio"])
            ),
            "vector_particle_usage_ratio": float(
                len(vector_innovations) / particle_count
            ),
            "vector_innovation_abs_mean_deg": (
                None
                if not vector_innovations
                else float(
                    math.degrees(float(np.mean(vector_innovations)))
                )
            ),
            "vector_innovation_abs_p95_deg": (
                None
                if not vector_innovations
                else float(
                    math.degrees(
                        float(np.percentile(vector_innovations, 95))
                    )
                )
            ),
        }


class CSOResample(ResampleBlock):
    def forward(self, pf_state: Any, target_count: int) -> None:
        pf_state.cso_resample(target_count=target_count)


class SystematicResample(ResampleBlock):
    """Systematic resampling with diversity injection.

    Parameters
    ----------
    inject_ratio : float
        Fraction of particles replaced with random samples (0.0–1.0).
    noise_scale : float
        Gaussian noise std added to copied particles (metres).
    """

    def __init__(self, inject_ratio: float = 0.05, noise_scale: float = 0.15) -> None:
        self.inject_ratio = float(np.clip(inject_ratio, 0.0, 1.0))
        self.noise_scale = float(max(0.0, noise_scale))

    def forward(self, pf_state: Any, target_count: int) -> None:
        pf_state.systematic_resample(
            target_count=target_count,
            inject_ratio=self.inject_ratio,
            noise_scale=self.noise_scale,
        )


class KLDSampleSize(ParticleSizeBlock):
    def __init__(self, epsilon: float = 0.12, z: float = 1.96,
                 bin_size_xy: float = 0.8, bin_size_theta: float = 0.35) -> None:
        self.epsilon = float(epsilon)
        self.z = float(z)
        self.bin_size_xy = float(bin_size_xy)
        self.bin_size_theta = float(bin_size_theta)

    def forward(self, pf_state: Any) -> int:
        return int(
            pf_state.adapt_particle_count_kld(
                epsilon=self.epsilon,
                z=self.z,
                bin_size_xy=self.bin_size_xy,
                bin_size_theta=self.bin_size_theta,
            )
        )


class ESSOrTargetTrigger(ResampleTriggerBlock):
    def __init__(self, ess_ratio_threshold: float = 0.5, warmup_steps: int = 8,
                 min_weight_cv: float = 0.01, flat_ess_ratio: float = 0.95) -> None:
        self.ess_ratio_threshold = float(ess_ratio_threshold)
        self.warmup_steps = int(max(0, warmup_steps))
        self.min_weight_cv = float(max(0.0, min_weight_cv))
        self.flat_ess_ratio = float(np.clip(flat_ess_ratio, 0.0, 1.0))

    @staticmethod
    def _weight_cv(pf_state: Any) -> float:
        ws = np.asarray([max(float(p.weight), 0.0) for p in pf_state.particles], dtype=float)
        if ws.size == 0:
            return 0.0
        total = float(np.sum(ws))
        if total <= 1e-12:
            return 0.0
        wn = ws / total
        mu = float(np.mean(wn))
        if mu <= 1e-12:
            return 0.0
        return float(np.std(wn) / (mu + 1e-12))

    def should_resample(self, pf_state: Any, target_count: int, hist_len: int | None = None, **kwargs: Any) -> bool:
        curr_n = max(1, len(pf_state.particles))
        ess = float(pf_state.effective_sample_size())
        if ess < self.ess_ratio_threshold * curr_n:
            return True

        if int(target_count) == curr_n:
            return False

        if hist_len is not None and int(hist_len) < self.warmup_steps:
            return False

        ess_ratio = ess / float(curr_n)
        weight_cv = self._weight_cv(pf_state)
        if ess_ratio >= self.flat_ess_ratio and weight_cv < self.min_weight_cv:
            return False

        return True


class AlwaysTrigger(ResampleTriggerBlock):
    def should_resample(self, pf_state: Any, target_count: int, **kwargs: Any) -> bool:
        return True


STEP_JUDGE_REGISTRY = Registry("step_judge")
STEP_LEN_REGISTRY = Registry("step_length")
HEADING_REGISTRY = Registry("heading")
MAG_REGISTRY = Registry("mag")
MOTION_REGISTRY = Registry("motion")
WEIGHT_REGISTRY = Registry("weight")
RESAMPLE_REGISTRY = Registry("resample")
PARTICLE_SIZE_REGISTRY = Registry("particle_size")
RESAMPLE_TRIGGER_REGISTRY = Registry("resample_trigger")


@STEP_JUDGE_REGISTRY.register("peak_dynamic", param_docs=describe_callable_params(AlgoStepJudge.__init__))
def _build_step_judge_peak_dynamic(**kwargs):
    return AlgoStepJudge(method="peak_dynamic", **kwargs)


@STEP_JUDGE_REGISTRY.register("peak_fixed", param_docs=describe_callable_params(AlgoStepJudge.__init__))
def _build_step_judge_peak_fixed(**kwargs):
    return AlgoStepJudge(method="peak_fixed", **kwargs)


@STEP_JUDGE_REGISTRY.register("zero_crossing", param_docs=describe_callable_params(AlgoStepJudge.__init__))
def _build_step_judge_zero_crossing(**kwargs):
    return AlgoStepJudge(method="zero_crossing", **kwargs)


@STEP_JUDGE_REGISTRY.register("valley_peak", param_docs=describe_callable_params(AlgoStepJudge.__init__))
def _build_step_judge_valley_peak(**kwargs):
    return AlgoStepJudge(method="valley_peak", **kwargs)


@STEP_JUDGE_REGISTRY.register("frequency_fft", param_docs=describe_callable_params(AlgoStepJudge.__init__))
def _build_step_judge_frequency_fft(**kwargs):
    return AlgoStepJudge(method="frequency_fft", **kwargs)


@STEP_JUDGE_REGISTRY.register("autocorr", param_docs=describe_callable_params(AlgoStepJudge.__init__))
def _build_step_judge_autocorr(**kwargs):
    return AlgoStepJudge(method="autocorr", **kwargs)


@STEP_LEN_REGISTRY.register("weinberg", param_docs=describe_callable_params(AlgoStepLength.__init__))
def _build_step_len_weinberg(**kwargs):
    return AlgoStepLength(method="weinberg", **kwargs)


@STEP_LEN_REGISTRY.register("adaptive", param_docs=describe_callable_params(AlgoStepLength.__init__))
def _build_step_len_adaptive(**kwargs):
    return AlgoStepLength(method="adaptive", **kwargs)


@STEP_LEN_REGISTRY.register("fixed", param_docs=describe_callable_params(AlgoStepLength.__init__))
def _build_step_len_fixed(**kwargs):
    return AlgoStepLength(method="fixed", **kwargs)


@HEADING_REGISTRY.register("q_fused", param_docs=describe_callable_params(AlgoHeading.__init__))
def _build_heading_q_fused(**kwargs):
    return AlgoHeading(method="q_fused", **kwargs)


@HEADING_REGISTRY.register(
    "quaternion",
    param_docs=describe_callable_params(QuaternionHeadingEstimator.__init__),
)
def _build_heading_quaternion(**kwargs):
    return QuaternionHeading(**kwargs)


@HEADING_REGISTRY.register("tilt_compass", param_docs=describe_callable_params(AlgoHeading.__init__))
def _build_heading_tilt_compass(**kwargs):
    return AlgoHeading(method="tilt_compass", **kwargs)


@HEADING_REGISTRY.register("gyro", param_docs=describe_callable_params(AlgoHeading.__init__))
def _build_heading_gyro(**kwargs):
    return AlgoHeading(method="gyro", **kwargs)


@HEADING_REGISTRY.register("core_motion", param_docs=describe_callable_params(AlgoHeading.__init__))
def _build_heading_core_motion(**kwargs):
    return AlgoHeading(method="core_motion", **kwargs)


@MAG_REGISTRY.register("norm_mean", param_docs=describe_callable_params(AlgoMag.__init__))
def _build_mag_norm_mean(**kwargs):
    return AlgoMag(method="norm_mean")


@MAG_REGISTRY.register("norm_last", param_docs=describe_callable_params(AlgoMag.__init__))
def _build_mag_norm_last(**kwargs):
    return AlgoMag(method="norm_last")


@MOTION_REGISTRY.register("gaussian", param_docs=describe_callable_params(GaussianMotion.__init__))
def _build_motion_gaussian(**kwargs):
    return GaussianMotion(**kwargs)


@WEIGHT_REGISTRY.register("ddtw", param_docs=describe_callable_params(DDTWWeight.__init__))
def _build_weight_ddtw(**kwargs):
    return DDTWWeight(**kwargs)


@RESAMPLE_REGISTRY.register("cso", param_docs={})
def _build_resample_cso(**kwargs):
    return CSOResample()


@RESAMPLE_REGISTRY.register("systematic", param_docs=describe_callable_params(SystematicResample.__init__))
def _build_resample_systematic(**kwargs):
    return SystematicResample(**kwargs)


@PARTICLE_SIZE_REGISTRY.register("kld", param_docs=describe_callable_params(KLDSampleSize.__init__))
def _build_particle_size_kld(**kwargs):
    return KLDSampleSize(**kwargs)


@RESAMPLE_TRIGGER_REGISTRY.register("ess_or_target", param_docs=describe_callable_params(ESSOrTargetTrigger.__init__))
def _build_resample_trigger_ess_or_target(**kwargs):
    return ESSOrTargetTrigger(**kwargs)


@RESAMPLE_TRIGGER_REGISTRY.register("always", param_docs={})
def _build_resample_trigger_always(**kwargs):
    return AlwaysTrigger()
