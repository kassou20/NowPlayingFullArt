#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# build.sh — Compile NowPlayingFullArt dylib for iOS (arm64)
# Requires: macOS with Xcode 26+ (iOS 26 SDK)
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/Sources"
OUT="$SCRIPT_DIR/out"
PRODUCT="NowPlayingFullArt"

mkdir -p "$OUT"

# Find the iOS SDK
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET="arm64-apple-ios17.0"
echo "SDK: $SDK"
echo "Target: $TARGET"

# ── Probe: does this SDK have MPMediaItemAnimatedArtwork? ──
echo "Checking for MPMediaItemAnimatedArtwork..."
PROBE=$(mktemp /tmp/npa_probe.XXXXXX.swift)
cat > "$PROBE" <<'EOF'
import MediaPlayer
// Class is @available(iOS 19.0, *) — wrap in availability check for the probe
if #available(iOS 19.0, *) {
    let _ = MPMediaItemAnimatedArtwork.self
}
EOF
if ! swiftc -typecheck -sdk "$SDK" -target "$TARGET" "$PROBE" 2>/dev/null; then
    echo "ERROR: This SDK does not have MPMediaItemAnimatedArtwork."
    echo "       You need Xcode 26 (iOS 26 SDK) or newer."
    rm -f "$PROBE"
    exit 1
fi
rm -f "$PROBE"
echo "API found ✓"

# ── Compile bootstrap.c ──
echo "Compiling bootstrap.c..."
xcrun clang -arch arm64 -isysroot "$SDK" \
    -miphoneos-version-min=17.0 \
    -c "$SRC/bootstrap.c" \
    -o "$OUT/bootstrap.o"

# ── Compile Swift source → dylib (fallback mode) ──
echo "Compiling $PRODUCT.dylib (fallback)..."
swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -emit-library \
    -o "$OUT/$PRODUCT.dylib" \
    -module-name "$PRODUCT" \
    -Xlinker -install_name -Xlinker "@rpath/$PRODUCT.dylib" \
    -Xlinker "$OUT/bootstrap.o" \
    -framework UIKit \
    -framework MediaPlayer \
    -framework AVFoundation \
    -framework CoreImage \
    "$SRC/NowPlayingFullArt.swift"

# ── Verify the binary references the right symbol ──
if nm "$OUT/$PRODUCT.dylib" | grep -q "MPMediaItemAnimatedArtwork"; then
    echo "Symbol check: MPMediaItemAnimatedArtwork found ✓"
else
    echo "WARNING: MPMediaItemAnimatedArtwork not found in binary"
fi

# ── Summary ──
echo ""
echo "Build complete!"
ls -lh "$OUT/$PRODUCT.dylib"
echo ""
echo "Next: inject into Plexamp IPA with Sideloadly"
echo "  1. Open Sideloadly"
echo "  2. Load decrypted Plexamp.ipa"
echo "  3. Advanced Options → Tweak injection → + → select $PRODUCT.dylib"
echo "  4. Sign with Apple ID and install"
