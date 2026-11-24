#!/bin/sh
HERE="$(cd "$(dirname "$0")" && pwd)"
export QT_VULKAN_LIB="${QT_VULKAN_LIB:-$(brew --prefix)/lib/libvulkan.1.dylib}"
exec "$HERE/chiaki-ng/build/gui/chiaki.app/Contents/MacOS/chiaki" "$@"
