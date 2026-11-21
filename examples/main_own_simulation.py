"""Run the maintained own-data pipeline from an example entry point.

The implementation lives in :mod:`Geomag.branching`; keeping this file as a
thin wrapper prevents examples from silently drifting away from ``main.py``.
"""

import argparse

from Geomag.branching import BranchConfig, resolve_own_selection, run_branch_simulation


def run_own_simulation(
    own_dataset_key="route1_run2",
    window_size=400,
    max_frames=None,
    map_mode="raw",
    mirror_y=False,
    heading_offset_deg=-90.0,
    trim_head=0,
    trim_tail=0,
    output_json=None,
    output_png=None,
    show=False,
):
    selection = resolve_own_selection(own_dataset_key)
    return run_branch_simulation(
        BranchConfig(
            branch="own",
            window_size=window_size,
            max_frames=max_frames,
            show=show,
            output_json=output_json,
            output_png=output_png,
            own_profile=selection["own_profile"],
            own_dataset_key=selection["own_dataset_key"],
            own_data_dir=selection["own_data_dir"],
            own_map_mode=map_mode,
            own_mirror_y=mirror_y,
            own_heading_offset_deg=heading_offset_deg,
            own_trim_head=trim_head,
            own_trim_tail=trim_tail,
        )
    )


def main():
    parser = argparse.ArgumentParser(
        description="Run the maintained own-data PF/PDR pipeline."
    )
    parser.add_argument(
        "--dataset-key",
        default="route1_run2",
        help="Evaluation dataset key: route1_run2 or route2_run1.",
    )
    parser.add_argument("--window-size", type=int, default=400)
    parser.add_argument("--max-frames", type=int, default=None)
    parser.add_argument("--map-mode", choices=["raw", "tile12"], default="raw")
    parser.add_argument("--mirror-y", action="store_true")
    parser.add_argument("--heading-offset-deg", type=float, default=-90.0)
    parser.add_argument("--trim-head", type=int, default=0)
    parser.add_argument("--trim-tail", type=int, default=0)
    parser.add_argument("--output-json", default=None)
    parser.add_argument("--output-png", default=None)
    parser.add_argument("--show", action="store_true")
    args = parser.parse_args()

    run_own_simulation(
        own_dataset_key=args.dataset_key,
        window_size=args.window_size,
        max_frames=args.max_frames,
        map_mode=args.map_mode,
        mirror_y=args.mirror_y,
        heading_offset_deg=args.heading_offset_deg,
        trim_head=args.trim_head,
        trim_tail=args.trim_tail,
        output_json=args.output_json,
        output_png=args.output_png,
        show=args.show,
    )


if __name__ == "__main__":
    main()
