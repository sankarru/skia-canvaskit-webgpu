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
        # CMake>=3.24 injects -fdiagnostics-color=always into every compile
        # (Ninja default). Harmless for .c/.cc, but assembling compiler-rt's
        # .s during emscripten sysroot builds warns "argument unused" — and
        # Dawn's struct_info step uses -Werror. Turn color off entirely.
        "-DCMAKE_COLOR_DIAGNOSTICS=OFF",
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
# ---- 1f. Copy Emscripten headers (not vanilla) for wasm ----
# build_dawn.py copies cmake_dawn/gen/include/{dawn,webgpu} for Skia to
# consume, but under EMSCRIPTEN that dir is never produced — the usable
# headers (no __EMSCRIPTEN__ guard) live at
# cmake_dawn/gen/src/emdawnwebgpu/include/{dawn,webgpu}. Repoint the source.
python3 - <<'EOF'
import pathlib
p = pathlib.Path("third_party/dawn/build_dawn.py")
src = p.read_text()
old = '  generated_headers_src = os.path.join(build_dir, "gen", "include")\n'
assert old in src, "build_dawn.py headers anchor missing"
new = old + '''  if target_os == "wasm":
    generated_headers_src = os.path.join(
        build_dir, "gen", "src", "emdawnwebgpu", "include")
'''
p.write_text(src.replace(old, new))
print("build_dawn.py: wasm headers copied from emdawnwebgpu layout")
EOF

# ---- 1g. Emscripten headers must include Dawn-tagged API ----
# Dawn's generator renders emdawnwebgpu headers with enabled_tags=['emscripten']
# only, dropping everything tagged 'dawn' (16-bit formats, feature tiers,
# wgpu::Status...). Skia main's __EMSCRIPTEN__ branches REQUIRE those names,
# so the EM headers are unusable as generated. Widen to match the vanilla
# set minus 'native' (desktop-only). The api.h __EMSCRIPTEN__ guard is keyed
# off 'native' presence so vanilla keeps its guard and EM stays clean:
#   vanilla (dawn+emscripten+native+deprecated): guard ON (unchanged)
#   emscripten (emscripten+dawn+deprecated):     guard OFF (fixed)
python3 - <<'EOF'
import pathlib
g = pathlib.Path("third_party/externals/dawn/generator/dawn_json_generator.py")
src = g.read_text()
old_tags = "enabled_tags=['emscripten'])"
assert src.count(old_tags) >= 2, f"expected >=2 EM tag sites, found {src.count(old_tags)}"
src = src.replace(old_tags,
                  "enabled_tags=['emscripten', 'dawn', 'deprecated'])")
g.write_text(src)
print("dawn_json_generator.py: EM tags widened (headers + modules)")

t = pathlib.Path("third_party/externals/dawn/generator/templates/api.h")
tsrc = t.read_text()
old_guard = "{%- if 'dawn' in enabled_tags %}"
assert tsrc.count(old_guard) == 1, "api.h guard anchor not unique/found"
tsrc = tsrc.replace(old_guard,
                    "{%- if 'dawn' in enabled_tags and 'native' in enabled_tags %}")
t.write_text(tsrc)
print("api.h: emscripten guard now requires native tag")

# Same guard lives in the C++ templates (vanilla webgpu_cpp.h /
# webgpu_cpp_chained_struct.h must keep it; EM output must not have it).
# api_cpp_print.h and the rest have no such guard (verified).
for _name in ["api_cpp.h", "api_cpp_chained_struct.h"]:
    _p = pathlib.Path("third_party/externals/dawn/generator/templates") / _name
    _s = _p.read_text()
    _old = "{% if 'dawn' in enabled_tags %}"
    assert _s.count(_old) == 1, f"{_name} guard anchor not unique/found"
    _p.write_text(_s.replace(
        _old, "{% if 'dawn' in enabled_tags and 'native' in enabled_tags %}"))
    print(f"{_name}: emscripten guard now requires native tag")
EOF
# ---- 1h. Skia must include Dawn's EM headers, not Emscripten's bundled ones
# dawn_api_config sets include_dirs=[] for canvaskit ("Emscripten includes its
# own WebGPU headers"), so Skia compiles against emsdk's stale subset (no
# Status, no 16-bit formats, no feature tiers...). Point it at Dawn's own
# generated Emscripten headers first (copied by build_dawn.py), then Dawn
# sources for the redirectors. Gen dir first so it shadows the emsdk copy.
python3 - <<'EOF'
import pathlib
p = pathlib.Path("third_party/dawn/BUILD.gn")
src = p.read_text()
old = """  } else {
    # Emscripten includes its own WebGPU headers.
    include_dirs = []
  }
  if (is_win) {"""
assert src.count(old) == 1, "dawn_api_config anchor not unique/found"
new = """  } else {
    # CanvasKit-on-Dawn: Emscripten's bundled WebGPU headers are too old for
    # Skia's Graphite backend (missing Status, 16-bit formats, feature
    # tiers...). Use Dawn's generated Emscripten headers instead.
    include_dirs = [
      "$root_gen_dir/third_party/dawn/include",
      "../externals/dawn",
      "../externals/dawn/include",
    ]
  }
  if (is_win) {"""
p.write_text(src.replace(old, new))
print("dawn_api_config: canvaskit uses Dawn EM headers")
EOF

# ---- 1j. Define CK_ENABLE_WEBGPU (upstream never wires it) ----
# canvaskit_bindings.cpp gates the Dawn MakeGrContext() + _MakeGrContext
# embind binding on CK_ENABLE_WEBGPU, but modules/canvaskit/BUILD.gn only
# ever defines CK_ENABLE_WEBGL. Result: webgpu.js calls this._MakeGrContext()
# which doesn't exist ("not a function"). Wire the define to the GN arg.
python3 - <<'EOF'
import pathlib
p = pathlib.Path("modules/canvaskit/BUILD.gn")
src = p.read_text()
old = """  if (skia_enable_ganesh) {
    defines += [ "SK_GANESH" ]
    if (skia_canvaskit_enable_webgl) {
      defines += [
        "SK_GL",
        "CK_ENABLE_WEBGL",
      ]
    }
  }"""
assert src.count(old) == 1, "canvaskit BUILD.gn ganesh anchor not unique/found"
new = old + """
  if (skia_canvaskit_enable_webgpu) {
    defines += [ "CK_ENABLE_WEBGPU" ]
  }"""
p.write_text(src.replace(old, new))
print("canvaskit BUILD.gn: CK_ENABLE_WEBGPU wired")
EOF
# Upstream Skia carries stale __EMSCRIPTEN__ branches written against Dawn's
# removed C API. The unified C++ API works on Emscripten, so drop the stale
# branches. Assert-anchored: fails loud if upstream migrates these itself.
python3 "$REPO_DIR/scripts/port-skia-dawn-wasm.py" "$SKIA_DIR"
# ---- 1j2. Port CanvasKit Dawn bindings Ganesh -> Graphite ----
# Upstream's CK_ENABLE_WEBGPU bindings target the removed Ganesh-on-Dawn
# backend (GrDirectContext::MakeDawn no longer exists). Rewrites them around
# Graphite (ContextFactory::MakeDawn, per-surface Recorder, explicit
# snap/insert/submit present). Same JS contract. Assert-anchored.
python3 "$REPO_DIR/scripts/port-canvaskit-graphite.py" "$SKIA_DIR"
# ---- 1k. Drop Emscripten's libwebgpu.a; wire Dawn's JS glue instead ----
# Emscripten's lib duplicates 4 Dawn C functions AND predates Dawn's struct
# layouts. Dawn's side is self-consistent (headers+objects+JS, one rev), so:
# remove -sUSE_WEBGPU=1 and add Dawn's emdawnwebgpu --js-library files.
# (GetQueue/WGPUReference/etc. resolve via Dawn headers (inline) + objects;
# html5 import_* shims come from Emscripten's libhtml5_webgpu.js, added in 1l.)
python3 - <<'EOF'
import pathlib
p = pathlib.Path("modules/canvaskit/BUILD.gn")
src = p.read_text()
old = """      "-sUSE_WEBGL2=0",
      "-sUSE_WEBGPU=1",
      "-sASYNCIFY","""
assert src.count(old) == 1, "canvaskit webgpu ldflags anchor not unique/found"
new = """      "-sUSE_WEBGL2=0",
      "-sASYNCIFY","""
src = src.replace(old, new)
old2 = """      # Modules from html5_webgpu for JS<->WASM interop
      "-sEXPORTED_RUNTIME_METHODS=WebGPU,JsValStore","""
assert src.count(old2) == 1, "canvaskit exports anchor not unique/found"
new2 = """      # Modules from html5_webgpu for JS<->WASM interop
      "-sEXPORTED_RUNTIME_METHODS=WebGPU,JsValStore",

      # Dawn's own Emscripten JS glue (same rev as headers/objects).
      # EM gen dir paths are relative to root_build_dir (ninja link cwd).
      "--js-library=cmake_dawn/gen/src/emdawnwebgpu/library_webgpu_enum_tables.js",
      "--js-library=cmake_dawn/gen/src/emdawnwebgpu/library_webgpu_generated_sig_info.js",
      "--js-library=cmake_dawn/gen/src/emdawnwebgpu/library_webgpu_generated_struct_info.js",
      "--js-library=" + rebase_path(
              "../../third_party/externals/dawn/third_party/emdawnwebgpu/pkg/webgpu/src/library_webgpu.js",
              root_build_dir),"""
p.write_text(src.replace(old2, new2))
print("canvaskit BUILD.gn: Dawn emdawnwebgpu JS libs wired, USE_WEBGPU dropped")
EOF
# ---- 1l. Canvaskit target: Dawn EM includes + html5 JS glue + Ganesh guard --
# (a) canvaskit_bindings resolves webgpu headers via Emscripten's stale subset
#     (its C++ wrappers are declaration-only there). Point it at Dawn's
#     generated headers (inline bodies, same rev as the linked objects).
# (b) emscripten_webgpu_import_texture/release_js_handle/get_device live in
#     Emscripten's libhtml5_webgpu.js (NOT auto-linked without USE_WEBGPU).
#     Wire it explicitly by absolute path (baked per-run, deterministic).
# (c) GrDirectContext::releaseResourcesAndAbandonContext has no implementation
#     (Ganesh sources unbuilt) — guard its embind registration out.
python3 - <<'EOF'
import pathlib
p = pathlib.Path("modules/canvaskit/BUILD.gn")
src = p.read_text()
old_deps = 'skia_wasm_lib("canvaskit") {\n  deps = [ "../..:skia" ]\n'
assert src.count(old_deps) == 1, "canvaskit target anchor not unique/found"
new_deps = old_deps + """  if (skia_canvaskit_enable_webgpu) {
    # Dawn's generated Emscripten headers (inline C++ bodies). Emscripten's
    # bundled subset is too old and its native lib is deliberately unlinked.
    include_dirs = [ "$root_gen_dir/third_party/dawn/include" ]
  }
"""
src = src.replace(old_deps, new_deps)
old_js = '      "--js-library=cmake_dawn/gen/src/emdawnwebgpu/library_webgpu_generated_struct_info.js",\n'
assert src.count(old_js) == 1, "js-libs anchor not unique/found"
emsdk_js = (
    pathlib.Path.cwd()
    / "third_party/externals/emsdk/upstream/emscripten/src/lib/libhtml5_webgpu.js"
)
assert emsdk_js.exists(), f"html5_webgpu.js missing at {emsdk_js}"
new_js = old_js + f'      "--js-library={emsdk_js}",\n'
src = src.replace(old_js, new_js)
p.write_text(src)
print("canvaskit BUILD.gn: Dawn includes + html5 JS lib wired")
EOF
python3 - <<'EOF'
import pathlib, re
p = pathlib.Path("modules/canvaskit/canvaskit_bindings.cpp")
src = p.read_text()
m = re.search(r'            \.function\("_getResourceCacheLimitBytes",', src)
assert m is not None, "resource-cache block anchor missing"
end_marker = "self.setResourceCacheLimits(maxResources, maxResourceBytes);\n                      }));\n"
e = src.find(end_marker, m.start())
assert e != -1, "resource-cache block end anchor missing"
e += len(end_marker)
block = src[m.start():e]
guarded = "#ifdef CK_ENABLE_WEBGL\n" + block
    + "#else\n            ;  // terminate class_ chain when WebGL methods are out\n"
    + "#endif  // CK_ENABLE_WEBGL\n"
src = src[: m.start()] + guarded + src[e:]
p.write_text(src)
print("bindings: Ganesh-only resource-cache methods guarded to WebGL")
EOF
# ---- 3. Emscripten from DEPS ----
python3 bin/activate-emsdk
# shellcheck disable=SC1091
source third_party/externals/emsdk/emsdk_env.sh

# ---- 3b. ccache as Emscripten compiler wrapper ----
# sccache was tried and REMOVED: it injects -fdiagnostics-color=always into
# clang's argv, fatal for assembler paths under -Werror (Dawn struct_info).
# ccache only preserves client flags (never injects), so it is safe here.
# (Filament's "no ccache" rule is about cmake picking /usr/bin/ccache as the
# COMPILER; we invoke it solely as emcc's COMPILER_WRAPPER, so detection is
# unaffected.) Cache dir persists via CI (CCACHE_DIR below).
if [ "${USE_CCACHE:-true}" = "true" ]; then
  if command -v ccache >/dev/null 2>&1; then
    export EM_CONFIG="$EMSDK/.emscripten"
    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-4G}"
    export CCACHE_COMPRESS="${CCACHE_COMPRESS:-true}"
    export CCACHE_SLOPPINESS="time_macros"
    python3 - <<'EOF'
import pathlib, os, re
cfg = pathlib.Path(os.environ["EM_CONFIG"])
src = cfg.read_text()
line = "COMPILER_WRAPPER = 'ccache'"
if "COMPILER_WRAPPER" in src:
    src = re.sub(r"(?m)^#?\s*COMPILER_WRAPPER\s*=.*$", line, src)
else:
    src = src.rstrip("\n") + "\n" + line + "\n"
cfg.write_text(src)
print("emcc wrapper:", [l for l in src.splitlines() if "COMPILER_WRAPPER" in l])
EOF
    ccache -z >/dev/null 2>&1 || true
    echo 'int ccache_warmup(void){return 42;}' > /tmp/ccache_warmup.c
    emcc -c /tmp/ccache_warmup.c -o /tmp/ccache_warmup.o
    echo "--- ccache stats after warmup (files/direct hits must be >= 0, misses >= 1) ---"
    ccache -s | grep -E "cache (hit|miss)|files in cache|Cache size" || ccache -s || true
    echo "ccache enabled via COMPILER_WRAPPER"
  else
    echo "WARNING: ccache not found; install it (apt install ccache) for faster rebuilds"
  fi
fi

# Prevent host headers leaking into emscripten (macOS; harmless on Linux)
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH || true

# Belt and braces (harmless without sccache): keep the unused-arg downgrade
# for any -Werror assembler path in Emscripten tooling.
export EMCC_CFLAGS="-Wno-error=unused-command-line-argument"

# ---- 4. Build ----
bash modules/canvaskit/compile.sh webgpu

echo "=== OUTPUT ==="
ls -la out/canvaskit_wasm/canvaskit.js out/canvaskit_wasm/canvaskit.wasm
