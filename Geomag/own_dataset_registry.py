import json
from pathlib import Path

TILE_COUNT_X = 12
TILE_COUNT_Y = 8
TILE_SIZE_X_M = 0.96
TILE_SIZE_Y_M = 1.10


def tile_center(ix, iy):
    return [float((ix + 0.5) * TILE_SIZE_X_M), float((iy + 0.5) * TILE_SIZE_Y_M)]


ROUTE1_XY_M = [
    tile_center(1, 0),
    tile_center(1, 7),
    tile_center(5, 7),
    tile_center(5, 0),
    tile_center(1, 0),
]

ROUTE2_XY_M = [
    tile_center(1, 0),
    tile_center(1, 5),
    tile_center(4, 5),
]


_REPO_ROOT = Path(__file__).resolve().parent.parent
_OWN_PACKAGE_ROOT = _REPO_ROOT / "data" / "own_data_package"


def _load_manifest():
    manifest_path = _OWN_PACKAGE_ROOT / "manifest.json"
    with manifest_path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _load_registry(manifest):
    map_meta = manifest.get("map", {})
    tile_size_x_m = float(map_meta.get("tile_size_x_m", TILE_SIZE_X_M))
    tile_size_y_m = float(map_meta.get("tile_size_y_m", TILE_SIZE_Y_M))
    registry = {}
    for key, dataset in manifest.get("datasets", {}).items():
        route_label = dataset.get("route_label")
        route_key = dataset.get("route_key", f"{route_label}_tile_vertices")
        vertices = manifest.get("routes", {}).get(route_key)
        if not vertices:
            raise ValueError(
                f"Missing route {route_key!r} for own dataset {key!r}"
            )
        route_xy_m = [
            [
                float((float(ix) + 0.5) * tile_size_x_m),
                float((float(iy) + 0.5) * tile_size_y_m),
            ]
            for ix, iy in vertices
        ]
        registry[key] = {
            **dataset,
            "folder_name": dataset.get("folder_name", key),
            "route_xy_m": route_xy_m,
            "evaluation_enabled": bool(dataset.get("evaluation_enabled", True)),
            "evaluation_tier": str(
                dataset.get(
                    "evaluation_tier",
                    "confirmed"
                    if dataset.get("evaluation_enabled", True)
                    else "excluded",
                )
            ).lower(),
        }
    return registry


_MANIFEST = _load_manifest()
_REGISTRY = _load_registry(_MANIFEST)


def available_own_dataset_keys(evaluation_only=False, include_provisional=False):
    keys = _REGISTRY.keys()
    if evaluation_only:
        keys = [
            key
            for key, spec in _REGISTRY.items()
            if bool(spec.get("evaluation_enabled", True))
            and (
                include_provisional
                or str(spec.get("evaluation_tier", "confirmed")) == "confirmed"
            )
        ]
    return sorted(keys)


def default_own_evaluation_keys():
    configured = list(_MANIFEST.get("default_evaluation_datasets", []))
    if not configured:
        return available_own_dataset_keys(evaluation_only=True)
    unknown = [key for key in configured if key not in _REGISTRY]
    disabled = [
        key
        for key in configured
        if key in _REGISTRY
        and not bool(_REGISTRY[key].get("evaluation_enabled", True))
    ]
    if unknown or disabled:
        raise ValueError(
            "Invalid default own-data evaluation selection: "
            f"unknown={unknown}, disabled={disabled}"
        )
    return configured


def get_own_dataset_spec(own_dataset_key):
    token = str(own_dataset_key or "").strip()
    if token not in _REGISTRY:
        raise ValueError(
            f"Unknown own dataset key: {own_dataset_key}. Available keys: {available_own_dataset_keys()}"
        )

    spec = dict(_REGISTRY[token])
    dataset_path = spec.get("dataset_path", spec["folder_name"])
    dataset_dir = (_OWN_PACKAGE_ROOT / dataset_path).resolve()
    return {
        "key": token,
        "dataset_dir": str(dataset_dir),
        "route_label": spec["route_label"],
        "route_xy_m": [[float(x), float(y)] for x, y in spec["route_xy_m"]],
        "assignment_confidence": spec["assignment_confidence"],
        "evaluation_enabled": bool(spec.get("evaluation_enabled", True)),
        "evaluation_tier": str(spec.get("evaluation_tier", "confirmed")),
        "evaluation_role": str(spec.get("evaluation_role", "primary")),
        "data_issue": spec.get("data_issue"),
        "historical_alias": spec.get("historical_alias"),
        "route_confirmation": dict(spec.get("route_confirmation", {})),
        "capture_metadata": dict(spec.get("capture_metadata", {})),
    }


def assert_own_dataset_evaluable(own_dataset_key):
    spec = get_own_dataset_spec(own_dataset_key)
    if not spec["evaluation_enabled"]:
        raise ValueError(
            f"Own dataset {own_dataset_key!r} is excluded from evaluation: "
            f"{spec['data_issue']}. Use one of "
            f"{available_own_dataset_keys(evaluation_only=True)}."
        )
    return spec


def resolve_own_dataset_dir(own_dataset_key):
    return get_own_dataset_spec(own_dataset_key)["dataset_dir"]


def get_own_route_xy_m(own_dataset_key):
    return get_own_dataset_spec(own_dataset_key)["route_xy_m"]


def independent_repeat_keys(own_dataset_key):
    """Return evaluable captures of the same route, excluding the query run."""
    target = get_own_dataset_spec(own_dataset_key)
    output = []
    for key in available_own_dataset_keys(evaluation_only=True):
        if key == target["key"]:
            continue
        candidate = get_own_dataset_spec(key)
        if candidate["route_label"] != target["route_label"]:
            continue
        if candidate.get("data_issue"):
            continue
        output.append(key)
    return sorted(output)
