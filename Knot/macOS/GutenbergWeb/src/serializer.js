import { SUPPORTED_BLOCKS } from "./blockSpecs.js";

export { SUPPORTED_BLOCKS };

export function blocksToMarkdown(blocks, attachmentTokensByURL = {}) {
  return blocks
    .map((block) => blockToMarkdown(block, attachmentTokensByURL, 0))
    .map((value) => value.trim())
    .filter(Boolean)
    .join("\n\n");
}

function blockToMarkdown(block, attachmentTokensByURL, depth) {
  switch (block.name) {
    case "core/paragraph":
      return inlineHTMLToMarkdown(block.attributes?.content || "");
    case "core/heading":
      return headingToMarkdown(block);
    case "core/list":
      return listToMarkdown(block, attachmentTokensByURL, depth);
    case "core/list-item":
      return listItemContent(block);
    case "core/quote":
      return quoteToMarkdown(block);
    case "core/code":
      return codeToMarkdown(block);
    case "core/separator":
      return "---";
    case "core/image":
      return imageToMarkdown(block, attachmentTokensByURL);
    default:
      return "";
  }
}

function headingToMarkdown(block) {
  const level = Math.min(Math.max(Number(block.attributes?.level || 2), 1), 6);
  const content = inlineHTMLToMarkdown(block.attributes?.content || "");
  return `${"#".repeat(level)} ${content}`;
}

function listToMarkdown(block, attachmentTokensByURL, depth) {
  const ordered = Boolean(block.attributes?.ordered);
  const items = block.innerBlocks?.length
    ? block.innerBlocks
    : htmlListItems(block.attributes?.values || "").map((content) => ({
      name: "core/list-item",
      attributes: { content },
      innerBlocks: [],
    }));

  return items
    .map((item, index) => {
      const marker = ordered ? `${index + 1}.` : "-";
      const indent = "  ".repeat(depth);
      const content = listItemContent(item);
      const nested = (item.innerBlocks || [])
        .map((child) => blockToMarkdown(child, attachmentTokensByURL, depth + 1))
        .filter(Boolean)
        .join("\n");
      return nested
        ? `${indent}${marker} ${content}\n${nested}`
        : `${indent}${marker} ${content}`;
    })
    .join("\n");
}

function listItemContent(block) {
  return inlineHTMLToMarkdown(block.attributes?.content || "");
}

function quoteToMarkdown(block) {
  const raw = block.attributes?.value || block.attributes?.content || "";
  const quote = inlineHTMLToMarkdown(raw)
    .split(/\r?\n/)
    .map((line) => `> ${line}`)
    .join("\n");
  const citation = inlineHTMLToMarkdown(block.attributes?.citation || "");
  return citation ? `${quote}\n> — ${citation}` : quote;
}

function codeToMarkdown(block) {
  const code = textFromHTML(block.attributes?.content || "");
  const fence = code.includes("```") ? "````" : "```";
  return `${fence}\n${code}\n${fence}`;
}

function imageToMarkdown(block, attachmentTokensByURL) {
  const url = block.attributes?.url || "";
  const alt = inlineHTMLToMarkdown(block.attributes?.alt || "");
  if (attachmentTokensByURL[url]) {
    return attachmentTokensByURL[url];
  }
  if (!url) { return ""; }
  return `![${alt}](${url})`;
}

function htmlListItems(html) {
  const root = parseHTML(`<ul>${html}</ul>`);
  return Array.from(root.querySelectorAll("li")).map((item) => item.innerHTML);
}

function inlineHTMLToMarkdown(html) {
  const root = parseHTML(html);
  return Array.from(root.childNodes)
    .map((node) => inlineNodeToMarkdown(node))
    .join("")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function textFromHTML(html) {
  return parseHTML(html).textContent || "";
}

function parseHTML(html) {
  const template = document.createElement("template");
  template.innerHTML = html || "";
  return template.content;
}

function inlineNodeToMarkdown(node) {
  if (node.nodeType === Node.TEXT_NODE) {
    return node.textContent || "";
  }
  if (node.nodeType !== Node.ELEMENT_NODE) {
    return "";
  }

  const children = Array.from(node.childNodes)
    .map((child) => inlineNodeToMarkdown(child))
    .join("");
  const tag = node.tagName.toLowerCase();

  switch (tag) {
    case "strong":
    case "b":
      return `**${children}**`;
    case "em":
    case "i":
      return `*${children}*`;
    case "code":
      return `\`${children}\``;
    case "a": {
      const href = node.getAttribute("href") || "";
      return href ? `[${children}](${href})` : children;
    }
    case "br":
      return "\n";
    case "p":
      return children;
    default:
      return children;
  }
}
