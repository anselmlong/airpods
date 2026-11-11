"""Neutral pose, dead-zone steer, and jaw-clench detection."""

from __future__ import annotations

import math
from collections import deque
from collections.abc import Iterable
from dataclasses import dataclass

from stream import Sample

DEFAULT_THRESHOLD = 0.02
DEFAULT_DEAD_ZONE = math.radians(5.0)
DEFAULT_WINDOW_S = 0.15
DEFAULT_REFRACTORY_S = 0.40
DEFAULT_ATTITUDE_GATE = math.radians(8.0)
DEFAULT_CALIBRATION_S = 0.5
DEFAULT_SENSITIVITY = 1.0
MIN_CALIBRATION_SAMPLES = 3


def acceleration_magnitude(ax: float, ay: float, az: float) -> float:
    return math.sqrt(ax * ax + ay * ay + az * az)


def wrap_angle(angle: float) -> float:
    """Shortest signed angle, in radians, wrapped into [-pi, pi]."""
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


def dead_zone_velocity(theta: float, dead_zone: float, sensitivity: float) -> float:
    """Velocity control: 0 inside the dead zone, then k times the excess angle."""
    if abs(theta) < dead_zone:
        return 0.0
    return sensitivity * (theta - math.copysign(dead_zone, theta))


@dataclass(frozen=True)
class ControlState:
    calibrating: bool
    yaw: float
    pitch: float
    roll: float
    vx: float
    vy: float
    ax: float
    ay: float
    az: float
    magnitude: float
    clench: bool


class Controller:
    """Calibrate a neutral pose, then map yaw/pitch and detect jaw clenches.

    A clench is a short acceleration spike whose attitude barely changes.
    Head turns move yaw, pitch, or roll and are rejected.
    """

    def __init__(
        self,
        threshold: float = DEFAULT_THRESHOLD,
        sensitivity: float = DEFAULT_SENSITIVITY,
        dead_zone: float = DEFAULT_DEAD_ZONE,
        window_s: float = DEFAULT_WINDOW_S,
        refractory_s: float = DEFAULT_REFRACTORY_S,
        attitude_gate: float = DEFAULT_ATTITUDE_GATE,
        calibration_s: float = DEFAULT_CALIBRATION_S,
    ) -> None:
        self.threshold = threshold
        self.sensitivity = sensitivity
        self.dead_zone = dead_zone
        self.window_s = window_s
        self.refractory_s = refractory_s
        self.attitude_gate = attitude_gate
        self.calibration_s = calibration_s
        self._cal_samples: list[Sample] = []
        self._cal_start: float | None = None
        self._yaw0 = 0.0
        self._pitch0 = 0.0
        self._roll0 = 0.0
        self._calibrated = False
        self._window: deque[Sample] = deque()
        self._armed = False
        self._prev_t: float | None = None
        self._last_fire = -1e9

    @property
    def calibrated(self) -> bool:
        return self._calibrated

    def update(self, sample: Sample) -> ControlState:
        magnitude = acceleration_magnitude(sample.ax, sample.ay, sample.az)
        if self._cal_start is None:
            self._cal_start = sample.t
        if not self._calibrated:
            self._cal_samples.append(sample)
            elapsed = sample.t - self._cal_start
            if elapsed >= self.calibration_s and len(self._cal_samples) >= MIN_CALIBRATION_SAMPLES:
                count = len(self._cal_samples)
                self._yaw0 = sum(item.yaw for item in self._cal_samples) / count
                self._pitch0 = sum(item.pitch for item in self._cal_samples) / count
                self._roll0 = sum(item.roll for item in self._cal_samples) / count
                self._calibrated = True
                self._window.clear()
                self._armed = False
                self._prev_t = None
            else:
                return self._state(sample, magnitude, 0.0, 0.0, 0.0, 0.0, 0.0, False)

        yaw = wrap_angle(sample.yaw - self._yaw0)
        pitch = wrap_angle(sample.pitch - self._pitch0)
        roll = wrap_angle(sample.roll - self._roll0)
        vx = dead_zone_velocity(yaw, self.dead_zone, self.sensitivity)
        vy = dead_zone_velocity(pitch, self.dead_zone, self.sensitivity)
        clench = self._detect_clench(sample)
        return self._state(sample, magnitude, yaw, pitch, roll, vx, vy, clench)

    def _detect_clench(self, sample: Sample) -> bool:
        if self._prev_t is not None and sample.t - self._prev_t > self.window_s:
            self._armed = False
        self._prev_t = sample.t
        self._window.append(sample)
        cutoff = sample.t - self.window_s
        while self._window and self._window[0].t < cutoff:
            self._window.popleft()

        score = max(
            acceleration_magnitude(item.ax, item.ay, item.az) for item in self._window
        )
        attitude_ok = (
            _span(item.yaw for item in self._window) < self.attitude_gate
            and _span(item.pitch for item in self._window) < self.attitude_gate
            and _span(item.roll for item in self._window) < self.attitude_gate
        )
        armed = score >= self.threshold and attitude_ok
        clench = (
            armed
            and not self._armed
            and (sample.t - self._last_fire) >= self.refractory_s
        )
        if clench:
            self._last_fire = sample.t
        self._armed = armed
        return clench

    def _state(
        self,
        sample: Sample,
        magnitude: float,
        yaw: float,
        pitch: float,
        roll: float,
        vx: float,
        vy: float,
        clench: bool,
    ) -> ControlState:
        return ControlState(
            calibrating=not self._calibrated,
            yaw=yaw,
            pitch=pitch,
            roll=roll,
            vx=vx,
            vy=vy,
            ax=sample.ax,
            ay=sample.ay,
            az=sample.az,
            magnitude=magnitude,
            clench=clench,
        )


def _span(values: Iterable[float]) -> float:
    numbers = list(values)
    return max(numbers) - min(numbers)
