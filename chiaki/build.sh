#!/bin/sh
# Builds the chiaki-ng submodule with smooth-anything compiled in.
# Needs: brew install qt@6 ffmpeg pkgconf opus openssl@3 cmake ninja nasm protobuf@29 speexdsp libplacebo \
#        json-c miniupnpc libevent sdl2 vulkan-loader molten-vk
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/chiaki/chiaki-ng"
[ -f "$SRC/CMakeLists.txt" ] || git -C "$HERE" submodule update --init --recursive
cd "$SRC"
# Apply the hook once; a tree that already has it is left alone.
if git apply --check "$HERE/chiaki/smooth-hook.patch" 2>/dev/null; then git apply "$HERE/chiaki/smooth-hook.patch"; fi
# nanopb's generator needs the Python protobuf module; a private environment keeps the system Python untouched.
[ -d build-venv ] || { python3 -m venv build-venv && ./build-venv/bin/pip install -q "protobuf>=5,<6" setuptools; }
P="$(brew --prefix)"
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DPYTHON_EXECUTABLE="$PWD/build-venv/bin/python" -DSMOOTH_ANYTHING_DIR="$HERE" \
  -DOPENSSL_ROOT_DIR="$P/opt/openssl@3" -DOPENSSL_INCLUDE_DIR="$P/opt/openssl@3/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$P/opt/openssl@3/lib/libcrypto.dylib" -DOPENSSL_SSL_LIBRARY="$P/opt/openssl@3/lib/libssl.dylib" \
  -DCMAKE_PREFIX_PATH="$P/opt/openssl@3;$P/opt/qt@6;$P/opt/protobuf@29"
# chiaki-ng links OpenSSL 3, but with OpenSSL 4 linked into the Homebrew prefix its headers are found first and
# the link fails on OPENSSL_sk_* symbols. Neither CPATH nor compiler flags come before that include path, so
# OpenSSL 4 is unlinked for the duration of the build, as chiaki-ng's own CI does, and linked again afterwards.
if [ -L "$P/include/openssl" ] && readlink "$P/include/openssl" | grep -q "openssl@4"; then
  brew unlink openssl@4 >/dev/null
  trap 'brew link openssl@4 >/dev/null' EXIT
fi
CPATH="$P/opt/ffmpeg/include" PATH="$PWD/build-venv/bin:$PATH" cmake --build build --config Release --target chiaki
echo "built $SRC/build/gui/chiaki.app"
