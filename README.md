# smooth-anything

Real-time 30 → 60 fps frame interpolation for any window on macOS.

Pick a window; it generates the frame halfway between each pair of source frames, upscales and
sharpens the result to 1080p, and shows it in its own window. It was built to play 30 fps PS5 games
over PS Remote Play at 60 fps, but works on any window.

Apple frameworks only (ScreenCaptureKit, VideoToolbox, Metal, Core Animation). One Objective-C
file, no dependencies.

## Requirements

- Apple silicon Mac, macOS 27 or later (on macOS 26 super resolution rejects 1280×720 frames, so
  there is no 1080p output)
- Xcode command line tools
- Screen Recording permission for the terminal you run it from
  (System Settings → Privacy & Security → Screen & System Audio Recording)

## Usage

```sh
./build.sh
./smooth-anything
```

1. Click the window to smooth in the system picker.
2. The result appears in a separate window that floats above the others. Move and resize it freely.
3. Double-click it for full screen (double-click again or Esc to leave). F also toggles once the
   window has been clicked.
4. Quit by closing the window or with Ctrl+C.

The output window never becomes the active app, so the captured app keeps receiving keyboard and
controller input, in full screen too.

### Options

With no options it runs for the best picture: 1080p, sharpened, steadiest pacing, 50 ms behind the
source window.

| Option | Effect |
|---|---|
| `--no-upscale` | 720p output, 33–50 ms behind |
| `--low-latency` | 720p output, always 33 ms behind. A late source frame shows as a one-refresh hold |
| `--sharpen <n>` | Sharpening strength. Default 1.5, 0 is off. Above about 2.5 it amplifies compression noise |
| `--match <text>` | Skip the picker and capture the app whose name or bundle id contains the text |

For troubleshooting:

| Option | Effect |
|---|---|
| `--crop-top <pt>` | Capture the whole window minus this many points at the top, instead of detecting the picture area |
| `--no-stalls` | Do not print stalls |
| `--passthrough` | No interpolation, for comparison |
| `--debug-diff` | Print how each captured frame was classified |

### What it prints

- `Capturing WxH at (x, y) of the WxH window`: the area being captured. A video app usually
  letterboxes its 16:9 picture inside its window; only the picture is captured, so the output has
  no black borders.
- `source: no new frame for N ms`: the captured window did not change for that long. Normal on
  still screens; during play it means the source stalled.
- `output: nothing shown for N ms`: frames arrived but were not shown.
- A status line every two seconds. `out` is frames shown per second, `held refreshes` counts
  refreshes with nothing new to show, and `behind source window` is the added delay.

### Checking the result

Frames handed to a layer are not necessarily frames on screen. `verify` captures a window at the
display rate and reports how often the picture really changes:

```sh
./verify --match smooth-anything          # the interpolated output
./verify --match com.playstation.RemotePlay
```

| Source | Changes per second | Motion split evenly across refreshes |
|---|---|---|
| True 60 fps | 57–60 | 90–100 % |
| 30 fps | about 30 | under 15 % |

`--match pid:<n>` selects one process when several instances are running.

## How it works

1. **Capture** the window with ScreenCaptureKit at 1280×720. If the app replaces its window (Remote
   Play does when a session starts), its largest window is followed.
2. **Find the picture.** Every two seconds a screenshot shows which part of the window is lit. The
   16:9 area around everything seen lit so far is captured. The area only grows, so a dark scene
   cannot make it cut into the picture.
3. **Drop repeats.** A 30 fps source on a 60 Hz display shows every frame twice, and a video stream
   re-encodes the repeat, so it is faint rather than identical. A frame is a repeat when its
   difference from the previous capture is small next to the last real frame's difference.
4. **Interpolate** the midpoint with `VTLowLatencyFrameInterpolation`. A scene cut is shown without
   a middle frame.
5. **Upscale** to 1080p with `VTLowLatencySuperResolutionScaler`, then **sharpen** with an unsharp
   mask on the luma plane (a Metal compute pass).
6. **Schedule** each frame for one specific display refresh and commit its `IOSurface` as layer
   contents for that refresh.

## Limits

Measured on an M1 Mac mini, macOS 27, 60 Hz display.

| | |
|---|---|
| Interpolation at 1280×720 | 6–9 ms per frame |
| Interpolation at 1920×1080 | about 100 ms, not usable. Sizes in between are rejected |
| Upscale to 1080p plus sharpening | 6–7 ms per frame |
| Delay behind the source window | 50 ms, or 33 ms with `--low-latency` |
| On-screen output | 56–60 changes per second |

- **33 ms is the floor on a 60 Hz display.** The middle frame needs the next source frame and must
  be shown one refresh before it, and the compositor takes its snapshot about 10 ms before each
  refresh, so a captured frame cannot make the very next one. Upscaling takes long enough to cost a
  third refresh.
- **A source below 30 fps shows as short holds.** There is nothing to show for the missing frames.
- **Sharper output needs a sharper source.** A game stream carries little detail beyond 720p: on
  the same frame, a native 1080p capture looked no sharper than 720p plus super resolution.

## Notes for anyone changing this

Things that cost time to find:

- **Display path.** `AVSampleBufferDisplayLayer` skipped refreshes whether fed by timestamps or
  display-immediately (about 39 distinct frames per second on screen). Setting `CALayer.contents`
  from a `CADisplayLink` callback does not.
- **Capture rate.** `SCStreamConfiguration.minimumFrameInterval = 1/60` loses about two refreshes
  per second. Use a smaller interval.
- **Commit deadline.** A commit needs about 12.5 ms before a refresh to make it.
- **GPU contention.** GPU work running across the compositor's snapshot point makes it miss
  refreshes, so the second upscale of each pair waits until that point has passed.
- **Hidden windows.** A window completely covered by an opaque window is treated as hidden, and its
  captures arrive in bursts about 100 ms apart. The full-screen panel is therefore 0.999 opaque.
  Marking it non-opaque without real translucency was not enough.

Tried and dropped on the M1:

| Idea | Result |
|---|---|
| Interpolator's 1/3–2/3 mode, to fill long gaps | About 35 ms per call, too slow |
| Second upscale with MetalFX, 1080p → 1440p | 5–6 ms more per frame. Output fell to 25–45 fps |
| Core Image sharpening filter on the output layer | The compositor showed 24–29 fps |
| Sharpening with no overshoot at all | Barely visible. The unsharp mask in use allows a capped overshoot |
| Lanczos instead of bilinear for the final scale | No visible difference |
| Large-radius local contrast on top of the unsharp mask | More punch, but dark halos around figures |
| Capturing at 1080p and showing real frames untouched | Pacing held, but no sharper than 720p plus super resolution |

## License

MIT. See [LICENSE](LICENSE).

## Trademarks

PlayStation, PS5 and PS Remote Play are trademarks of Sony Interactive Entertainment. This project
is not affiliated with or endorsed by Sony.
