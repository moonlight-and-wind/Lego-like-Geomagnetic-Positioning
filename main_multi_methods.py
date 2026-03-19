import argparse
import json
import math
from pathlib import Path

import numpy as np

from Geomag import (
    Initializer,
    PFConfig,
    PDRConfig,
    build_pdr_from_config,
    build_pf_from_config,
)
from Geomag.algorithms import get_sensor, get_test_len, get_true_route
from Geomag.models import PFState, Particle
from Geomag.pipeline import GeomagPipeline, ParticleSizeStage, PredictStage, ResampleDecisionStage, UpdateStage


def build_main_configs():
    pdr_config = PDRConfig(
        step_judge="peak_dynamic",
        step_judge_params={
            "peak_sigma": 0.4,
            "peak_prominence": 0.2,
            "min_samples_per_step": 4.5,
        },
        step_length="weinberg",
        step_length_params={"weinberg_k": 0.45},
        heading="gyro",
        heading_params={"dt": 0.01},
        mag="norm_mean",
    )
    pf_config = PFConfig(
        state_params={
            "num_particles": 5000,
            "min_particles": 2000,
            "max_particles": 10000000000000,
        },
        motion="gaussian",
        motion_params={"heading_noise_std": 0.01, "step_noise_std": 0.01},
        weight="ddtw",
        weight_params={"sigma": 0.1, "max_hist": 100},
        particle_size="kld",
        particle_size_params={"epsilon": 0.10, "bin_size_xy": 0.5, "bin_size_theta": 0.35},
        resample_trigger="ess_or_target",
        resample_trigger_params={"ess_ratio_threshold": 0.40},
        resample="cso",
    )
    return pdr_config, pf_config


def build_main_context():
    return Initializer(
        num_runs=1,
        window_size=400,
        route_source="uji",
        sensor_source="uji",
        uji_test_file="tt02.txt",
    ).create_context()


def wrap_pi(rad):
    return float(((float(rad) + math.pi) % (2.0 * math.pi)) - math.pi)


def kalman_step(state_xy, cov_xy, delta_xy, meas_xy, process_var=0.16, meas_var=0.36):
    x_pred = np.asarray(state_xy, dtype=float) + np.asarray(delta_xy, dtype=float)
    p_pred = np.asarray(cov_xy, dtype=float) + np.eye(2, dtype=float) * float(process_var)

    z = np.asarray(meas_xy, dtype=float).reshape(2)
    s = p_pred + np.eye(2, dtype=float) * float(meas_var)
    k = np.linalg.solve(s.T, p_pred.T).T
    x_upd = x_pred + k @ (z - x_pred)
    p_upd = (np.eye(2, dtype=float) - k) @ p_pred
    return x_upd, p_upd


def ekf_step(state_xyz, cov_xyz, step_len, heading_angle, meas_xy):
    x, y, _ = np.asarray(state_xyz, dtype=float).reshape(3)
    theta = wrap_pi(heading_angle)
    c = math.cos(theta)
    s = math.sin(theta)

    x_pred = float(x + step_len * c)
    y_pred = float(y + step_len * s)
    state_pred = np.asarray([x_pred, y_pred, theta], dtype=float)

    f = np.asarray(
        [
            [1.0, 0.0, -step_len * s],
            [0.0, 1.0, step_len * c],
            [0.0, 0.0, 1.0],
        ],
        dtype=float,
    )
    q = np.diag([0.16, 0.16, 0.03**2]).astype(float)
    p_pred = f @ np.asarray(cov_xyz, dtype=float) @ f.T + q

    h = np.asarray([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], dtype=float)
    r = np.diag([0.36, 0.36]).astype(float)
    z = np.asarray(meas_xy, dtype=float).reshape(2)
    y_residual = z - (h @ state_pred)
    s_mat = h @ p_pred @ h.T + r
    k = np.linalg.solve(s_mat.T, (p_pred @ h.T).T).T
    state_upd = state_pred + k @ y_residual
    p_upd = (np.eye(3, dtype=float) - k @ h) @ p_pred
    state_upd[2] = wrap_pi(state_upd[2])
    return state_upd, p_upd


def raw_dtw_distance(a, b, window_ratio=0.25):
    a = np.asarray(a, dtype=float).reshape(-1)
    b = np.asarray(b, dtype=float).reshape(-1)
    if a.size == 0 or b.size == 0:
        return 0.0

    n, m = int(a.size), int(b.size)
    window = max(abs(n - m), int(max(n, m) * float(window_ratio)), 4)
    dp = np.full((n + 1, m + 1), np.inf, dtype=float)
    dp[0, 0] = 0.0
    for i in range(1, n + 1):
        ai = float(a[i - 1])
        j0 = max(1, i - window)
        j1 = min(m, i + window)
        for j in range(j0, j1 + 1):
            cost = abs(ai - float(b[j - 1]))
            dp[i, j] = cost + min(dp[i - 1, j], dp[i, j - 1], dp[i - 1, j - 1])
    return float(dp[n, m] / max(1, n + m))


def _normalize_particle_weights(particles):
    total = float(sum(max(float(p.weight), 0.0) for p in particles))
    if total <= 1e-12:
        w = 1.0 / max(len(particles), 1)
        for p in particles:
            p.weight = float(w)
        return
    inv_total = 1.0 / total
    for p in particles:
        p.weight = float(max(float(p.weight), 0.0) * inv_total)


def _systematic_resample_indices(weights, rng, n_samples=None):
    w = np.asarray(weights, dtype=float).reshape(-1)
    src_n = int(w.size)
    if src_n == 0:
        return np.asarray([], dtype=int)
    w = np.clip(w, a_min=0.0, a_max=None)
    w_sum = float(np.sum(w))
    if w_sum <= 1e-12:
        w = np.full(src_n, 1.0 / src_n, dtype=float)
    else:
        w = w / w_sum
    out_n = src_n if n_samples is None else max(1, int(n_samples))
    cdf = np.cumsum(w)
    cdf[-1] = 1.0
    u0 = float(rng.random()) / out_n
    us = u0 + (np.arange(out_n, dtype=float) / out_n)
    return np.searchsorted(cdf, us, side="left")


def simple_resample_pf_state(pf_state, target_count=None, hist_keep=64):
    if not pf_state.particles:
        pf_state.particles = pf_state._spawn_particles(pf_state.min_particles)
        pf_state.n_particles = len(pf_state.particles)
        pf_state._normalize_weights()
        return

    pf_state._normalize_weights()
    curr_n = len(pf_state.particles)
    if target_count is None:
        target_count = curr_n
    target_count = int(np.clip(int(target_count), pf_state.min_particles, pf_state.max_particles))

    ws = [float(p.weight) for p in pf_state.particles]
    idx = _systematic_resample_indices(ws, pf_state.rng, n_samples=target_count)
    if idx.size == 0:
        return

    keep = max(1, int(hist_keep))
    unif_w = 1.0 / len(idx)
    src_particles = pf_state.particles
    new_particles = []
    for i in idx:
        src = src_particles[int(i)]
        new_particles.append(
            Particle(
                x=float(src.x),
                y=float(src.y),
                theta=float(src.theta),
                weight=float(unif_w),
                mag_hist=list(src.mag_hist[-keep:]),
            )
        )

    pf_state.particles = new_particles
    pf_state.n_particles = len(new_particles)
    pf_state._normalize_weights()


class MagicolClassicTracker:
    # Magnetic-only Magicol-style APF baseline:
    # map-constrained particle motion + DTW magnetic-sequence weighting + importance resampling.
    def __init__(
        self,
        start_xy,
        map_proxy,
        num_particles=5000,
        heading_noise_std=0.01,
        step_noise_std=0.01,
        sigma=0.1,
        max_hist=100,
    ):
        self.map_proxy = map_proxy
        self.rng = np.random.default_rng(20260315)
        self.num_particles = max(100, int(num_particles))
        self.heading_noise_std = max(float(heading_noise_std), math.radians(10.0))
        self.base_step_noise_std = float(step_noise_std)
        self.sigma = max(1e-6, float(sigma))
        self.max_hist = max(4, int(max_hist))

        x0, y0 = float(start_xy[0]), float(start_xy[1])
        self.particles = []
        for _ in range(self.num_particles):
            px = float(x0 + self.rng.normal(0.0, 0.8))
            py = float(y0 + self.rng.normal(0.0, 0.8))
            px, py = self.map_proxy.clamp_to_map(px, py)
            self.particles.append(
                Particle(
                    x=float(px),
                    y=float(py),
                    theta=float(self.rng.uniform(-math.pi, math.pi)),
                    weight=1.0 / self.num_particles,
                    mag_hist=[],
                )
            )

    def _estimate_xy(self):
        _normalize_particle_weights(self.particles)
        particles_sorted = sorted(self.particles, key=lambda p: float(p.weight), reverse=True)
        keep_n = max(1, int(0.5 * len(particles_sorted)))
        top = particles_sorted[:keep_n]
        ws = np.asarray([float(p.weight) for p in top], dtype=float)
        ws_sum = float(np.sum(ws))
        if ws_sum <= 1e-12:
            ws = np.full(keep_n, 1.0 / keep_n, dtype=float)
        else:
            ws = ws / ws_sum
        xs = np.asarray([float(p.x) for p in top], dtype=float)
        ys = np.asarray([float(p.y) for p in top], dtype=float)
        return float(np.sum(xs * ws)), float(np.sum(ys * ws))

    def _resample(self):
        _normalize_particle_weights(self.particles)
        ws = [float(p.weight) for p in self.particles]
        idx = _systematic_resample_indices(ws, self.rng)
        if idx.size == 0:
            return
        new_particles = []
        unif_w = 1.0 / len(idx)
        for i in idx:
            src = self.particles[int(i)]
            new_particles.append(
                Particle(
                    x=float(src.x),
                    y=float(src.y),
                    theta=float(src.theta),
                    weight=float(unif_w),
                    mag_hist=list(src.mag_hist[-self.max_hist:]),
                )
            )
        self.particles = new_particles

    def step(self, step_len, heading_angle, geomag_seq):
        obs = np.asarray(list(geomag_seq), dtype=float).reshape(-1)
        step_sigma = max(self.base_step_noise_std, 0.2 * max(float(step_len), 1e-6))
        for p in self.particles:
            theta = wrap_pi(float(heading_angle) + float(self.rng.normal(0.0, self.heading_noise_std)))
            dist = max(0.0, float(step_len) + float(self.rng.normal(0.0, step_sigma)))
            nx = float(p.x + dist * math.cos(theta))
            ny = float(p.y + dist * math.sin(theta))
            cx, cy = self.map_proxy.clamp_to_map(nx, ny)
            hit_wall = (abs(cx - nx) > 1e-9) or (abs(cy - ny) > 1e-9)

            p.x, p.y, p.theta = float(cx), float(cy), float(theta)
            pred_mag = float(self.map_proxy.map_magnitude(p.x, p.y))
            p.mag_hist.append(pred_mag)

            hist_len = int(max(1, min(len(p.mag_hist), len(obs), self.max_hist)))
            pred_seq = np.asarray(p.mag_hist[-hist_len:], dtype=float)
            obs_seq = obs[-hist_len:] if obs.size else np.asarray([pred_mag], dtype=float)
            d = raw_dtw_distance(obs_seq, pred_seq, window_ratio=0.25)
            w = math.exp(-((d * d) / (2.0 * self.sigma * self.sigma + 1e-12)))
            if hit_wall:
                w *= 0.01
            p.weight = float(max(1e-12, float(p.weight) * w))

        est = self._estimate_xy()
        self._resample()
        return est


def summarize_method_errors(tracks, route, geomag_map):
    route_x, route_y = GeomagPipeline._route_to_xy_for_error(route, geomag_map)
    summaries = {}
    for name, track in tracks.items():
        if route_x is None or route_y is None:
            series = None
            stats = None
        else:
            series = GeomagPipeline._compute_error_series(track, route_x, route_y)
            stats = GeomagPipeline._summarize_error(series)
        summaries[name] = {
            "error_series": None if series is None else np.asarray(series, dtype=float).tolist(),
            "error_stats": stats,
        }
    return summaries


def print_summary_table(summaries):
    print("\nMethod error summary [m]")
    print(f"{'method':<18} {'mean':>9} {'median':>9} {'p95':>9} {'final':>9}")
    print("-" * 58)

    def _sort_key(item):
        stats = item[1].get("error_stats")
        if not stats:
            return float("inf")
        return float(stats.get("final", float("inf")))

    for name, payload in sorted(summaries.items(), key=_sort_key):
        stats = payload.get("error_stats")
        if not stats:
            print(f"{name:<18} {'n/a':>9} {'n/a':>9} {'n/a':>9} {'n/a':>9}")
            continue
        print(
            f"{name:<18} "
            f"{float(stats['mean']):9.3f} "
            f"{float(stats['median']):9.3f} "
            f"{float(stats['p95']):9.3f} "
            f"{float(stats['final']):9.3f}"
        )


def plot_comparison(tracks, summaries, route, geomag_map, output_png, show=False):
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise ImportError("matplotlib is required for plotting. Install it with: pip install matplotlib") from exc

    route_x, route_y = GeomagPipeline._route_to_xy_for_error(route, geomag_map)
    fig, axes = plt.subplots(1, 2, figsize=(13, 5.6), dpi=130)
    ax_traj, ax_err = axes

    if route_x is not None and route_y is not None:
        ax_traj.plot(route_x, route_y, color="black", linewidth=2.0, label="true_route")

    for name, track in tracks.items():
        arr = np.asarray(track, dtype=float)
        if arr.ndim != 2 or arr.shape[1] < 2 or arr.shape[0] == 0:
            continue
        ax_traj.plot(arr[:, 0], arr[:, 1], linewidth=1.5, label=name)
        ax_traj.scatter([arr[0, 0]], [arr[0, 1]], s=10)
    ax_traj.set_title("Trajectory Comparison")
    ax_traj.set_xlabel("X (m)")
    ax_traj.set_ylabel("Y (m)")
    ax_traj.grid(True, alpha=0.25)
    ax_traj.legend(loc="best", fontsize=8)
    ax_traj.axis("equal")

    for name, payload in summaries.items():
        series = payload.get("error_series")
        if not series:
            continue
        err = np.asarray(series, dtype=float).reshape(-1)
        if err.size == 0:
            continue
        ax_err.plot(np.arange(err.size), err, linewidth=1.7, label=name)
    ax_err.set_title("Error Series Comparison")
    ax_err.set_xlabel("Step Index")
    ax_err.set_ylabel("Euclidean Error (m)")
    ax_err.grid(True, alpha=0.25)
    ax_err.legend(loc="best", fontsize=8)

    fig.tight_layout()
    out_path = Path(output_png)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, bbox_inches="tight")
    if show:
        plt.show()
    plt.close(fig)
    return str(out_path)


def run_comparison(
    show=False,
    max_frames=None,
    output_json="results/multi_method_comparison_tt02.json",
    output_png="results/multi_method_comparison_tt02.png",
):
    context = build_main_context()
    pdr_config, pf_config = build_main_configs()
    pdr_module = build_pdr_from_config(pdr_config)
    pf_module = build_pf_from_config(pf_config)
    pf_simple_predict = PredictStage(motion=pf_config.motion, motion_kwargs=pf_config.motion_params)
    pf_simple_update = UpdateStage(weight=pf_config.weight, weight_kwargs=pf_config.weight_params)
    pf_simple_particle_size = ParticleSizeStage(
        particle_size=pf_config.particle_size,
        particle_size_kwargs=pf_config.particle_size_params,
    )
    pf_simple_resample_decision = ResampleDecisionStage(
        trigger=pf_config.resample_trigger,
        trigger_kwargs=pf_config.resample_trigger_params,
    )

    route = get_true_route(
        source=context.route_source,
        data_root=context.data_root,
        uji_test_file=context.uji_test_file,
        own_data_dir=context.own_data_dir,
    )
    if not route:
        raise ValueError("True route is empty. Cannot run comparison.")

    pf_state = PFState(
        init_pos=route[0],
        mag_map=context.geomag_map,
        **dict(pf_config.state_params or {}),
    )
    pf_state_simple = PFState(
        init_pos=route[0],
        mag_map=context.geomag_map,
        **dict(pf_config.state_params or {}),
    )
    start_xy = tuple(map(float, pf_state.get_pos()))
    start_xy_simple = tuple(map(float, pf_state_simple.get_pos()))

    tracks = {
        "pf_main": [start_xy],
        "pf_simple_resample": [start_xy_simple],
        "kf_fusion": [start_xy],
        "ekf_fusion": [start_xy],
        "magicol_classic": [start_xy],
        "pdr_only": [start_xy],
    }
    particle_counts = [len(pf_state.particles)]
    particle_counts_simple = [len(pf_state_simple.particles)]
    geomag_hist = []
    sample_buffer = []

    kf_state = np.asarray(start_xy, dtype=float)
    kf_cov = np.eye(2, dtype=float) * 0.5
    ekf_state = np.asarray([start_xy[0], start_xy[1], 0.0], dtype=float)
    ekf_cov = np.diag([0.5, 0.5, 0.2]).astype(float)
    magicol_tracker = MagicolClassicTracker(
        start_xy=start_xy,
        map_proxy=pf_state,
        num_particles=int((pf_config.state_params or {}).get("num_particles", 5000)),
        heading_noise_std=float((pf_config.motion_params or {}).get("heading_noise_std", 0.01)),
        step_noise_std=float((pf_config.motion_params or {}).get("step_noise_std", 0.01)),
        sigma=float((pf_config.weight_params or {}).get("sigma", 0.1)),
        max_hist=int((pf_config.weight_params or {}).get("max_hist", 100)),
    )

    test_len = get_test_len(
        source=context.sensor_source,
        data_root=context.data_root,
        uji_test_file=context.uji_test_file,
        own_data_dir=context.own_data_dir,
    )
    if max_frames is not None:
        test_len = min(int(max_frames), int(test_len))

    def _print_progress(current, total, width=36):
        total = max(int(total), 1)
        current = min(max(int(current), 0), total)
        ratio = current / total
        filled = int(width * ratio)
        bar = "#" * filled + "-" * (width - filled)
        print(f"\rProgress [{bar}] {current}/{total} ({ratio * 100:5.1f}%)", end="", flush=True)

    _print_progress(0, test_len)
    for i in range(test_len):
        mag, acc, gyro = get_sensor(
            source=context.sensor_source,
            data_root=context.data_root,
            uji_test_file=context.uji_test_file,
            own_data_dir=context.own_data_dir,
        )
        sample_buffer.append([acc, gyro, mag])

        if not pdr_module.detect_step(sample_buffer):
            _print_progress(i + 1, test_len)
            continue

        step_len = float(pdr_module.estimate_step_len(sample_buffer))
        heading = float(pdr_module.estimate_heading(sample_buffer))
        obs_mag = float(pdr_module.extract_mag())
        geomag_hist.append(obs_mag)
        geomag_window = geomag_hist[-context.window_size :]

        pdr_x, pdr_y = tracks["pdr_only"][-1]
        delta_x = float(step_len * math.cos(heading))
        delta_y = float(step_len * math.sin(heading))
        pdr_pos = (float(pdr_x + delta_x), float(pdr_y + delta_y))
        tracks["pdr_only"].append(pdr_pos)

        pf_pos = pf_module.step(
            pf_state=pf_state,
            step_len=step_len,
            heading_angle=heading,
            geomag_seq=geomag_window,
        )
        pf_xy = (float(pf_pos[0]), float(pf_pos[1]))
        tracks["pf_main"].append(pf_xy)
        particle_counts.append(len(pf_state.particles))

        if getattr(pf_state_simple, "map_points", None) is None:
            pf_simple_xy = tuple(map(float, pf_state_simple.get_pos()))
        else:
            simple_ctx = {
                "pf_state": pf_state_simple,
                "step_len": float(step_len),
                "heading_angle": float(heading),
                "geomag_seq": list(geomag_window),
                "target_n": len(pf_state_simple.particles),
                "should_resample": False,
            }
            pf_simple_predict(simple_ctx)
            pf_simple_update(simple_ctx)
            pf_simple_particle_size(simple_ctx)
            pf_simple_resample_decision(simple_ctx)
            if bool(simple_ctx.get("should_resample", False)):
                simple_resample_pf_state(
                    pf_state_simple,
                    target_count=int(simple_ctx.get("target_n", len(pf_state_simple.particles))),
                )
            pf_simple_xy = tuple(map(float, pf_state_simple.get_pos()))

        tracks["pf_simple_resample"].append(pf_simple_xy)
        particle_counts_simple.append(len(pf_state_simple.particles))

        kf_state, kf_cov = kalman_step(
            state_xy=kf_state,
            cov_xy=kf_cov,
            delta_xy=(delta_x, delta_y),
            meas_xy=pf_xy,
        )
        kfx, kfy = pf_state.clamp_to_map(float(kf_state[0]), float(kf_state[1]))
        kf_state = np.asarray([kfx, kfy], dtype=float)
        tracks["kf_fusion"].append((float(kf_state[0]), float(kf_state[1])))

        ekf_state, ekf_cov = ekf_step(
            state_xyz=ekf_state,
            cov_xyz=ekf_cov,
            step_len=step_len,
            heading_angle=heading,
            meas_xy=pf_xy,
        )
        ekx, eky = pf_state.clamp_to_map(float(ekf_state[0]), float(ekf_state[1]))
        ekf_state[0], ekf_state[1] = ekx, eky
        tracks["ekf_fusion"].append((float(ekf_state[0]), float(ekf_state[1])))

        magicol_xy = magicol_tracker.step(
            step_len=step_len,
            heading_angle=heading,
            geomag_seq=geomag_window,
        )
        tracks["magicol_classic"].append((float(magicol_xy[0]), float(magicol_xy[1])))

        sample_buffer.clear()
        _print_progress(i + 1, test_len)

    print()
    summaries = summarize_method_errors(tracks=tracks, route=route, geomag_map=context.geomag_map)
    print_summary_table(summaries)
    saved_plot = plot_comparison(
        tracks=tracks,
        summaries=summaries,
        route=route,
        geomag_map=context.geomag_map,
        output_png=output_png,
        show=show,
    )

    payload = {
        "config_source": "main.py",
        "context": {
            "window_size": int(context.window_size),
            "route_source": context.route_source,
            "sensor_source": context.sensor_source,
            "uji_test_file": context.uji_test_file,
        },
        "methods": summaries,
        "tracks": {k: [list(map(float, xy)) for xy in v] for k, v in tracks.items()},
        "particle_counts": [int(v) for v in particle_counts],
        "particle_counts_simple_resample": [int(v) for v in particle_counts_simple],
        "show_flag": bool(show),
        "output_png": saved_plot,
    }

    out_path = Path(output_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"Saved comparison output to: {out_path}")
    print(f"Saved comparison plot to: {saved_plot}")
    return payload


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=(
            "Compare PF(main-CSO), PF(simple resample, no CSO), KF, EKF, Magicol(classic APF), "
            "and PDR-only with main.py parameters."
        )
    )
    parser.add_argument("--show", action="store_true", help="Show the generated plot window.")
    parser.add_argument("--max-frames", type=int, default=None, help="Limit frames for a faster debug run.")
    parser.add_argument(
        "--output-json",
        type=str,
        default="results/multi_method_comparison_tt02.json",
        help="Output path for JSON summary.",
    )
    parser.add_argument(
        "--output-png",
        type=str,
        default="results/multi_method_comparison_tt02.png",
        help="Output path for trajectory/error comparison plot.",
    )
    args = parser.parse_args()
    run_comparison(
        show=bool(args.show),
        max_frames=args.max_frames,
        output_json=args.output_json,
        output_png=args.output_png,
    )
