"""Hands-free scrolling: nod down for the next video, nod up to go back.

Reads the same UDP motion stream as the other tools in this folder:

    ./airpods.app/Contents/MacOS/airpods --stream-only
    python game/scroll.py

The gesture logic is a plain function of (pitch, time), so it can be exercised without
AirPods or a Mac:

    python game/scroll.py --selftest     # synthetic nods, asserts what the detector emits
    python game/scroll.py --simulate     # print what it would do, no events sent
    python game/scroll.py --demo         # read the real stream, print, send nothing

Sending scroll events needs macOS and Accessibility permission for the terminal:

    pip install pyobjc-framework-Quartz
    System Settings -> Privacy & Security -> Accessibility
"""

from __future__ import annotations

import argparse
import math
import sys
import time

from stream import MotionStream

DEFAULT_NOD_DEG = 10.0
DEFAULT_CALIBRATE_S = 1.5
DEFAULT_REFRACTORY_S = 0.7
DEFAULT_RETURN_FRACTION = 0.45
SCROLL_LINES = 12


class NodDetector:
    """Turns a stream of pitch samples into +1 (next), -1 (back) or 0 (nothing).

    Neutral pitch is the mean of the first `calibrate_s` seconds, so the gesture is
    relative to however you happen to be sitting. A nod fires once, then the head has
    to come back within `return_fraction` of the way to neutral before it can fire again,
    and two gestures are never closer than `refractory_s`.
    """

    def __init__(
        self,
        nod_deg: float = DEFAULT_NOD_DEG,
        calibrate_s: float = DEFAULT_CALIBRATE_S,
        refractory_s: float = DEFAULT_REFRACTORY_S,
        return_fraction: float = DEFAULT_RETURN_FRACTION,
    ) -> None:
        self.nod = abs(nod_deg)
        self.calibrate_s = calibrate_s
        self.refractory_s = refractory_s
        self.return_deg = self.nod * return_fraction
        self.neutral: float | None = None
        self._calibrating_since: float | None = None
        self._sum = 0.0
        self._n = 0
        self._armed = True
        self._last = -math.inf

    @property
    def calibrated(self) -> bool:
        return self.neutral is not None

    def feed(self, pitch: float, t: float) -> int:
        if self.neutral is None:
            if self._calibrating_since is None:
                self._calibrating_since = t
            self._sum += pitch
            self._n += 1
            if t - self._calibrating_since >= self.calibrate_s:
                self.neutral = self._sum / self._n
            return 0

        tilt = math.degrees(pitch - self.neutral)  # positive = chin down

        if self._armed and t - self._last >= self.refractory_s:
            if tilt > self.nod:
                self._armed, self._last = False, t
                return 1
            if tilt < -self.nod:
                self._armed, self._last = False, t
                return -1
        elif not self._armed and abs(tilt) < self.return_deg:
            self._armed = True
        return 0


def post_scroll(lines: int) -> None:
    import Quartz  # imported here so the detector and --selftest run anywhere

    event = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, lines)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def post_key(code: int) -> None:
    import Quartz

    for down in (True, False):
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateKeyboardEvent(None, code, down))


def act(direction: int, keys: bool, reverse: bool) -> None:
    step = SCROLL_LINES if reverse else -SCROLL_LINES
    if keys:
        post_key(125 if direction > 0 else 126)  # down / up arrow
    else:
        post_scroll(step * direction)


def read_stream(host: str, port: int):
    stream = MotionStream(host, port)
    while True:
        sample = stream.read()
        if sample is not None:
            yield sample.pitch, sample.t


def simulate(step_s: float = 0.02, cycles: int = 3):
    """A head that holds still, nods down, returns, then nods up: enough to watch the detector work."""
    t = 0.0

    def ramp(a: float, b: float, dur: float):
        nonlocal t
        n = max(1, int(dur / step_s))
        for i in range(n):
            yield math.radians(a + (b - a) * (i + 1) / n), t
            t += step_s

    def hold(deg: float, dur: float):
        nonlocal t
        for _ in range(max(1, int(dur / step_s))):
            yield math.radians(deg), t
            t += step_s

    yield from hold(0.0, 2.0)          # calibration window
    for _ in range(cycles):
        yield from ramp(0.0, 22.0, 0.6)   # nod down
        yield from ramp(22.0, 0.0, 0.4)   # back to neutral
        yield from hold(0.0, 1.0)
        yield from ramp(0.0, -22.0, 0.6)  # nod up
        yield from ramp(-22.0, 0.0, 0.4)
        yield from hold(0.0, 1.0)


def selftest() -> int:
    det = NodDetector()
    events = [(round(t, 2), d) for t, d in ((t, det.feed(p, t)) for p, t in simulate()) if d]
    expected = [1, -1, 1, -1, 1, -1]
    got = [d for _, d in events]
    ok = got == expected
    print(f"selftest: {len(events)} gestures {got} — {'ok' if ok else 'FAILED, expected ' + str(expected)}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Hands-free scrolling from the AirPods motion stream.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--keys", action="store_true", help="send arrow keys instead of scroll events")
    ap.add_argument("--reverse", action="store_true", help="flip the scroll direction")
    ap.add_argument("--nod", type=float, default=DEFAULT_NOD_DEG, help="degrees of tilt that count as a nod")
    ap.add_argument("--demo", action="store_true", help="print gestures, send no events")
    ap.add_argument("--simulate", action="store_true", help="use a synthetic head, no AirPods needed")
    ap.add_argument("--selftest", action="store_true", help="check the detector against synthetic nods")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    det = NodDetector(nod_deg=args.nod)
    source = simulate() if args.simulate else read_stream(args.host, args.port)
    print("calibrating: hold still" if not args.simulate else "simulating a head", flush=True)

    for pitch, t in source:
        direction = det.feed(pitch, t)
        if not direction:
            continue
        print("next" if direction > 0 else "back", flush=True)
        if not args.demo and not args.simulate:
            act(direction, args.keys, args.reverse)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
