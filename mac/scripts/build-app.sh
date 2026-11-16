#!/usr/bin/env bash
# Builds mac/build/STTpro.app (Apple Silicon).
#
#   scripts/build-app.sh             # Release build
#   scripts/build-app.sh --install   # …and copy to /Applications
#   scripts/build-app.sh --open      # …and launch it
#
# Uses xcodebuild when full Xcode is installed, otherwise SwiftPM from the
# Command Line Tools. Force one with BUILD_TOOL=xcodebuild|swiftpm.
# Signs ad-hoc by default; set SIGN_IDENTITY="Apple Development: …" to sign
# with a real certificate (keeps Accessibility permission across rebuilds).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/STTpro.app"
INSTALL=0
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --open) OPEN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

tool="${BUILD_TOOL:-}"
if [[ -z "$tool" ]]; then
  if xcodebuild -version >/dev/null 2>&1; then tool=xcodebuild; else tool=swiftpm; fi
fi

echo "==> Building with $tool"
if [[ "$tool" == xcodebuild ]]; then
  xcodebuild -scheme STTpro -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT/.build/xcode" \
    build -quiet
  BIN="$ROOT/.build/xcode/Build/Products/Release/STTpro"
else
  swift build -c release --arch arm64 --product STTpro
  BIN="$(swift build -c release --arch arm64 --show-bin-path)/STTpro"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/STTpro"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

LOCAL_CERT="STTpro Local Code Signing"
KEYCHAIN_ARGS=()
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_CERT"; then
  SIGN_IDENTITY="$LOCAL_CERT"
fi
# Default: a stable identity from a project-local keychain (see setup-local-signing.sh).
# Set SIGN_IDENTITY=- to force ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  KC="$("$ROOT/scripts/setup-local-signing.sh" | tail -1)"
  SIGN_IDENTITY="$LOCAL_CERT"
  KEYCHAIN_ARGS=(--keychain "$KC")
fi
IDENTITY="${SIGN_IDENTITY:--}"
echo "==> Signing (${IDENTITY})"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --identifier com.sttpro.mac "$APP"
  echo "    note: ad-hoc signature changes every build, so macOS forgets the Accessibility"
  echo "    permission after each rebuild. Run scripts/create-signing-cert.sh once to fix that."
else
  codesign --force "${KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" --identifier com.sttpro.mac \
    --options runtime --entitlements "$ROOT/Resources/STTpro.entitlements" "$APP"
fi
codesign --verify --strict "$APP"
echo "==> Built $APP"

if [[ $INSTALL == 1 ]]; then
  pkill -x STTpro 2>/dev/null || true
  rm -rf /Applications/STTpro.app
  cp -R "$APP" /Applications/STTpro.app
  APP=/Applications/STTpro.app
  echo "==> Installed to $APP"
fi

if [[ $OPEN == 1 ]]; then
  pkill -x STTpro 2>/dev/null || true
  open "$APP"
fi
