#!/bin/sh
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=26.0 main.m -o smooth-anything \
  -framework Cocoa -framework AVFoundation -framework ScreenCaptureKit \
  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore
echo "built ./smooth-anything"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=26.0 verify.m -o verify \
  -framework Cocoa -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo
echo "built ./verify"
