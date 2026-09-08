import { fromHtml } from "hast-util-from-html";
import { defaultSchema, sanitize } from "hast-util-sanitize";
import { toMdast } from "hast-util-to-mdast";
import { toMarkdown } from "mdast-util-to-markdown";

const schema = {
  ...defaultSchema,
  tagNames: ["p", "br", "strong", "b", "em", "i", "code", "pre", "a", "ul", "ol", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"],
  attributes: { ...defaultSchema.attributes, a: ["href", "title"] },
  protocols: { href: ["http", "https", "mailto"] },
};

export function sanitizedHtmlToMarkdown(source: string): string {
  const tree = fromHtml(source, { fragment: true });
  const clean = sanitize(tree, schema);
  return toMarkdown(toMdast(clean), { bullet: "-", fences: true }).trim().replace(/\[([^\]]+)\]\(\)/g, "$1");
}

export function inlineHtmlToMarkdown(source: string): string {
  return sanitizedHtmlToMarkdown(`<p>${source}</p>`).replace(/\n+$/, "");
}
