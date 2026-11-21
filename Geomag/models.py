import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
import numpy.typing as npt

from Geomag.distance import latlon_to_xy


@dataclass
class RunContext:
    num_runs: int
    window_size: int
    geomag_map: Any
    route_source: str = "uji"
    sensor_source: str = "uji"
    data_root: str = "data/raw"
    uji_test_file: str = "tt01.txt"
    own_data_dir: str = "data/Geomagnetic Navigation 2026-03-03 15-28-45"
    own_dataset_key: str | None = None


@dataclass
class Particle:
    x: float = 0.0
    y: float = 0.0
    theta: float = 0.0
    weight: float = 1.0
    mag_hist: list[float] = field(default_factory=list)
    alive: bool = True
    step_scale: float = 1.0
    heading_bias: float = 0.0


@dataclass
class LocalizationHealthMonitor:
    """Convert calibrated PF diagnostics into warnings and recovery actions.

    A broad posterior is reported as ambiguous immediately, but recovery is
    deliberately delayed until ambiguity persists.  This prevents the global
    diversity particles used by normal resampling from causing a spurious
    reset after a single weak magnetic observation.
    """

    warning_streak: int = 2
    expand_streak: int = 4
    reinitialize_streak: int = 7
    cooldown_steps: int = 4
    low_score_threshold: float = 0.32
    lost_score_threshold: float = 0.14
    low_confidence_streak: int = 0
    lost_streak: int = 0
    cooldown_remaining: int = 0
    recovery_count: int = 0
    sensor_fault_streak: int = 0
    heading_fault_streak: int = 0

    def update(
        self,
        uncertainty,
        *,
        step_index: int,
        integrity: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        integrity = dict(integrity or {})
        score = float(uncertainty.get("score", 0.0))
        core_radius = float(uncertainty.get("core_radius80_m", math.inf))
        information = float(uncertainty.get("measurement_information", 0.0))
        low = bool(
            uncertainty.get("level") == "low"
            or score < self.low_score_threshold
        )
        lost_evidence = bool(
            score < self.lost_score_threshold
            and (core_radius > 2.0 or information < 0.12)
        )
        magnetometer_valid = bool(
            integrity.get("magnetometer_valid", True)
        )
        heading_fault = bool(integrity.get("heading_fault", False))
        relative_heading_recovery = bool(
            integrity.get("relative_heading_recovery", False)
        )
        heading_fault_started = bool(
            integrity.get("heading_fault_started", False)
        )
        heading_fault_cleared = bool(
            integrity.get("heading_fault_cleared", False)
        )
        initial_anchor_mismatch = bool(
            integrity.get("initial_anchor_mismatch", False)
        )
        if (
            relative_heading_recovery
            and not heading_fault
            and core_radius <= 1.75
            and score >= 0.24
        ):
            # Once the gyro fault has cleared, a compact relative-heading
            # posterior is usable even when the scalar magnetic map provides
            # only modest discrimination.
            low = False
            lost_evidence = False
        self.sensor_fault_streak = (
            0 if magnetometer_valid else self.sensor_fault_streak + 1
        )
        self.heading_fault_streak = (
            self.heading_fault_streak + 1 if heading_fault else 0
        )
        self.low_confidence_streak = (
            self.low_confidence_streak + 1 if low else 0
        )
        self.lost_streak = self.lost_streak + 1 if lost_evidence else 0

        if self.cooldown_remaining > 0:
            self.cooldown_remaining -= 1

        action = "none"
        if heading_fault_cleared:
            self.low_confidence_streak = 0
            self.lost_streak = 0

        if initial_anchor_mismatch:
            action = "reinitialize_anchor"
        elif heading_fault_started:
            action = "reinitialize_heading"
        elif heading_fault_cleared:
            action = "concentrate_heading"
        elif not magnetometer_valid or heading_fault:
            # Do not repeatedly broaden/reset while the input sensor itself is
            # invalid. The caller keeps prediction alive and waits for usable
            # observations before evaluating ordinary PF recovery.
            action = "none"
        elif self.cooldown_remaining == 0:
            if self.lost_streak >= self.reinitialize_streak:
                action = "reinitialize"
            elif self.low_confidence_streak == self.expand_streak:
                action = "expand_search"

        if action != "none":
            self.recovery_count += 1
            self.cooldown_remaining = self.cooldown_steps

        if action != "none":
            status = "recovering"
        elif not magnetometer_valid:
            status = "degraded"
        elif heading_fault or initial_anchor_mismatch:
            status = "lost"
        elif self.lost_streak >= self.warning_streak:
            status = "lost"
        elif self.low_confidence_streak >= self.warning_streak:
            status = "ambiguous"
        else:
            status = "healthy"

        reasons = []
        if core_radius > 2.0:
            reasons.append("particle_core_spread")
        if information < 0.12:
            reasons.append("weak_magnetic_discrimination")
        if float(uncertainty.get("ess_ratio", 1.0)) < 0.08:
            reasons.append("weight_degeneracy")
        if not magnetometer_valid:
            reasons.append("magnetometer_invalid")
        if heading_fault:
            reasons.append("gyro_heading_inconsistent")
        if initial_anchor_mismatch:
            reasons.append("initial_anchor_mismatch")
        if not reasons and low:
            reasons.append("low_calibrated_score")

        return {
            "step_index": int(step_index),
            "status": status,
            "score": score,
            "low_confidence_streak": int(self.low_confidence_streak),
            "lost_streak": int(self.lost_streak),
            "sensor_fault_streak": int(self.sensor_fault_streak),
            "heading_fault_streak": int(self.heading_fault_streak),
            "action": action,
            "reason_codes": reasons,
            "recovery_count": int(self.recovery_count),
        }


class PFState:
    """Particle-filter state: particles, map, resampling, and estimation."""

    def __init__(
        self,
        init_pos: Any,
        mag_map: Any,
        num_particles: int = 50000,
        seed: int = 42,
        weight_sigma: float = 8.0,
        map_knn_k: int = 10,
        map_idw_power: float = 2.0,
        min_particles: int = 1000,
        max_particles: int = 100000000,
        init_position_std: float = 0.8,
        init_step_scale_std: float = 0.0,
        min_step_scale: float = 0.65,
        max_step_scale: float = 1.35,
        init_heading_bias_std: float = 0.0,
    ) -> None:
        self.mag_map = mag_map
        self.rng = np.random.default_rng(seed)
        # Keep latent calibration draws separate so enabling scale/bias
        # estimation does not silently change the spatial particle sequence.
        self.calibration_rng = np.random.default_rng(int(seed) + 1009)
        self.weight_sigma = float(weight_sigma)
        self.map_knn_k = max(1, int(map_knn_k))
        self.map_idw_power = float(map_idw_power)
        self.min_particles = int(min_particles)
        self.max_particles = int(max_particles)
        self.init_position_std = float(max(0.0, init_position_std))
        self.init_step_scale_std = float(max(0.0, init_step_scale_std))
        self.min_step_scale = float(min_step_scale)
        self.max_step_scale = float(max_step_scale)
        if self.max_step_scale < self.min_step_scale:
            self.min_step_scale, self.max_step_scale = self.max_step_scale, self.min_step_scale
        self.init_heading_bias_std = float(max(0.0, init_heading_bias_std))
        self.n_particles = int(np.clip(num_particles, self.min_particles, self.max_particles))
        self.map_points = self._load_map_points(mag_map)
        self.grid_interpolator = self._load_grid_interpolator(mag_map)
        self.vector_grid_interpolator = self._load_vector_grid_interpolator(
            mag_map
        )
        self.strict_map_bounds = self._infer_strict_map_bounds(mag_map, self.map_points)
        self.map_bounds = self._infer_map_bounds(self.map_points)
        self.x0, self.y0 = self._normalize_init_pos(init_pos, mag_map)
        self.particles = self._spawn_particles(self.n_particles)
        self.mag_bias = None
        self.mag_bias_residuals = []
        self.current_mag_vector = None
        self.current_heading_angle = None
        self.vector_alignment_offset = None
        self.vector_norm_scale = None
        self.last_weight_diagnostics = {}
        self.last_motion_diagnostics = {}
        self.last_motion_heading = None
        self.heading_recovery_mode = False
        self.motion_heading_delta_override = None
        self._normalize_weights()
        self.estimate = self._estimate_xy()
        self.last_position_uncertainty = self.position_uncertainty()

    def _normalize_init_pos(self, init_pos, mag_map) -> tuple[float, float]:
        arr = np.asarray(init_pos, dtype=float).reshape(-1)
        if arr.size < 2:
            return 0.0, 0.0
        a, b = float(arr[0]), float(arr[1])

        # If map provides geo origin and pos looks like lat/lon, convert to local xy.
        try:
            if isinstance(mag_map, dict) and "output_model_npz" in mag_map:
                p = Path(mag_map["output_model_npz"])
                if p.exists():
                    model = np.load(p)
                    if "origin_lat" in model and "origin_lon" in model and abs(a) <= 90 and abs(b) <= 180:
                        lat0 = float(model["origin_lat"][0])
                        lon0 = float(model["origin_lon"][0])
                        return latlon_to_xy(a, b, lat0, lon0)
        except Exception:
            pass

        return a, b

    def _load_map_points(self, mag_map) -> dict[str, npt.NDArray[np.float64]] | None:
        if not isinstance(mag_map, dict):
            return None

        # UJI continuous model points
        if "output_model_npz" in mag_map:
            path = Path(mag_map["output_model_npz"])
            if path.exists():
                model = np.load(path)
                x = np.asarray(model.get("x_train", []), dtype=float)
                y = np.asarray(model.get("y_train", []), dtype=float)
                z = np.asarray(model.get("z_train", []), dtype=float)
                if x.size and y.size and z.size and x.size == y.size == z.size:
                    return {"x": x, "y": y, "z": z}

        # Own grid points
        if mag_map.get("source") == "own":
            cloud = np.asarray(mag_map.get("map_points", []), dtype=float)
            if cloud.ndim == 2 and cloud.shape[1] >= 3 and cloud.shape[0] > 0:
                finite = np.isfinite(cloud[:, 0]) & np.isfinite(cloud[:, 1]) & np.isfinite(cloud[:, 2])
                if np.any(finite):
                    return {"x": cloud[finite, 0], "y": cloud[finite, 1], "z": cloud[finite, 2]}

            grid_array = mag_map.get("grid_array")
            if grid_array is not None:
                grid = np.asarray(grid_array, dtype=float)
                if grid.ndim == 2 and grid.size > 0:
                    meta = mag_map.get("grid_map_contract", {}).get("meta", {})
                    origin = meta.get("origin_xy_m", [0.0, 0.0])
                    ox = float(origin[0]) if len(origin) > 0 else 0.0
                    oy = float(origin[1]) if len(origin) > 1 else 0.0
                    tile_size_x_m = float(meta.get("tile_size_x_m", meta.get("cell_size_m", 1.0)) or 1.0)
                    tile_size_y_m = float(meta.get("tile_size_y_m", meta.get("cell_size_m", 1.0)) or 1.0)
                    anchor = str(meta.get("anchor", "center")).strip().lower()
                    if anchor not in {"center", "corner"}:
                        anchor = "center"

                    flip_raw = meta.get("flip_y", True)
                    if isinstance(flip_raw, str):
                        flip_y = flip_raw.strip().lower() in {"1", "true", "yes", "y", "on"}
                    else:
                        flip_y = bool(flip_raw)

                    rows, cols = grid.shape
                    col_idx = np.tile(np.arange(cols, dtype=float), rows)
                    row_idx = np.repeat(np.arange(rows, dtype=float), cols)
                    y_idx = (rows - 1.0 - row_idx) if flip_y else row_idx
                    offset_x = 0.5 * tile_size_x_m if anchor == "center" else 0.0
                    offset_y = 0.5 * tile_size_y_m if anchor == "center" else 0.0

                    z = grid.reshape(-1)
                    finite = np.isfinite(z)
                    if np.any(finite):
                        x = ox + col_idx * tile_size_x_m + offset_x
                        y = oy + y_idx * tile_size_y_m + offset_y
                        return {"x": x[finite], "y": y[finite], "z": z[finite]}

        return None

    @staticmethod
    def _load_grid_interpolator(mag_map):
        """Return metadata for direct bilinear lookup on a regular own-data grid.

        Treating a dense scan-line grid as an unstructured point cloud makes
        KNN select many neighbours from the same row and produces discontinuous
        values between rows.  Keeping the regular-grid contract lets us
        interpolate in both spatial dimensions.
        """
        if not isinstance(mag_map, dict) or mag_map.get("source") != "own":
            return None
        grid = np.asarray(mag_map.get("grid_array", []), dtype=float)
        if grid.ndim != 2 or grid.size == 0:
            return None

        meta = mag_map.get("grid_map_contract", {}).get("meta", {})
        origin = meta.get("origin_xy_m", [0.0, 0.0])
        ox = float(origin[0]) if len(origin) > 0 else 0.0
        oy = float(origin[1]) if len(origin) > 1 else 0.0
        dx = float(meta.get("tile_size_x_m", meta.get("cell_size_m", 1.0)) or 1.0)
        dy = float(meta.get("tile_size_y_m", meta.get("cell_size_m", 1.0)) or 1.0)
        if dx <= 0.0 or dy <= 0.0:
            return None
        anchor = str(meta.get("anchor", "center")).strip().lower()
        offset_x = 0.5 * dx if anchor == "center" else 0.0
        offset_y = 0.5 * dy if anchor == "center" else 0.0
        flip_raw = meta.get("flip_y", True)
        flip_y = (
            flip_raw.strip().lower() in {"1", "true", "yes", "y", "on"}
            if isinstance(flip_raw, str)
            else bool(flip_raw)
        )
        return {
            "grid": grid,
            "origin_x": ox,
            "origin_y": oy,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "spacing_x": dx,
            "spacing_y": dy,
            "flip_y": flip_y,
        }

    @staticmethod
    def _load_vector_grid_interpolator(mag_map):
        if not isinstance(mag_map, dict) or mag_map.get("source") != "own":
            return None
        grid = np.asarray(mag_map.get("vector_grid", []), dtype=float)
        if grid.ndim != 3 or grid.shape[2] != 3 or grid.size == 0:
            return None
        meta = mag_map.get("vector_grid_meta", {})
        origin = meta.get("origin_xy_m", [0.0, 0.0])
        ox = float(origin[0]) if len(origin) > 0 else 0.0
        oy = float(origin[1]) if len(origin) > 1 else 0.0
        dx = float(meta.get("spacing_x_m", 1.0) or 1.0)
        dy = float(meta.get("spacing_y_m", 1.0) or 1.0)
        if dx <= 0.0 or dy <= 0.0:
            return None
        anchor = str(meta.get("anchor", "center")).strip().lower()
        offset_x = 0.5 * dx if anchor == "center" else 0.0
        offset_y = 0.5 * dy if anchor == "center" else 0.0
        flip_raw = meta.get("flip_y", True)
        flip_y = (
            flip_raw.strip().lower() in {"1", "true", "yes", "y", "on"}
            if isinstance(flip_raw, str)
            else bool(flip_raw)
        )
        return {
            "grid": grid,
            "origin_x": ox,
            "origin_y": oy,
            "offset_x": offset_x,
            "offset_y": offset_y,
            "spacing_x": dx,
            "spacing_y": dy,
            "flip_y": flip_y,
        }

    def _spawn_particles(self, n: int, center=None) -> list[Particle]:
        if center is None:
            cx, cy = self.x0, self.y0
        else:
            cx, cy = float(center[0]), float(center[1])
        particles = []
        attempts = 0
        max_attempts = max(100, int(n) * 20)
        while len(particles) < int(n) and attempts < max_attempts:
            attempts += 1
            px = float(cx + self.rng.normal(0.0, self.init_position_std))
            py = float(cy + self.rng.normal(0.0, self.init_position_std))
            if not self.in_strict_map_bounds(px, py):
                continue
            particles.append(
                Particle(
                    x=px,
                    y=py,
                    theta=float(self.rng.uniform(-math.pi, math.pi)),
                    weight=1.0 / max(n, 1),
                    step_scale=float(
                        np.clip(
                            1.0
                            + (
                                self.calibration_rng.normal(
                                    0.0, self.init_step_scale_std
                                )
                                if self.init_step_scale_std > 0.0
                                else 0.0
                            ),
                            self.min_step_scale,
                            self.max_step_scale,
                        )
                    ),
                    heading_bias=float(
                        (((self.calibration_rng.normal(0.0, self.init_heading_bias_std)
                           if self.init_heading_bias_std > 0.0 else 0.0) + math.pi)
                         % (2.0 * math.pi))
                        - math.pi
                    ),
                )
            )
        while len(particles) < int(n):
            px, py = self._random_in_strict_map()
            particles.append(
                Particle(
                    x=px,
                    y=py,
                    theta=float(self.rng.uniform(-math.pi, math.pi)),
                    weight=1.0 / max(n, 1),
                    step_scale=float(
                        np.clip(
                            1.0
                            + (
                                self.calibration_rng.normal(
                                    0.0, self.init_step_scale_std
                                )
                                if self.init_step_scale_std > 0.0
                                else 0.0
                            ),
                            self.min_step_scale,
                            self.max_step_scale,
                        )
                    ),
                    heading_bias=float(
                        (((self.calibration_rng.normal(0.0, self.init_heading_bias_std)
                           if self.init_heading_bias_std > 0.0 else 0.0) + math.pi)
                         % (2.0 * math.pi))
                        - math.pi
                    ),
                )
            )
        return particles

    @staticmethod
    def _infer_strict_map_bounds(mag_map, map_points):
        if isinstance(mag_map, dict):
            keys = ("rangex_min", "rangex_max", "rangey_min", "rangey_max")
            if all(k in mag_map for k in keys):
                try:
                    return (
                        float(mag_map["rangex_min"]),
                        float(mag_map["rangex_max"]),
                        float(mag_map["rangey_min"]),
                        float(mag_map["rangey_max"]),
                    )
                except (TypeError, ValueError):
                    pass
        return PFState._infer_map_bounds(map_points, pad=0.0)

    @staticmethod
    def _infer_map_bounds(map_points, pad=0.4):
        if map_points is None:
            return None
        x = np.asarray(map_points.get("x", []), dtype=float)
        y = np.asarray(map_points.get("y", []), dtype=float)
        if x.size == 0 or y.size == 0:
            return None
        return (
            float(np.min(x) - pad),
            float(np.max(x) + pad),
            float(np.min(y) - pad),
            float(np.max(y) + pad),
        )

    def clamp_to_map(self, x: float, y: float) -> tuple[float, float]:
        if self.map_bounds is None:
            return float(x), float(y)
        min_x, max_x, min_y, max_y = self.map_bounds
        return float(np.clip(x, min_x, max_x)), float(np.clip(y, min_y, max_y))

    def clamp_to_strict_map(self, x: float, y: float) -> tuple[float, float]:
        if self.strict_map_bounds is None:
            return float(x), float(y)
        min_x, max_x, min_y, max_y = self.strict_map_bounds
        return float(np.clip(x, min_x, max_x)), float(np.clip(y, min_y, max_y))

    def in_strict_map_bounds(self, x: float, y: float) -> bool:
        if self.strict_map_bounds is None:
            return True
        min_x, max_x, min_y, max_y = self.strict_map_bounds
        return bool(min_x <= float(x) <= max_x and min_y <= float(y) <= max_y)

    def _random_in_strict_map(self) -> tuple[float, float]:
        if self.strict_map_bounds is None:
            return self.x0, self.y0
        min_x, max_x, min_y, max_y = self.strict_map_bounds
        return (
            float(self.rng.uniform(min_x, max_x)),
            float(self.rng.uniform(min_y, max_y)),
        )

    @staticmethod
    def kill_particle(p: Particle) -> None:
        p.alive = False
        p.weight = 0.0

    def _normalize_weights(self) -> None:
        live = [p for p in self.particles if getattr(p, "alive", True)]
        total = float(sum(max(p.weight, 0.0) for p in live))
        if total <= 1e-12:
            # Soft recovery: inject tiny weights before hard respawn so
            # particles that were killed by a single bad match can recover.
            n_live = len(live)
            n_total = len(self.particles)
            if n_total > 0 and n_live == 0:
                # All dead — give every particle a uniform tiny weight
                # and re-check on next cycle.
                tiny = 1.0 / float(n_total)
                for p in self.particles:
                    p.alive = True
                    p.weight = tiny
                total = 1.0
            else:
                n = int(np.clip(n_total or self.min_particles, self.min_particles, self.max_particles))
                center = getattr(self, "estimate", (self.x0, self.y0))
                self.particles = self._spawn_particles(n, center=center)
                w = 1.0 / max(len(self.particles), 1)
                for p in self.particles:
                    p.alive = True
                    p.weight = w
                return
        for p in self.particles:
            if getattr(p, "alive", True):
                p.weight = max(p.weight, 0.0) / total
            else:
                p.weight = 0.0

    def _estimate_xy(self) -> tuple[float, float]:
        if not self.particles:
            return (0.0, 0.0)
        self._normalize_weights()
        live = [p for p in self.particles if getattr(p, "alive", True)]
        xs = np.asarray([p.x for p in live], dtype=float)
        ys = np.asarray([p.y for p in live], dtype=float)
        ws = np.asarray([p.weight for p in live], dtype=float)
        return float(np.sum(xs * ws)), float(np.sum(ys * ws))

    def get_pos(self) -> tuple[float, float]:
        self.estimate = self._estimate_xy()
        return self.estimate

    def effective_sample_size(self) -> float:
        if not self.particles:
            return 0.0
        ws = np.asarray([p.weight for p in self.particles], dtype=float)
        denom = float(np.sum(ws * ws))
        if denom <= 1e-12:
            return 0.0
        return float(1.0 / denom)

    def position_uncertainty(self) -> dict[str, float | str]:
        """Summarize spatial particle dispersion for UI confidence display.

        ``radius95_m`` is the weighted 95th percentile distance from the
        posterior mean.  It is a diagnostic spread measure, not a guaranteed
        statistical coverage bound.
        """
        live = [p for p in self.particles if getattr(p, "alive", True)]
        if not live:
            return {
                "radius95_m": 0.0,
                "core_radius80_m": 0.0,
                "sigma_major_m": 0.0,
                "sigma_minor_m": 0.0,
                "ess_ratio": 0.0,
                "measurement_information": 0.0,
                "global_ambiguity": 0.0,
                "score": 0.0,
                "level": "low",
            }
        xs = np.asarray([p.x for p in live], dtype=float)
        ys = np.asarray([p.y for p in live], dtype=float)
        weights = np.asarray([max(float(p.weight), 0.0) for p in live], dtype=float)
        total = float(np.sum(weights))
        if total <= 1e-12:
            weights.fill(1.0 / len(live))
        else:
            weights /= total
        mean_x = float(np.sum(xs * weights))
        mean_y = float(np.sum(ys * weights))
        centered = np.column_stack((xs - mean_x, ys - mean_y))
        covariance = (centered * weights[:, None]).T @ centered
        eigenvalues = np.maximum(np.linalg.eigvalsh(covariance), 0.0)
        sigma_minor = float(math.sqrt(eigenvalues[0]))
        sigma_major = float(math.sqrt(eigenvalues[-1]))

        distances = np.sqrt((xs - mean_x) ** 2 + (ys - mean_y) ** 2)
        order = np.argsort(distances)
        cumulative = np.cumsum(weights[order])

        def weighted_radius(mass: float) -> float:
            index = min(
                int(np.searchsorted(cumulative, float(mass))),
                len(order) - 1,
            )
            return float(distances[order[index]])

        core_radius80 = weighted_radius(0.80)
        radius95 = weighted_radius(0.95)
        ess_ratio = float(self.effective_sample_size()) / max(float(len(live)), 1.0)
        measurement_information = float(
            np.clip(
                self.last_weight_diagnostics.get("information_score", 0.65),
                0.0,
                1.0,
            )
        )
        global_ambiguity = float(
            np.clip((radius95 - core_radius80) / 4.0, 0.0, 1.0)
        )
        spatial_score = math.exp(-core_radius80 / 1.75)
        measurement_score = 0.55 + 0.45 * measurement_information
        degeneracy_score = float(np.clip(ess_ratio / 0.10, 0.0, 1.0))
        ambiguity_score = 1.0 - 0.35 * global_ambiguity
        score = float(
            np.clip(
                spatial_score
                * measurement_score
                * degeneracy_score
                * ambiguity_score,
                0.0,
                1.0,
            )
        )
        if score >= 0.62 and core_radius80 <= 0.85:
            level = "high"
        elif score >= 0.32 and core_radius80 <= 1.75:
            level = "medium"
        else:
            level = "low"
        return {
            "radius95_m": radius95,
            "core_radius80_m": core_radius80,
            "sigma_major_m": sigma_major,
            "sigma_minor_m": sigma_minor,
            "ess_ratio": ess_ratio,
            "measurement_information": measurement_information,
            "global_ambiguity": global_ambiguity,
            "score": score,
            "level": level,
        }

    def expand_search(
        self,
        *,
        inject_ratio: float = 0.25,
        noise_scale: float = 0.45,
    ) -> None:
        """Broaden the next posterior without changing the current output."""
        self.systematic_resample(
            target_count=len(self.particles),
            inject_ratio=inject_ratio,
            noise_scale=noise_scale,
        )

    def reinitialize_for_recovery(
        self,
        *,
        anchor_xy,
        pdr_hint_xy=None,
        heading_angle: float | None = None,
    ) -> None:
        """Rebuild a mixed local/PDR/global cloud after persistent loss."""
        target_count = int(
            np.clip(len(self.particles), self.min_particles, self.max_particles)
        )
        anchor = np.asarray(anchor_xy, dtype=float).reshape(-1)
        if anchor.size < 2 or not np.all(np.isfinite(anchor[:2])):
            anchor = np.asarray((self.x0, self.y0), dtype=float)
        pdr_hint = np.asarray(
            anchor[:2] if pdr_hint_xy is None else pdr_hint_xy,
            dtype=float,
        ).reshape(-1)
        if pdr_hint.size < 2 or not np.all(np.isfinite(pdr_hint[:2])):
            pdr_hint = anchor[:2]
        heading = (
            float(self.last_motion_heading or 0.0)
            if heading_angle is None
            else float(heading_angle)
        )
        local_count = int(round(target_count * 0.65))
        pdr_count = int(round(target_count * 0.25))
        global_count = target_count - local_count - pdr_count
        particles = []

        def append_cloud(count, center, std):
            for _ in range(max(0, int(count))):
                x, y = self.clamp_to_strict_map(
                    float(center[0] + self.rng.normal(0.0, std)),
                    float(center[1] + self.rng.normal(0.0, std)),
                )
                particles.append(
                    Particle(
                        x=x,
                        y=y,
                        theta=float(
                            ((heading + self.rng.normal(0.0, 0.45) + math.pi)
                             % (2.0 * math.pi))
                            - math.pi
                        ),
                        weight=1.0 / target_count,
                        step_scale=float(
                            np.clip(1.0, self.min_step_scale, self.max_step_scale)
                        ),
                    )
                )

        append_cloud(local_count, anchor[:2], 1.10)
        append_cloud(pdr_count, pdr_hint[:2], 1.60)
        for _ in range(max(0, global_count)):
            x, y = self._random_in_strict_map()
            particles.append(
                Particle(
                    x=x,
                    y=y,
                    theta=float(self.rng.uniform(-math.pi, math.pi)),
                    weight=1.0 / target_count,
                )
            )
        self.particles = particles
        self.n_particles = len(particles)
        self._normalize_weights()
        self.estimate = self._estimate_xy()

    def reinitialize_at_anchor(
        self,
        anchor_xy,
        *,
        heading_angle: float | None = None,
        position_std: float = 0.20,
    ) -> None:
        """Reset tightly around a caller-supplied trusted start anchor."""
        anchor = np.asarray(anchor_xy, dtype=float).reshape(-1)
        if anchor.size < 2 or not np.all(np.isfinite(anchor[:2])):
            raise ValueError("A finite two-dimensional anchor is required.")
        target_count = int(
            np.clip(len(self.particles), self.min_particles, self.max_particles)
        )
        heading = float(heading_angle or 0.0)
        particles = []
        for _ in range(target_count):
            x, y = self.clamp_to_strict_map(
                float(anchor[0] + self.rng.normal(0.0, position_std)),
                float(anchor[1] + self.rng.normal(0.0, position_std)),
            )
            particles.append(
                Particle(
                    x=x,
                    y=y,
                    theta=float(
                        ((heading + self.rng.normal(0.0, 0.08) + math.pi)
                         % (2.0 * math.pi))
                        - math.pi
                    ),
                    weight=1.0 / target_count,
                    step_scale=1.0,
                )
            )
        self.particles = particles
        self.n_particles = len(particles)
        self._normalize_weights()
        self.estimate = self._estimate_xy()

    def mean_particle_heading(self) -> float:
        """Return the weighted circular mean of live particle headings."""
        live = [p for p in self.particles if getattr(p, "alive", True)]
        if not live:
            return float(self.last_motion_heading or 0.0)
        weights = np.asarray(
            [max(float(p.weight), 0.0) for p in live], dtype=float
        )
        total = float(np.sum(weights))
        weights = (
            np.full(len(live), 1.0 / len(live))
            if total <= 1e-12
            else weights / total
        )
        sine = float(
            np.sum(weights * np.sin([float(p.theta) for p in live]))
        )
        cosine = float(
            np.sum(weights * np.cos([float(p.theta) for p in live]))
        )
        return float(math.atan2(sine, cosine))

    def reinitialize_global_heading(
        self,
        anchor_xy=None,
        *,
        secondary_anchor_xy=None,
        heading_hypotheses=None,
        local_ratio: float = 0.90,
        secondary_ratio: float = 0.10,
        local_position_std: float = 0.50,
    ) -> None:
        """Create position/heading hypotheses after gyro corruption.

        A position saved before the suspicious yaw window is preferred when
        available. Heading stays fully multi-modal because the absolute gyro
        yaw can no longer be trusted.
        """
        target_count = int(
            np.clip(len(self.particles), self.min_particles, self.max_particles)
        )
        anchor = None
        if anchor_xy is not None:
            candidate = np.asarray(anchor_xy, dtype=float).reshape(-1)
            if candidate.size >= 2 and np.all(np.isfinite(candidate[:2])):
                anchor = candidate[:2]
        secondary_anchor = None
        if secondary_anchor_xy is not None:
            candidate = np.asarray(secondary_anchor_xy, dtype=float).reshape(-1)
            if candidate.size >= 2 and np.all(np.isfinite(candidate[:2])):
                secondary_anchor = candidate[:2]
        headings = np.asarray(
            [] if heading_hypotheses is None else heading_hypotheses,
            dtype=float,
        ).reshape(-1)

        def draw_heading():
            if headings.size:
                base = float(headings[len(particles) % headings.size])
                return float(
                    ((base + self.rng.normal(0.0, 0.12) + math.pi)
                     % (2.0 * math.pi))
                    - math.pi
                )
            return float(self.rng.uniform(-math.pi, math.pi))

        local_count = (
            0
            if anchor is None
            else int(round(target_count * float(np.clip(local_ratio, 0.0, 1.0))))
        )
        secondary_count = (
            0
            if secondary_anchor is None
            else int(
                round(
                    target_count
                    * float(np.clip(secondary_ratio, 0.0, 1.0))
                )
            )
        )
        secondary_count = min(secondary_count, target_count - local_count)
        particles = []
        for _ in range(local_count):
            x, y = self.clamp_to_strict_map(
                float(anchor[0] + self.rng.normal(0.0, local_position_std)),
                float(anchor[1] + self.rng.normal(0.0, local_position_std)),
            )
            particles.append(
                Particle(
                    x=x,
                    y=y,
                    theta=draw_heading(),
                    weight=1.0 / target_count,
                    step_scale=1.0,
                    heading_bias=0.0,
                )
            )
        for _ in range(secondary_count):
            x, y = self.clamp_to_strict_map(
                float(
                    secondary_anchor[0]
                    + self.rng.normal(0.0, local_position_std)
                ),
                float(
                    secondary_anchor[1]
                    + self.rng.normal(0.0, local_position_std)
                ),
            )
            particles.append(
                Particle(
                    x=x,
                    y=y,
                    theta=draw_heading(),
                    weight=1.0 / target_count,
                    step_scale=1.0,
                    heading_bias=0.0,
                )
            )
        for _ in range(target_count - local_count - secondary_count):
            x, y = self._random_in_strict_map()
            particles.append(
                Particle(
                    x=x,
                    y=y,
                    theta=draw_heading(),
                    weight=1.0 / target_count,
                    step_scale=1.0,
                    heading_bias=0.0,
                )
            )
        self.particles = particles
        self.n_particles = len(self.particles)
        self.heading_recovery_mode = True
        self.last_motion_heading = None
        self._normalize_weights()
        self.estimate = self._estimate_xy()

    def map_magnitude(self, x: float, y: float, k: int | None = None) -> float:
        if self.map_points is None:
            return 0.0
        if not self.in_strict_map_bounds(x, y):
            return float("nan")
        if self.grid_interpolator is not None:
            spec = self.grid_interpolator
            grid = spec["grid"]
            rows, cols = grid.shape
            col = (float(x) - spec["origin_x"] - spec["offset_x"]) / spec["spacing_x"]
            row_from_bottom = (float(y) - spec["origin_y"] - spec["offset_y"]) / spec["spacing_y"]
            row = (rows - 1.0 - row_from_bottom) if spec["flip_y"] else row_from_bottom
            col = float(np.clip(col, 0.0, cols - 1.0))
            row = float(np.clip(row, 0.0, rows - 1.0))
            c0, r0 = int(math.floor(col)), int(math.floor(row))
            c1, r1 = min(c0 + 1, cols - 1), min(r0 + 1, rows - 1)
            tx, ty = col - c0, row - r0
            values = np.asarray(
                [grid[r0, c0], grid[r0, c1], grid[r1, c0], grid[r1, c1]],
                dtype=float,
            )
            if np.all(np.isfinite(values)):
                top = (1.0 - tx) * values[0] + tx * values[1]
                bottom = (1.0 - tx) * values[2] + tx * values[3]
                return float((1.0 - ty) * top + ty * bottom)

        px = self.map_points["x"]
        py = self.map_points["y"]
        pz = self.map_points["z"]
        if px.size == 0:
            return 0.0
        dx = px - float(x)
        dy = py - float(y)
        dist2 = dx * dx + dy * dy
        kk_raw = self.map_knn_k if k is None else int(k)
        kk = max(1, min(int(kk_raw), dist2.size))
        idx = np.argpartition(dist2, kk - 1)[:kk]
        d = np.sqrt(dist2[idx]) + 1e-6
        w = 1.0 / (d ** self.map_idw_power)
        return float(np.sum(w * pz[idx]) / np.sum(w))

    def map_vector(self, x: float, y: float) -> npt.NDArray[np.float64]:
        """Bilinearly interpolate the optional survey-phone-frame vector map."""
        if (
            self.vector_grid_interpolator is None
            or not self.in_strict_map_bounds(x, y)
        ):
            return np.full(3, np.nan, dtype=float)
        spec = self.vector_grid_interpolator
        grid = spec["grid"]
        rows, cols = grid.shape[:2]
        col = (
            float(x) - spec["origin_x"] - spec["offset_x"]
        ) / spec["spacing_x"]
        row_from_bottom = (
            float(y) - spec["origin_y"] - spec["offset_y"]
        ) / spec["spacing_y"]
        row = (
            rows - 1.0 - row_from_bottom
            if spec["flip_y"]
            else row_from_bottom
        )
        col = float(np.clip(col, 0.0, cols - 1.0))
        row = float(np.clip(row, 0.0, rows - 1.0))
        c0, r0 = int(math.floor(col)), int(math.floor(row))
        c1, r1 = min(c0 + 1, cols - 1), min(r0 + 1, rows - 1)
        tx, ty = col - c0, row - r0
        values = np.asarray(
            [
                grid[r0, c0],
                grid[r0, c1],
                grid[r1, c0],
                grid[r1, c1],
            ],
            dtype=float,
        )
        if not np.all(np.isfinite(values)):
            return np.full(3, np.nan, dtype=float)
        top = (1.0 - tx) * values[0] + tx * values[1]
        bottom = (1.0 - tx) * values[2] + tx * values[3]
        return np.asarray((1.0 - ty) * top + ty * bottom, dtype=float)

    def adapt_particle_count_kld(self, epsilon: float = 0.12, z: float = 1.96, bin_size_xy: float = 0.8, bin_size_theta: float = 0.35) -> int:
        if not self.particles:
            return self.min_particles
        bins = set()
        for p in self.particles:
            if not getattr(p, "alive", True):
                continue
            bx = int(math.floor(p.x / float(bin_size_xy)))
            by = int(math.floor(p.y / float(bin_size_xy)))
            bt = int(math.floor((p.theta + math.pi) / float(bin_size_theta)))
            bins.add((bx, by, bt))
        k = len(bins)
        if k <= 1:
            return self.min_particles
        n = (k - 1) / (2.0 * float(epsilon))
        t = 1.0 - 2.0 / (9.0 * (k - 1)) + float(z) * math.sqrt(2.0 / (9.0 * (k - 1)))
        n = int(math.ceil(n * (t ** 3)))
        return int(np.clip(n, self.min_particles, self.max_particles))

    def systematic_resample(self, target_count: int | None = None,
                            inject_ratio: float = 0.05, noise_scale: float = 0.15) -> None:
        """Systematic resampling with diversity injection.

        Preserves high-weight particles through stratified sampling, then
        injects a small fraction of random particles to maintain diversity.
        """
        if not self.particles:
            self.particles = self._spawn_particles(self.min_particles)
            return
        self._normalize_weights()
        live = [p for p in self.particles if getattr(p, "alive", True) and p.weight > 0.0]
        if not live:
            center = getattr(self, "estimate", (self.x0, self.y0))
            self.particles = self._spawn_particles(self.min_particles, center=center)
            self._normalize_weights()
            return

        n_live = len(live)
        if target_count is None:
            target_count = n_live
        target_count = int(np.clip(target_count, self.min_particles, self.max_particles))
        ratio = float(np.clip(inject_ratio, 0.0, 1.0))
        n_inject = int(round(target_count * ratio))
        n_copy = target_count - n_inject

        weights = np.asarray([p.weight for p in live], dtype=float)
        weights /= weights.sum()
        cumsum = np.cumsum(weights)
        cumsum[-1] = 1.0

        new_particles = []
        if n_copy:
            u0 = float(self.rng.uniform(0.0, 1.0 / n_copy))
            for i in range(n_copy):
                u = u0 + float(i) / n_copy
                idx = int(np.searchsorted(cumsum, u))
                idx = min(idx, n_live - 1)
                base = live[idx]
                nx, ny = self.clamp_to_strict_map(
                    float(base.x + self.rng.normal(0.0, noise_scale)),
                    float(base.y + self.rng.normal(0.0, noise_scale)),
                )
                new_particles.append(Particle(
                    x=nx,
                    y=ny,
                    theta=float(((base.theta + self.rng.normal(0.0, 0.08) + math.pi)
                                 % (2.0 * math.pi)) - math.pi),
                    weight=1.0 / target_count,
                    mag_hist=list(base.mag_hist[-64:]),
                    step_scale=float(
                        np.clip(base.step_scale, self.min_step_scale, self.max_step_scale)
                    ),
                    heading_bias=float(base.heading_bias),
                ))

        for _ in range(n_inject):
            nx, ny = self._random_in_strict_map()
            new_particles.append(Particle(
                x=nx, y=ny,
                theta=float(self.rng.uniform(-math.pi, math.pi)),
                weight=1.0 / target_count,
                step_scale=float(
                    np.clip(
                        1.0
                        + (
                            self.calibration_rng.normal(
                                0.0, self.init_step_scale_std
                            )
                            if self.init_step_scale_std > 0.0
                            else 0.0
                        ),
                        self.min_step_scale,
                        self.max_step_scale,
                    )
                ),
                heading_bias=float(
                    (((self.calibration_rng.normal(0.0, self.init_heading_bias_std)
                       if self.init_heading_bias_std > 0.0 else 0.0) + math.pi)
                     % (2.0 * math.pi))
                    - math.pi
                ),
            ))

        self.particles = new_particles
        self.n_particles = len(self.particles)
        self._normalize_weights()

    def cso_resample(self, target_count: int | None = None) -> None:
        if not self.particles:
            self.particles = self._spawn_particles(self.min_particles)
            return
        self._normalize_weights()
        particles = sorted(
            [p for p in self.particles if getattr(p, "alive", True) and p.weight > 0.0],
            key=lambda p: p.weight,
            reverse=True,
        )
        if not particles:
            center = getattr(self, "estimate", (self.x0, self.y0))
            self.particles = self._spawn_particles(self.min_particles, center=center)
            self.n_particles = len(self.particles)
            self._normalize_weights()
            return
        n = len(particles)
        if target_count is None:
            target_count = n
        target_count = int(np.clip(target_count, self.min_particles, self.max_particles))

        n_rooster = max(1, int(0.2 * n))
        n_hen = max(1, int(0.5 * n))
        roosters = particles[:n_rooster]
        hens = particles[n_rooster : n_rooster + n_hen]
        chicks = particles[n_rooster + n_hen :]

        gbest = roosters[0]
        new_particles = []
        attempts = 0
        max_attempts = max(100, target_count * 20)
        while len(new_particles) < target_count and attempts < max_attempts:
            attempts += 1
            role_r = float(self.rng.random())
            if role_r < 0.25 and roosters:
                base = roosters[int(self.rng.integers(0, len(roosters)))]
                history_seed = list(base.mag_hist)
                scale_seed = float(base.step_scale)
                bias_seed = float(base.heading_bias)
                nx = base.x + float(self.rng.normal(0.0, 0.35))
                ny = base.y + float(self.rng.normal(0.0, 0.35))
                nt = base.theta + float(self.rng.normal(0.0, 0.08))
            elif role_r < 0.75 and hens and roosters:
                h = hens[int(self.rng.integers(0, len(hens)))]
                r = roosters[int(self.rng.integers(0, len(roosters)))]
                history_seed = list(h.mag_hist)
                scale_seed = float(h.step_scale)
                bias_seed = float(h.heading_bias)
                nx = h.x + 0.6 * (r.x - h.x) + 0.2 * (gbest.x - h.x) + float(self.rng.normal(0.0, 0.25))
                ny = h.y + 0.6 * (r.y - h.y) + 0.2 * (gbest.y - h.y) + float(self.rng.normal(0.0, 0.25))
                nt = h.theta + 0.3 * (r.theta - h.theta) + float(self.rng.normal(0.0, 0.06))
            else:
                leader = hens[int(self.rng.integers(0, len(hens)))] if hens else gbest
                c = chicks[int(self.rng.integers(0, len(chicks)))] if chicks else leader
                history_seed = list(c.mag_hist)
                scale_seed = float(c.step_scale)
                bias_seed = float(c.heading_bias)
                nx = c.x + 0.8 * (leader.x - c.x) + float(self.rng.normal(0.0, 0.3))
                ny = c.y + 0.8 * (leader.y - c.y) + float(self.rng.normal(0.0, 0.3))
                nt = c.theta + 0.6 * (leader.theta - c.theta) + float(self.rng.normal(0.0, 0.08))

            if not self.in_strict_map_bounds(nx, ny):
                continue

            new_particles.append(
                Particle(
                    x=float(nx),
                    y=float(ny),
                    theta=float(((nt + math.pi) % (2.0 * math.pi)) - math.pi),
                    weight=1.0 / target_count,
                    mag_hist=history_seed[-64:],
                    step_scale=float(
                        np.clip(scale_seed, self.min_step_scale, self.max_step_scale)
                    ),
                    heading_bias=float(bias_seed),
                )
            )
        while len(new_particles) < target_count:
            nx, ny = self._random_in_strict_map()
            new_particles.append(
                Particle(
                    x=float(nx),
                    y=float(ny),
                    theta=float(self.rng.uniform(-math.pi, math.pi)),
                    weight=1.0 / target_count,
                    step_scale=float(
                        np.clip(
                            1.0
                            + (
                                self.calibration_rng.normal(
                                    0.0, self.init_step_scale_std
                                )
                                if self.init_step_scale_std > 0.0
                                else 0.0
                            ),
                            self.min_step_scale,
                            self.max_step_scale,
                        )
                    ),
                    heading_bias=float(
                        (((self.calibration_rng.normal(0.0, self.init_heading_bias_std)
                           if self.init_heading_bias_std > 0.0 else 0.0) + math.pi)
                         % (2.0 * math.pi))
                        - math.pi
                    ),
                )
            )
        self.particles = new_particles
        self.n_particles = len(self.particles)
        self._normalize_weights()


# Backward-compatible alias to keep naming close to prior script.
PF_State = PFState
