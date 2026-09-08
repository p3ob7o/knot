import { describe, expect, test } from "vitest";
import { blocksToMarkdown, markdownToBlocks } from "../src/codec";
import { sanitizedHtmlToMarkdown } from "../src/html";

describe("T14 rich Markdown codec", () => {
  test("supports nested lists, starts, quotes, marks, links, code, images, and captions", () => {
    const source = "## Head **bold** and [link](https://example.com)  \nnext\n\n3. outer\n   - inner\n\n> quoted\n>\n> - item\n\n```swift\nlet fence = `ok`\n```\n\n![alt](asset.png \"title\")";
    const blocks = markdownToBlocks(source);
    expect(blocks.map((block) => block.name)).toEqual(["core/heading", "core/paragraph", "core/list", "core/quote", "core/code", "core/image"]);
    const image = blocks.find((block) => block.name === "core/image");
    if (image) image.attributes.caption = "<em>Caption</em>";
    const output = blocksToMarkdown(blocks);
    expect(output).toContain("3. outer");
    expect(output).toContain("- inner");
    expect(output).toContain("```swift");
    expect(output).toContain("![alt](asset.png \"title\")");
    expect(output).toContain("Caption");
  });

  test("retains unsupported Obsidian and frontmatter regions as exact source blocks", () => {
    for (const source of ["---\ntags: [one]\n---", "![[asset.png|caption]]", "| A | B |\n| - | - |\n| 1 | 2 |", "> [!note]\n> body"]) {
      const blocks = markdownToBlocks(source);
      expect(blocks).toHaveLength(1);
      expect(blocks[0].name).toBe("knot/source");
      expect(blocksToMarkdown(blocks)).toBe(source);
    }
  });

  test("unknown block data is an actionable error", () => {
    expect(() => blocksToMarkdown([{ name: "plugin/unknown", attributes: {} }])).toThrow("unsupportedBlock");
  });
});

describe("clipboard sanitizer", () => {
  test("keeps readable formatting and removes active content and unsafe schemes", () => {
    const output = sanitizedHtmlToMarkdown('<p onclick="bad()"><strong>safe</strong> <a href="javascript:bad()">link</a></p><script>bad()</script><form><input value="x"></form>');
    expect(output).toContain("**safe** link");
    expect(output).not.toMatch(/javascript|script|form|onclick|bad\(\)/i);
  });
});
