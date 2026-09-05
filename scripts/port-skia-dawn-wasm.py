#!/usr/bin/env python3
"""Port Skia's Graphite-Dawn backend to the current Dawn API for wasm.

Skia main's src/gpu/graphite/dawn/ carries stale `#if defined(__EMSCRIPTEN__)`
branches written against Dawn's OLD C API (WGPUBufferMapAsyncStatus,
ImageCopy*, ShaderModuleWGSLDescriptor, ...). Current Dawn removed those names;
the unified C++ API (MapAsyncStatus, TexelCopy*, ShaderSourceWGSL, Futures,
CallbackMode, ...) works on Emscripten. This script deletes the stale
Emscripten special-cases so the unified code compiles everywhere.

Every edit is anchored and asserted: if upstream migrates these files
themselves, the script fails LOUDLY (instead of silently half-patching) and
the corresponding hunk should simply be dropped.

Run from the Skia checkout root:  python3 <repo>/scripts/port-skia-dawn-wasm.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.cwd()
D = ROOT / "src/gpu/graphite/dawn"
assert (D / "DawnBuffer.cpp").exists(), f"Skia dawn dir not found under {ROOT}"
FAILURES = []


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"HUNK-FAILED: {msg}")


def remove_em_ifelse(path, start_re, label, count=1):
    """Delete '#if defined(__EMSCRIPTEN__) ... #else NATIVE ... #endif' spans,
    keeping the native branch. The native branch must not itself contain EM
    directives. `count` occurrences are replaced (for repeated patterns)."""
    p = D / path
    src = p.read_text()
    out = src
    found = 0
    while True:
        m = re.search(start_re, out)
        if m is None:
            break
        found += 1
        tail = out[m.start():]
        e_else = re.search(r"\n#else\n", tail)
        check(e_else is not None, f"{path} [{label}]: #else anchor missing")
        if e_else is None:
            return
        after_else = tail[e_else.end():]
        e_endif = re.search(r"\n#endif[^\n]*\n", after_else)
        check(e_endif is not None, f"{path} [{label}]: #endif anchor missing")
        if e_endif is None:
            return
        native_branch = after_else[: e_endif.start()]
        check(
            "__EMSCRIPTEN__" not in native_branch,
            f"{path} [{label}]: native branch contains EM directives, abort",
        )
        out = out[: m.start()] + native_branch + after_else[e_endif.end():]
    check(found == count, f"{path} [{label}]: expected {count}, found {found}")
    if found == count:
        p.write_text(out)
        print(f"patched {path} [{label} x{found}]")


def replace_once(path, old, new, label):
    p = D / path
    src = p.read_text()
    n = src.count(old)
    check(n == 1, f"{path} [{label}]: expected 1 anchor, found {n}")
    if n == 1:
        p.write_text(src.replace(old, new))
        print(f"patched {path} [{label}]")


# ---------------------------------------------------------------- DawnBuffer
# Stale C-style map helpers + C-callback call site -> unified C++ API.
remove_em_ifelse(
    "DawnBuffer.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\nbool is_map_succeeded\(WGPUBufferMapAsyncStatus",
    "em-helpers",
)
remove_em_ifelse(
    "DawnBuffer.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n    fBuffer\.MapAsync\(",
    "em-mapasync-call",
)

# ------------------------------------------------------------------ DawnCaps
# SupportedLimits -> Limits directly (Dawn unified GetLimits(Limits*)).
remove_em_ifelse(
    "DawnCaps.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n    wgpu::SupportedLimits supportedLimits;",
    "em-limits",
)

# -------------------------------------------------------- DawnCommandBuffer
# TexelCopy* aliases pointed at deleted ImageCopy* structs -> use Dawn's own.
replace_once(
    "DawnCommandBuffer.cpp",
    "namespace wgpu {\n"
    "using TexelCopyBufferInfo = ImageCopyBuffer;\n"
    "using TexelCopyTextureInfo = ImageCopyTexture;\n"
    "}  // namespace wgpu\n",
    "",
    "em-texel-alias",
)
remove_em_ifelse(
    "DawnCommandBuffer.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n    wgpu::RenderPassTimestampWrites",
    "render-ts",
)
remove_em_ifelse(
    "DawnCommandBuffer.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n    wgpu::ComputePassTimestampWrites",
    "compute-ts",
)

# -------------------------------------------------------- DawnErrorChecker
# C-callback + DawnAsyncWait version -> Future-based version (works on wasm).
remove_em_ifelse(
    "DawnErrorChecker.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n    struct ErrorState \{\n"
    r"        SkEnumBitMask<DawnErrorType> fError;\n",
    "em-errorstate",
)

# -------------------------------------------------------- DawnQueueManager
# AsyncWait submission class (predates wgpu::Future on wasm) -> Future version.
# Layout is #if EM / AsyncWait / #else / Future / #endif: standard removal.
remove_em_ifelse(
    "DawnQueueManager.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n// GpuWorkSubmission with AsyncWait\.",
    "em-class",
)
remove_em_ifelse(
    "DawnQueueManager.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n"
    r"    return std::make_unique<DawnWorkSubmissionWithAsyncWait>",
    "em-factory",
)

# --------------------------------------- DawnGraphicsPipeline (same hunk x2)
remove_em_ifelse(
    "DawnGraphicsPipeline.cpp",
    r"#if defined\(__EMSCRIPTEN__\)\n"
    r"            layout\.stepMode = wgpu::VertexStepMode::VertexBufferNotUsed;",
    "vertex-step",
    count=2,
)

# --------------------------------------- ShaderModule sites (same hunk x3)
for _path in ["DawnGraphiteUtils.cpp", "DawnResourceProvider.cpp", "DawnSharedContext.cpp"]:
    remove_em_ifelse(
        _path,
        r"#if defined\(__EMSCRIPTEN__\)\n"
        r"    wgpu::ShaderModuleWGSLDescriptor wgslDesc;",
        "em-wgsl-desc",
    )

# ------------------------------------------------- verify no stale names left
STALE = [
    "WGPUBufferMapAsyncStatus",
    "ImageCopyBuffer",
    "ImageCopyTexture",
    "ShaderModuleWGSLDescriptor",
    "SupportedLimits",
    "RenderPassTimestampWrites",
    "ComputePassTimestampWrites",
    "VertexBufferNotUsed",
    "DawnWorkSubmissionWithAsyncWait",
    "TexelCopyBufferInfo = ImageCopyBuffer",
]
for f in sorted(D.glob("Dawn*.cpp")) + sorted(D.glob("Dawn*.h")):
    text = f.read_text()
    for name in STALE:
        if re.search(r"\b" + re.escape(name) + r"\b", text):
            print(f"LEFTOVER?: {f.name}:{name}")
# wgpu::ErrorCallback (old C typedef): only acceptable inside UncapturedError*.
for f in sorted(D.glob("Dawn*.cpp")) + sorted(D.glob("Dawn*.h")):
    text = f.read_text()
    for m in re.finditer(r"(?<!Uncaptured)ErrorCallback", text):
        print(f"LEFTOVER?: {f.name}:ErrorCallback@{m.start()}")

if FAILURES:
    print(f"\n{len(FAILURES)} hunk(s) failed — upstream moved; rework needed.")
    sys.exit(1)
print("\nAll Skia Dawn-wasm hunks applied.")
