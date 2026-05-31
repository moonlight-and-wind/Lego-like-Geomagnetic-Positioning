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
own = "route1_run2"  # "route1_run2", "route2_run1", "own_branch", or a raw data/own_data directory.
# Note: avoid "route1_run1" — the sensor data does not match the registered route.


def build_config_from_args(args):
    uji_defaults = resolve_uji_selection(args.uji)
    uji_test_file = args.uji_test_file or uji_defaults["uji_test_file"]
    uji_data_root = args.uji_data_root or uji_defaults["uji_data_root"]

    own_defaults = resolve_own_selection(args.own)
    own_profile = args.own_profile or own_defaults["own_profile"]
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
        own_dataset_key=own_dataset_key,
        own_data_dir=own_data_dir,
        own_map_mode=args.own_map_mode,
        own_map_npz_path=args.own_map_npz_path,
        own_route_xy_m=parse_route_control_points(args.own_route) if args.own_route else None,
        own_initial_heading_deg=args.own_initial_heading_deg,
        own_use_route_initial_heading=not args.no_route_initial_heading,
        own_mirror_y=args.mirror_y,
        own_heading_offset_deg=args.own_heading_offset_deg,
        own_trim_head=args.own_trim_head,
        own_trim_tail=args.own_trim_tail,
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

    parser.add_argument("--own", type=str, default=own, help="Own data selector: package key, 'own_branch', or raw data/own_data directory.")
    parser.add_argument("--own-profile", choices=["own_branch", "package"], default=None)
    parser.add_argument("--own-dataset-key", type=str, default=None, help="Low-level override for package profile.")
    parser.add_argument("--own-data-dir", type=str, default=None, help="Low-level override for own_branch profile.")
    parser.add_argument("--own-map-mode", choices=["raw", "tile12"], default="raw", help="Own map mode.")
    parser.add_argument("--own-map-npz-path", type=str, default=None, help="Optional own-branch npz map path.")
    parser.add_argument("--own-route", type=str, default=None, help="Optional route controls: 'x1,y1; x2,y2'.")
    parser.add_argument("--own-initial-heading-deg", type=float, default=None, help="Known initial heading, math degrees: 0=+X, 90=+Y.")
    parser.add_argument("--no-route-initial-heading", action="store_true", help="Disable known first-step heading from the route.")
    parser.add_argument("--mirror-y", action="store_true", help="Legacy own-data Y mirror heading correction.")
    parser.add_argument("--own-heading-offset-deg", type=float, default=-90.0, help="Own heading offset after correction.")
    parser.add_argument("--own-trim-head", type=int, default=0, help="Drop first N own-data sensor frames.")
    parser.add_argument("--own-trim-tail", type=int, default=0, help="Drop last N own-data sensor frames.")

    args = parser.parse_args()
    return run_branch_simulation(build_config_from_args(args))


if __name__ == "__main__":
    main()
