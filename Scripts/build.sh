#!/bin/bash
# 构建 MacEasyTier.app 并复制到 dist/。
#
#   Scripts/build.sh                              Release、当前架构、ad-hoc 签名
#   Scripts/build.sh --debug                      Debug（产物为 MacEasyTierDev.app）
#   Scripts/build.sh --no-generate                跳过 xcodegen
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build.sh
#
# 环境变量：CONFIG（Release|Debug）、ARCH（arm64|x86_64|universal）、
# SIGN_IDENTITY（默认 "-"，即 ad-hoc）、OUT_DIR（默认 dist）、BUILD_DIR（默认 build）、
# GENERATE_PROJECT（默认 1）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Release}"
ARCH="${ARCH:-$(uname -m)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
GENERATE_PROJECT="${GENERATE_PROJECT:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIG=Debug ;;
    --no-generate) GENERATE_PROJECT=0 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

case "$CONFIG" in
  Release|Debug) ;;
  *) echo "error: CONFIG must be Release or Debug (got '$CONFIG')" >&2; exit 1 ;;
esac

case "$ARCH" in
  arm64|x86_64) ARCHS="$ARCH" ;;
  universal) ARCHS="arm64 x86_64" ;;
  *) echo "error: ARCH must be arm64, x86_64 or universal (got '$ARCH')" >&2; exit 1 ;;
esac

ARCH="$ARCH" "$ROOT/Scripts/fetch-core.sh"

if [[ "$GENERATE_PROJECT" == 1 ]]; then
  command -v xcodegen >/dev/null 2>&1 || {
    echo "error: xcodegen is required to regenerate maceasytier.xcodeproj" >&2
    echo "       install it with: brew install xcodegen" >&2
    exit 1
  }
  xcodegen generate --spec project.yml
fi

PRODUCT="$(xcodebuild -project maceasytier.xcodeproj -scheme maceasytier \
  -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/^ *PRODUCT_NAME = /{print $2; exit}')"
[[ -n "$PRODUCT" ]] || { echo "error: cannot read PRODUCT_NAME from the project" >&2; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
LOG="$BUILD_DIR/build.log"

echo "Building $PRODUCT ($CONFIG, $ARCHS)…"
if ! xcodebuild -project maceasytier.xcodeproj -scheme maceasytier \
  -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build >"$LOG" 2>&1; then
  tail -n 120 "$LOG" >&2
  echo "error: xcodebuild failed, see $LOG" >&2
  exit 1
fi

APP="$BUILD_DIR/Build/Products/$CONFIG/$PRODUCT.app"
[[ -d "$APP" ]] || { echo "error: build produced no app at $APP" >&2; exit 1; }

# 先签嵌套的 EasyTier 二进制，再签 App 本身。
SIGN_BASE=(--force --sign "$SIGN_IDENTITY" --options runtime)
[[ "$SIGN_IDENTITY" != "-" ]] && SIGN_BASE+=(--timestamp)
if [[ -d "$APP/Contents/Helpers" ]]; then
  for helper in "$APP/Contents/Helpers/"*; do
    [[ -f "$helper" ]] || continue
    codesign "${SIGN_BASE[@]}" "$helper"
  done
fi

# 统一在这里签名，Developer ID 与 ad-hoc 走同一路径。
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime
  --entitlements "$ROOT/App/Resources/maceasytier.entitlements")
[[ "$SIGN_IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$APP"

EXPECTED_ARCHS="$(echo "$ARCHS" | tr ' ' '\n' | sort | tr '\n' ' ')"
ACTUAL_ARCHS="$(lipo -archs "$APP/Contents/MacOS/$PRODUCT" | tr ' ' '\n' | sort | tr '\n' ' ')"
[[ "$ACTUAL_ARCHS" == "$EXPECTED_ARCHS" ]] || {
  echo "error: expected architectures '$EXPECTED_ARCHS', got '$ACTUAL_ARCHS'" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/$PRODUCT.app"
ditto "$APP" "$OUT_DIR/$PRODUCT.app"
codesign --verify --deep --strict "$OUT_DIR/$PRODUCT.app"

echo "Built $OUT_DIR/$PRODUCT.app"
echo "  arch: ${ACTUAL_ARCHS% }"
echo "  sign: $SIGN_IDENTITY"
