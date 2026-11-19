import { defineConfig } from "vite";
import { fileURLToPath } from "node:url";
import { readFileSync, writeFileSync } from "node:fs";
import react from "@vitejs/plugin-react";

function macOSWKWebViewBundlePlugin() {
  function classicScriptHTML(source) {
    return source
      .replace(/\s+type="module"/g, "")
      .replace(/\s+crossorigin(="[^"]*")?/g, "")
      .replace(
        /<script(?![^>]*\bdefer\b)([^>]*\bsrc="\.\/assets\/index-[^"]+\.js"[^>]*)><\/script>/g,
        "<script defer$1></script>"
      );
  }

  return {
    name: "knot-macos-wkwebview-bundle",
    closeBundle() {
      const indexURL = new URL("./dist/index.html", import.meta.url);
      const source = readFileSync(indexURL, "utf8");
      writeFileSync(indexURL, classicScriptHTML(source));
    },
  };
}

export default defineConfig({
  plugins: [react(), macOSWKWebViewBundlePlugin()],
  base: "./",
  resolve: {
    alias: {
      "@wordpress/upload-media": fileURLToPath(new URL("./src/uploadMediaStub.js", import.meta.url)),
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rolldownOptions: {
      output: {
        format: "iife",
        name: "KnotGutenbergEditor",
        entryFileNames: "assets/[name]-[hash].js",
      },
    },
  },
});
