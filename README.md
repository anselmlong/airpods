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
