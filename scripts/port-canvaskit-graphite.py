#!/usr/bin/env python3
"""Port CanvasKit's Dawn bindings from Ganesh to Graphite (wasm).

Upstream modules/canvaskit/canvaskit_bindings.cpp gates its Dawn GPU code on
CK_ENABLE_WEBGPU, but that code is written against Ganesh (GrDirectContext,
GrBackendTexture, SkSurfaces::WrapBackendTexture) whose Dawn backend was
removed from Skia. This script rewrites those regions against Graphite:

  device context: skgpu::graphite::Context via ContextFactory::MakeDawn
  surfaces:       per-surface Recorder + BackendTexture::MakeDawn(texture)
                  wrapped via skgpu::graphite::WrapBackendTexture
  present:        explicit Recorder::snap + insertRecording + Context::submit
                  (plus submit-on-dispose, matching Ganesh surface behavior)

The JS contract is unchanged (opaque device context; surface-like object with
getCanvas/flush/dispose/_replaceBackendTexture/reportBackendTypeIsGPU), so
webgpu.js needs no changes. Known limitation: persistent-surface texture
rebind now recreates internals (same visible behavior).

Every edit is anchored and asserted: if upstream ports this itself, the script
fails LOUDLY and the corresponding hunk should be dropped.

Run from the Skia checkout root. Takes optional Skia root argv[1].
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.cwd()
P = ROOT / "modules/canvaskit/canvaskit_bindings.cpp"
assert P.exists(), f"bindings not found under {ROOT}"
FAILURES = []


def check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"HUNK-FAILED: {msg}")


def replace_once(old, new, label):
    src = P.read_text()
    n = src.count(old)
    check(n == 1, f"[{label}]: expected 1 anchor, found {n}")
    if n == 1:
        P.write_text(src.replace(old, new))
        print(f"patched [{label}]")


# ------------------------------------------------------------------ includes
replace_once(
    """#ifdef CK_ENABLE_WEBGPU
#include <emscripten/html5_webgpu.h>
#include <webgpu/webgpu.h>
#include <webgpu/webgpu_cpp.h>
#endif  // CK_ENABLE_WEBGPU""",
    """#ifdef CK_ENABLE_WEBGPU
#include <emscripten/html5_webgpu.h>
#include <webgpu/webgpu.h>
#include <webgpu/webgpu_cpp.h>
#include <memory>
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/dawn/DawnBackendContext.h"
#include "include/gpu/graphite/dawn/DawnGraphiteTypes.h"
#endif  // CK_ENABLE_WEBGPU""",
    "graphite-includes",
)

# ------------------------------------------------- device context + surfaces
replace_once(
    """#ifdef CK_ENABLE_WEBGPU

sk_sp<GrDirectContext> MakeGrContext() {
    GrContextOptions options;
    wgpu::Device device = wgpu::Device::Acquire(emscripten_webgpu_get_device());
    return GrDirectContext::MakeDawn(device, options);
}""",
    """#ifdef CK_ENABLE_WEBGPU

// Graphite-backed device context for Dawn-on-Emscripten. Returned to JS as an
// opaque handle (replaces GrDirectContext in the Ganesh model).
struct DawnGraphiteContext {
    wgpu::Instance instance;
    wgpu::Device device;
    wgpu::Queue queue;
    std::unique_ptr<skgpu::graphite::Context> context;
};

// One GPU surface: its own Recorder (deferred-canvas rules forbid sharing),
// the wrapped swapchain texture, and the queue-owning context (shared).
struct DawnGraphiteSurface {
    std::shared_ptr<DawnGraphiteContext> fDevCtx;
    std::unique_ptr<skgpu::graphite::Recorder> fRecorder;
    sk_sp<SkSurface> fSurface;
    sk_sp<SkColorSpace> fColorSpace;

    bool reset(uint32_t textureHandle, sk_sp<SkColorSpace> cs) {
        if (!fDevCtx || !fDevCtx->context) {
            return false;
        }
        if (cs) {
            fColorSpace = std::move(cs);
        }
        if (!fColorSpace) {
            fColorSpace = SkColorSpace::MakeSRGB();
        }
        // Import the JS swapchain texture (adds a native ref); release the
        // JS-store handle right away.
        wgpu::Texture texture(emscripten_webgpu_import_texture(textureHandle));
        emscripten_webgpu_release_js_handle(textureHandle);
        if (!texture.Get()) {
            return false;
        }
        // Dimensions/format are queried from the texture itself.
        skgpu::graphite::BackendTexture backendTex =
                skgpu::graphite::BackendTextures::MakeDawn(texture.Get());
        auto recorder = fDevCtx->context->makeRecorder();
        if (!recorder) {
            return false;
        }
        sk_sp<SkSurface> surface = SkSurfaces::WrapBackendTexture(
                recorder.get(), backendTex, fColorSpace,
                /*props=*/nullptr, /*releaseP=*/nullptr, /*releaseC=*/nullptr,
                "DawnCanvasSurface");
        if (!surface) {
            return false;
        }
        fRecorder = std::move(recorder);
        fSurface = std::move(surface);
        return true;
    }

    SkCanvas* getCanvas() const { return fSurface ? fSurface->getCanvas() : nullptr; }
    int width() const { return fSurface ? fSurface->width() : 0; }
    int height() const { return fSurface ? fSurface->height() : 0; }
    bool reportBackendTypeIsGPU() const { return true; }
    bool flush() {
        if (!fSurface || !fRecorder || !fDevCtx || !fDevCtx->context) {
            return false;
        }
        std::unique_ptr<skgpu::graphite::Recording> recording = fRecorder->snap();
        if (!recording) {
            return true;  // nothing recorded
        }
        skgpu::graphite::InsertRecordingInfo info;
        info.fRecording = recording.get();
        info.fTargetSurface = fSurface.get();
        if (fDevCtx->context->insertRecording(info) !=
            skgpu::graphite::InsertStatus::kSuccess) {
            return false;
        }
        return fDevCtx->context->submit();
    }
    void dispose() {
        this->flush();
        fSurface.reset();
        fRecorder.reset();
    }
    bool replaceBackendTexture(uint32_t textureHandle,
                               uint32_t,
                               int,
                               int) {
        // Swapchain-resize path: recreate internals around the new texture
        // (Graphite surfaces cannot rebind in place). Old contents discarded.
        return this->reset(textureHandle, nullptr);
    }
};

std::shared_ptr<DawnGraphiteContext> MakeGrContext() {
    auto ctx = std::make_shared<DawnGraphiteContext>();
    // Best-effort Instance (may stay null on Emscripten; the backend only
    // requires device+queue there: adapter queries are guarded out).
    if (WGPUInstance rawInstance = wgpuCreateInstance(nullptr)) {
        ctx->instance = wgpu::Instance::Acquire(rawInstance);
    }
    ctx->device = wgpu::Device::Acquire(emscripten_webgpu_get_device());
    if (!ctx->device.Get()) {
        return nullptr;
    }
    ctx->queue = ctx->device.GetQueue();
    if (!ctx->queue.Get()) {
        return nullptr;
    }
    skgpu::graphite::DawnBackendContext backendCtx;
    backendCtx.fInstance = ctx->instance;
    backendCtx.fDevice = ctx->device;
    backendCtx.fQueue = ctx->queue;
    skgpu::graphite::ContextOptions options;
    ctx->context = skgpu::graphite::ContextFactory::MakeDawn(backendCtx, options);
    if (!ctx->context) {
        return nullptr;
    }
    return ctx;
}""",
    "graphite-context-impl",
)

# ----------------------------------------------- MakeGPUTextureSurface body
replace_once(
    """sk_sp<SkSurface> MakeGPUTextureSurface(sk_sp<GrDirectContext> dContext,
                                       uint32_t textureHandle,
                                       uint32_t textureFormat,
                                       int width,
                                       int height,
                                       sk_sp<SkColorSpace> colorSpace) {
    if (!colorSpace) {
        colorSpace = SkColorSpace::MakeSRGB();
    }

    wgpu::TextureFormat format = static_cast<wgpu::TextureFormat>(textureFormat);
    wgpu::Texture texture(emscripten_webgpu_import_texture(textureHandle));
    emscripten_webgpu_release_js_handle(textureHandle);

    // GrDawnRenderTargetInfo currently only supports a 1-mip TextureView.
    constexpr uint32_t mipLevelCount = 1;
    constexpr uint32_t sampleCount = 1;

    GrDawnTextureInfo info;
    info.fTexture = texture;
    info.fFormat = format;
    info.fLevelCount = mipLevelCount;

    GrBackendTexture target(width, height, info);
    return SkSurfaces::WrapBackendTexture(
            dContext.get(),
            target,
            kTopLeft_GrSurfaceOrigin,
            sampleCount,
            colorSpace->isSRGB() ? kRGBA_8888_SkColorType : kRGBA_F16_SkColorType,
            colorSpace,
            nullptr);
}""",
    """std::shared_ptr<DawnGraphiteSurface> MakeGPUTextureSurface(
        std::shared_ptr<DawnGraphiteContext> devCtx,
        uint32_t textureHandle,
        uint32_t /*textureFormat*/,
        int /*width*/,
        int /*height*/,
        sk_sp<SkColorSpace> colorSpace) {
    if (!devCtx || !devCtx->context) {
        return nullptr;
    }
    auto out = std::make_shared<DawnGraphiteSurface>();
    out->fDevCtx = std::move(devCtx);
    if (!out->reset(textureHandle, std::move(colorSpace))) {
        return nullptr;
    }
    return out;
}""",
    "graphite-texture-surface",
)

# ------------------------------------------- ReplaceBackendTexture (delete)
replace_once(
    """bool ReplaceBackendTexture(
        SkSurface& surface, uint32_t textureHandle, uint32_t textureFormat, int width, int height) {
    wgpu::TextureFormat format = static_cast<wgpu::TextureFormat>(textureFormat);
    wgpu::Texture texture(emscripten_webgpu_import_texture(textureHandle));
    emscripten_webgpu_release_js_handle(textureHandle);

    GrDawnTextureInfo info;
    info.fTexture = texture;
    info.fFormat = format;
    info.fLevelCount = 1;

    // Use kDiscard_ContentChangeMode to discard the contents of the old backing texture. This not
    // only avoids an unnecessary blit, we also don't support copying the contents of a swapchain
    // texture due to the default GPUCanvasConfiguration usage bits we used when configuring the
    // GPUCanvasContext in JS.
    //
    // The default usage bits only contain GPUTextureUsage.RENDER_ATTACHMENT. To support a copy we
    // would need to also set GPUTextureUsage.TEXTURE_BINDING (to sample it in a shader) or
    // GPUTextureUsage.COPY_SRC (for a copy command).
    //
    // See https://www.w3.org/TR/webgpu/#namespacedef-gputextureusage and
    // https://www.w3.org/TR/webgpu/#dictdef-gpucanvasconfiguration.
    GrBackendTexture target(width, height, info);
    return surface.replaceBackendTexture(
            target, kTopLeft_GrSurfaceOrigin, SkSurface::kDiscard_ContentChangeMode);
}""",
    """// (Replaced by DawnGraphiteSurface::replaceBackendTexture above: Graphite
// surfaces cannot rebind in place, so swapchain resizes recreate internals.)""",
    "graphite-replace-fn",
)

# --------------------------------- SkSurface-bound _replaceBackendTexture stub
replace_once(
    """            .function("_replaceBackendTexture",
                      optional_override([](SkSurface& self,
                                           uint32_t texHandle,
                                           uint32_t texFormat,
                                           int width,
                                           int height) {
                          return ReplaceBackendTexture(self, texHandle, texFormat, width, height);
                      }))""",
    """            .function("_replaceBackendTexture",
                      optional_override([](SkSurface&,
                                           uint32_t,
                                           uint32_t,
                                           int,
                                           int) {
                          // Graphite path lives on DawnGraphiteSurface; raster
                          // surfaces always reported false here anyway.
                          return false;
                      }))""",
    "surface-replace-stub",
)

# -------------------------------------- holder class_ registrations (embind)
replace_once(
    """#ifdef CK_ENABLE_WEBGPU
    constant("webgpu", true);
    function("_MakeGPUTextureSurface", &MakeGPUTextureSurface);
#endif  // CK_ENABLE_WEBGPU""",
    """#ifdef CK_ENABLE_WEBGPU
    constant("webgpu", true);
    function("_MakeGPUTextureSurface", &MakeGPUTextureSurface);
    class_<DawnGraphiteContext>("DawnGraphiteContext")
        .smart_ptr<std::shared_ptr<DawnGraphiteContext>>(
                "shared_ptr<DawnGraphiteContext>");
    class_<DawnGraphiteSurface>("DawnGraphiteSurface")
        .smart_ptr<std::shared_ptr<DawnGraphiteSurface>>(
                "shared_ptr<DawnGraphiteSurface>")
        .function("getCanvas", &DawnGraphiteSurface::getCanvas, allow_raw_pointers())
        .function("flush", &DawnGraphiteSurface::flush)
        .function("dispose", &DawnGraphiteSurface::dispose)
        .function("reportBackendTypeIsGPU",
                  &DawnGraphiteSurface::reportBackendTypeIsGPU)
        .function("width", &DawnGraphiteSurface::width)
        .function("height", &DawnGraphiteSurface::height)
        .function("_replaceBackendTexture",
                  &DawnGraphiteSurface::replaceBackendTexture);
#endif  // CK_ENABLE_WEBGPU""",
    "holder-bindings",
)

# ------------------------------------------------------------------ includes
# (appended last so line numbers above stay stable for review)
replace_once(
    """#include <emscripten/html5_webgpu.h>
#include <webgpu/webgpu.h>
#include <webgpu/webgpu_cpp.h>""",
    """#include <webgpu/webgpu.h>
#include <webgpu/webgpu_cpp.h>
// NOTE: emsdk's <emscripten/html5_webgpu.h> references the removed
// WGPUSwapChain type; declare the 3 used shims directly instead (their
// implementations come from libhtml5_webgpu.js at link time).
extern "C" {
WGPUDevice emscripten_webgpu_get_device(void);
void emscripten_webgpu_release_js_handle(int js_handle);
WGPUTexture emscripten_webgpu_import_texture(int js_handle);
}""",
    "html5-shims",
)

# --------------------------------- SkSurface GPU helpers need Ganesh impls --
# reportBackendTypeIsGPU/sampleCnt/_resetContext call into unbuilt Ganesh
# code. In Dawn-only builds every SkSurface is raster, so take the
# CPU-build branch (reportBackendTypeIsGPU=false) instead.
replace_once(
    """#ifdef ENABLE_GPU
            .function("reportBackendTypeIsGPU", optional_override([](SkSurface& self) -> bool {
                          return self.getCanvas()->recordingContext() != nullptr;
                      }))""",
    """#if defined(ENABLE_GPU) && defined(CK_ENABLE_WEBGL)
            .function("reportBackendTypeIsGPU", optional_override([](SkSurface& self) -> bool {
                          return self.getCanvas()->recordingContext() != nullptr;
                      }))""",
    "surface-gpu-guard",
)

if FAILURES:
    print(f"\n{len(FAILURES)} hunk(s) failed — upstream moved; rework needed.")
    sys.exit(1)
print("\nAll CanvasKit Graphite-port hunks applied.")
