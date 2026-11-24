#!/bin/sh
# Runs the chiaki-ng built by chiaki/build.sh. Usage: chiaki/run.sh <path to the chiaki-ng checkout> [chiaki arguments]
# Without the Vulkan loader chiaki-ng falls back to OpenGL, renders on the main thread, and the stream stutters badly.
SRC="${1:?usage: chiaki/run.sh <path to the chiaki-ng checkout> [chiaki arguments]}"
shift
export QT_VULKAN_LIB="${QT_VULKAN_LIB:-$(brew --prefix)/lib/libvulkan.1.dylib}"
exec "$SRC/build/gui/chiaki.app/Contents/MacOS/chiaki" "$@"
