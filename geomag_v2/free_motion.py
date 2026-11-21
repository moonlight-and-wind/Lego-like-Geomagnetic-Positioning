"""Generic motion segmentation without a fixed turn count or turn angle."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from geomag_v2.capture import Capture
from geomag_v2.motion import moving_average


@dataclass(frozen=True)
class FreeTurn:
    onset_index: int
    completion_index: int
    signed_angle_deg: float


@dataclass(frozen=True)
class FreeSegment:
    index: int
    start_index: int
    end_index: int
    duration_s: float
    step_count: int
    sqrt_prominence_sum: float
    prominence_sum_mps2: float
    acceleration_rms_mps2: float
    relative_yaw_rad: np.ndarray
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


def detect_turn_regions(
    capture: Capture,
    *,
    start_rate_deg_s: float = 28.0,
    end_rate_deg_s: float = 12.0,
    minimum_angle_deg: float = 30.0,
    quiet_time_s: float = 0.18,
) -> list[FreeTurn]:
    """Detect arbitrary turn regions with angular-rate hysteresis."""
    time_s = capture.time_s
    yaw_deg = np.degrees(capture.yaw_rad)
    sample_rate = 1.0 / float(np.median(np.diff(time_s)))
    width = max(1, round(0.12 * sample_rate))
    rate = np.abs(np.gradient(yaw_deg, time_s))
    rate = moving_average(rate, width)
    quiet_samples = max(2, round(quiet_time_s * sample_rate))
    padding = max(1, round(0.08 * sample_rate))
    turns = []
    index = 0
    while index < rate.size:
        if rate[index] < start_rate_deg_s:
            index += 1
            continue
        onset = index
        last_active = index
        cursor = index + 1
        while cursor < rate.size:
            if rate[cursor] >= end_rate_deg_s:
                last_active = cursor
            if cursor - last_active >= quiet_samples:
                break
            cursor += 1
        padded_onset = max(0, onset - padding)
        completion = min(rate.size - 1, last_active + padding)
        angle = float(yaw_deg[completion] - yaw_deg[padded_onset])
        if abs(angle) >= minimum_angle_deg:
            turns.append(FreeTurn(padded_onset, completion, angle))
        index = max(cursor, onset + 1)
    return turns


def _step_peaks(capture: Capture) -> list[tuple[int, float]]:
    time_s = capture.time_s
    sample_rate = 1.0 / float(np.median(np.diff(time_s)))
    vertical = capture.user_acceleration_mps2[:, 2]
    detrended = vertical - moving_average(vertical, round(0.8 * sample_rate))
    signal = moving_average(detrended, round(0.06 * sample_rate))
    centered = signal - float(np.median(signal))
    robust_sigma = float(1.4826 * np.median(np.abs(centered)))
    threshold = max(0.18, 1.6 * robust_sigma)
    radius = max(2, round(0.35 * sample_rate))
    candidates = []
    for index in range(1, signal.size - 1):
        if not (signal[index] > signal[index - 1] and signal[index] >= signal[index + 1]):
            continue
        left = signal[max(0, index - radius) : index + 1]
        right = signal[index : min(signal.size, index + radius + 1)]
        prominence = float(signal[index] - max(float(left.min()), float(right.min())))
        if prominence >= threshold:
            candidates.append((index, prominence))
    accepted: list[tuple[int, float]] = []
    gap = max(1, round(0.55 * sample_rate))
    for candidate in candidates:
        if not accepted or candidate[0] - accepted[-1][0] >= gap:
            accepted.append(candidate)
        elif candidate[1] > accepted[-1][1]:
            accepted[-1] = candidate
    return accepted


def _activity_progress(acceleration: np.ndarray) -> np.ndarray:
    centered = acceleration - np.median(acceleration, axis=0)
    activity = np.linalg.norm(centered, axis=1)
    width = max(1, round(activity.size / 100))
    activity = moving_average(activity, width)
    activity = np.maximum(activity - np.percentile(activity, 15), 0.0)
    cumulative = np.concatenate(([0.0], np.cumsum(activity[1:])))
    if cumulative[-1] <= 1e-9:
        return np.linspace(0.0, 1.0, acceleration.shape[0])
    return cumulative / cumulative[-1]


def segment_free_motion(
    capture: Capture,
    *,
    include_trailing_segment: bool = True,
) -> tuple[list[FreeTurn], list[FreeSegment]]:
    """Return straight motion segments; turns contribute no translation."""
    turns = detect_turn_regions(capture)
    if not turns:
        raise ValueError(f"{capture.dataset_key}: no turn regions detected")
    intervals = [(0, turns[0].onset_index)]
    intervals.extend(
        (previous.completion_index, following.onset_index)
        for previous, following in zip(turns[:-1], turns[1:], strict=True)
    )
    if include_trailing_segment:
        intervals.append((turns[-1].completion_index, capture.time_s.size - 1))
    peaks = [
        peak
        for peak in _step_peaks(capture)
        if not any(turn.onset_index <= peak[0] <= turn.completion_index for turn in turns)
    ]
    sample_rate = 1.0 / float(np.median(np.diff(capture.time_s)))
    segments = []
    for interval_index, (raw_start, raw_end) in enumerate(intervals):
        segment_peaks = [peak for peak in peaks if raw_start <= peak[0] <= raw_end]
        is_trailing = include_trailing_segment and interval_index == len(intervals) - 1
        if is_trailing and not segment_peaks:
            continue
        start, end = raw_start, raw_end
        if segment_peaks:
            times = np.asarray([capture.time_s[index] for index, _ in segment_peaks])
            median_interval = float(np.median(np.diff(times))) if times.size >= 2 else 0.65
            padding = max(1, round(0.5 * median_interval * sample_rate))
            start = max(raw_start, segment_peaks[0][0] - padding)
            end = min(raw_end, segment_peaks[-1][0] + padding)
        if end <= start:
            continue
        acceleration = capture.user_acceleration_mps2[start : end + 1]
        centered = acceleration - np.median(acceleration, axis=0)
        rms = float(np.sqrt(np.mean(np.sum(centered * centered, axis=1))))
        if is_trailing and rms < 0.25:
            continue
        relative_yaw = capture.yaw_rad[start : end + 1] - capture.yaw_rad[0]
        segments.append(
            FreeSegment(
                index=len(segments),
                start_index=start,
                end_index=end,
                duration_s=float(capture.time_s[end] - capture.time_s[start]),
                step_count=len(segment_peaks),
                sqrt_prominence_sum=float(
                    sum(np.sqrt(value) for _, value in segment_peaks)
                ),
                prominence_sum_mps2=float(sum(value for _, value in segment_peaks)),
                acceleration_rms_mps2=rms,
                relative_yaw_rad=relative_yaw.copy(),
                time_s=capture.time_s[start : end + 1].copy(),
                magnetic_field_ut=capture.magnetic_field_ut[start : end + 1].copy(),
                inertial_progress=_activity_progress(acceleration),
            )
        )
    return turns, segments


def integrate_free_track(
    segments: list[FreeSegment],
    lengths_m: np.ndarray,
    *,
    initial_heading_rad: float = 0.0,
    samples_per_segment: int = 30,
) -> tuple[np.ndarray, np.ndarray]:
    """Integrate robust straight headings without angle snapping.

    The capture protocol keeps the phone facing forward and walks straight
    between detected turns.  A circular mean suppresses handheld yaw jitter,
    while every segment angle still comes from Core Motion and remains free.
    The first walking segment defines zero relative heading because the recent
    captures do not contain a surveyed absolute-heading anchor.
    """
    lengths = np.asarray(lengths_m, dtype=float)
    if lengths.size != len(segments):
        raise ValueError("Segment lengths are not aligned with motion segments.")
    points = [np.zeros(2, dtype=float)]
    corner_indices = [0]
    first_heading = float(
        np.angle(np.mean(np.exp(1j * segments[0].relative_yaw_rad)))
    )
    for segment, length in zip(segments, lengths, strict=True):
        sample_axis = np.linspace(0.0, 1.0, segment.time_s.size)
        target_axis = np.linspace(0.0, 1.0, samples_per_segment + 1)
        progress = np.interp(target_axis, sample_axis, segment.inertial_progress)
        segment_heading = float(
            np.angle(np.mean(np.exp(1j * segment.relative_yaw_rad)))
        )
        heading = np.full(
            target_axis.size,
            initial_heading_rad + segment_heading - first_heading,
        )
        for index in range(1, target_axis.size):
            distance = float(length) * max(0.0, float(progress[index] - progress[index - 1]))
            direction_heading = 0.5 * (heading[index - 1] + heading[index])
            direction = np.asarray(
                [np.cos(direction_heading), np.sin(direction_heading)], dtype=float
            )
            points.append(points[-1] + distance * direction)
        corner_indices.append(len(points) - 1)
    return np.asarray(points), np.asarray(corner_indices, dtype=int)
