import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

describe("macOS native bridge", () => {
  test("startup probes do not depend on WKWebView result conversion", () => {
    const source = readFileSync(resolve("..", "GutenbergEditorWindowController.swift"), "utf8");

    expect(source).not.toMatch(/evaluateJavaScript\(\s*"""\s*JSON\.stringify/s);
  });
});
