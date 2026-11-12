#!/bin/bash
# 将 dist/MacEasyTier.app 打包成带 /Applications 快捷方式的 DMG。
#
#   Scripts/package.sh                       构建 + 打包（ad-hoc 签名）
#   Scripts/package.sh --skip-build          直接使用 dist/ 中已有产物
#   SIGN_IDENTITY="Developer ID Application: …" \
#   NOTARY_PROFILE=my-profile Scripts/package.sh
#                                            开发者 ID 签名 + 公证
#
# 环境变量：ARCH（arm64|x86_64|universal，默认当前架构）、SIGN_IDENTITY（默认 "-"）、
# NOTARY_PROFILE（notarytool 凭据配置名，留空则跳过公证）、OUT_DIR（默认 dist）、
# BUILD_DIR（传给 build.sh，默认 build）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH="${ARCH:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
SKIP_BUILD=0
VOLUME_NAME="MacEasyTier"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ "$SKIP_BUILD" == 0 ]]; then
  ARCH="$ARCH" SIGN_IDENTITY="$SIGN_IDENTITY" OUT_DIR="$OUT_DIR" BUILD_DIR="$BUILD_DIR" \
    "$ROOT/Scripts/build.sh"
fi

APP="$OUT_DIR/MacEasyTier.app"
[[ -d "$APP" ]] || { echo "error: no app at $APP (run Scripts/build.sh first)" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$VERSION" ]] || { echo "error: CFBundleShortVersionString missing from $APP" >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"

case "$APP_ARCHS" in
  arm64) SUFFIX="" ;;
  x86_64) SUFFIX="-intel" ;;
  *arm64*x86_64*|*x86_64*arm64*) SUFFIX="-universal" ;;
  *) echo "error: unexpected architectures: $APP_ARCHS" >&2; exit 1 ;;
esac

DMG="$OUT_DIR/MacEasyTier-$VERSION$SUFFIX.dmg"
STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
cleanup() {
  hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$MOUNT"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/MacEasyTier.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG"

# 校验成品：挂载后必须同时看到 app 与指向 /Applications 的快捷方式。
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
[[ -d "$MOUNT/MacEasyTier.app" ]] || { echo "error: DMG is missing MacEasyTier.app" >&2; exit 1; }
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || {
  echo "error: DMG is missing the /Applications symlink" >&2
  exit 1
}
codesign --verify --deep --strict "$MOUNT/MacEasyTier.app"
hdiutil detach -quiet "$MOUNT"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "Packaged $DMG"
echo "  version: $VERSION"
echo "  arch:    $APP_ARCHS"
echo "  sign:    $SIGN_IDENTITY${NOTARY_PROFILE:+ (notarized: $NOTARY_PROFILE)}"
echo "  size:    $(du -h "$DMG" | cut -f1)"
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256" )
