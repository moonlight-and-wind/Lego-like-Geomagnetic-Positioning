import logging

from Geomag.algorithms import get_map, get_sensor, get_sensor_diagnostics, get_test_len

logger = logging.getLogger(__name__)


def collect_sensor_stream(source, **kwargs):
    """Read the full sensor stream for one test run.

    Returns a dict with aligned arrays/lists:
    - t: sensor timestamp when available, otherwise the sample index
    - acc: accelerometer [x, y, z]
    - gyro: gyroscope [x, y, z]
    - mag: magnetometer [x, y, z]
    """
    n = get_test_len(source=source, **kwargs)
    acc = []
    gyro = []
    mag = []
    t = []
    for i in range(n):
        m, a, g = get_sensor(source=source, **kwargs)
        mag.append(m)
        acc.append(a)
        gyro.append(g)
        sensor_time = get_sensor_diagnostics().get("time")
        t.append(i if sensor_time is None else float(sensor_time))
    return {
        "t": t,
        "acc": acc,
        "gyro": gyro,
        "mag": mag,
    }


def get_uji_map():
    """Load UJI map metadata for visualization.

    Prefer rebuilding map from raw data; if map building dependencies are not
    available, fall back to existing processed artifacts.
    """
    try:
        return get_map(source="uji")
    except Exception:
        logger.warning(
            "UJI map building failed — falling back to pre-built artifacts. "
            "Install pykrige and gstools for full map building support."
        )
        return {
            "source": "uji",
            "output_model_npz": "data/processed/uji_mag_model_kriging.npz",
            "output_preview_npz": "data/processed/uji_mag_grid_preview_kriging.npz",
        }
