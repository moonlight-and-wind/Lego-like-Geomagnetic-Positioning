import Geomag as g
import Geomag.algorithms
import numpy as np
from matplotlib import pyplot as plt
from Geomag import *
map_array = np.array([[0.3, 1.2, 0.47],
                 [1.9, 0.6, 0.56],
                 [1.1, 3.2, 0.74],
                 [3.3, 4.4, 1.47],
                 [4.7, 3.8, 1.74]])
map_dict = Geomag.algorithms.get_map(
    source="own",
    config_path="pyproject.toml",
    force_download=False,
    force_extract=False,
    own_grid_array=map_array,
    own_grid_map_path=None,
    own_grid_format="array",
    own_grid_meta={"x_min": 0, "y_min": 0, "x_max": 10, "y_max": 10},)
plt.imshow(map_dict["map"], origin="lower", extent=[map_dict["rangex_min"], map_dict["rangex_max"], map_dict["rangey_min"], map_dict["rangey_max"]])
plt.show()
