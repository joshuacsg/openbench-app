#!/bin/bash
# Build FluxCore.xcframework from the sibling flux repo.
#
# Usage: ./Scripts/build-xcframework.sh
#
# Prerequisites:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim
#   (cmake + nasm on PATH if using the x264 feature)

set -euo pipefail

FLUX_ROOT="${FLUX_ROOT:-$(cd "$(dirname "$0")/../../flux" && pwd)}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/FluxCore.xcframework"

echo "flux repo: $FLUX_ROOT"
echo "output:    $OUT_DIR"

# Build for physical device (arm64)
echo "→ building aarch64-apple-ios (device)..."
cargo build \
  --manifest-path "$FLUX_ROOT/Cargo.toml" \
  -p flux-core-ffi \
  --release \
  --target aarch64-apple-ios

# Build for simulator (arm64 sim)
echo "→ building aarch64-apple-ios-sim (simulator)..."
cargo build \
  --manifest-path "$FLUX_ROOT/Cargo.toml" \
  -p flux-core-ffi \
  --release \
  --target aarch64-apple-ios-sim

# Assemble the xcframework
echo "→ assembling xcframework..."
rm -rf "$OUT_DIR"
xcodebuild -create-xcframework \
  -library "$FLUX_ROOT/target/aarch64-apple-ios/release/libflux_core_ffi.a" \
    -headers "$FLUX_ROOT/crates/flux-core-ffi/include" \
  -library "$FLUX_ROOT/target/aarch64-apple-ios-sim/release/libflux_core_ffi.a" \
    -headers "$FLUX_ROOT/crates/flux-core-ffi/include" \
  -output "$OUT_DIR"

echo "✓ FluxCore.xcframework built at $OUT_DIR"
