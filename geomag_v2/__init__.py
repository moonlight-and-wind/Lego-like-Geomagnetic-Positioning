"""Second-generation positioning core for the recent iPhone captures.

The package is intentionally independent from the legacy :mod:`Geomag`
pipeline.  It shares no registry, particle-filter state, or historical map.
"""

from geomag_v2.catalog import CALIBRATION_KEYS, RECENT_ROUTES, RouteSpec
from geomag_v2.pipeline import run_validation

__all__ = ["CALIBRATION_KEYS", "RECENT_ROUTES", "RouteSpec", "run_validation"]
