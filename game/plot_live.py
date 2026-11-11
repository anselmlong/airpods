"""Live plot of AirPods acceleration so a jaw clench shows up as a spike."""

from __future__ import annotations

import argparse
from collections import deque

import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation

from control import DEFAULT_THRESHOLD, acceleration_magnitude
from stream import HOST, PORT, open_stream


def windowed_columns(
    history: deque[tuple[float, float, float, float, float]],
    sample_t: float,
    ax: float,
    ay: float,
    az: float,
    magnitude: float,
    window_s: float,
) -> np.ndarray:
    """Append one sample and return columns still inside the time window."""
    history.append((sample_t, ax, ay, az, magnitude))
    cutoff = sample_t - window_s
    while history and history[0][0] < cutoff:
        history.popleft()
    return np.asarray(history, dtype=float)


def main() -> None:
    parser = argparse.ArgumentParser(description="Plot live AirPods acceleration.")
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--seconds", type=float, default=5.0, help="width of the time window")
    args = parser.parse_args()

    stream = open_stream(args.host, args.port)
    history: deque[tuple[float, float, float, float, float]] = deque()

    fig, ax = plt.subplots(figsize=(9, 4.5))
    try:
        fig.canvas.manager.set_window_title("AirPods acceleration")
    except AttributeError:
        pass
    lines = [
        ax.plot([], [], label="ax")[0],
        ax.plot([], [], label="ay")[0],
        ax.plot([], [], label="az")[0],
        ax.plot([], [], label="magnitude", linewidth=2.0)[0],
    ]
    ax.axhline(
        args.threshold,
        color="black",
        linestyle="--",
        linewidth=1,
        label="threshold",
    )
    ax.set_xlabel("seconds")
    ax.set_ylabel("g")
    ax.set_xlim(-args.seconds, 0)
    ax.set_ylim(-0.05, max(0.25, args.threshold * 2))
    ax.legend(loc="upper right")
    ax.set_title(f"jaw clench threshold {args.threshold:.2f} g")
    fig.tight_layout()

    def update(_frame: int):
        columns = None
        for sample in stream.drain():
            magnitude = acceleration_magnitude(sample.ax, sample.ay, sample.az)
            columns = windowed_columns(
                history, sample.t, sample.ax, sample.ay, sample.az, magnitude, args.seconds
            )
        if columns is None:
            return lines
        times = columns[:, 0] - columns[-1, 0]
        for index, line in enumerate(lines, start=1):
            line.set_data(times, columns[:, index])
        values = columns[:, 1:]
        low = min(-0.05, float(values.min()) - 0.02)
        high = max(args.threshold * 1.4, float(values.max()) + 0.02, 0.2)
        ax.set_ylim(low, high)
        return lines

    def on_close(_event: object) -> None:
        stream.close()

    fig.canvas.mpl_connect("close_event", on_close)
    animation = FuncAnimation(fig, update, interval=50, blit=False)
    try:
        plt.show()
    finally:
        stream.close()
        del animation


if __name__ == "__main__":
    main()
