# smooth-anything

Real-time 30 → 60 fps frame interpolation for any window on macOS.

It captures a window you pick, generates the frame halfway between each pair of source frames,
upscales the result to 1080p, and shows it in its own window. It was built to play 30 fps PS5 games
over PS Remote Play at 60 fps, but works on any window.

Apple frameworks only (ScreenCaptureKit, VideoToolbox, Core Animation). One Objective-C file, no
dependencies.

## Requirements

- Apple silicon Mac, macOS 26 or later
- Xcode command line tools
- Screen Recording permission for the terminal you run it from
  (System Settings → Privacy & Security → Screen & System Audio Recording)

## Build and run

```sh
./build.sh
./smooth-anything
```

Click the window to smooth in the system picker. The result appears in a separate window that
floats above other windows; move and resize it like any window. Quit by closing it or with Ctrl+C.

**Full screen:** double-click the output window, or press F while it has the keyboard (Esc or
double-click to leave). This covers the screen with a borderless panel instead of entering a macOS
full-screen Space, and the output window never activates the app, so the captured app stays
frontmost and keeps receiving controller input.

**Filling the window:** a video app usually letterboxes its 16:9 picture inside a window of another
shape. Every two seconds the lit part of the window is measured from a screenshot, and only the
16:9 area around everything seen lit so far is captured, so the output has no black borders. The
area only ever grows, so a dark scene cannot make it cut into the picture; the terminal prints
`Capturing WxH at (x, y)` whenever it changes. A window that does not hold a 16:9 picture is
captured whole, minus a standard title bar.

If the captured app replaces its window (Remote Play does this when a session starts or goes full
screen), the app's largest window is followed automatically.

| Option | Effect |
|---|---|
| `--match <text>` | Skip the picker and capture the app whose name or bundle id contains the text |
| `--fullscreen` | Start in full screen |
| `--no-upscale` | Show frames at 720p. By default every shown frame is super-resolved to 1080p, which costs one more refresh of delay (50 ms instead of 33 ms) |
| `--cushion 0` | Lowest delay; a late source frame shows as a one-refresh hold. Meant for use with `--no-upscale` |
| `--steady` | Keep one spare refresh of delay permanently for the steadiest pacing |
| `--crop-top <pt>` | Capture the whole window minus exactly this many points at the top, and turn off picture-area detection |
| `--no-stalls` | Do not print stalls. By default every gap of 0.12–3 s is printed: `source:` when the captured window did not change, `output:` when frames arrived but were not shown |
| `--passthrough` | No interpolation, for comparison |
| `--debug-diff` | Print per-frame classification |

## Checking the result

Counting frames handed to a layer does not prove they reached the screen. `verify` captures a
window at the display rate and reports how often the picture really changes:

```sh
./verify --match smooth-anything          # the interpolated output
./verify --match com.playstation.RemotePlay
```

A true 60 fps source reads about 57–60 changes per second with 90–100 % of the motion split evenly
across refreshes; a 30 fps source reads about 30 and under 15 %.

## How it works

1. **Capture** the window with ScreenCaptureKit, scaled to 1280×720. The window comes from
   `SCContentSharingPicker`.
2. **Drop repeats.** A 30 fps source on a 60 Hz display shows every frame twice, and a video stream
   re-encodes the repeat, so it is faint rather than identical. A frame counts as a repeat when its
   difference from the previous capture is small relative to the last real frame's difference; a
   second repeat in a row must also be as faint as the first, so motion that slows sharply is not
   mistaken for repeats.
3. **Interpolate** the midpoint with `VTLowLatencyFrameInterpolation`. A scene cut (a difference far
   above the recent motion level) is shown without a middle frame.
4. **Upscale** to 1080p with `VTLowLatencySuperResolutionScaler` (unless `--no-upscale`).
5. **Schedule** every frame for one specific display refresh and commit its `IOSurface` as layer
   contents for that refresh.

## Measured on an M1 Mac mini (macOS 27, 60 Hz display)

| | |
|---|---|
| Interpolation, 1280×720 | 6–9 ms per frame |
| Interpolation, 1920×1080 | about 100 ms: not usable. Sizes in between are rejected |
| Upscale 720p → 1080p | 4–6 ms per frame |
| Delay behind the source window | 50 ms (three refreshes); 33 ms with `--no-upscale` |
| On-screen output | 56–60 changes per second |

Two refreshes is the floor for this design on a 60 Hz display: the middle frame needs the next
source frame and must be shown one refresh before it, and the compositor takes its snapshot about
10 ms before each refresh, so a frame captured in one refresh cannot make the next. Upscaling adds
4–6 ms before the middle frame is ready, which pushes it past that snapshot and costs a third
refresh. For the lowest delay run `./smooth-anything --no-upscale --cushion 0`.

When the source itself falls below 30 fps there is nothing to show for the missing refreshes, and
they appear as short holds.

## Notes for anyone changing this

- `AVSampleBufferDisplayLayer` skipped refreshes whether fed by timestamps or display-immediately
  (about 39 distinct frames per second on screen). Setting `CALayer.contents` from a `CADisplayLink`
  callback does not.
- `SCStreamConfiguration.minimumFrameInterval = 1/60` loses about two refreshes per second; use a
  smaller interval.
- A commit needs roughly 12.5 ms before a refresh to make it.
- GPU work running across the compositor's snapshot point makes it miss refreshes, so the second
  upscale of each pair waits until that point has passed.
- The interpolator's 1/3–2/3 mode takes about 35 ms here, too slow to fill long gaps.

## License

MIT. See [LICENSE](LICENSE).

## Trademarks

PlayStation, PS5 and PS Remote Play are trademarks of Sony Interactive Entertainment. This project
is not affiliated with or endorsed by Sony.
