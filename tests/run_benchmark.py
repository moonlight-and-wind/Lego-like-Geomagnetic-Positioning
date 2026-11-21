"""Benchmark PF configs on the valid route1_run2 package capture."""
import json
import time
from pathlib import Path

import numpy as np

from Geomag import PFConfig
from Geomag.branching import BranchConfig, run_own_branch


def mk_pf(sigma, accum_mode, alpha, resample, boundary, heading_noise=0.08, step_noise=0.15):
    return PFConfig(
        state_params={"num_particles": 5000, "min_particles": 2000, "max_particles": 10000},
        motion="gaussian",
        motion_params={"heading_noise_std": heading_noise,
                       "step_noise_std": step_noise,
                       "boundary_handling": boundary},
        weight="ddtw",
        weight_params={"sigma": sigma, "max_hist": 80, "window_ratio": 0.30,
                       "accumulate_mode": accum_mode, "alpha": alpha},
        particle_size="kld",
        particle_size_params={"epsilon": 0.10, "bin_size_xy": 0.5, "bin_size_theta": 0.35},
        resample_trigger="ess_or_target",
        resample_trigger_params={"ess_ratio_threshold": 0.40},
        resample=resample,
        resample_params={"inject_ratio": 0.05, "noise_scale": 0.15} if resample == "systematic" else {},
    )


# All configs use the same valid dataset so the comparison remains controlled.
CONFIGS = [
    # ── Baselines ──
    ("A_baseline_multiply_kill_cso",
     mk_pf(0.5, "multiply", 0.0, "cso", "kill", 0.01, 0.01)),
    ("B_baseline_multiply_kill_sys",
     mk_pf(0.5, "multiply", 0.0, "systematic", "kill", 0.01, 0.01)),

    # ── EMA + clamp (our core) — sweep sigma ──
    ("C_ema_clamp_s03_cso",
     mk_pf(0.3, "average", 0.5, "cso", "clamp")),
    ("D_ema_clamp_s05_cso",
     mk_pf(0.5, "average", 0.5, "cso", "clamp")),
    ("E_ema_clamp_s08_cso",
     mk_pf(0.8, "average", 0.5, "cso", "clamp")),
    ("F_ema_clamp_s12_cso",
     mk_pf(1.2, "average", 0.5, "cso", "clamp")),
    ("G_ema_clamp_s20_cso",
     mk_pf(2.0, "average", 0.5, "cso", "clamp")),

    # ── EMA + clamp + systematic ──
    ("H_ema_clamp_s05_sys",
     mk_pf(0.5, "average", 0.5, "systematic", "clamp")),
    ("I_ema_clamp_s08_sys",
     mk_pf(0.8, "average", 0.5, "systematic", "clamp")),
]


def main():
    print(f"{'#':<3s} {'Label':<30s} {'σ':>5s} {'Accum':<10s} {'Bound':<6s} {'Rsmp':<8s} {'PF_mean':>8s} {'PF_med':>8s} {'PF_p95':>8s} {'PF_final':>8s}  Time")
    print("-" * 112)

    results = []
    for i, (label, pf_config) in enumerate(CONFIGS):
        t0 = time.time()

        cfg = BranchConfig(branch="own",
                          own_profile="package",
                          own_dataset_key="route1_run2",
                          own_data_dir="data/own_data_package/route1_run2",
                          show=False)

        import Geomag.branching as br
        original = br.build_own_configs

        def patched(profile="package"):
            pdr, _ = original(profile)
            return pdr, pf_config
        br.build_own_configs = patched

        try:
            result = run_own_branch(cfg)
            r = {
                "label": label,
                "sigma": pf_config.weight_params.get("sigma"),
                "accum": pf_config.weight_params.get("accumulate_mode"),
                "boundary": pf_config.motion_params.get("boundary_handling"),
                "resample": pf_config.resample,
                "pf_mean": result["pf_error_stats"]["mean"],
                "pf_median": result["pf_error_stats"]["median"],
                "pf_p95": result["pf_error_stats"]["p95"],
                "pf_final": result["pf_error_stats"]["final"],
                "pdr_mean": result["pdr_error_stats"]["mean"],
                "steps": result["steps_detected"],
            }
            elapsed = time.time() - t0
            print(f"{len(results)+1:<3d} {label:<30s} {str(r['sigma']):>5s} {r['accum']:<10s} {r['boundary']:<6s} {r['resample']:<8s} {r['pf_mean']:>8.2f} {r['pf_median']:>8.2f} {r['pf_p95']:>8.2f} {r['pf_final']:>8.2f}  {elapsed:.0f}s")
            results.append(r)
        except Exception as exc:
            elapsed = time.time() - t0
            print(f"{len(results)+1:<3d} {label:<30s} ERROR: {exc} ({elapsed:.0f}s)")
        finally:
            br.build_own_configs = original

    # Save
    out = Path("results/benchmark_grid.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(results, indent=2, default=str), encoding="utf-8")
    print(f"\nSaved to {out}")

    if results:
        best_m = min(results, key=lambda r: r["pf_mean"])
        best_f = min(results, key=lambda r: r["pf_final"])
        best_p = min(results, key=lambda r: r["pf_p95"])
        bl = [r for r in results if "baseline" in r["label"]]
        opt = [r for r in results if "baseline" not in r["label"]]

        print(f"\n{'='*60}")
        print(f"Best mean:  {best_m['label']} → {best_m['pf_mean']:.2f}m")
        print(f"Best final: {best_f['label']} → {best_f['pf_final']:.2f}m")
        print(f"Best P95:   {best_p['label']} → {best_p['pf_p95']:.2f}m")

        if bl and opt:
            bl_mean = np.mean([r["pf_mean"] for r in bl])
            bl_final = np.mean([r["pf_final"] for r in bl])
            bl_p95 = np.mean([r["pf_p95"] for r in bl])
            op_mean = np.mean([r["pf_mean"] for r in opt])
            op_final = np.mean([r["pf_final"] for r in opt])
            op_p95 = np.mean([r["pf_p95"] for r in opt])
            print(f"\nBaseline avg:  mean={bl_mean:.2f}m  P95={bl_p95:.2f}m  final={bl_final:.2f}m")
            print(f"Optimized avg: mean={op_mean:.2f}m  P95={op_p95:.2f}m  final={op_final:.2f}m")
            print(f"Improvement:   mean={(bl_mean-op_mean)/bl_mean*100:+.0f}%  P95={(bl_p95-op_p95)/bl_p95*100:+.0f}%  final={(bl_final-op_final)/bl_final*100:+.0f}%")


if __name__ == "__main__":
    main()
