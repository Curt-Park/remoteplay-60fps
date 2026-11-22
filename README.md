# smooth-anything

Real-time 30 → 60 fps frame interpolation for any window on macOS.

It captures a window, generates the frame halfway between each pair of source frames, and shows the
result in an overlay. It was built to play 30 fps PS5 games over PS Remote Play at 60 fps, but
`--match` points it at any app.

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
./smooth-anything --side
```

Start the source app first or later; the tool waits for its window and follows it when the app
replaces the window (Remote Play does this when a session starts or goes full screen). Quit with
Ctrl+C.

| Option | Effect |
|---|---|
| `--match <text>` | App name or bundle id to capture. Default: `com.playstation.RemotePlay` |
| `--side` | Show the result next to the source window instead of over it |
| `--upscale` | Super-resolve every shown frame from 720p to 1080p |
| `--cushion 0` | Lowest delay; a late source frame shows as a one-refresh hold |
| `--steady` | Keep one spare refresh of delay permanently for the steadiest pacing |
| `--passthrough` | No interpolation, for comparison |
| `--debug-diff` | Print per-frame classification |

Without `--side` the overlay covers the source window, takes no clicks or focus, and is visible
only while the source app is frontmost.

## Checking the result

Counting frames handed to a layer does not prove they reached the screen. `verify` captures a
window at the display rate and reports how often the picture really changes:

```sh
./verify --match smooth-anything          # the interpolated output (use with --side)
./verify --match com.playstation.RemotePlay
```

A true 60 fps source reads about 57–60 changes per second with 90–100 % of the motion split evenly
across refreshes; a 30 fps source reads about 30 and under 15 %.

## How it works

1. **Capture** the window with ScreenCaptureKit, scaled to 1280×720.
2. **Drop repeats.** A 30 fps source on a 60 Hz display shows every frame twice, and a video stream
   re-encodes the repeat, so it is faint rather than identical. A frame counts as a repeat when its
   difference from the previous capture is small relative to the last real frame's difference.
3. **Interpolate** the midpoint with `VTLowLatencyFrameInterpolation`. A scene cut (a difference far
   above the recent motion level) is shown without a middle frame.
4. **Optionally upscale** with `VTLowLatencySuperResolutionScaler`.
5. **Schedule** every frame for one specific display refresh and commit its `IOSurface` as layer
   contents for that refresh.

## Measured on an M1 Mac mini (macOS 27, 60 Hz display)

| | |
|---|---|
| Interpolation, 1280×720 | 6–9 ms per frame |
| Interpolation, 1920×1080 | about 100 ms: not usable. Sizes in between are rejected |
| Upscale 720p → 1080p | 4–6 ms per frame |
| Delay behind the source window | 33 ms (two refreshes); 50 ms with `--upscale` |
| On-screen output | 56–60 changes per second |

Two refreshes is the floor for this design on a 60 Hz display: the middle frame needs the next
source frame and must be shown one refresh before it, and the compositor takes its snapshot about
10 ms before each refresh, so a frame captured in one refresh cannot make the next.

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

## Trademarks

PlayStation, PS5 and PS Remote Play are trademarks of Sony Interactive Entertainment. This project
is not affiliated with or endorsed by Sony.
