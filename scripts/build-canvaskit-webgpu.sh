#!/bin/bash
# Build CanvasKit (Skia Graphite + Dawn WebGPU) with all features.
# Runs inside GitHub Actions (ubuntu-24.04). Expects to be run from the
# root of a full Skia checkout (google/skia@main + git-sync-deps done).
#
# Env toggles (set by workflow_dispatch inputs):
#   ENABLE_PDF / ENABLE_SVG / ENABLE_PARTICLES (default true)
set -ex

SKIA_DIR="${SKIA_DIR:-$PWD}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENABLE_PDF="${ENABLE_PDF:-true}"
ENABLE_SVG="${ENABLE_SVG:-true}"
ENABLE_PARTICLES="${ENABLE_PARTICLES:-true}"

cd "$SKIA_DIR"

# ---- 1. Dawn tint patch (missing include) ----
# Upstream may have fixed it; apply only if still needed.
if [ -f "$REPO_DIR/patches/dawn-tint.patch" ]; then
  if git -C third_party/externals/dawn apply --check "$REPO_DIR/patches/dawn-tint.patch" 2>/dev/null; then
    echo "Applying dawn-tint.patch"
    git -C third_party/externals/dawn apply "$REPO_DIR/patches/dawn-tint.patch"
  else
    echo "dawn-tint.patch not needed (already fixed upstream or Dawn layout changed)"
  fi
fi

# ---- 2. Extra GN features not covered by compile.sh flags ----
# compile.sh webgpu already enables: graphite, webgpu/dawn, skottie,
# paragraph (+harfbuzz/icu shaper), skshaper, pathops, canvas+matrix
# bindings, fonts (+embedded), woff2, jpeg/png/webp decode+encode,
# rt-shader, skp serialization, effects deserialization.
CS="modules/canvaskit/compile.sh"
cp "$CS" "$CS.bak"

if [ "$ENABLE_PDF" = "true" ]; then
  # NOTE: builds SkPDF lib into the binary; upstream CanvasKit ships
  # no PDF *JS bindings*, so JS control needs custom bindings (follow-up).
  sed -i 's/skia_enable_pdf=false/skia_enable_pdf=true/' "$CS"
fi
if [ "$ENABLE_SVG" = "true" ]; then
  # NOTE: same caveat — no upstream SVG JS bindings; lib compiled in.
  if grep -q 'skia_enable_svg' "$CS"; then
    sed -i 's/skia_enable_svg=false/skia_enable_svg=true/' "$CS"
  else
    sed -i 's|skia_enable_skottie=${ENABLE_SKOTTIE} \\|skia_enable_skottie=${ENABLE_SKOTTIE} \\\n  skia_enable_svg=true \\|' "$CS"
  fi
fi
if [ "$ENABLE_PARTICLES" = "true" ]; then
  # NOTE: same caveat — no upstream particles JS bindings; lib compiled in.
  if grep -q 'skia_enable_particles' "$CS"; then
    sed -i 's/skia_enable_particles=false/skia_enable_particles=true/' "$CS"
  else
    sed -i 's|skia_enable_skottie=${ENABLE_SKOTTIE} \\|skia_enable_skottie=${ENABLE_SKOTTIE} \\\n  skia_enable_particles=true \\|' "$CS"
  fi
fi
grep -nE 'skia_enable_(pdf|svg|particles|skottie|graphite)|skia_use_(dawn|webgpu)=' "$CS"

# ---- 3. Emscripten from DEPS ----
python3 bin/activate-emsdk
# shellcheck disable=SC1091
source third_party/externals/emsdk/emsdk_env.sh

# Prevent host headers leaking into emscripten (macOS; harmless on Linux)
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH || true

# ---- 4. Build ----
bash modules/canvaskit/compile.sh webgpu

echo "=== OUTPUT ==="
ls -la out/canvaskit_wasm/canvaskit.js out/canvaskit_wasm/canvaskit.wasm
