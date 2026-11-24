#!/bin/sh
# Builds dist/remoteplay-60fps.app with every library inside, a DMG of it, and a source archive that
# includes chiaki-ng, as the AGPL asks of a binary release. Follows chiaki-ng's own macOS release workflow.
# Usage: ./package.sh <version>
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?usage: ./package.sh <version>}"
NAME=remoteplay-60fps
P="$(brew --prefix)"
SRC="$HERE/chiaki-ng"
DIST="$HERE/dist"
APP="$DIST/$NAME.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The source archive is taken from HEAD, so it must match what gets built.
git -C "$HERE" diff --quiet HEAD -- . ':!chiaki-ng' || { echo "commit your changes first" >&2; exit 1; }

"$HERE/build.sh"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -a "$SRC/build/gui/chiaki.app" "$APP"

# Qt, the QML imports (QtWebEngine for the PSN login included) and the Homebrew libraries they need.
mkdir -p "$WORK/qml"
cp "$SRC/scripts/qtwebengine_import.qml" "$WORK/qml/"
"$P/opt/qt@6/bin/macdeployqt" "$APP" -qmldir="$SRC/gui/src/qml" -qmldir="$WORK/qml" -libpath="$P/lib"
HELPER="$APP/Contents/Frameworks/QtWebEngineCore.framework/Helpers/QtWebEngineProcess.app"
[ -d "$HELPER" ] && ln -sfn ../../../../../../../Frameworks "$HELPER/Contents/Frameworks"
ln -sf libvulkan.1.dylib "$APP/Contents/Frameworks/vulkan"

# sdl2-compat loads SDL3 at run time from next to itself, so macdeployqt cannot see it.
cp "$P/opt/sdl3/lib/libSDL3.0.dylib" "$APP/Contents/Frameworks/libSDL3.dylib"

# MoltenVK is the Vulkan driver; the loader looks for drivers in the bundle's Resources/vulkan/icd.d.
ICD="$APP/Contents/Resources/vulkan/icd.d"
mkdir -p "$ICD"
cp "$P/opt/molten-vk/lib/libMoltenVK.dylib" "$ICD/"
sed 's|"library_path" *: *"[^"]*"|"library_path": "./libMoltenVK.dylib"|' "$P/etc/vulkan/icd.d/MoltenVK_icd.json" > "$ICD/MoltenVK_icd.json"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier io.github.curt-park.$NAME" -c "Set :CFBundleName $NAME" \
  -c "Add :CFBundleDisplayName string $NAME" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" \
  -c "Add :NSLocalNetworkUsageDescription string $NAME connects to your PS5 on the local network." "$PLIST"

# Licenses: this project, chiaki-ng, and every Homebrew formula whose files were bundled.
LICENSES="$APP/Contents/Resources/licenses"
mkdir -p "$LICENSES/third-party"
cp "$HERE/LICENSE" "$LICENSES/$NAME-MIT.txt"
cp "$SRC/COPYING" "$LICENSES/chiaki-ng-COPYING.txt"
cp "$SRC/LICENSES/"* "$LICENSES/"
FORMULAS=$(
  for entry in $(ls "$APP/Contents/Frameworks"); do
    for candidate in "$P"/opt/*/lib/"$entry"; do
      [ -e "$candidate" ] && realpath "$candidate" | sed -n "s|^$P/Cellar/\([^/]*\)/.*|\1|p" && break
    done
  done | sort -u
)
FORMULAS=$(printf '%s\nsdl3\nmolten-vk\n' "$FORMULAS" | sort -u)
for formula in $FORMULAS; do
  prefix="$(realpath "$P/opt/$formula")"
  mkdir -p "$LICENSES/third-party/$formula"
  find "$prefix" -maxdepth 1 -type f \( -iname 'licen[cs]e*' -o -iname 'copying*' -o -iname 'notice*' \) \
    -exec cp {} "$LICENSES/third-party/$formula/" \;
done
# Homebrew's Qt and glib formulas ship no license texts, so the standard GPL and LGPL texts go in once for all.
mkdir -p "$LICENSES/common"
cp "$(realpath "$P/opt/ffmpeg")"/COPYING.* "$LICENSES/common/"
brew info --json=v2 $FORMULAS | python3 -I -c '
import json, sys
print("# Third-party libraries\n\nBuilt from Homebrew. Each folder next to this file holds the license files the formula ships;")
print("where a folder is empty, the formula ships none and its license is the one named below. The GPL and LGPL")
print("texts are in ../common.\n")
print("| Library | Version | License | Source |\n|---|---|---|---|")
for formula in json.load(sys.stdin)["formulae"]:
    cells = [formula["name"], formula["versions"]["stable"], formula["license"] or "see folder", formula["urls"]["stable"]["url"]]
    print("| " + " | ".join(cells) + " |")
' > "$LICENSES/third-party/README.md"

# macdeployqt leaves some Homebrew paths behind: QtWebEngine's helper still loads Qt from Homebrew, and a few
# binaries keep Homebrew search paths, which on a Mac with Homebrew would mix its libraries into the app.
find "$APP" -type f | while IFS= read -r file; do
  file -b "$file" | grep -q "Mach-O" || continue
  own="$(otool -D "$file" | tail -n +2)"
  otool -L "$file" | tail -n +2 | awk '{print $1}' | grep "^$P/" | grep -v -x -F "$own" | while IFS= read -r dependency; do
    case "$dependency" in
      *.framework/*) bundled="@rpath/${dependency##*/lib/}" ;;
      *) bundled="@rpath/${dependency##*/}" ;;
    esac
    install_name_tool -change "$dependency" "$bundled" "$file" 2>/dev/null
  done
  otool -l "$file" | awk '/LC_RPATH/{getline; getline; print $2}' | grep "^$P/" | while IFS= read -r searched; do
    install_name_tool -delete_rpath "$searched" "$file" 2>/dev/null
  done
done

codesign --force --deep --sign - --entitlements "$SRC/gui/entitlements.xml" "$APP"

mkdir "$WORK/dmg"
cp -a "$APP" "$WORK/dmg/"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "$NAME" -srcfolder "$WORK/dmg" -format UDZO -ov "$DIST/$NAME-$VERSION.dmg" >/dev/null
codesign --force --sign - "$DIST/$NAME-$VERSION.dmg"

# GitHub's own source archives leave submodules out, so this one carries chiaki-ng and its third-party code.
git -C "$HERE" archive --prefix="$NAME-$VERSION/" -o "$WORK/top.tar" HEAD
git -C "$HERE" submodule foreach --recursive --quiet \
  "git archive --prefix=\"$NAME-$VERSION/\$displaypath/\" -o \"$WORK/sub-\$sha1.tar\" HEAD"
set -- "@$WORK/top.tar"
for part in "$WORK"/sub-*.tar; do set -- "$@" "@$part"; done
tar -czf "$DIST/$NAME-$VERSION-source.tar.gz" "$@"

echo "built $DIST/$NAME-$VERSION.dmg and $DIST/$NAME-$VERSION-source.tar.gz"
