import { describe, expect, test } from "vitest";
import { blocksToMarkdown } from "../src/serializer.js";

describe("blocksToMarkdown", () => {
  test("serializes paragraph and heading blocks", () => {
    const blocks = [
      {
        name: "core/heading",
        attributes: { level: 1, content: "Project plan" },
      },
      {
        name: "core/paragraph",
        attributes: { content: "Hello <strong>world</strong><br>Next" },
      },
    ];

    expect(blocksToMarkdown(blocks)).toBe("# Project plan\n\nHello **world**\nNext");
  });

  test("serializes unordered and ordered lists", () => {
    const blocks = [
      {
        name: "core/list",
        attributes: { ordered: false },
        innerBlocks: [
          { name: "core/list-item", attributes: { content: "One" } },
          { name: "core/list-item", attributes: { content: "Two" } },
        ],
      },
      {
        name: "core/list",
        attributes: { ordered: true },
        innerBlocks: [
          { name: "core/list-item", attributes: { content: "First" } },
          { name: "core/list-item", attributes: { content: "Second" } },
        ],
      },
    ];

    expect(blocksToMarkdown(blocks)).toBe("- One\n- Two\n\n1. First\n2. Second");
  });

  test("serializes quote code separator and image blocks", () => {
    const blocks = [
      {
        name: "core/quote",
        attributes: { value: "Line one<br>Line two", citation: "Ada" },
      },
      {
        name: "core/code",
        attributes: { content: "let value = 1" },
      },
      { name: "core/separator", attributes: {} },
      {
        name: "core/image",
        attributes: { url: "blob:knot-image", alt: "Sketch" },
      },
    ];

    expect(blocksToMarkdown(blocks, {
      "blob:knot-image": "{{knot-attachment:1}}",
    })).toBe([
      "> Line one",
      "> Line two",
      "> — Ada",
      "",
      "```",
      "let value = 1",
      "```",
      "",
      "---",
      "",
      "{{knot-attachment:1}}",
    ].join("\n"));
  });
});
