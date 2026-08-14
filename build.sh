#!/bin/bash
# Builds "Harbor for DeepSeek Harness.app".
#
# Ad-hoc signing is the default, which is enough to run an app you built
# yourself. An app *downloaded* from the internet also needs notarization to
# open without a trip through System Settings, so --sign and --notarize exist
# for whoever publishes the release.
set -euo pipefail

APP_NAME="Harbor for DeepSeek Harness"
BUNDLE_ID="io.github.cwy433-png.harbor"
VERSION="0.1.0"
DEPLOYMENT_TARGET="13.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
SIGN_IDENTITY="-"
NOTARIZE_PROFILE=""
MAKE_DMG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)      SIGN_IDENTITY="$2"; shift 2 ;;
    --notarize)  NOTARIZE_PROFILE="$2"; shift 2 ;;
    --dmg)       MAKE_DMG="yes"; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./build.sh [--dmg] [--sign <identity>] [--notarize <keychain-profile>]

  (no flags)   Ad-hoc signed. Runs on the machine that built it.
  --dmg        Also package a release disk image.
  --sign       Developer ID Application identity, e.g. "Developer ID Application: Name (TEAMID)"
  --notarize   notarytool keychain profile name; implies a real --sign identity.

Create the notarytool profile once with:
  xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific-password>
EOF
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Building icon"
ICONSET="$BUILD/icon.iconset"
mkdir -p "$ICONSET"
# Quick Look renders the SVG; sips and iconutil are the rest of the pipeline.
# All three ship with macOS, so building requires no package manager.
qlmanage -t -s 1024 -o "$BUILD" "$ROOT/Resources/icon.svg" >/dev/null 2>&1
BASE_PNG="$BUILD/icon.svg.png"
if [[ ! -f "$BASE_PNG" ]]; then
  echo "    icon render failed; continuing without one" >&2
else
  for size in 16 32 128 256 512; do
    sips -z $size $size "$BASE_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$BASE_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Compiling (universal)"
SOURCES=("$ROOT"/Sources/*.swift)
SLICES=()
for arch in arm64 x86_64; do
  slice="$BUILD/harbor-$arch"
  # main.swift must be last: top-level code has to be in the file the compiler
  # treats as the entry point.
  swiftc \
    -target "${arch}-apple-macosx${DEPLOYMENT_TARGET}" \
    -O -whole-module-optimization \
    -framework AppKit -framework WebKit -framework CryptoKit \
    -o "$slice" \
    "$ROOT/Sources/Support.swift" \
    "$ROOT/Sources/Runtime.swift" \
    "$ROOT/Sources/Server.swift" \
    "$ROOT/Sources/SetupWindow.swift" \
    "$ROOT/Sources/MainWindow.swift" \
    "$ROOT/Sources/main.swift" \
    2>&1 | grep -v "^$" || true
  if [[ ! -f "$slice" ]]; then
    echo "    $arch build failed" >&2
    exit 1
  fi
  SLICES+=("$slice")
done
lipo -create -output "$APP/Contents/MacOS/Harbor" "${SLICES[@]}"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Harbor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key>
  <string>Unofficial launcher. Not affiliated with DeepSeek.</string>
  <!-- The harness serves plain HTTP on loopback, which App Transport Security
       blocks by default. Scoped to local networking rather than disabled. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

cat > "$BUILD/entitlements.plist" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- The app runs Node, which JITs. Without this the hardened runtime kills
       the child on its first optimised compile. -->
  <key>com.apple.security.cs.allow-jit</key><true/>
  <!-- The managed Node is downloaded at runtime, so it is not part of this
       bundle's signature and library validation would refuse to exec it. -->
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENTITLEMENTS

echo "==> Signing ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime --timestamp \
    --entitlements "$BUILD/entitlements.plist" \
    "$APP"
fi
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

if [[ -n "$NOTARIZE_PROFILE" ]]; then
  echo "==> Notarizing"
  ZIP="$BUILD/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$APP"
  echo "==> Packaging notarized zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

if [[ -n "$MAKE_DMG" ]]; then
  echo "==> Packaging disk image"
  STAGING="$BUILD/dmg"
  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  # The drag target, so installing is one gesture inside the mounted window.
  ln -s /Applications "$STAGING/Applications"

  # Without notarization macOS refuses the first launch, and the dialog it
  # shows does not say what to do about it. Putting the instructions in the
  # disk image means they are on screen at exactly the moment they are needed.
  if [[ -z "$NOTARIZE_PROFILE" ]]; then
    cat > "$STAGING/READ ME FIRST.txt" <<'FIRSTRUN'
Harbor for DeepSeek Harness
===========================

1. Drag the app onto the Applications folder shown here.

2. The first time you open it, macOS will say it cannot be opened,
   because this app is not notarized by Apple.

   To open it anyway:
     - Open  System Settings > Privacy & Security
     - Scroll to the bottom
     - Next to the message about Harbor, click "Open Anyway"

   You only have to do this once.

   If you would rather not, you can build the app yourself from source
   instead — a locally built app is not blocked. See the README.

---

Harbor for DeepSeek Harness（中文）
==================================

1. 把 app 拖到这里显示的「应用程序」文件夹上。

2. 第一次打开时，macOS 会提示无法打开，因为这个 app 没有经过 Apple 公证。

   绕过方法：
     - 打开  系统设置 > 隐私与安全性
     - 滚动到底部
     - 在关于 Harbor 的提示旁点「仍要打开」

   只需操作这一次。

   如果你不接受这一步，也可以自己从源码构建——本地构建的 app 不会被拦。
   见 README。

---

This is an unofficial launcher. Not affiliated with DeepSeek.
本项目为非官方启动器，与 DeepSeek 无关联。
FIRSTRUN
  fi

  DMG="$BUILD/$APP_NAME.dmg"
  rm -f "$DMG"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"
  rm -rf "$STAGING"
  echo "    $(du -h "$DMG" | cut -f1)  $(basename "$DMG")"
fi

echo
echo "Built: $APP"
du -sh "$APP" | sed 's/^/    /'
