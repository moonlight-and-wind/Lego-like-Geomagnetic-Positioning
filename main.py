import argparse

from Geomag.branching import (
    BranchConfig,
    parse_route_control_points,
    resolve_own_selection,
    resolve_uji_selection,
    run_branch_simulation,
)

# Change these variables for the usual workflow.
branch = "own"  # "uji" or "own"
uji = "2"  # "tt01"..."tt11", "1"..."11", "tt02.txt", or a raw test-file path.
own = "route1_run2"  # primary/secondary confirmed capture, own_branch, or a raw directory
# Note: avoid "route1_run1" — the sensor data does not match the registered route.


def build_config_from_args(args):
    uji_defaults = resolve_uji_selection(args.uji)
    uji_test_file = args.uji_test_file or uji_defaults["uji_test_file"]
    uji_data_root = args.uji_data_root or uji_defaults["uji_data_root"]

    own_defaults = resolve_own_selection(args.own)
    own_profile = args.own_profile or own_defaults["own_profile"]
    own_data_source = args.own_data_source or own_defaults["own_data_source"]
    own_dataset_key = args.own_dataset_key or own_defaults["own_dataset_key"]
    own_data_dir = args.own_data_dir or own_defaults["own_data_dir"]

    return BranchConfig(
        branch=args.branch,
        window_size=args.window_size,
        max_frames=args.max_frames,
        show=not args.no_show,
        output_json=args.output_json,
        output_png=args.output_png,
        uji_test_file=uji_test_file,
        uji_data_root=uji_data_root,
        own_profile=own_profile,
        own_data_source=own_data_source,
        own_dataset_key=own_dataset_key,
        own_data_dir=own_data_dir,
        own_map_mode=args.own_map_mode,
        own_map_profile=args.own_map_profile,
        own_map_npz_path=args.own_map_npz_path,
        own_map_offset_x_m=args.own_map_offset_x_m,
        own_map_offset_y_m=args.own_map_offset_y_m,
        own_route_xy_m=parse_route_control_points(args.own_route) if args.own_route else None,
        own_initial_heading_deg=args.own_initial_heading_deg,
        own_use_route_initial_heading=not args.no_route_initial_heading,
        own_mirror_y=args.mirror_y,
        own_heading_offset_deg=args.own_heading_offset_deg,
        own_heading_method=args.own_heading_method,
        own_quaternion_use_magnetometer=(
            args.own_quaternion_use_magnetometer
        ),
        own_gyro_bias_stationary_min_duration_s=(
            args.own_gyro_bias_stationary_min_duration_s
        ),
        own_gyro_rate_scale=args.own_gyro_rate_scale,
        own_trim_head=args.own_trim_head,
        own_trim_tail=args.own_trim_tail,
        own_pf_smoothing_alpha=args.own_pf_smoothing_alpha,
        own_pf_smoothing_mode=args.own_pf_smoothing_mode,
        own_vector_map_enabled=args.own_vector_map,
        own_vector_map_path=args.own_vector_map_path,
        own_vector_weight=args.own_vector_weight,
        own_vector_angle_sigma_deg=args.own_vector_angle_sigma_deg,
        own_vector_reject_deg=args.own_vector_reject_deg,
        own_vector_norm_tolerance_ratio=(
            args.own_vector_norm_tolerance_ratio
        ),
        own_alignment_mode=args.own_alignment_mode,
        own_heading_snap_deg=args.own_heading_snap_deg,
        own_step_peak_prominence=args.own_step_peak_prominence,
        own_step_min_interval_s=args.own_step_min_interval_s,
        own_step_weinberg_k=args.own_step_weinberg_k,
        own_step_length_scale=args.own_step_length_scale,
        own_progress_template_json=args.own_progress_template_json,
        own_progress_correction_gain=args.own_progress_correction_gain,
        own_repeat_progress_enabled=not args.no_own_repeat_progress,
        own_repeat_progress_gain=args.own_repeat_progress_gain,
        own_step_cadence_weight=args.own_step_cadence_weight,
        own_step_variability_weight=args.own_step_variability_weight,
        own_pf_joint_calibration=not args.no_own_pf_joint_calibration,
    )


def main():
    parser = argparse.ArgumentParser(description="Run a geomagnetic positioning simulation by branch.")
    parser.add_argument("--branch", choices=["uji", "own"], default=branch, help="Simulation branch.")
    parser.add_argument("--window-size", type=int, default=400, help="Geomagnetic history window.")
    parser.add_argument("--max-frames", type=int, default=None, help="Limit consumed sensor frames for quick checks.")
    parser.add_argument("--no-show", action="store_true", help="Save plots without opening a window.")
    parser.add_argument("--output-json", type=str, default=None, help="Optional JSON output path.")
    parser.add_argument("--output-png", type=str, default=None, help="Optional plot output path.")

    parser.add_argument("--uji", type=str, default=uji, help="UJI selector: tt01..tt11, 1..11, tt02.txt, or raw test-file path.")
    parser.add_argument("--uji-test-file", type=str, default=None, help="Low-level override for UJI test file.")
    parser.add_argument("--uji-data-root", type=str, default=None, help="Low-level override for UJI data root.")

    parser.add_argument(
        "--own",
        type=str,
        default=own,
        help=(
            "Own data selector: confirmed package key, 'own_branch', "
            "or raw data/own_data directory."
        ),
    )
    parser.add_argument("--own-profile", choices=["own_branch", "package"], default=None)
    parser.add_argument(
        "--own-data-source",
        choices=["auto", "registry", "directory"],
        default=None,
        help="Sensor source, independent of the own-data algorithm profile.",
    )
    parser.add_argument("--own-dataset-key", type=str, default=None, help="Low-level override for package profile.")
    parser.add_argument("--own-data-dir", type=str, default=None, help="Sensor folder used by the directory data source.")
    parser.add_argument("--own-map-mode", choices=["raw", "tile12"], default="raw", help="Own map mode.")
    parser.add_argument(
        "--own-map-profile",
        choices=["auto", "survey_kriging", "tile_manifest"],
        default="auto",
        help="Explicit physical interpretation of the own magnetic map.",
    )
    parser.add_argument("--own-map-npz-path", type=str, default=None, help="Optional own-branch npz map path.")
    parser.add_argument("--own-map-offset-x-m", type=float, default=0.0)
    parser.add_argument("--own-map-offset-y-m", type=float, default=0.0)
    parser.add_argument("--own-route", type=str, default=None, help="Optional route controls: 'x1,y1; x2,y2'.")
    parser.add_argument("--own-initial-heading-deg", type=float, default=None, help="Known initial heading, math degrees: 0=+X, 90=+Y.")
    parser.add_argument("--no-route-initial-heading", action="store_true", help="Disable known first-step heading from the route.")
    parser.add_argument("--mirror-y", action="store_true", help="Legacy own-data Y mirror heading correction.")
    parser.add_argument("--own-heading-offset-deg", type=float, default=-90.0, help="Own heading offset after correction.")
    parser.add_argument(
        "--own-heading-method",
        choices=["gyro", "core_motion", "quaternion", "q_fused", "tilt_compass"],
        default="gyro",
        help=(
            "Heading estimator for own data. core_motion uses DeviceMotion.csv "
            "yaw when the iPhone package provides it."
        ),
    )
    parser.add_argument(
        "--own-quaternion-use-magnetometer",
        action="store_true",
        help="Enable anomaly-gated magnetometer yaw correction in quaternion mode.",
    )
    parser.add_argument(
        "--own-gyro-bias-stationary-min-duration-s",
        type=float,
        default=0.0,
        help=(
            "Consecutive stationary time required for legacy gyro-Z bias "
            "calibration. Zero preserves the established own-data baseline."
        ),
    )
    parser.add_argument(
        "--own-gyro-rate-scale",
        type=float,
        default=1.0,
        help=(
            "Dimensionless angular-rate scale measured on an independent "
            "known-turn calibration walk."
        ),
    )
    parser.add_argument("--own-trim-head", type=int, default=0, help="Drop first N own-data sensor frames.")
    parser.add_argument("--own-trim-tail", type=int, default=0, help="Drop last N own-data sensor frames.")
    parser.add_argument(
        "--own-pf-smoothing-alpha",
        type=float,
        default=0.3,
        help="EMA history weight for displayed PF output; 0 disables smoothing.",
    )
    parser.add_argument(
        "--own-pf-smoothing-mode",
        choices=["none", "ema", "motion_adaptive"],
        default="ema",
        help=(
            "Reported PF trajectory smoothing. motion_adaptive smooths only "
            "the correction residual after a PDR motion prediction."
        ),
    )
    parser.add_argument(
        "--own-vector-map",
        action="store_true",
        help=(
            "Enable the experimental three-axis direction likelihood with "
            "automatic scalar fallback."
        ),
    )
    parser.add_argument(
        "--own-vector-map-path",
        default="data/processed/own_vector_map.npz",
    )
    parser.add_argument("--own-vector-weight", type=float, default=0.10)
    parser.add_argument(
        "--own-vector-angle-sigma-deg",
        type=float,
        default=25.0,
    )
    parser.add_argument(
        "--own-vector-reject-deg",
        type=float,
        default=60.0,
    )
    parser.add_argument(
        "--own-vector-norm-tolerance-ratio",
        type=float,
        default=0.35,
    )
    parser.add_argument(
        "--own-alignment-mode",
        choices=["active_walk_uniform_speed", "capture_time"],
        default="active_walk_uniform_speed",
        help=(
            "Reference-route alignment for own data. The default excludes "
            "stationary recording tails using detected step events."
        ),
    )
    parser.add_argument(
        "--own-heading-snap-deg",
        type=float,
        default=0.0,
        help="Snap own-data headings to this grid interval; 0 disables the constraint.",
    )
    parser.add_argument(
        "--own-step-peak-prominence",
        type=float,
        default=0.30,
        help="Minimum acceleration-peak prominence for an own-data step.",
    )
    parser.add_argument(
        "--own-step-min-interval-s",
        type=float,
        default=0.40,
        help="Minimum time between own-data steps; suppresses duplicate peaks.",
    )
    parser.add_argument(
        "--own-step-weinberg-k",
        type=float,
        default=0.31,
        help="Base coefficient for the adaptive own-data step model.",
    )
    parser.add_argument(
        "--own-step-length-scale",
        type=float,
        default=1.0,
        help=(
            "Personal step-length scale measured on an independent known-"
            "distance calibration walk."
        ),
    )
    parser.add_argument(
        "--own-step-cadence-weight",
        type=float,
        default=0.0,
        help="Learned metres-per-Hz correction around the 1.8 Hz cadence reference.",
    )
    parser.add_argument(
        "--own-progress-template-json",
        default=None,
        help="Prior independent same-route result JSON used as a magnetic progress template.",
    )
    parser.add_argument(
        "--own-progress-correction-gain",
        type=float,
        default=0.0,
        help="Experimental causal progress-to-step-scale correction gain; zero disables it.",
    )
    parser.add_argument(
        "--no-own-repeat-progress",
        action="store_true",
        help="Disable automatic causal magnetic template matching against an independent same-route capture.",
    )
    parser.add_argument(
        "--own-repeat-progress-gain",
        type=float,
        default=0.30,
        help="Step-scale correction gain for an automatically selected independent repeat capture.",
    )
    parser.add_argument(
        "--own-step-variability-weight",
        type=float,
        default=0.0,
        help="Learned step correction for acceleration-magnitude variability.",
    )
    parser.add_argument(
        "--no-own-pf-joint-calibration",
        action="store_true",
        help="Disable particle step-scale and heading-bias estimation for ablation.",
    )

    args = parser.parse_args()
    return run_branch_simulation(build_config_from_args(args))


if __name__ == "__main__":
    main()
