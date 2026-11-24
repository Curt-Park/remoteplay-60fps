#!/bin/sh
# Builds chiaki-ng v1.10.1 with smooth-anything compiled in. Usage: chiaki/build.sh <path to a chiaki-ng checkout>
# Needs: brew install qt@6 ffmpeg pkgconf opus openssl@3 cmake ninja nasm protobuf@29 speexdsp libplacebo \
#        json-c miniupnpc libevent sdl2 vulkan-loader molten-vk
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?usage: chiaki/build.sh <path to a chiaki-ng checkout at v1.10.1>}"
cd "$SRC"
git apply --check "$HERE/chiaki/smooth-hook.patch" 2>/dev/null && git apply "$HERE/chiaki/smooth-hook.patch"
# nanopb's generator needs the Python protobuf module; a private environment keeps the system Python untouched.
[ -d build-venv ] || { python3 -m venv build-venv && ./build-venv/bin/pip install -q "protobuf>=5,<6" setuptools; }
P="$(brew --prefix)"
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DPYTHON_EXECUTABLE="$PWD/build-venv/bin/python" -DSMOOTH_ANYTHING_DIR="$HERE" \
  -DOPENSSL_ROOT_DIR="$P/opt/openssl@3" -DOPENSSL_INCLUDE_DIR="$P/opt/openssl@3/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$P/opt/openssl@3/lib/libcrypto.dylib" -DOPENSSL_SSL_LIBRARY="$P/opt/openssl@3/lib/libssl.dylib" \
  -DCMAKE_PREFIX_PATH="$P/opt/openssl@3;$P/opt/qt@6;$P/opt/protobuf@29"
# If the link fails on OPENSSL_sk_* symbols, OpenSSL 4 headers shadowed OpenSSL 3: run `brew unlink openssl@4`,
# rebuild, then `brew link openssl@4`.
CPATH="$P/opt/ffmpeg/include" PATH="$PWD/build-venv/bin:$PATH" cmake --build build --config Release --target chiaki
echo "built $SRC/build/gui/chiaki.app"
