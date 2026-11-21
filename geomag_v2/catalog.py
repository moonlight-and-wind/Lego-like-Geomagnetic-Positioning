"""The explicit recent-only data boundary used by V2."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class RouteSpec:
    key: str
    group: str
    points_m: tuple[tuple[float, float], ...]
    geometry_status: str

    @property
    def segment_lengths_m(self) -> np.ndarray:
        points = np.asarray(self.points_m, dtype=float)
        return np.linalg.norm(np.diff(points, axis=0), axis=1)

    @property
    def total_length_m(self) -> float:
        return float(self.segment_lengths_m.sum())


ROUTE_13 = ((0.0, 0.0), (0.0, 1.8), (1.8, 1.8), (1.8, 0.0), (0.0, 0.0))
ROUTE_14 = ((0.0, 0.0), (0.0, -6.0), (-0.6, -6.0), (-0.6, 0.0), (0.0, 0.0))
ROUTE_15 = ((0.0, 0.0), (-12.0, 0.0), (-12.0, 0.6), (0.0, 0.6), (0.0, 0.0))

RECENT_ROUTES = (
    RouteSpec("route_13_1", "route_13", ROUTE_13, "operator_confirmed"),
    RouteSpec("route_13_2", "route_13", ROUTE_13, "operator_confirmed"),
    RouteSpec("route_13_3", "route_13", ROUTE_13, "operator_confirmed"),
    RouteSpec("route_14_2", "route_14", ROUTE_14, "operator_confirmed"),
    RouteSpec("route_14_3", "route_14", ROUTE_14, "operator_confirmed"),
    RouteSpec("route_15_1", "route_15", ROUTE_15, "recorded"),
    RouteSpec("route_15_2", "route_15", ROUTE_15, "recorded"),
    RouteSpec("route_15_3", "route_15", ROUTE_15, "recorded"),
)

CALIBRATION_KEYS = frozenset({"route_13_1", "route_14_2", "route_15_1"})
