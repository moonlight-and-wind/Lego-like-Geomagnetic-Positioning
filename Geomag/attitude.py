"""Stateful quaternion attitude estimation for handheld-phone PDR."""

from __future__ import annotations

import math

import numpy as np

from Geomag.distance import _wrap_angle_pi


def _normalize_quaternion(quaternion):
    q = np.asarray(quaternion, dtype=float)
    norm = float(np.linalg.norm(q))
    if norm <= 1e-12:
        return np.asarray([1.0, 0.0, 0.0, 0.0], dtype=float)
    return q / norm


def _quaternion_multiply(left, right):
    w1, x1, y1, z1 = np.asarray(left, dtype=float)
    w2, x2, y2, z2 = np.asarray(right, dtype=float)
    return np.asarray(
        [
            w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
            w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
            w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
            w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
        ],
        dtype=float,
    )


def _quaternion_from_euler(roll, pitch, yaw):
    cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)
    cy, sy = math.cos(yaw * 0.5), math.sin(yaw * 0.5)
    return _normalize_quaternion(
        [
            cr * cp * cy + sr * sp * sy,
            sr * cp * cy - cr * sp * sy,
            cr * sp * cy + sr * cp * sy,
            cr * cp * sy - sr * sp * cy,
        ]
    )


def _yaw_from_quaternion(quaternion):
    w, x, y, z = np.asarray(quaternion, dtype=float)
    return _wrap_angle_pi(
        math.atan2(
            2.0 * (w * z + x * y),
            1.0 - 2.0 * (y * y + z * z),
        )
    )


def _rotate_world_to_body(quaternion, vector):
    q = np.asarray(quaternion, dtype=float)
    conjugate = np.asarray([q[0], -q[1], -q[2], -q[3]], dtype=float)
    pure = np.asarray([0.0, *np.asarray(vector, dtype=float)], dtype=float)
    rotated = _quaternion_multiply(
        _quaternion_multiply(conjugate, pure),
        q,
    )
    return rotated[1:]


def _tilt_compensated_compass(acc, mag):
    acc = np.asarray(acc, dtype=float)
    mag = np.asarray(mag, dtype=float)
    acc_norm = float(np.linalg.norm(acc))
    mag_norm = float(np.linalg.norm(mag))
    if acc_norm <= 1e-12 or mag_norm <= 1e-12:
        return None
    ax, ay, az = acc / acc_norm
    mx, my, mz = mag
    roll = math.atan2(float(ay), float(az))
    pitch = math.atan2(float(-ax), math.sqrt(float(ay * ay + az * az)))
    mx_horizontal = mx * math.cos(pitch) + mz * math.sin(pitch)
    my_horizontal = (
        mx * math.sin(roll) * math.sin(pitch)
        + my * math.cos(roll)
        - mz * math.sin(roll) * math.cos(pitch)
    )
    return _wrap_angle_pi(math.atan2(-my_horizontal, mx_horizontal))


class QuaternionHeadingEstimator:
    """Gyro-propagated quaternion with gravity and gated magnetic corrections.

    The quaternion maps body coordinates to a local world frame. Accelerometer
    feedback only corrects roll/pitch. Magnetometer yaw feedback is optional
    and rejected when its norm or direction is inconsistent.
    """

    def __init__(
        self,
        initial_heading_rad=None,
        heading_offset_deg=0.0,
        nominal_dt=0.01,
        max_dt_s=0.10,
        assume_face_up=True,
        gravity_gain=1.5,
        acc_reject_mps2=2.0,
        calibrate_gyro_bias=True,
        stationary_gyro_threshold=0.12,
        stationary_acc_tolerance=0.30,
        stationary_min_duration_s=0.25,
        use_magnetometer=False,
        magnetic_yaw_gain=0.08,
        magnetic_norm_tolerance_ratio=0.15,
        magnetic_reject_deg=45.0,
        magnetic_correction_limit_deg_s=12.0,
    ):
        self.initial_heading_rad = (
            None if initial_heading_rad is None else float(initial_heading_rad)
        )
        self.heading_offset_rad = math.radians(float(heading_offset_deg))
        self.nominal_dt = max(1e-4, float(nominal_dt))
        self.max_dt_s = max(self.nominal_dt, float(max_dt_s))
        self.assume_face_up = bool(assume_face_up)
        self.gravity_gain = max(0.0, float(gravity_gain))
        self.acc_reject_mps2 = max(1e-6, float(acc_reject_mps2))
        self.calibrate_gyro_bias = bool(calibrate_gyro_bias)
        self.stationary_gyro_threshold = max(
            0.0, float(stationary_gyro_threshold)
        )
        self.stationary_acc_tolerance = max(
            0.0, float(stationary_acc_tolerance)
        )
        self.stationary_min_duration_s = max(
            0.0, float(stationary_min_duration_s)
        )
        self.use_magnetometer = bool(use_magnetometer)
        self.magnetic_yaw_gain = max(0.0, float(magnetic_yaw_gain))
        self.magnetic_norm_tolerance_ratio = max(
            0.0, float(magnetic_norm_tolerance_ratio)
        )
        self.magnetic_reject_rad = math.radians(float(magnetic_reject_deg))
        self.magnetic_correction_limit_rad_s = math.radians(
            max(0.0, float(magnetic_correction_limit_deg_s))
        )

        self.quaternion = None
        self.last_time = None
        self.gyro_bias = np.zeros(3, dtype=float)
        self.gyro_bias_sum = np.zeros(3, dtype=float)
        self.gyro_bias_samples = 0
        self.gyro_bias_pending_sum = np.zeros(3, dtype=float)
        self.gyro_bias_pending_samples = 0
        self.gyro_bias_pending_start_time = None
        self.gyro_bias_stationary_confirmed = False
        self.compass_alignment_rad = None
        self.magnetic_norm_baseline = None
        self.diagnostics = {}

    def _initialize(self, acc, mag):
        yaw = (
            self.initial_heading_rad
            if self.initial_heading_rad is not None
            else self.heading_offset_rad
        )
        if self.assume_face_up:
            roll = 0.0
            pitch = 0.0
        else:
            acc_norm = max(float(np.linalg.norm(acc)), 1e-12)
            ax, ay, az = np.asarray(acc, dtype=float) / acc_norm
            roll = math.atan2(float(ay), float(az))
            pitch = math.atan2(
                float(-ax),
                math.sqrt(float(ay * ay + az * az)),
            )
        raw_compass = _tilt_compensated_compass(acc, mag)
        if self.initial_heading_rad is None and raw_compass is not None:
            yaw = _wrap_angle_pi(raw_compass + self.heading_offset_rad)
        self.quaternion = _quaternion_from_euler(roll, pitch, yaw)
        if raw_compass is not None:
            self.compass_alignment_rad = _wrap_angle_pi(yaw - raw_compass)
        mag_norm = float(np.linalg.norm(mag))
        if mag_norm > 1e-12:
            self.magnetic_norm_baseline = mag_norm

    def _update_bias(self, acc, gyro, sample_time):
        acc_norm = float(np.linalg.norm(acc))
        gyro_norm = float(np.linalg.norm(gyro))
        stationary = (
            abs(acc_norm - 9.80665) <= self.stationary_acc_tolerance
            and gyro_norm <= self.stationary_gyro_threshold
        )
        if self.calibrate_gyro_bias and stationary:
            if self.gyro_bias_stationary_confirmed:
                self.gyro_bias_sum += gyro
                self.gyro_bias_samples += 1
            else:
                if self.gyro_bias_pending_samples == 0:
                    self.gyro_bias_pending_start_time = sample_time
                self.gyro_bias_pending_sum += gyro
                self.gyro_bias_pending_samples += 1
                pending_duration = (
                    self.gyro_bias_pending_samples * self.nominal_dt
                    if sample_time is None
                    or self.gyro_bias_pending_start_time is None
                    else sample_time
                    - self.gyro_bias_pending_start_time
                    + self.nominal_dt
                )
                if pending_duration >= self.stationary_min_duration_s:
                    self.gyro_bias_sum += self.gyro_bias_pending_sum
                    self.gyro_bias_samples += self.gyro_bias_pending_samples
                    self.gyro_bias_pending_sum[:] = 0.0
                    self.gyro_bias_pending_samples = 0
                    self.gyro_bias_stationary_confirmed = True
            if self.gyro_bias_samples:
                self.gyro_bias = self.gyro_bias_sum / float(
                    self.gyro_bias_samples
                )
        elif not stationary:
            self.gyro_bias_pending_sum[:] = 0.0
            self.gyro_bias_pending_samples = 0
            self.gyro_bias_pending_start_time = None
            self.gyro_bias_stationary_confirmed = False
        return stationary

    def _propagate(self, acc, gyro, dt):
        acc_norm = float(np.linalg.norm(acc))
        acc_quality = float(
            np.clip(
                1.0 - abs(acc_norm - 9.80665) / self.acc_reject_mps2,
                0.0,
                1.0,
            )
        )
        corrected_gyro = np.asarray(gyro, dtype=float) - self.gyro_bias
        if acc_norm > 1e-12 and acc_quality > 0.0:
            measured_gravity_body = np.asarray(acc, dtype=float) / acc_norm
            estimated_gravity_body = _rotate_world_to_body(
                self.quaternion,
                [0.0, 0.0, 1.0],
            )
            gravity_error = np.cross(
                measured_gravity_body,
                estimated_gravity_body,
            )
            corrected_gyro += (
                self.gravity_gain * acc_quality * gravity_error
            )
        else:
            gravity_error = np.zeros(3, dtype=float)

        angular_speed = float(np.linalg.norm(corrected_gyro))
        if angular_speed > 1e-12 and dt > 0.0:
            half_angle = 0.5 * angular_speed * dt
            delta_quaternion = np.asarray(
                [
                    math.cos(half_angle),
                    *(
                        corrected_gyro
                        / angular_speed
                        * math.sin(half_angle)
                    ),
                ],
                dtype=float,
            )
            self.quaternion = _normalize_quaternion(
                _quaternion_multiply(
                    self.quaternion,
                    delta_quaternion,
                )
            )
        return corrected_gyro, gravity_error, acc_quality

    def _correct_magnetic_yaw(self, acc, mag, dt):
        raw_compass = _tilt_compensated_compass(acc, mag)
        mag_norm = float(np.linalg.norm(mag))
        if (
            raw_compass is None
            or self.compass_alignment_rad is None
            or self.magnetic_norm_baseline is None
        ):
            return None, None, False, 0.0, 0.0

        compass_heading = _wrap_angle_pi(
            raw_compass + self.compass_alignment_rad
        )
        quaternion_yaw = _yaw_from_quaternion(self.quaternion)
        innovation = _wrap_angle_pi(compass_heading - quaternion_yaw)
        norm_ratio_error = abs(
            mag_norm - self.magnetic_norm_baseline
        ) / max(self.magnetic_norm_baseline, 1e-12)
        accepted = bool(
            self.use_magnetometer
            and norm_ratio_error <= self.magnetic_norm_tolerance_ratio
            and abs(innovation) <= self.magnetic_reject_rad
        )
        correction = 0.0
        if accepted and dt > 0.0:
            correction = self.magnetic_yaw_gain * innovation * dt
            limit = self.magnetic_correction_limit_rad_s * dt
            correction = float(np.clip(correction, -limit, limit))
            yaw_delta = _quaternion_from_euler(0.0, 0.0, correction)
            self.quaternion = _normalize_quaternion(
                _quaternion_multiply(yaw_delta, self.quaternion)
            )
            self.magnetic_norm_baseline = (
                0.995 * self.magnetic_norm_baseline + 0.005 * mag_norm
            )
        return (
            compass_heading,
            innovation,
            accepted,
            correction,
            norm_ratio_error,
        )

    def update(self, samples):
        if samples is None:
            return self.heading
        for item in samples:
            if item is None or len(item) < 3:
                continue
            acc = np.asarray(item[0][:3], dtype=float)
            gyro = np.asarray(item[1][:3], dtype=float)
            mag = np.asarray(item[2][:3], dtype=float)
            sample_time = (
                None
                if len(item) < 4 or item[3] is None
                else float(item[3])
            )
            if self.quaternion is None:
                self._initialize(acc, mag)
                self.last_time = sample_time
                self._update_bias(acc, gyro, sample_time)
                continue
            if (
                sample_time is not None
                and self.last_time is not None
                and sample_time <= self.last_time
            ):
                continue
            dt = (
                self.nominal_dt
                if sample_time is None or self.last_time is None
                else float(sample_time - self.last_time)
            )
            dt = float(np.clip(dt, 0.0, self.max_dt_s))
            stationary = self._update_bias(acc, gyro, sample_time)
            corrected_gyro, gravity_error, acc_quality = self._propagate(
                acc,
                gyro,
                dt,
            )
            (
                compass_heading,
                magnetic_innovation,
                magnetic_accepted,
                magnetic_correction,
                magnetic_norm_ratio_error,
            ) = self._correct_magnetic_yaw(acc, mag, dt)
            self.last_time = sample_time
            self.diagnostics = {
                "method": "quaternion",
                "heading_rad": float(self.heading),
                "heading_deg": float(math.degrees(self.heading)),
                "quaternion_wxyz": self.quaternion.astype(float).tolist(),
                "dt_s": dt,
                "gyro_bias_xyz_rad_s": self.gyro_bias.astype(float).tolist(),
                "gyro_bias_samples": int(self.gyro_bias_samples),
                "gyro_bias_pending_samples": int(
                    self.gyro_bias_pending_samples
                ),
                "gyro_bias_stationary_confirmed": bool(
                    self.gyro_bias_stationary_confirmed
                ),
                "corrected_gyro_xyz_rad_s": corrected_gyro.astype(float).tolist(),
                "gravity_error_xyz": gravity_error.astype(float).tolist(),
                "acc_quality": float(acc_quality),
                "stationary": bool(stationary),
                "use_magnetometer": bool(self.use_magnetometer),
                "yaw_compass_deg": (
                    None
                    if compass_heading is None
                    else float(math.degrees(compass_heading))
                ),
                "magnetic_innovation_deg": (
                    None
                    if magnetic_innovation is None
                    else float(math.degrees(magnetic_innovation))
                ),
                "magnetic_accepted": bool(magnetic_accepted),
                "magnetic_correction_deg": float(
                    math.degrees(magnetic_correction)
                ),
                "magnetic_norm_uT": float(np.linalg.norm(mag)),
                "magnetic_norm_baseline_uT": self.magnetic_norm_baseline,
                "magnetic_norm_ratio_error": float(
                    magnetic_norm_ratio_error
                ),
            }
        return self.heading

    @property
    def heading(self):
        if self.quaternion is None:
            return float(
                self.initial_heading_rad
                if self.initial_heading_rad is not None
                else self.heading_offset_rad
            )
        return float(_yaw_from_quaternion(self.quaternion))
