#!/bin/sh
# Runs the chiaki-ng built by chiaki/build.sh; arguments are passed on to it.
# Without the Vulkan loader chiaki-ng falls back to OpenGL, renders on the main thread, and the stream stutters badly.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export QT_VULKAN_LIB="${QT_VULKAN_LIB:-$(brew --prefix)/lib/libvulkan.1.dylib}"
exec "$HERE/chiaki/chiaki-ng/build/gui/chiaki.app/Contents/MacOS/chiaki" "$@"
