import { fromMarkdown } from "mdast-util-from-markdown";
import { frontmatterFromMarkdown, frontmatterToMarkdown } from "mdast-util-frontmatter";
import { gfmFromMarkdown, gfmToMarkdown } from "mdast-util-gfm";
import { toMarkdown } from "mdast-util-to-markdown";
import { frontmatter } from "micromark-extension-frontmatter";
import { gfm } from "micromark-extension-gfm";
import { inlineHtmlToMarkdown } from "./html";

export const SUPPORTED_BLOCKS = [
  "core/paragraph", "core/heading", "core/list", "core/list-item", "core/quote",
  "core/code", "core/separator", "core/image", "knot/source",
] as const;

export type BlockSpec = {
  name: string;
  attributes: Record<string, unknown>;
  innerBlocks?: BlockSpec[];
};

type MdNode = {
  type: string;
  value?: string;
  depth?: number;
  ordered?: boolean;
  start?: number | null;
  url?: string;
  title?: string | null;
  alt?: string | null;
  lang?: string | null;
  children?: MdNode[];
  position?: { start: { offset?: number }; end: { offset?: number } };
};

const escapeHTML = (value: string): string => value
  .replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;");

function inlineHTML(nodes: MdNode[] = []): string | null {
  let result = "";
  for (const node of nodes) {
    const child = node.children ? inlineHTML(node.children) : "";
    if (child === null) return null;
    switch (node.type) {
      case "text": result += escapeHTML(node.value ?? ""); break;
      case "strong": result += `<strong>${child}</strong>`; break;
      case "emphasis": result += `<em>${child}</em>`; break;
      case "inlineCode": result += `<code>${escapeHTML(node.value ?? "")}</code>`; break;
      case "link": result += `<a href="${escapeHTML(node.url ?? "")}"${node.title ? ` title="${escapeHTML(node.title)}"` : ""}>${child}</a>`; break;
      case "break": result += "<br>"; break;
      default: return null;
    }
  }
  return result;
}

function sourceSlice(node: MdNode, source: string): string {
  const start = node.position?.start.offset;
  const end = node.position?.end.offset;
  return typeof start === "number" && typeof end === "number" ? source.slice(start, end) : source;
}

function opaque(node: MdNode, source: string, reason = node.type): BlockSpec {
  return { name: "knot/source", attributes: { source: sourceSlice(node, source), reason } };
}

function paragraph(node: MdNode, source: string): BlockSpec {
  if (node.children?.length === 1 && node.children[0].type === "image") return blockFromNode(node.children[0], source);
  const raw = sourceSlice(node, source);
  if (/!?\[\[[\s\S]*?\]\]|(^|\n)>\s*\[!|(^|[^\\])\$[^\n$]+\$/m.test(raw)) return opaque(node, source, "obsidian-source");
  const content = inlineHTML(node.children);
  return content === null ? opaque(node, source, "unsupported-inline") : { name: "core/paragraph", attributes: { content } };
}

function listItem(node: MdNode, source: string): BlockSpec {
  const children = node.children ?? [];
  const first = children[0]?.type === "paragraph" ? inlineHTML(children[0].children) : null;
  if (first === null) return opaque(node, source, "unsupported-list-item");
  const nested = children.slice(1).map((child) => blockFromNode(child, source));
  return { name: "core/list-item", attributes: { content: first }, innerBlocks: nested };
}

function blockFromNode(node: MdNode, source: string): BlockSpec {
  switch (node.type) {
    case "paragraph": return paragraph(node, source);
    case "heading": {
      const content = inlineHTML(node.children);
      return content === null ? opaque(node, source) : { name: "core/heading", attributes: { level: node.depth ?? 2, content } };
    }
    case "list": return {
      name: "core/list",
      attributes: { ordered: Boolean(node.ordered), start: node.start ?? 1 },
      innerBlocks: (node.children ?? []).map((child) => listItem(child, source)),
    };
    case "blockquote": {
      if (/>\s*\[!/.test(sourceSlice(node, source))) return opaque(node, source, "obsidian-callout");
      return { name: "core/quote", attributes: {}, innerBlocks: (node.children ?? []).map((child) => blockFromNode(child, source)) };
    }
    case "code": return { name: "core/code", attributes: { content: node.value ?? "", language: node.lang ?? "" } };
    case "thematicBreak": return { name: "core/separator", attributes: {} };
    case "image": return { name: "core/image", attributes: { url: node.url ?? "", alt: node.alt ?? "", title: node.title ?? "", caption: "" } };
    default: return opaque(node, source);
  }
}

export function markdownToBlocks(source: string): BlockSpec[] {
  const tree = fromMarkdown(source, {
    extensions: [frontmatter(["yaml"]), gfm()],
    mdastExtensions: [frontmatterFromMarkdown(["yaml"]), gfmFromMarkdown()],
  }) as MdNode;
  const blocks = (tree.children ?? []).map((node) => blockFromNode(node, source));
  return blocks.length > 0 ? blocks : [{ name: "core/paragraph", attributes: { content: "" } }];
}

function inlineMarkdown(value: unknown): string {
  return inlineHtmlToMarkdown(typeof value === "string" ? value : "");
}

function mdastFromBlock(block: BlockSpec): MdNode {
  switch (block.name) {
    case "core/paragraph": return fromMarkdown(inlineMarkdown(block.attributes.content)).children[0] as MdNode ?? { type: "paragraph", children: [] };
    case "core/heading": {
      const parsed = fromMarkdown(`${"#".repeat(Math.min(6, Math.max(1, Number(block.attributes.level) || 2)))} ${inlineMarkdown(block.attributes.content)}`) as MdNode;
      return parsed.children![0];
    }
    case "core/list": return {
      type: "list", ordered: Boolean(block.attributes.ordered), start: Number(block.attributes.start) || 1,
      children: (block.innerBlocks ?? []).map(mdastFromBlock),
    };
    case "core/list-item": return {
      type: "listItem",
      children: [
        (fromMarkdown(inlineMarkdown(block.attributes.content)) as MdNode).children?.[0] ?? { type: "paragraph", children: [] },
        ...(block.innerBlocks ?? []).map(mdastFromBlock),
      ],
    };
    case "core/quote": return { type: "blockquote", children: (block.innerBlocks ?? []).map(mdastFromBlock) };
    case "core/code": return { type: "code", value: String(block.attributes.content ?? ""), lang: String(block.attributes.language ?? "") || null };
    case "core/separator": return { type: "thematicBreak" };
    case "core/image": return { type: "image", url: String(block.attributes.id ? `knot-asset://${block.attributes.id}` : block.attributes.url ?? ""), alt: String(block.attributes.alt ?? ""), title: String(block.attributes.title ?? "") || null };
    default: throw new Error(`unsupportedBlock:${block.name}`);
  }
}

export function blocksToMarkdown(blocks: BlockSpec[]): string {
  const pieces = blocks.map((block) => {
    if (block.name === "knot/source") return String(block.attributes.source ?? "");
    if (block.name === "core/image") {
      const image = toMarkdown({ type: "root", children: [mdastFromBlock(block)] } as never).trimEnd();
      const caption = inlineMarkdown(block.attributes.caption).trim();
      return caption ? image + "\n\n" + caption : image;
    }
    return toMarkdown({ type: "root", children: [mdastFromBlock(block)] } as never, {
      bullet: "-", fences: true, extensions: [frontmatterToMarkdown(["yaml"]), gfmToMarkdown()],
    }).trimEnd();
  });
  return pieces.join("\n\n");
}

export function blockSpecForType(name: string): BlockSpec {
  if (!SUPPORTED_BLOCKS.includes(name as typeof SUPPORTED_BLOCKS[number]) || name === "knot/source") {
    throw new Error(`unsupportedBlock:${name}`);
  }
  if (name === "core/heading") return { name, attributes: { level: 2, content: "" } };
  if (name === "core/list") return { name, attributes: { ordered: false, start: 1 }, innerBlocks: [{ name: "core/list-item", attributes: { content: "" }, innerBlocks: [] }] };
  return { name, attributes: {} };
}
