#!/bin/bash
# 下载固定版本的 EasyTier macOS 二进制到 Vendor/easytier/<arch>/。
#
#   Scripts/fetch-core.sh                当前架构
#   ARCH=universal Scripts/fetch-core.sh arm64 + x86_64
#   EASYTIER_VERSION=2.6.4 Scripts/fetch-core.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${EASYTIER_VERSION:-2.6.4}"
ARCH="${ARCH:-$(uname -m)}"
VENDOR="$ROOT/Vendor/easytier"

case "$ARCH" in
  arm64) ARCHS=(arm64) ;;
  x86_64) ARCHS=(x86_64) ;;
  universal) ARCHS=(arm64 x86_64) ;;
  *) echo "error: ARCH must be arm64, x86_64 or universal (got '$ARCH')" >&2; exit 1 ;;
esac

asset_name() {
  case "$1" in
    arm64) echo "aarch64" ;;
    x86_64) echo "x86_64" ;;
    *) echo "error: unsupported arch $1" >&2; exit 1 ;;
  esac
}

checksum_for() {
  local arch="$1"
  case "$VERSION:$arch" in
    2.6.4:arm64) echo "4be1882d1aa36d31c1d6ba0596f2cf8a097e371f8da124212324b2e0f8df7e4b" ;;
    2.6.4:x86_64) echo "89fc28a6e6995259d76ce3f11775220e8a21c760e94df91a6a9db30a69b6982e" ;;
    *) echo "" ;;
  esac
}

for host_arch in "${ARCHS[@]}"; do
  target="$VENDOR/$host_arch"
  if [[ -x "$target/easytier-core" ]]; then
    echo "EasyTier $VERSION ($host_arch) already present"
    continue
  fi

  asset_arch="$(asset_name "$host_arch")"
  zip_name="easytier-macos-${asset_arch}-v${VERSION}.zip"
  url="https://github.com/EasyTier/EasyTier/releases/download/v${VERSION}/${zip_name}"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading EasyTier $VERSION ($host_arch)…"
  curl -L --fail --silent --show-error --max-time 300 -o "$tmp/$zip_name" "$url"

  expected="$(checksum_for "$host_arch")"
  if [[ -n "$expected" ]]; then
    actual="$(shasum -a 256 "$tmp/$zip_name" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || {
      echo "error: checksum mismatch for $zip_name" >&2
      echo "  expected $expected" >&2
      echo "  actual   $actual" >&2
      exit 1
    }
  fi

  unzip -q "$tmp/$zip_name" -d "$tmp"
  mkdir -p "$target"
  cp "$tmp/easytier-macos-${asset_arch}/easytier-core" "$target/easytier-core"
  chmod +x "$target/easytier-core"
  printf '%s\n' "$VERSION" > "$target/.version"
  rm -rf "$tmp"
  trap - EXIT
  echo "Installed $target"
done
