# airpods

A macOS pointer that follows where you look. Clench your jaw to left-click. Press `\` to pause and resume tracking.

AirPods supply the jaw signal through headphone motion. The cursor itself comes from the camera: Vision face landmarks, a short calibration, and a ridge fit of pupil position inside each eye plus face pose.

Requires macOS 14, AirPods that report headphone motion, and a camera.

## Run

```bash
./build.sh
./airpods.app/Contents/MacOS/airpods
```

`build.sh` compiles a release binary, wraps it in `airpods.app`, and ad-hoc signs it. Each rebuild changes that signature, so macOS may ask for Camera, Motion & Fitness, and Accessibility again. Allow this app, not only the terminal.

On launch, look at each yellow dot until calibration finishes (25 dots). Stay in the same seat afterward. Control-C quits.

| Input | Action |
| --- | --- |
| Where you look | Moves the pointer |
| Jaw clench | Left click |
| `\` | Pause or resume tracking |

Clicks are ignored while tracking is paused, and until calibration finishes.

## Motion stream

Headphone motion is also sent as UDP text, `yaw,pitch,roll,ax,ay,az`, to `127.0.0.1:9999`.

```bash
./airpods.app/Contents/MacOS/airpods --stream-only
./airpods.app/Contents/MacOS/airpods --stream-only 127.0.0.1 9999
```

`--stream-only` skips the camera and the pointer. The tools in `game/` read that stream:

```bash
pip install -r game/requirements.txt
python game/plot_live.py
python game/record.py --label clench --output data/clench.csv
```

## Hands-free scrolling

`game/scroll.py` turns head gestures into scroll events, so a feed advances without touching
anything: nod down for the next video, nod up to go back. It reads the same motion stream, so it
needs `--stream-only` running and nothing else from this app.

```bash
pip install pyobjc-framework-Quartz          # macOS only
./airpods.app/Contents/MacOS/airpods --stream-only &
python game/scroll.py
```

Hold still for the first 1.5 seconds: that is where "neutral" comes from, so the gesture is relative
to how you are actually sitting. Then nod. `--nod 7` makes it more sensitive, `--keys` sends arrow
keys instead of wheel events, `--reverse` flips the scroll direction.

Nothing needs AirPods to try it:

```bash
python game/scroll.py --selftest    # synthetic nods, asserts the gestures it emits
python game/scroll.py --simulate    # watch a synthetic head drive it, sends no events
```

Sending events needs Accessibility permission for the terminal (System Settings -> Privacy &
Security -> Accessibility). It scrolls whatever window has focus, so it works on the web players
(TikTok, Reels, Shorts), not in the phone apps.
