import { readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

describe("macOS WKWebView bundle", () => {
  test("loads from a classic local script entrypoint", () => {
    const html = readFileSync(resolve("dist/index.html"), "utf8");

    expect(html).not.toContain('type="module"');
    expect(html).not.toContain("modulepreload");
    expect(html).toMatch(/<script[^>]+\bdefer\b[^>]+src="\.\/assets\/index-[^"]+\.js"><\/script>/);
  });

  test("does not bundle the full Gutenberg block library", () => {
    const scriptPath = readFileSync(resolve("dist/index.html"), "utf8")
      .match(/src="([^"]+)"/)?.[1];

    expect(scriptPath).toBeTruthy();

    const stats = statSync(resolve("dist", scriptPath));
    expect(stats.size).toBeLessThanOrEqual(4_000_000);
  });
});
