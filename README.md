# smooth-anything

30 → 60 fps frame interpolation for PS5 Remote Play on macOS.

Many PS5 games run at 30 fps, and some (GTA 6) have no 60 fps mode at all. smooth-anything is built
into [chiaki-ng](https://github.com/chiaki-ng/chiaki-ng), the open-source Remote Play client, and
inserts a generated frame between every two game frames, so the game plays at 60 fps on a Mac. It
uses only Apple frameworks (VideoToolbox, Metal, Core Animation).

MIT licensed; a binary built with chiaki-ng is covered by chiaki-ng's AGPL-3.0. Not affiliated with
Sony.

## Requirements

- Apple silicon Mac, macOS 27. 1080p interpolation needs an M2 Pro or faster; an M1 uses 720p.
- Xcode command line tools and Homebrew
- A PS5 registered in chiaki-ng, streaming 1080p SDR
- Local Network access for your terminal (System Settings > Privacy & Security > Local Network),
  or chiaki-ng cannot reach the PS5

## Build and run

```sh
brew install qt@6 ffmpeg pkgconf opus openssl@3 cmake ninja nasm protobuf@29 speexdsp libplacebo \
             json-c miniupnpc libevent sdl2 vulkan-loader molten-vk
git submodule update --init --recursive
./build.sh
./run.sh
```

`build.sh` applies `smooth-hook.patch` to the chiaki-ng submodule (v1.10.1) and builds it.
`run.sh` starts it with the Vulkan loader set and passes arguments on. To check what really reaches
the screen, run `./verify --match pid:<chiaki pid>` (needs Screen Recording permission).

## How it works

1. **Take** each frame chiaki-ng decodes (`SmoothSubmit` in `smooth.m`) instead of its own view.
2. **Drop repeats.** A 30 fps game in a 60 fps stream sends every frame twice; the second copy is
   recognised by its small difference from the first.
3. **Interpolate** the midpoint of two game frames with `VTLowLatencyFrameInterpolation` at 1080p.
   If a warm-up call takes over 25 ms, it uses 720p and upscales the result with
   `VTLowLatencySuperResolutionScaler`. Scene cuts get no middle frame.
4. **Schedule** the middle frame and the untouched real frame on consecutive display refreshes.
5. **Present** through a Metal layer in a child window over chiaki-ng, driven by a display link.

The added delay is about 55–70 ms after a frame is decoded.

## Environment variables

| Variable | Effect |
|---|---|
| `SMOOTH_OFF=1` | Run as plain chiaki-ng |
| `SMOOTH_INTERP_720=1` | Interpolate at 720p even on a Mac fast enough for 1080p |
| `SMOOTH_DEBUG=1` | Print frame rates, timings and delay every two seconds |
| `SMOOTH_DIFF=1` | Print how each decoded frame was classified |
