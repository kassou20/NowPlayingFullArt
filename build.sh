#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build.sh — Compile NowPlayingFullArt.dylib (pure Objective-C) for iOS arm64
# Requires: macOS with Xcode (iOS SDK)
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/Sources"
OUT="$SCRIPT_DIR/out"
PRODUCT="NowPlayingFullArt"

mkdir -p "$OUT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios17.0"
echo "SDK: $SDK"
echo "Target: $TARGET"

echo "Compiling $PRODUCT.dylib (Objective-C)..."
xcrun clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 \
    -dynamiclib \
    -o "$OUT/$PRODUCT.dylib" \
    -install_name "@rpath/$PRODUCT.dylib" \
    -framework Foundation \
    -framework UIKit \
    -framework MediaPlayer \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreImage \
    -lobjc \
    -fobjc-arc \
    "$SRC/NowPlayingFullArt.m"

# Verify the binary has the constructor
if nm "$OUT/$PRODUCT.dylib" | grep -q "npa_constructor"; then
    echo "Symbol check: npa_constructor found ✓"
else
    echo "WARNING: npa_constructor not found in binary"
fi

echo ""
echo "Build complete!"
ls -lh "$OUT/$PRODUCT.dylib"
echo ""
echo "Next: inject into Plexamp IPA with Sideloadly"
echo "  1. Open Sideloadly"
echo "  2. Load decrypted Plexamp.ipa"
echo "  3. Advanced Options → Tweak injection → + → select $PRODUCT.dylib"
echo "  4. Sign with Apple ID and install"
