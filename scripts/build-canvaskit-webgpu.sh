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
USE_SCCACHE="${USE_SCCACHE:-false}"

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

# ---- 1b. Dawn must be compiled with Emscripten, not host cc/c++ ----
# third_party/dawn/BUILD.gn sets _cc/_cxx from file-scope cc/cxx, which
# arrive as literal "cc"/"c++" for the wasm toolchain on current main.
# That makes Dawn's CMake configure host-GCC builds (and chokes on C++20
# modules). Force emcc/em++ when targeting wasm. Host tint build is
# untouched (guarded by current_os).
python3 - <<'EOF'
import pathlib
p = pathlib.Path("third_party/dawn/BUILD.gn")
src = p.read_text()
old = """} else {
  _cc = cc
  _cxx = cxx
  _dawn_lib_name = "libdawn_combined.a\""""
new = """} else {
  _cc = cc
  _cxx = cxx
  if (current_os == "wasm") {
    # Absolute source paths; no build-arg scope needed.
    _cc = rebase_path("//third_party/externals/emsdk/upstream/emscripten/emcc")
    _cxx = rebase_path("//third_party/externals/emsdk/upstream/emscripten/em++")
  }
  _dawn_lib_name = "libdawn_combined.a\""""
assert old in src, "dawn BUILD.gn anchor not found; upstream changed the file"
p.write_text(src.replace(old, new))
print("dawn BUILD.gn: wasm cc/cxx forced to emcc/em++")
EOF

# ---- 1c. Give Dawn its Emdawnwebgpu headers (vendored in Dawn itself) ----
# cmake_utils.py hardcodes -DDAWN_EMDAWNWEBGPU_DIR=NOT_SYNCED_BY_SKIA, but
# current Dawn *requires* these headers for wasm builds: its generated
# webgpu.h errors with "Use the headers provided by Emdawnwebgpu instead".
# Dawn vendors the package at third_party/emdawnwebgpu (committed files,
# not a submodule), so point CMake at it like the other verified deps.
python3 - <<'EOF'
import pathlib
p = pathlib.Path("third_party/dawn/cmake_utils.py")
src = p.read_text()
old = '"-DDAWN_EMDAWNWEBGPU_DIR=NOT_SYNCED_BY_SKIA",'
new = """f"-DDAWN_EMDAWNWEBGPU_DIR={verify_and_get('dawn/third_party/emdawnwebgpu')}\","""
assert old in src, "cmake_utils.py anchor not found; upstream changed the file"
p.write_text(src.replace(old, new))
print("cmake_utils.py: DAWN_EMDAWNWEBGPU_DIR -> vendored copy")
EOF
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
# NOTE: skia_enable_particles does not exist on current main (GN warns
# "never appeared in a declare_args block") — the particles module builds
# as part of the default skia target, so there is nothing to flip.
# (Still no upstream JS bindings for it — same caveat as SVG/PDF.)
grep -nE 'skia_enable_(pdf|svg|particles|skottie|graphite)|skia_use_(dawn|webgpu)=' "$CS"

# ---- 1d. Build Dawn with Emscripten's toolchain file (not SYSTEM_NAME=wasm) ----
# Dawn keys its entire Emscripten path (emdawnwebgpu headers shadowing the
# vanilla generated ones) off the EMSCRIPTEN cmake var, which is only set by
# Emscripten's toolchain file. -DCMAKE_SYSTEM_NAME=wasm leaves EMSCRIPTEN=0
# while emcc still defines __EMSCRIPTEN__, tripping the guard in
# gen/include/dawn/webgpu.h ("Use the headers provided by Emdawnwebgpu").
python3 - <<'EOF'
import pathlib
p = pathlib.Path("third_party/dawn/build_dawn.py")
src = p.read_text()
old_sys = """      f"-DCMAKE_SYSTEM_NAME={target_os}",
      f"-DCMAKE_SYSTEM_PROCESSOR={target_cpu}",
"""
assert old_sys in src, "build_dawn.py SYSTEM lines anchor missing"
src = src.replace(old_sys, "")
old_loc = "  configure_cmd += get_third_party_locations()\n"
assert old_loc in src, "build_dawn.py locations anchor missing"
new_loc = """  if target_os == "wasm":
    _emsdk = os.environ.get("EMSDK", "")
    assert _emsdk, "EMSDK env var required for wasm Dawn build (source emsdk_env.sh)"
    configure_cmd += [
        "-DCMAKE_TOOLCHAIN_FILE=" + os.path.join(
            _emsdk, "upstream", "emscripten", "cmake", "Modules",
            "Platform", "Emscripten.cmake"),
    ]
  else:
    configure_cmd += [
        f"-DCMAKE_SYSTEM_NAME={target_os}",
        f"-DCMAKE_SYSTEM_PROCESSOR={target_cpu}",
    ]
  configure_cmd += get_third_party_locations()
"""
p.write_text(src.replace(old_loc, new_loc))
print("build_dawn.py: wasm uses Emscripten toolchain file")
EOF

# ---- 1e. Dawn has no dawn_proc target under Emscripten ----
# src/dawn/CMakeLists.txt guards dawn_proc with if(NOT EMSCRIPTEN) — the
# Emscripten port (emdawnwebgpu) provides the proc table instead. Skia's
# build_dawn.py hardcodes the target list, so drop dawn_proc for wasm
# (combine_into_library derives from the same list, so it follows).
python3 - <<'EOF'
import pathlib
p = pathlib.Path("third_party/dawn/build_dawn.py")
src = p.read_text()
old = '  build_targets = ["webgpu_headers_gen", "dawn_proc", "dawn_native"]\n'
assert old in src, "build_dawn.py targets anchor missing"
new = old + '''  if target_os == "wasm":
    # Under EMSCRIPTEN, Dawn builds no dawn_proc (NOT EMSCRIPTEN-guarded)
    # and no dawn_native (native/ subdir skipped). The Emscripten port
    # targets provide the C/C++ shims + JS glue instead.
    build_targets = ["webgpu_headers_gen", "emdawnwebgpu_c", "emdawnwebgpu_cpp"]
'''
p.write_text(src.replace(old, new))
print("build_dawn.py: dawn_proc dropped for wasm")
EOF

# ---- 3. Emscripten from DEPS ----
python3 bin/activate-emsdk
# shellcheck disable=SC1091
source third_party/externals/emsdk/emsdk_env.sh

# ---- 3b. sccache as Emscripten compiler wrapper ----
# emcc does NOT read EM_COMPILER_WRAPPER from the environment; the wrapper
# comes from the emscripten config file (COMPILER_WRAPPER) or the
# --compiler-wrapper flag. Write it into $EMSDK/.emscripten so every emcc
# (ninja, cmake, warmup) goes through sccache with zero GN changes.
if [ "$USE_SCCACHE" = "true" ]; then
  if command -v sccache >/dev/null 2>&1; then
    # emcc reads ONLY its config file for the wrapper (env is ignored), and
    # it locates that file via EM_CONFIG else ~/.emscripten — pin it to the
    # file we edit so the wrapper is guaranteed active.
    export EM_CONFIG="$EMSDK/.emscripten"
    python3 - <<'EOF'
import pathlib, os, re
cfg = pathlib.Path(os.environ["EM_CONFIG"])
src = cfg.read_text()
line = "COMPILER_WRAPPER = 'sccache'"
if "COMPILER_WRAPPER" in src:
    src = re.sub(r"(?m)^#?\s*COMPILER_WRAPPER\s*=.*$", line, src)
else:
    src = src.rstrip("\n") + "\n" + line + "\n"
cfg.write_text(src)
print("emcc config:", os.environ["EM_CONFIG"])
print([l for l in src.splitlines() if "COMPILER_WRAPPER" in l])
EOF
    # Start server loudly (no suppression: a dead server = silent no-cache).
    sccache --stop-server >/dev/null 2>&1 || true
    sccache --start-server
    echo 'int sccache_warmup(void){return 42;}' > /tmp/sccache_warmup.c
    # One real emcc clang compile through the wrapper; stats must show ≥1.
    emcc -c /tmp/sccache_warmup.c -o /tmp/sccache_warmup.o
    echo "--- sccache stats after warmup (Compilations must be >= 1) ---"
    sccache --show-stats | grep -E "Compilations|Cache hits|Cache misses|Cache hits rate" || true
    echo "sccache enabled via COMPILER_WRAPPER in .emscripten config"
  else
    echo "WARNING: USE_SCCACHE=true but sccache not on PATH; building uncached"
  fi
fi

# Prevent host headers leaking into emscripten (macOS; harmless on Linux)
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH || true

# ---- 4. Build ----
bash modules/canvaskit/compile.sh webgpu

echo "=== OUTPUT ==="
ls -la out/canvaskit_wasm/canvaskit.js out/canvaskit_wasm/canvaskit.wasm
