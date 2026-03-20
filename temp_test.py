"""
ATTENTION: DO NOT DO ANY MODIFICATION CURRENTLY!
Some of the logic must be integrated into the "own" branch of
_api_get_map() in the future. This is only an exclusive python file
used for map builder's test. This file can build and plot the magnetic
map based on data recorded in magnetometer_map_own.py. Everyone should
fully understand how it works before move forward to further map building
works.
@ author: tianhs6523
@ email: kudoumakoto6523@gmail.com
@ date: Mar 20th, 2026
TODO
"""


import Geomag.algorithms
import numpy as np
from matplotlib import pyplot as plt
from Geomag import *

from magnetometer_map_own import data
import numpy as np

def line_array_to_point_cloud(line_array,
                              line_gap=0.96,          # 相邻测线间距，单位 m
                              line_length=8 * 1.01,  # 每条线长度，单位 m
                              target_dy=0.05):       # 纵向保留到 5 cm 一个点
    """
    输入:
        line_array: shape = (n_lines, n_samples_per_line)
    输出:
        points: shape = (N, 3), 每行是 [x, y, value]
        meta:   地图范围
    """
    B = np.asarray(line_array, dtype=float)
    n_lines, n_raw = B.shape

    # 原始纵向坐标：沿每条线均匀分布
    y_raw = np.linspace(0.0, line_length, n_raw, endpoint=False)

    # 纵向先降采样，否则点太密，Kriging 没必要吃这么多高度相关点
    if target_dy is not None and target_dy > 0:
        n_keep = int(np.floor(line_length / target_dy)) + 1
        idx = np.linspace(0, n_raw - 1, n_keep, dtype=int)
        B = B[:, idx]
        y = y_raw[idx]
    else:
        y = y_raw

    # 横向坐标：第 i 条线在 x=i*0.96 m
    x = np.arange(n_lines, dtype=float) * line_gap

    # 生成点云
    X, Y = np.meshgrid(x, y, indexing="ij")
    points = np.column_stack([X.ravel(), Y.ravel(), B.ravel()])

    meta = {
        "x_min": float(x.min()),
        "x_max": float(x.max()),
        "y_min": float(y.min()),
        "y_max": float(y.max()),
    }
    return points, meta

map_lines = np.array(data)   # shape: (n_lines, n_samples)
own_points, own_meta = line_array_to_point_cloud(
    map_lines,
    line_gap=0.96,
    line_length=8 * 1.01,
    target_dy=0.05
)

map_dict = Geomag.algorithms.get_map(
    source="own",
    config_path="pyproject.toml",
    force_download=False,
    force_extract=False,
    own_grid_array=own_points,      # 注意：现在传的是 N×3 点云
    own_grid_map_path=None,
    own_grid_format="array",
    own_grid_meta=own_meta,
)

plt.imshow(
    np.asarray(map_dict["map"]).T,
    origin="lower",
    extent=[
        map_dict["rangex_min"], map_dict["rangex_max"],
        map_dict["rangey_min"], map_dict["rangey_max"]
    ],
    aspect="equal"
)
plt.colorbar(label="Magnetic field")
plt.show()

# map_array = np.array([[0.3, 1.2, 0.47],
#                  [1.9, 0.6, 0.56],
#                  [1.1, 3.2, 0.74],
#                  [3.3, 4.4, 1.47],
#                  [4.7, 3.8, 1.74]])

# map_array = np.array(data)
# map_dict = Geomag.algorithms.get_map(
#     source="own",
#     config_path="pyproject.toml",
#     force_download=False,
#     force_extract=False,
#     own_grid_array=map_array,
#     own_grid_map_path=None,
#     own_grid_format="array",
#     own_grid_meta={"x_min": 0, "y_min": 0, "x_max": 10, "y_max": 10}
#     )
# plt.imshow(map_dict["map"], origin="lower", extent=[map_dict["rangex_min"], map_dict["rangex_max"], map_dict["rangey_min"], map_dict["rangey_max"]])
# plt.show()
