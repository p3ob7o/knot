import { createHash } from "node:crypto";
import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import react from "@vitejs/plugin-react";

const buildID = "knot-gutenberg-20260908-v1";
const maximumEditorScriptBytes = 4_000_000;

function mimeType(path) {
  if (path.endsWith(".html")) return "text/html; charset=utf-8";
  if (path.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (path.endsWith(".css")) return "text/css; charset=utf-8";
  if (path.endsWith(".json")) return "application/json";
  if (path.endsWith(".woff2")) return "font/woff2";
  return "application/octet-stream";
}

function allFiles(root, prefix = "") {
  return readdirSync(new URL(`${prefix || "."}/`, root)).flatMap((name) => {
    const relative = prefix ? `${prefix}/${name}` : name;
    const url = new URL(relative, root);
    return statSync(url).isDirectory() ? allFiles(root, relative) : [relative];
  });
}

function macOSWKWebViewBundlePlugin() {
  return {
    name: "knot-macos-wkwebview-bundle",
    closeBundle() {
      const dist = new URL("./dist/", import.meta.url);
      const indexURL = new URL("index.html", dist);
      const html = readFileSync(indexURL, "utf8")
        .replace(/\s+type="module"/g, "")
        .replace(/\s+crossorigin(="[^"]*")?/g, "")
        .replace(/<script(?![^>]*\bdefer\b)([^>]*\bsrc="\.\/assets\/[^"]+\.js"[^>]*)><\/script>/g, (_match, attributes) => "<script defer" + attributes + "></script>")
        .replace(/<script(?![^>]*\bnonce=)/g, '<script nonce="__KNOT_CSP_NONCE__"');
      const scriptTags = html.match(/<script\b[^>]*>/g) ?? [];
      if (scriptTags.length === 0 || scriptTags.some((tag) => !tag.includes("nonce=\"__KNOT_CSP_NONCE__\""))) {
        throw new Error("Every emitted editor script must carry the per-session CSP nonce placeholder");
      }
      writeFileSync(indexURL, html);
      const editorScripts = allFiles(dist).filter((path) => path.endsWith(".js"));
      const editorScriptBytes = editorScripts.reduce((sum, path) => sum + statSync(new URL(path, dist)).size, 0);
      if (editorScriptBytes > maximumEditorScriptBytes) {
        throw new Error(`Editor scripts total  bytes; reviewed budget is `);
      }
      const files = {};
      for (const path of allFiles(dist).filter((path) => path !== "knot-manifest.json")) {
        const data = readFileSync(new URL(path, dist));
        files[path] = { sha256: createHash("sha256").update(data).digest("hex"), bytes: data.byteLength, mimeType: mimeType(path) };
      }
      writeFileSync(new URL("knot-manifest.json", dist), JSON.stringify({ version: 1, buildID, entry: "index.html", files }, null, 2));
    },
  };
}

export default defineConfig({
  plugins: [react(), macOSWKWebViewBundlePlugin()],
  define: { __KNOT_BUILD_ID__: JSON.stringify(buildID) },
  base: "./",
  resolve: { alias: { "@wordpress/upload-media": fileURLToPath(new URL("./src/uploadMediaStub.js", import.meta.url)) } },
  build: {
    manifest: true,
    chunkSizeWarningLimit: maximumEditorScriptBytes / 1000,
    outDir: "dist",
    emptyOutDir: true,
    rolldownOptions: { output: { format: "iife", name: "KnotGutenbergEditor", entryFileNames: "assets/[name]-[hash].js" } },
  },
});
