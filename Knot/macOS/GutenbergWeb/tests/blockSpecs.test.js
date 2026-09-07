import { expect, test } from "vitest";
import {
  blockSpecForType,
  initialBlockSpecsFromText,
} from "../src/blockSpecs.js";

test("starts an empty editor with an editable paragraph block", () => {
  expect(initialBlockSpecsFromText("")).toEqual([
    {
      name: "core/paragraph",
      attributes: {},
    },
  ]);
});

test("turns promoted h1 text into heading and paragraph block specs", () => {
  expect(initialBlockSpecsFromText("# Project\nNext thought")).toEqual([
    {
      name: "core/heading",
      attributes: {
        level: 1,
        content: "Project",
      },
    },
    {
      name: "core/paragraph",
      attributes: {
        content: "Next thought",
      },
    },
  ]);
});

test("creates list specs with a writable list item", () => {
  expect(blockSpecForType("core/list")).toEqual({
    name: "core/list",
    attributes: {},
    innerBlocks: [
      {
        name: "core/list-item",
        attributes: {},
      },
    ],
  });
});
