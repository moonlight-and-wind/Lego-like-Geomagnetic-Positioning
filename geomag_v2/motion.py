"""Turn-state segmentation and segment-level motion features."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from geomag_v2.capture import Capture


@dataclass(frozen=True)
class Turn:
    onset_index: int
    completion_index: int
    signed_angle_deg: float


@dataclass(frozen=True)
class SegmentObservation:
    index: int
    start_index: int
    end_index: int
    duration_s: float
    active_duration_s: float
    step_count: int
    sqrt_prominence_sum: float
    prominence_sum_mps2: float
    acceleration_rms_mps2: float
    heading_delta_rad: float
    time_s: np.ndarray
    magnetic_field_ut: np.ndarray
    inertial_progress: np.ndarray

    @property
    def distance_features(self) -> np.ndarray:
        return np.asarray(
            [
                self.duration_s,
                float(self.step_count),
                self.sqrt_prominence_sum,
                self.prominence_sum_mps2,
                self.acceleration_rms_mps2,
            ],
            dtype=float,
        )


def moving_average(values: np.ndarray, width: int) -> np.ndarray:
    values = np.asarray(values, dtype=float)
    width = max(1, int(width))
    if width == 1:
        return values.copy()
    return np.convolve(values, np.ones(width) / width, mode="same")


def detect_quarter_turns(
    capture: Capture,
    *,
    count: int = 4,
    departure_deg: float = 15.0,
    completion_tolerance_deg: float = 15.0,
) -> list[Turn]:
    relative = np.degrees(capture.yaw_rad - capture.yaw_rad[0])
    tail = relative[-max(10, relative.size // 20) :]
    direction = -1.0 if float(np.median(tail)) < 0.0 else 1.0
    directed = direction * relative
    turns: list[Turn] = []
    cursor = 0
    for number in range(1, count + 1):
        onset_candidates = np.flatnonzero(
            (np.arange(directed.size) >= cursor)
            & (directed >= (number - 1) * 90.0 + departure_deg)
        )
        if onset_candidates.size == 0:
            break
        onset = int(onset_candidates[0])
        completion_candidates = np.flatnonzero(
            (np.arange(directed.size) >= onset)
            & (directed >= number * 90.0 - completion_tolerance_deg)
        )
        if completion_candidates.size == 0:
            break
        completion = int(completion_candidates[0])
        turns.append(
            Turn(
                onset,
                completion,
                float(relative[completion] - relative[onset]),
            )
        )
        cursor = completion + 1
    if len(turns) != count:
        raise ValueError(
            f"{capture.dataset_key}: expected {count} quarter turns, found {len(turns)}"
        )
    return turns


def _peak_events(
    capture: Capture,
    turns: list[Turn],
    *,
    minimum_interval_s: float = 0.55,
) -> list[tuple[int, float]]:
    dt = np.diff(capture.time_s)
    sample_rate = 1.0 / float(np.median(dt[dt > 0.0]))
    vertical = capture.user_acceleration_mps2[:, 2]
    detrended = vertical - moving_average(vertical, round(0.8 * sample_rate))
    signal = moving_average(detrended, round(0.06 * sample_rate))
    endpoint = turns[-1].onset_index
    centered = signal[: endpoint + 1] - float(np.median(signal[: endpoint + 1]))
    robust_sigma = float(1.4826 * np.median(np.abs(centered)))
    threshold = max(0.18, 1.6 * robust_sigma)
    radius = max(2, round(0.35 * sample_rate))
    candidates: list[tuple[int, float]] = []
    for index in range(1, endpoint):
        if not (signal[index] > signal[index - 1] and signal[index] >= signal[index + 1]):
            continue
        left = signal[max(0, index - radius) : index + 1]
        right = signal[index : min(signal.size, index + radius + 1)]
        prominence = float(signal[index] - max(float(left.min()), float(right.min())))
        if prominence >= threshold:
            candidates.append((index, prominence))

    accepted: list[tuple[int, float]] = []
    gap = max(1, round(minimum_interval_s * sample_rate))
    for candidate in candidates:
        if not accepted or candidate[0] - accepted[-1][0] >= gap:
            accepted.append(candidate)
        elif candidate[1] > accepted[-1][1]:
            accepted[-1] = candidate
    return [
        candidate
        for candidate in accepted
        if not any(turn.onset_index <= candidate[0] <= turn.completion_index for turn in turns)
    ]


def _activity_progress(acceleration: np.ndarray) -> np.ndarray:
    centered = acceleration - np.median(acceleration, axis=0)
    activity = np.linalg.norm(centered, axis=1)
    activity = moving_average(activity, max(1, round(activity.size / 100)))
    activity = np.maximum(activity - np.percentile(activity, 15), 0.0)
    cumulative = np.concatenate(([0.0], np.cumsum(activity[1:])))
    if cumulative[-1] <= 1e-9:
        return np.linspace(0.0, 1.0, acceleration.shape[0])
    return cumulative / cumulative[-1]


def segment_capture(capture: Capture) -> tuple[list[Turn], list[SegmentObservation]]:
    turns = detect_quarter_turns(capture)
    boundaries = [
        (0, turns[0].onset_index),
        (turns[0].completion_index, turns[1].onset_index),
        (turns[1].completion_index, turns[2].onset_index),
        (turns[2].completion_index, turns[3].onset_index),
    ]
    peaks = _peak_events(capture, turns)
    first_heading = None
    output = []
    for index, (start, end) in enumerate(boundaries):
        end = max(start + 1, end)
        segment_peaks = [(sample, value) for sample, value in peaks if start <= sample <= end]
        peak_times = np.asarray([capture.time_s[sample] for sample, _ in segment_peaks])
        if peak_times.size >= 2:
            active_duration = float(
                peak_times[-1] - peak_times[0] + np.median(np.diff(peak_times))
            )
        elif peak_times.size == 1:
            active_duration = 0.65
        else:
            active_duration = 0.0
        acceleration = capture.user_acceleration_mps2[start : end + 1]
        centered = acceleration - np.median(acceleration, axis=0)
        rms = float(np.sqrt(np.mean(np.sum(centered * centered, axis=1))))
        heading = float(np.angle(np.mean(np.exp(1j * capture.yaw_rad[start : end + 1]))))
        if first_heading is None:
            first_heading = heading
        output.append(
            SegmentObservation(
                index=index,
                start_index=start,
                end_index=end,
                duration_s=float(capture.time_s[end] - capture.time_s[start]),
                active_duration_s=active_duration,
                step_count=len(segment_peaks),
                sqrt_prominence_sum=float(
                    sum(np.sqrt(value) for _, value in segment_peaks)
                ),
                prominence_sum_mps2=float(sum(value for _, value in segment_peaks)),
                acceleration_rms_mps2=rms,
                heading_delta_rad=float(np.angle(np.exp(1j * (heading - first_heading)))),
                time_s=capture.time_s[start : end + 1].copy(),
                magnetic_field_ut=capture.magnetic_field_ut[start : end + 1].copy(),
                inertial_progress=_activity_progress(acceleration),
            )
        )
    return turns, output
