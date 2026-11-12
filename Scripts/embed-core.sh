#!/bin/bash
# Xcode 构建阶段：把 Vendor/easytier/<arch> 中的 core/cli 嵌入 App 的 Contents/Helpers。
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
ARCHS="${ARCHS:-$(uname -m)}"
VENDOR="$ROOT/Vendor/easytier"

mkdir -p "$HELPERS"

embed() {
  local name="$1"
  local slices=()
  for arch in $ARCHS; do
    local path="$VENDOR/$arch/$name"
    [[ -x "$path" ]] || {
      echo "error: missing $path. Run Scripts/fetch-core.sh ARCH=universal" >&2
      exit 1
    }
    slices+=("$path")
  done

  if [[ "${#slices[@]}" -gt 1 ]]; then
    lipo -create "${slices[@]}" -output "$HELPERS/$name"
  else
    cp "${slices[0]}" "$HELPERS/$name"
  fi
  chmod +x "$HELPERS/$name"
  # Xcode 的签名阶段在脚本之后；先做 ad-hoc 签名，IDE 构建也能直接运行。
  /usr/bin/codesign --force --sign - --options runtime "$HELPERS/$name" >/dev/null 2>&1 || true
}

embed easytier-core

# 编译 root 守护 helper（停止 TUN core 的可靠通道）。
HELPER_SRC="$ROOT/Helper/MacEasyTierHelper.c"
if [[ -f "$HELPER_SRC" ]]; then
  ARCH_FLAGS=()
  for arch in $ARCHS; do
    ARCH_FLAGS+=(-arch "$arch")
  done
  xcrun clang -O2 -mmacosx-version-min=14.0 "${ARCH_FLAGS[@]}" \
    -o "$HELPERS/MacEasyTierHelper" "$HELPER_SRC"
  chmod +x "$HELPERS/MacEasyTierHelper"
  /usr/bin/codesign --force --sign - --options runtime "$HELPERS/MacEasyTierHelper" >/dev/null 2>&1 || true
fi

echo "Embedded EasyTier binaries for: $ARCHS"
