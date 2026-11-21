import numpy as np

from data.own_data.magnetometer_map_own import data
from Geomag.algorithms import get_map, get_sensor, get_test_len, get_true_route
from Geomag.own_dataset_registry import get_own_dataset_spec


def build_demo_tile_matrix(raw_matrix, target_cols=12):
    matrix = np.asarray(raw_matrix, dtype=float)
    if matrix.ndim != 2 or matrix.shape[0] == 0 or matrix.shape[1] == 0:
        raise ValueError("magnetometer_map_own.data must be a non-empty 2D array.")
    if matrix.shape[1] == target_cols:
        return matrix
    idx = np.linspace(0, matrix.shape[1] - 1, target_cols, dtype=int)
    return matrix[:, idx]


def main():
    own_dataset_key = "route1_run2"
    dataset_spec = get_own_dataset_spec(own_dataset_key)
    tile_matrix = build_demo_tile_matrix(data, target_cols=12)

    own_map = get_map(
        source="own",
        own_grid_array=tile_matrix,
        own_grid_meta={
            "tile_size_x_m": 0.96,
            "tile_size_y_m": 1.10,
            "anchor": "center",
            "flip_y": True,
            "origin_xy_m": [0.0, 0.0],
        },
    )

    route_xy_m = get_true_route(source="own", own_dataset_key=own_dataset_key)
    test_len = get_test_len(source="own", own_dataset_key=own_dataset_key)
    first_mag, first_acc, first_gyro = get_sensor(source="own", own_dataset_key=own_dataset_key)

    print("=== OWN DATA PACKAGE DEMO ===")
    print(f"dataset_key: {dataset_spec['key']}")
    print(f"dataset_dir: {dataset_spec['dataset_dir']}")
    print(f"route_label: {dataset_spec['route_label']}")
    print(f"map_input_shape: {tile_matrix.shape}")
    print(f"map_point_cloud_mode: {own_map.get('point_cloud_mode')}")
    print(f"map_points_count: {own_map.get('point_cloud_shape', [0, 0])[0]}")
    print(
        "map_bounds_m: "
        f"x=[{own_map.get('rangex_min'):.3f}, {own_map.get('rangex_max'):.3f}], "
        f"y=[{own_map.get('rangey_min'):.3f}, {own_map.get('rangey_max'):.3f}]"
    )
    print(f"route_points: {len(route_xy_m)}")
    print(f"route_start_xy_m: {route_xy_m[0]}")
    print(f"route_end_xy_m: {route_xy_m[-1]}")
    print(f"sensor_frames: {test_len}")
    print(f"first_mag: {first_mag}")
    print(f"first_acc: {first_acc}")
    print(f"first_gyro: {first_gyro}")


if __name__ == "__main__":
    main()
