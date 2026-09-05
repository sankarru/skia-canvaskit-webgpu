# skia-canvaskit-webgpu

CanvasKit WASM built from **latest Skia main** with the **Graphite + Dawn (WebGPU)**
backend, compiled on GitHub Actions (Ubuntu 24.04 + Emscripten from DEPS).

Based on the recipe in [open-pencil/skia](https://github.com/open-pencil/skia)
(`webgpu` branch: `BUILD_WEBGPU.md` + `patches/dawn-tint.patch`).

## Features compiled in

| Area | Status |
|---|---|
| Skia Graphite + Dawn WebGPU | ✅ |
| Paragraph + HarfBuzz/ICU shaper | ✅ JS API |
| Skottie (Lottie) | ✅ JS API |
| JPEG/PNG/WebP decode **and** encode | ✅ JS API |
| PathOps, canvas/matrix bindings, RT-shader, SKP, effects | ✅ JS API |
| Fonts (embedded + woff2) | ✅ |
| SkSVG / SkPDF / particles libs | ✅ compiled in, ❌ **no upstream JS bindings** |

SVG / particles / PDF have no JavaScript bindings upstream (`modules/canvaskit/src`
ships none), so they are compiled into the binary but not yet callable from JS.
Writing those bindings is the follow-up task.

## Build

Actions → `build-canvaskit-webgpu` → Run workflow. Inputs toggle
`enable_pdf` / `enable_svg` / `enable_particles`, the Skia ref, and whether to
publish a release. Artifacts (`canvaskit.js`, `canvaskit.wasm`, `SKIA_SHA`,
`SHA256SUMS`) upload on every run; releases are tagged
`canvaskit-webgpu-YYYYMMDD-<sha12>`.

Takes ~1–3h on `ubuntu-24.04` runners (full Skia clone + DEPS + Emscripten).

## Use (JS)

```js
const ck = await CanvasKitInit({ locateFile: f => '/canvaskit/' + f });
const device = await (await navigator.gpu.requestAdapter()).requestDevice();
const devCtx = ck.MakeGPUDeviceContext(device);
const canvasCtx = ck.MakeGPUCanvasContext(devCtx, canvas);
// per frame:
const surface = ck.MakeGPUCanvasSurface(canvasCtx, null, W, H);
const c = surface.getCanvas();
c.clear(ck.parseColorString('#87CEEB')); // NOTE: ck.Color() is NaN-broken here
const p = new ck.Paint();                // NOTE: no MakePaint factory
p.setColor(ck.parseColorString('#4A90E2'));
c.drawRect(ck.XYWHRect(50, 50, 200, 150), p);
surface.flush();
```

Quirks found while probing v0.1.0 (verify against new builds):
`ck.Color()` → `NaN`, use `parseColorString`/`Color4f`; paint = `new ck.Paint()`;
text size via `new ck.Font(null, px)` passed to `drawText`; `makeImageSnapshot()`
on swapchain surfaces returns null; `surface.reportBackendTypeIsGPU()` proves GPU.
