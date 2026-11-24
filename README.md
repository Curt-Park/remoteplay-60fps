# smooth-anything

30 → 60 fps frame interpolation for PS5 Remote Play on macOS.

[chiaki-ng](https://github.com/chiaki-ng/chiaki-ng) receives and decodes the stream; `smooth.m` is
compiled into it and takes each decoded frame. The real frames are shown as decoded, and between
every two of them a middle frame is generated and shown, so a 30 fps game plays at 60 fps.

Apple frameworks only (VideoToolbox, Metal, Core Animation) on top of chiaki-ng.

## Requirements

- Apple silicon Mac, macOS 27
- Xcode command line tools and Homebrew
- A PS5 registered in chiaki-ng (the build shares settings with an installed chiaki-ng)

## Build and run

```sh
brew install qt@6 ffmpeg pkgconf opus openssl@3 cmake ninja nasm protobuf@29 speexdsp libplacebo \
             json-c miniupnpc libevent sdl2 vulkan-loader molten-vk
git submodule update --init --recursive
./build.sh
./run.sh
```

`build.sh` applies `smooth-hook.patch` to the `chiaki-ng` submodule (v1.10.1) and builds it. It
unlinks Homebrew's OpenSSL 4 for the duration of the build and links it again afterwards, because
chiaki-ng links OpenSSL 3 and would otherwise pick up the wrong headers.

`run.sh` starts the built chiaki-ng with the Vulkan loader set; arguments are passed on. Without the
loader chiaki-ng falls back to OpenGL, renders on the main thread, and the stream stutters badly.

Use a 1080p SDR stream. During a stream chiaki-ng's own menus are hidden under the picture.

| Environment variable | Effect |
|---|---|
| `SMOOTH_OFF=1` | Run as plain chiaki-ng |
| `SMOOTH_SHARPEN=<n>` | Sharpen the middle frames. Off by default: it makes them differ from the real frames |
| `SMOOTH_MAX_MOTION=<n>` | Show no middle frame when the picture changed by more than this (mean luma difference, 0–255). Fast turns then run at 30 fps instead of smearing; around 12–15 is where smearing starts |
| `SMOOTH_COARSE_MOTION=<n>` | Picture change (mean luma difference) above which the second, half-size interpolation runs. Default 6; `0` runs it always, `255` never |
| `SMOOTH_DEBUG=1` | Print a status line every two seconds |
| `SMOOTH_DIFF=1` | Print how each decoded frame was classified |

## Files

| | |
|---|---|
| `chiaki-ng` | Submodule, pinned to v1.10.1 |
| `smooth-hook.patch` | Hands chiaki-ng's decoded frames to `SmoothSubmit` and stops it redrawing its own window meanwhile |
| `smooth.m`, `smooth.h` | The interpolation pipeline and its two entry points |
| `verify.m` | Measures what a window really shows on screen |
| `build.sh`, `run.sh` | Build and start |

## How it works

1. **Take the frame.** chiaki-ng's hardware-decoded frame goes to `SmoothSubmit` instead of its
   stream view. A 720p copy is made for processing.
2. **Drop repeats.** A 60 fps stream of a 30 fps game carries every game frame twice, the second
   time as a faint re-encode. A frame is a repeat when its difference from the previous one is small
   next to the last real frame's difference.
3. **Interpolate** the midpoint of the two 720p copies with `VTLowLatencyFrameInterpolation`. A scene
   cut gets no middle frame.
4. **Interpolate again at half size when the picture moves a lot.** The same pair, shrunk to 640×360
   in the corner of a 720p canvas, goes through a second interpolator session. Halving the picture
   halves the motion in pixels, so the model follows moves it loses at full size. Where the two
   results differ and the picture moved, the half-size result is used; elsewhere the sharper one.
5. **Upscale** the middle frame to 1080p with `VTLowLatencySuperResolutionScaler`.
6. **Schedule** the middle frame and the untouched real frame for consecutive display refreshes.
7. **Present** through a `CAMetalLayer` in a borderless child window over chiaki-ng's content, once
   per refresh from a display link on its own thread.

## Measured on an M1 Mac mini (macOS 27, 60 Hz display, GTA 6 at 1080p)

| | |
|---|---|
| Interpolation at 1280×720 | 6–9 ms per frame |
| With the half-size pass and merge (fast motion only) | about 14 ms per frame, still 59–60 on screen |
| Interpolation at 1920×1080 | about 100 ms, not usable |
| Upscale to 1080p | 3–6 ms per frame |
| On screen | 59–60 picture changes per second, 96–99 % evenly spaced |
| Added delay | about 55–65 ms after a frame is decoded |

Output is exactly twice the number of distinct frames the console sends. About 3 % of game frames
arrive held for three refreshes instead of two; each of those costs one held refresh.

### Checking the result

Frames handed to a layer are not necessarily frames on screen. `verify` captures a window at the
display rate and reports how often the picture really changes:

```sh
./verify --match pid:<pid of the running chiaki>
```

It needs Screen Recording permission for the terminal. A true 60 fps picture reads 57–60 changes per
second with nearly every picture up for one refresh; a 30 fps picture reads about 30, two refreshes
each. Starting the measurement disturbs the pipeline for a second or two.

## Notes for anyone changing this

- **Presentation must not depend on the host's main thread.** Setting `CALayer.contents` from the
  main thread lost 40 % of frames inside chiaki-ng, and half when done from another thread.
  `AVSampleBufferDisplayLayer` skipped a third. A display-synced Metal layer queues presents and
  blocks for a refresh after one late frame. A view above chiaki-ng's own Metal layer showed 35 of 60
  frames, hence the child window.
- **chiaki-ng redraws its empty window** 30 times a second at full size during a stream, which took
  the upscale from 6 ms to 10–11 ms. The patch limits it to twice a second.
- **Judge lateness against the arrival time, not a rounded one.** Measured from the arrival time
  rounded up to a refresh, the limit flipped by a whole refresh for frames arriving near a boundary
  and 3–5 % of middle frames were skipped.
- **One slow frame must not shift the schedule.** A timeline more than two steps ahead of what is
  feasible is restarted, and each model is warmed up on blank frames before the first real one.
- **Do not sharpen middle frames.** A frame rebuilt from 720p is 0.9 luma levels from its native
  original unsharpened and 2.3 at sharpness 1.5; alternating with native frames, that shimmered.
- **A commit needs about 12.5 ms** before a refresh to make it.
- **Fast motion smears at full size.** In a quick camera turn a foreground object moves about 100 px
  between two game frames, and the 720p interpolation returns a blur of both positions. Vertical
  moves fail sooner than horizontal ones and leave horizontal streaks. The interpolator accepts only
  1280×720 and 1920×1080 on the M1 (the more accurate 1080p model takes 93 ms), which is why the
  half-size pass pads the shrunken picture into a 720p canvas. Its result is soft, so it is used
  only where the full-size result is wrong.

Tried and dropped on the M1:

| Idea | Result |
|---|---|
| Interpolator's 1/3–2/3 mode, to fill long gaps | About 35 ms per call, too slow |
| Second upscale with MetalFX, 1080p → 1440p | 5–6 ms more per frame; output fell to 25–45 fps |
| MetalFX frame interpolation with optical flow | 31 ms at 720p, 42 ms at 1080p |
| In middle frames, taking still areas from the two real frames | Measurably closer to the real frames, no visible difference, and it erased thin objects crossing between frames |
| Showing real frames through 720p as well | Softer and slower (about 38 fps) |

Earlier versions captured a window with ScreenCaptureKit instead of taking frames from chiaki-ng.
That worked on any app but paid for a second render and a capture; it is in the history before this
layout.

## License

MIT for this repository. See [LICENSE](LICENSE). chiaki-ng is AGPL-3.0, so a binary built with it is
covered by the AGPL.

PlayStation, PS5 and PS Remote Play are trademarks of Sony Interactive Entertainment. This project
is not affiliated with or endorsed by Sony.
