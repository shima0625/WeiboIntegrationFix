#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

cd "$PROJECT_DIR"
make clean
make FINALPACKAGE=1

DYLIB=".theos/obj/WeiboIntegrationFix.dylib"
if [[ ! -f "$DYLIB" ]]; then
  DYLIB=".theos/obj/debug/WeiboIntegrationFix.dylib"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/weibointegrationfix.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
chmod 0755 "$STAGE"

mkdir -p "$STAGE/DEBIAN" "$STAGE/Library/MobileSubstrate/DynamicLibraries"
install -m 0644 control "$STAGE/DEBIAN/control"
install -m 0755 "$DYLIB" "$STAGE/Library/MobileSubstrate/DynamicLibraries/WeiboIntegrationFix.dylib"
install -m 0644 WeiboIntegrationFix.plist "$STAGE/Library/MobileSubstrate/DynamicLibraries/WeiboIntegrationFix.plist"

mkdir -p packages
dpkg-deb -Zgzip --root-owner-group --build "$STAGE" "packages/com.shima.weibointegrationfix_0.1.0_iphoneos-arm.deb"
