/* On-device text reader for Scan. Runs PaddleOCR (PP-OCR models through
   onnxruntime-web) in a background worker, so the photo never leaves the
   device and the screen stays responsive. No key, no server.

   Message in:  { id, image: ArrayBuffer }        (JPEG or PNG bytes)
   Message out: { id, lines: [{ text, x, y, w, h, score }] }  or  { id, error } */
import { PaddleOcrService } from "https://cdn.jsdelivr.net/npm/ppu-paddle-ocr@6.7.1/web/+esm";

let ready = null;
let service = null;

function start() {
  if (!ready) {
    // "wasm" only: works on every phone and keeps results the same everywhere.
    // Models are served by the app itself (pwa/models/, see scripts/fetch_ocr_models.py).
    const at = (name) => new URL(`models/${name}`, self.location.href).href;
    service = new PaddleOcrService({
      model: { detection: at("det.ort"), recognition: at("rec.ort"), charactersDictionary: at("dict.txt") },
      session: { executionProviders: ["wasm"], graphOptimizationLevel: "all" },
    });
    ready = service.initialize().catch((e) => { ready = null; throw e; });
  }
  return ready;
}

self.onmessage = async (event) => {
  const { id, image, warm } = event.data || {};
  try {
    await start();
    if (warm) return self.postMessage({ id, lines: [] });
    const result = await service.recognize(image, { flatten: true });
    const lines = (result.results || []).map((r) => ({
      text: String(r.text || "").trim(),
      x: r.box?.x ?? 0, y: r.box?.y ?? 0, w: r.box?.width ?? 0, h: r.box?.height ?? 0,
      score: r.confidence ?? 0,
    })).filter((l) => l.text);
    self.postMessage({ id, lines });
  } catch (e) {
    self.postMessage({ id, error: String(e?.message || e) });
  }
};
