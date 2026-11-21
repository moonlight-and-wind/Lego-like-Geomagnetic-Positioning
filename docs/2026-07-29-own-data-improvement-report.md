# Own-data positioning improvement report

Date: 2026-07-29

## Scope

This iteration separates visualization effects from filter behaviour and
addresses heading drift without using the registered reference route as an
algorithm input.

Implemented:

- raw PF and EMA-smoothed PF tracks in the same trajectory plot
- heading, step length, ESS, DDTW, and magnetic-level diagnostic histories
- time-aligned and cross-track error metrics
- online stationary gyroscope Z-bias estimation
- turn-aware particle heading noise
- start-calibrated compass coordinates for optional `q_fused` experiments
- configurable PF output smoothing
- optional orthogonal-grid heading snapping for constrained capture protocols
- experimental DDTW shape + absolute level + gradient likelihood
- per-frame heading integration using sensor timestamps
- trainable step-length features: amplitude, cadence, and acceleration variance
- particle-level step-scale and heading-bias random-walk states
- turn-event, corner, and explicit endpoint metrics
- reconstructed three-axis survey map with optional yaw-aligned PF likelihood
- vector norm/direction gates with automatic scalar-DDTW fallback

## Default configuration result

The values below are deterministic full runs with seed 42. “Aligned” error
assumes route progress follows the sensor-time fraction inside the
automatically detected active walking interval. “Cross-track” measures distance
to the route geometry and does not assume walking speed.

| Dataset | Aligned mean | Aligned P95 | Aligned final | Cross-track mean | Cross-track P95 |
|---|---:|---:|---:|---:|---:|
| `route1_run2` | 1.141 m | 1.923 m | 0.764 m | 0.335 m | 0.927 m |
| `route2_run2` | 0.893 m | 1.535 m | 1.136 m | 0.413 m | 1.161 m |

Explicit endpoint distance, which compares against the registered endpoint
rather than the sensor-time fraction of the final detected step, is 0.664 m
for `route1_run2` and 1.185 m for `route2_run2`.

The raw-versus-EMA comparison is capture-dependent:

| Dataset | Raw PF aligned mean | Raw PF cross-track mean |
|---|---:|---:|
| `route1_run2` | 1.283 m | 0.340 m |
| `route2_run2` | 0.796 m | 0.447 m |

The low-lag EMA improves `route1_run2` relative to raw PF and reduces
`route2_run2` cross-track error, but it still slightly worsens the latter's
aligned and endpoint errors. The cyan output is a causal presentation filter
and must not be confused with the magenta particle-filter estimate; both are
retained in every report.

The reported raw PF position is the weighted posterior before resampling.
Resampling only prepares the particle population for the next step; reporting
the post-resampling mean would incorrectly let globally injected particles
create visible output jumps.

## Ablation conclusions

1. Gyroscope bias estimation materially improves `route1_run2` and reduces
   cross-track drift.
2. Turn-aware particle noise slightly improves tail error on `route2_run1` and
   is neutral on `route1_run2`.
3. Indoor compass measurements are too disturbed for continuous default
   correction. Coordinate alignment is fixed and available for experiments,
   but the default remains bias-corrected gyro heading.
4. Adding absolute magnetic level and gradient penalties improves some final
   errors but worsens mean error on both validation routes. The feature remains
   opt-in rather than being selected from the test routes.
5. The `route2_run1` capture protocol confirms a 90-degree physical turn with
   the phone face-up and pointing forward. However, integrating the entire raw
   gyroscope CSV gives -56.2 degrees around device Z; projection of all three
   gyro axes onto the estimated gravity direction gives only -57.8 degrees.
   The missing angle is therefore present in the recorded IMU data rather than
   being caused by the pipeline's fixed integration interval.
6. Applying the protocol's hysteretic 90-degree grid prior to `route2_run1`
   reduces smoothed aligned mean from 0.775 m to 0.691 m, cross-track mean from
   0.426 m to 0.073 m, and raw-PF aligned mean from 0.805 m to 0.217 m.
   It remains opt-in because `route1_run2` then exposes a different problem:
   the last segment's estimated step lengths sum to 6.21 m for a registered
   3.84 m segment, producing a large endpoint overshoot.
7. Continuous timestamp integration is now the default. For the controlled
   face-up captures it integrates device Z. A simple three-axis
   angular-rate-to-gravity projection over-rotates `route1_run2` by about
   7 degrees, so that approximation remains available for experiments but is
   not presented as a substitute for a full quaternion or ESKF attitude
   solution.
8. The adaptive base coefficient 0.31 makes total estimated walking distance
   23.312 m versus 23.080 m on `route1_run2`, and 8.428 m versus 8.380 m on
   `route2_run1`. Cadence and variability coefficients remain zero because
   fitting them on the same two evaluation captures would leak test labels.
9. The particle posterior converges to a final step scale of about 0.943 on
   `route1_run2` and 0.979 on `route2_run1`. The capability is useful, but the
   current scalar magnetic map is not informative enough to treat those values
   as independently validated personal gait calibration.

## Evaluation warning

The white route is a registered ideal polyline, not synchronized ground truth.
Detected turns on `route1_run2` occur at active-walk fractions approximately
0.283, 0.502, and 0.745, while constant-speed reference turns are 0.334, 0.500,
and 0.834. Therefore aligned mean error can still be biased by turn-detection
timing or departures from perfectly constant speed. Cross-track error and the
raw trajectory should always be inspected alongside the aligned statistic.

## Acquisition quality gate and batch regression

The first stage of the follow-up plan is now implemented:

- `manifest.json` 2.0 is the single source of truth for route assignment,
  evaluation status, and capture protocol metadata.
- `capture_metadata.schema.json` and `capture_metadata.template.json` define
  the required metadata for new captures.
- `python -m Geomag.data_quality` checks required streams, monotonic
  timestamps, non-finite values, sampling gaps, stream overlap, 3-second
  stationary windows, nominal route speed, turn annotations, and diagnostic
  device-Z yaw consistency.
- `python -m Geomag.batch_evaluation` runs one quality-gated configuration
  over the manifest-selected primary captures and writes per-run plus
  aggregate metrics. `--all-evaluable` also runs secondary repeats.

The current package audit finds no blocking integrity error in
`route1_run2`, `route2_run1`, or `route2_run2`, but the legacy captures lack
verified 3-second stationary calibration windows and synchronized turn-event
annotations. `route1_run1` remains quarantined: its device-Z yaw integral is
about +173 degrees while the registered route requires -270 degrees, in
addition to its explicit route-assignment warning.

The uniform batch regression reproduces the established default results:

| Dataset | PF aligned mean | PF cross-track mean | PF endpoint |
|---|---:|---:|---:|
| `route1_run2` | 1.141 m | 0.335 m | 0.664 m |
| `route2_run2` | 0.893 m | 0.413 m | 1.185 m |

This quality gate does not make the legacy route labels into synchronized
ground truth. Its purpose is to prevent malformed or misassigned captures from
silently entering algorithm comparisons, and to make the missing evidence
explicit before the quaternion/ESKF heading stage.

## Active-walk constant-speed alignment

Manual turn timestamps are not required for the existing controlled captures:
the route segment lengths define the expected turn fractions, and sensor
timestamps already define elapsed time. The evaluator now estimates motion
bounds from the first and last detected steps, expands each boundary by half a
robust median step interval, and clips the result to the sensor capture.

The comparison with the previous full-capture alignment is:

| Dataset | Full-capture PF mean | Active-walk PF mean | Excluded tail |
|---|---:|---:|---:|
| `route1_run2` | 0.930 m | 0.917 m | 0.055 s |
| `route2_run1` | 0.772 m | 0.772 m | 0.000 s |

This is an important negative result: although recording continued after the
endpoint, the usable files contain almost no stationary tail. Time alignment
was only a small part of the reported difference. It cannot explain the visible
route-shape gap, because alignment changes reference metrics and diagnostic
turn positions but does not alter the PDR/PF trajectory itself. In
`route2_run1`, the remaining dominant issue is still the under-recorded heading
turn: the detected turn occurs near progress 0.775 instead of the expected
0.656, and the device-Z yaw does not contain the full physical 90-degree turn.

## Quaternion heading ablation

A new stateful quaternion estimator now provides:

- exact quaternion propagation from timestamped three-axis angular rate
- gravity-based roll/pitch feedback with acceleration-magnitude weighting
- three-axis gyro-bias estimation after a configurable consecutive-stationary
  interval
- optional tilt-compensated magnetic yaw correction
- magnetic norm and heading-innovation rejection
- quaternion, bias, acceleration quality, magnetic acceptance, and correction
  diagnostics at every detected step

The implementation passes synthetic yaw integration, timestamp replay,
three-axis bias, magnetic acceptance/rejection, and pipeline registry tests.
However, adding a better attitude representation cannot create yaw information
that is absent or corrupted in the input. Full real-data results are:

| Dataset / heading | PF aligned mean | Cross-track mean | Endpoint |
|---|---:|---:|---:|
| `route1_run2` gyro default | 0.917 m | 0.310 m | 0.251 m |
| `route1_run2` quaternion | 1.344 m | 0.355 m | 1.137 m |
| `route1_run2` quaternion + gated mag | 1.859 m | 0.427 m | 3.178 m |
| `route2_run1` gyro default | 0.772 m | 0.426 m | 1.256 m |
| `route2_run1` quaternion | 0.776 m | 0.429 m | 1.494 m |
| `route2_run1` quaternion + gated mag | 0.770 m | 0.410 m | 1.601 m |

The quaternion yaw changes are approximately -288 degrees on `route1_run2`
and -55 degrees on `route2_run1`; the expected controlled-route changes are
-270 and -90 degrees. Gravity fusion therefore does not recover the missing
`route2_run1` turn. The magnetometer passes simple norm/direction gates because
its distortion is locally continuous, yet it moves `route1_run2` farther from
the expected yaw. This is why the magnetic option remains disabled by default.

The audit also revealed that the legacy gyro baseline accepted isolated
low-motion samples as bias observations. Requiring 0.25 seconds of consecutive
stationarity is now supported and is the quaternion default, but applying it
to these captures does not improve the overall benchmark: neither capture
contains a valid calibration interval. The established gyro baseline retains
its zero-duration setting for reproducible comparison; future captures should
use a verified stationary interval before enabling strict bias calibration.

The default heading is therefore unchanged. For the current controlled
orthogonal protocol, the explicit 90-degree grid state remains the only tested
source of the missing turn information. For general routes, a full ESKF would
still require a trustworthy yaw observation (clean magnetometer, visual
heading, floor-plan constraint, or another reference); covariance machinery
alone would not solve the observability problem.

## Confirmed independent `route2_run2` capture and map-geometry audit

Historical result files consistently identify the `20-10-45` capture as
`route2_run2`. The operator has now confirmed that it is an independent second
capture of the same registered route as `route2_run1`. It is therefore marked
`confirmed`; the manifest-selected primary evaluation uses `route1_run2` and
`route2_run2`, while `route2_run1` remains available as a separate repeat.

The sensor-fingerprint audit reports:

- candidate device-Z yaw: `-93.51°`
- registered route2 yaw: `-90°`
- cadence difference from `route2_run1`: `0.093 Hz`
- forward/reverse magnetic correlation: `0.421 / -0.335`
- sensor-only assignment recommendation before operator confirmation:
  `medium` confidence
- synchronized ground truth ready: `false`

The operator confirmation establishes the route identity, but it does not turn
the ideal polyline into synchronized point-by-point ground truth. The
machine-readable consistency report is `results/route_identity_audit.json`.

Two previously implicit map interpretations are now explicit:

| Profile | Physical interpretation |
|---|---|
| `survey_kriging` | measured eight-line Kriging grid, `6.72 × 8.074 m` |
| `tile_manifest` | registered `12 × 8` tiles, `11.52 × 8.80 m` |

Full deterministic comparisons with seed 42:

| Dataset | Profile | PF aligned mean | Cross-track mean | Endpoint |
|---|---|---:|---:|---:|
| `route1_run2` | tile | 1.141 m | 0.335 m | 0.664 m |
| `route1_run2` | survey | 1.270 m | 0.400 m | 1.000 m |
| `route2_run2` | tile | 0.893 m | 0.413 m | 1.185 m |
| `route2_run2` | survey | 0.895 m | 0.400 m | 1.131 m |

Across the two selected primary captures, `tile_manifest` has the better
aggregate aligned mean (`1.017 m` versus `1.082 m`), cross-track mean
(`0.374 m` versus `0.400 m`), and endpoint mean (`0.925 m` versus `1.065 m`).
It therefore remains the package default.
`survey_kriging` remains an explicit experimental profile and is never
silently mixed with the tile geometry.

## Output-smoothing and vector-map follow-up

The original EMA history weight `0.70` was selected before `route2_run2`
became a primary capture. A uniform sweep over both selected captures shows
that it is too strong:

| Output mode | Pair aligned mean | Pair cross-track mean | Pair endpoint mean |
|---|---:|---:|---:|
| raw PF | 1.040 m | 0.393 m | 0.949 m |
| EMA `0.70` | 1.181 m | **0.319 m** | 1.046 m |
| EMA `0.30` | **1.017 m** | 0.374 m | **0.925 m** |
| motion-adaptive `0.70` | 1.044 m | 0.396 m | 0.973 m |

EMA `0.30` is the new default because it improves all three aggregate metrics
relative to raw PF and avoids most of the short-route lag. The improvement is
not uniform per capture: stronger smoothing remains better for
`route1_run2`, while almost no smoothing is better for the aligned/endpoint
metrics of `route2_run2`. Therefore every result still reports both raw and
smoothed PF.

The very small `route1_run2` endpoint under EMA `0.70` is not pure localization
improvement. That route closes near its starting area, so a lagging causal
filter is pulled toward earlier points just when the walk returns to the
registered endpoint. The same lag is exposed as a large error on the open
`route2_run2`. EMA `0.30` avoids selecting a presentation filter that benefits
from this closed-loop geometry accident.

Two additional causal ideas were rejected. A one-step displacement
compensation did not improve the aggregate robustly, and a warm-up schedule
that increased smoothing with step count looked much better numerically but
implicitly exploited the large route-length difference between the two test
captures. Neither is promoted from this small evaluation set.

The nine raw magnetometer survey archives were audited against
`magnetometer_map_own.py`. The first eight archives reproduce the accepted
scalar scan lines after resampling, with selected magnitude correlations from
`0.962` to `0.997`; the later `19-56-48` archive remains excluded. The rebuilt
artifact contains an `8 × 1348 × 3` vector grid. It is produced by:

```bash
python -m Geomag.vector_map
```

These archives have no accelerometer, gyroscope, or attitude stream.
Consequently, the vector map is stored in the survey-phone frame rather than
being labelled as a world-frame magnetic map. The optional PF likelihood:

1. calibrates one relative yaw offset at the first valid detected step;
2. predicts the phone-frame horizontal magnetic direction from each
   particle's heading;
3. clips large angular penalties instead of killing particles;
4. disables the vector term for the current update when the norm or direction
   gate fails; and
5. always retains the existing scalar DDTW likelihood.

Conservative weight `0.10` on the physically documented survey geometry gives:

| Dataset | Scalar aligned / cross-track / endpoint | Scalar + vector aligned / cross-track / endpoint |
|---|---:|---:|
| `route1_run2` | 1.270 / 0.400 / 1.000 m | 1.212 / 0.366 / 1.012 m |
| `route2_run2` | 0.895 / 0.400 / 1.131 m | 0.901 / 0.402 / 1.158 m |

Weight `0.10` improves the selected pair's aggregate aligned and cross-track
means on the survey geometry (`1.082 → 1.056 m` and `0.400 → 0.384 m`),
while aggregate endpoint changes from `1.065` to `1.085 m`. Vector matching
therefore remains disabled by default.

For `route1_run2`, the direction gate accepts 37 of 55 detected steps. It
rejects 18 updates around a turn where gyro heading and measured magnetic
rotation disagree by more than 60 degrees. This is expected safety behaviour:
the reconstructed vector data reveals the heading inconsistency but cannot
repair missing/corrupt yaw by itself. Future acquisition should record
synchronized vector-map attitude and explicit turn events before this feature
is promoted.

## Step-length deficit and independent calibration

The selected `route2_run2` result still ended roughly one metre short in the
route's longitudinal direction. The decomposition is:

- detected steps: `14`, consistent with the capture duration and cadence;
- unscaled estimated distance: `6.602 m`;
- registered route length: `8.374 m`;
- distance ratio: `0.788`;
- estimated yaw change: `-76.7°`, versus a nominal `-90°`.

The dominant error is therefore step length, not a missed turn or display
smoothing. The capture has substantially higher per-step acceleration
variability than the slower captures. Published adaptive PDR models likewise
treat the Weinberg conversion factor as speed/person dependent or fit
frequency/variance coefficients offline; see the
[various-speed adaptive estimator](https://www.mdpi.com/1424-8220/16/9/1423)
and the
[frequency/variance model](https://www.mdpi.com/92536).

Broadening the PF's latent step-scale particles from `0.70–1.25` to
`0.65–1.45` did not solve the problem. The scalar magnetic likelihood selected
a final scale near `0.95`, and the `route2_run2` endpoint worsened from
`1.185 m` to `1.356 m`. The experiment was reverted.

The project now supports explicit independent calibration:

```bash
python -m Geomag.step_calibration \
  results/calibration_walk.json --known-distance-m 10 \
  --output-json results/step_calibration.json

python main.py --own route2_run2 --own-step-length-scale SCALE --no-show
```

The calibration command uses the unscaled detected-step history and computes
`known distance / estimated distance`. It explicitly warns that calibration
and evaluation must be different walks.

As a non-reportable upper bound, using the current test route itself produces
scale `1.2685`. Applying it reduces `route2_run2` aligned mean from `0.893` to
`0.327 m`, cross-track mean from `0.413` to `0.145 m`, and endpoint from
`1.185` to `0.223 m`. This confirms the error source, but these values are not
part of the official baseline because they leak the route distance.

## Cross-capture heading scale, magnetic progress, and map registration

The device-Z integral of `route1_run2` is `-284.503°` for a registered net
turn of `-270°`. Freezing the independently derived angular-rate scale
`270 / 284.503 = 0.9490245` and applying it to `route2_run2` produces:

| route2_run2 configuration | Aligned mean | Cross-track mean | Endpoint |
|---|---:|---:|---:|
| established baseline | 0.893 m | 0.413 m | 1.185 m |
| route1-derived gyro scale | 0.861 m | 0.384 m | 1.060 m |

This is a valid cross-route calibration experiment: the calibration value was
computed from route1 and frozen before route2 evaluation. The implementation
is exposed as `own_gyro_rate_scale` / `--own-gyro-rate-scale`; `1.0` remains
the portable default because the factor is device/session dependent.

`route2_run1` was next used as a prior same-route magnetic template. Scalar
magnitude was not repeatable enough after the turn. A causal matcher was
therefore implemented with step-to-step changes in the three phone-frame
magnetometer axes, per-axis normalization, a monotonic Viterbi/DTW state, and
a maximum template advance. Its progress estimate can weakly update the
external step scale. With gain `0.30`, plus the route1-derived gyro scale, the
exploratory route2 result is:

| Configuration | Aligned mean | Cross-track mean | Endpoint |
|---|---:|---:|---:|
| gyro scale only | 0.861 m | 0.384 m | 1.060 m |
| gyro + route2_run1 progress template | 0.837 m | 0.380 m | 0.819 m |

This result is not promoted to the official baseline. The matcher design and
gain were selected after inspecting the only available target repeat, so a
third independent route2 capture is required for an honest held-out test.
Moreover, a same-route template is a surveyed-path aid, not a solution for
arbitrary routes. The feature is disabled unless both a template JSON and a
positive correction gain are supplied.

Finally, a translation-only map registration was trained on route1. Rotation,
scale, and reflection were deliberately held fixed by the tile manifest to
limit overfitting. Magnetic-shape registration selected `(x=+1.0 m,
y=-0.5 m)`, but on route2 this worsened aligned / cross-track / endpoint error
to `0.904 / 0.411 / 1.073 m` relative to the gyro-only result. A separate
`y=+0.5 m` PF sweep appeared better, but inspection showed that it mainly
truncated the initial particle cloud at the shifted map boundary. It was
rejected as a boundary artifact. The official map offset therefore remains
`(0, 0)`.
