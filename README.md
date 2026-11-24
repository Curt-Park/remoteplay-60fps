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

### Using it with a streaming client

Any client works as the source. For PS5, [chiaki-ng](https://github.com/chiaki-ng/chiaki-ng) gives a
sharper picture than the official Remote Play app because its bitrate can be raised. Set its frame
rate to 30 so only real frames are sent, and keep its window around 1280×720 points: the picture is
processed at 720p, and a larger window only costs GPU time that the interpolation needs.

### Without capture: inside chiaki-ng

For PS5 this is the better way to run it. chiaki-ng v1.10.1 is included as a submodule and built with
smooth-anything compiled in. Decoded frames go straight to the interpolator and the result is laid
over chiaki-ng's own window, so nothing is captured and chiaki-ng does not render the video a second
time. Real frames are shown as decoded (1080p); only the middle frames are rebuilt from a 720p copy.
Wherever the two neighbouring real frames agree (HUD, text, anything standing still) a middle frame
takes its pixels from them, so only moving areas come from the rebuilt picture.

```sh
brew install qt@6 ffmpeg pkgconf opus openssl@3 cmake ninja nasm protobuf@29 speexdsp libplacebo \
             json-c miniupnpc libevent sdl2 vulkan-loader molten-vk
git submodule update --init --recursive
chiaki/build.sh        # applies chiaki/smooth-hook.patch to the submodule and builds it
chiaki/run.sh          # same settings and registered consoles as an installed chiaki-ng
```

Measured on an M1 with a 1080p GTA 6 stream: 59–60 picture changes per second on screen, 96–99 % of
the motion split evenly, 50 ms behind the decoded stream.

| Environment variable | Effect |
|---|---|
| `SMOOTH_OFF=1` | Run as plain chiaki-ng |
| `SMOOTH_NO_NATIVE=1` | Send real frames through 720p as well (slower: about 38 changes per second here) |
| `SMOOTH_SHARPEN=<n>` | Sharpen the moving areas of middle frames. Off by default: it makes them differ from the real frames |
| `SMOOTH_NO_BLEND=1` | Use the rebuilt middle frame everywhere, still areas included |
| `SMOOTH_DEBUG=1`, `SMOOTH_DIFF=1`, `SMOOTH_FLICKER=1` | Print scheduler counters, how each decoded frame was classified, and how far middle frames are from real ones in still areas |

Limits: HDR streams are not supported, and while a stream is shown chiaki-ng's own menus are hidden
under the picture. chiaki-ng is AGPL-3.0, so a binary built this way is covered by the AGPL.

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
| `--interp-size <WxH>` | Interpolate at this size instead of 1280×720. Above 1280×720's pixels the interpolator runs a slower network whose middle frames are closer to the real ones: 1284x722 measured +2.4 dB on an M2 Pro, at 15 ms instead of 8 ms a call. Not measured on an M1 |

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

It also prints how many refreshes each picture stayed up. An evenly paced 30 fps source is nearly
all 2s; many 1s and 3s mean uneven pacing, and 4 or more is a visible hitch.

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

- **One slow frame must not shift the schedule.** The time allowed for an upscale is the slowest of
  the last eight, capped at 30 ms, and a timeline that has fallen more than two steps behind is
  restarted. An estimate that rose at once and fell slowly turned every hiccup into a second of
  skipped middle frames.
- **Warm up the models.** The first super-resolution call takes over 100 ms, so each model is run on
  blank frames before capture starts.

- **Display path.** Frames are drawn into a `CAMetalLayer` (display sync off) and presented once per
  refresh from a `CADisplayLink` on its own thread. What failed, measured on screen:
  `AVSampleBufferDisplayLayer` (about 39 of 60 frames); `CALayer.contents` committed from a thread
  other than the main one (half lost) or from the main thread of a busy host (40 % lost); a
  display-synced Metal layer (presents queue up and block for a refresh after one late frame); a view
  inside a host window that has its own Metal layer (35 of 60), which is why the embedded output is a
  child window.
- **Capture rate.** `SCStreamConfiguration.minimumFrameInterval = 1/60` loses about two refreshes
  per second. Use a smaller interval.
- **Commit deadline.** A commit needs about 12.5 ms before a refresh to make it.
- **GPU contention.** GPU work running across the compositor's snapshot point makes it miss
  refreshes, so the second upscale of each pair waits until that point has passed.
- **Interpolator padding.** Above 1280×720 the interpolator's buffer attributes ask for extended
  pixels. A 1280×720 pool built from them crashed the super-resolution scaler.
- **Upscaling off the capture queue.** Each new frame needs an interpolation and two upscales. Run
  one after another on the capture queue they can outlast a 30 fps frame interval, so the real
  frame's upscale runs on a queue of its own. Measured, it and the next interpolation do not slow
  each other.
- **Faster source displays.** On a 120 Hz display each 30 fps frame is captured four times, twice
  as exact copies. Counting those copies as repeats made the next faint re-encode look like a new
  frame, so exact copies are not counted.
- **A host's own rendering.** chiaki-ng redrew its empty window 30 times a second at full size during a
  stream, which took the upscale from 6 ms to 10-11 ms and cost about ten frames a second on screen.
  The patch limits that to twice a second while smooth-anything has the video. It also needs the
  Vulkan loader: under the OpenGL fallback chiaki-ng renders on the main thread.
- **Do not judge lateness against a rounded time.** Frames fed by a host arrive at any point of the refresh
  cycle. Measured against the arrival time rounded up to a refresh, the limit flipped by a whole refresh
  whenever frames arrived near a boundary, and 3-5 % of middle frames were skipped. Measured against the
  arrival time itself, none were (2,308 frames, 753 of them within 3 ms of a boundary).
- **What is left is the source.** In a 60 fps Remote Play stream of a 30 fps game about 3 % of game frames
  are held for three refreshes instead of two, and most are not made up afterwards. Each costs one held
  refresh in the output: `out` is exactly twice `unique` in every two-second window.
- **Mixing native and rebuilt frames flickers unless they match.** Shown between native 1080p frames, a
  middle frame rebuilt from 720p was 2.0-2.6 luma levels away from its neighbours in still areas, and the
  picture shimmered at 30 Hz. Two things fixed most of it: taking still areas straight from the two real
  frames (0.14-0.8 levels), and not sharpening the middle frame, since a rebuilt frame is 0.9 levels from
  its native original unsharpened and 2.3 at sharpness 1.5.
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
