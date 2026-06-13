#!/usr/bin/env bash
# Rebuild flux-host from the current flux branch and make OpenBench Host use it.
#
# Usage: ./Scripts/rebuild-flux-host.sh [--frame-timing]
#
# Builds flux-host --release from the sibling ../flux repo (override with
# FLUX_ROOT) and installs it where HostManager.findFluxHostBinary() looks, so
# the menu-bar app picks up the new binary on its next launch.
#
# flux-host does NOT need the x264 feature / pkg-config (only openbench's
# ob-encode does), so this build is clean with a stock toolchain.
#
# Flags:
#   --frame-timing   Print how to enable per-frame timing (FLUX_FRAME_TIMING)
#                    and exit early-ish (still builds + installs first).

set -euo pipefail

# --- args -------------------------------------------------------------------
SHOW_FRAME_TIMING=0
for arg in "$@"; do
  case "$arg" in
    --frame-timing) SHOW_FRAME_TIMING=1 ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown flag: $arg (try --frame-timing or --help)" >&2
      exit 2
      ;;
  esac
done

# --- paths ------------------------------------------------------------------
# Match build-xcframework.sh: sibling ../flux, overridable via FLUX_ROOT.
FLUX_ROOT="${FLUX_ROOT:-$(cd "$(dirname "$0")/../../flux" && pwd)}"
BUILT_BIN="$FLUX_ROOT/target/release/flux-host"

# Canonical location HostManager.findFluxHostBinary() searches that a script
# can reliably create (candidate #1 is "next to the .app", whose path we can't
# know here; #2 is the development release path under $HOME). Keep this string
# in lockstep with HostManager.swift's candidate list.
INSTALL_DIR="$HOME/Documents/GitHub/flux/target/release"
INSTALL_BIN="$INSTALL_DIR/flux-host"

echo "flux repo:   $FLUX_ROOT"
echo "built bin:   $BUILT_BIN"
echo "install to:  $INSTALL_BIN"

# --- build ------------------------------------------------------------------
echo "→ cargo build --release -p flux-host..."
cargo build \
  --release \
  -p flux-host \
  --manifest-path "$FLUX_ROOT/Cargo.toml"

if [[ ! -x "$BUILT_BIN" ]]; then
  echo "✗ expected binary not found/executable at $BUILT_BIN" >&2
  exit 1
fi

# --- install ----------------------------------------------------------------
# If the build already lands on the canonical path (default sibling FLUX_ROOT
# == $HOME/Documents/GitHub/flux), there's nothing to link — the app already
# looks right here. Otherwise symlink the freshly built binary into place.
if [[ "$BUILT_BIN" -ef "$INSTALL_BIN" ]]; then
  echo "✓ built binary is already at the canonical install path"
else
  mkdir -p "$INSTALL_DIR"
  # Idempotent: replace any prior file/symlink, point at the fresh build.
  ln -sf "$BUILT_BIN" "$INSTALL_BIN"
  echo "✓ symlinked $INSTALL_BIN → $BUILT_BIN"
fi

echo
echo "✓ flux-host installed at: $INSTALL_BIN"
echo "  Restart OpenBench Host (quit from the menu bar, relaunch) to pick it up."

# --- optional: frame-timing hint -------------------------------------------
if [[ "$SHOW_FRAME_TIMING" -eq 1 ]]; then
  cat <<'EOF'

──────────────────────────────────────────────────────────────────────────────
Per-frame timing (FLUX_FRAME_TIMING)
──────────────────────────────────────────────────────────────────────────────
flux-stream emits ControlMessage::FrameTiming only when FLUX_FRAME_TIMING is
set in the flux-host process environment. To eyeball it, run flux-host straight
from a shell:

  FLUX_FRAME_TIMING=1 "$INSTALL_BIN" stream --advertise --display-id 1

Wiring this into the OpenBench Host subprocess (HostManager.swift) is a separate
step — this script intentionally does NOT edit HostManager.swift.
EOF
fi
