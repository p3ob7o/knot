import { describe, expect, test } from "vitest";
import showdown, { Converter } from "../vendor/showdown-safe/index.js";

describe("safe WordPress raw-paste adapter", () => {
  test("escapes active HTML and preserves pasted text without Markdown execution", () => {
    const value = '<img src=x onerror="run()">\n# literal heading';
    const expected = "<p>&lt;img src=x onerror=&quot;run()&quot;&gt;<br># literal heading</p>";
    expect(new Converter().makeHtml(value)).toBe(expected);
    expect(new showdown.Converter().makeHtml(value)).toBe(expected);
  });
});
