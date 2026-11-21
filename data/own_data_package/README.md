# Own Data Package

This package normalizes three raw ZIP captures into a deterministic layout:

- `route1_run1/` from `Geomagnetic Navigation 2026-03-12 21-12-10.zip`
- `route1_run2/` from `Geomagnetic Navigation 2026-03-19 20-04-39.zip`
- `route2_run1/` from `Geomagnetic Navigation 2026-03-19 20-03-26.zip`

The registry also references the extracted `20-10-45` capture as
`route2_run2`. The operator confirmed that it is an independent second
capture of the same route as `route2_run1`. It is now a confirmed primary
evaluation capture.

Each route folder contains:

- `Accelerometer.csv`
- `Gyroscope.csv`
- `Magnetometer.csv`
- `Location.csv`
- `meta/device.csv`
- `meta/time.csv`

Map interpretation metadata is recorded in `manifest.json`:

- tile count: `12 x 8`
- tile size: `96 cm x 110 cm`
- coordinate model hint: tile-based, center anchor, `flip_y = true`

Warning: `route1_run1` is excluded from route evaluation because its sensor
capture does not match the registered route. It remains in the package only for
raw-data inspection. The default evaluation uses `route1_run2` and
`route2_run2`. `route2_run1` remains available as a separate repeated capture.

Dataset tiers:

- `confirmed`: route identity confirmed and eligible for evaluation
- `provisional`: runnable and reported separately
- `excluded`: blocked from route-accuracy evaluation

Evaluation roles are separate from route identity:

- `primary`: selected by the manifest for the default batch
- `secondary_repeat`: confirmed independent repeat, run only when requested

Compare the two independent route2 capture fingerprints:

```bash
python -m Geomag.route_identity
```

Run every confirmed/repeated capture instead of the manifest-selected default:

```bash
python -m Geomag.batch_evaluation --all-evaluable
```

Two map geometries are intentionally explicit:

- `survey_kriging`: measured `6.72 m × 8.074 m` Kriging grid
- `tile_manifest`: `12 × 8` tile interpretation (`11.52 m × 8.80 m`)

Use `--map-profile survey_kriging` or `--map-profile tile_manifest` for a
controlled comparison. `auto` preserves the established branch defaults.

## Capture metadata and quality checks

`manifest.json` format 2.0 records the acquisition protocol and the evaluation
status of every dataset. Existing captures are marked `legacy_unannotated`
because no synchronized turn-event timestamps were recorded at acquisition
time.

For a new capture:

1. Copy `capture_metadata.template.json` to
   `<dataset-folder>/capture_metadata.json`, then fill in the real dataset key,
   route label, stationary durations, and turn-event times.
2. Keep the phone face-up with its front pointing forward.
3. Remain still for at least 3 seconds before walking.
4. After reaching the endpoint, remain still for at least 3 seconds before
   stopping the recording.
5. For a controlled constant-speed route, turn times are optional because
   route-segment length fractions provide the reference alignment. For
   arbitrary speed or stronger ground truth, record each turn time and signed
   angle when practical.

The evaluator detects the active walking interval from the first/last step
events and excludes stationary recording tails. Tile seams and 90-degree turns
remain a controlled validation mode, not a production requirement.

Audit all package data before evaluating:

```bash
python -m Geomag.data_quality
```

The report is written to `results/own_data_quality.json`. Integrity problems
such as missing streams, invalid timestamps, insufficient time overlap, or an
explicitly disabled capture are failures. Missing stationary windows and turn
annotations are warnings so legacy data can still be inspected.

Run the two manifest-selected primary datasets with the same configuration:

```bash
python -m Geomag.batch_evaluation
```

The batch command writes per-dataset results, plots, diagnostics, quality
checks, and an aggregate `summary.json` under `results/own_batch/`.
