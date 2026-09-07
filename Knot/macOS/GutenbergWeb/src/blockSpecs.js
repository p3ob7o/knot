export const SUPPORTED_BLOCKS = [
  "core/paragraph",
  "core/heading",
  "core/list",
  "core/list-item",
  "core/quote",
  "core/code",
  "core/separator",
  "core/image",
];

export function blockSpecForType(name) {
  switch (name) {
    case "core/heading":
      return {
        name,
        attributes: {
          level: 2,
        },
      };
    case "core/list":
      return {
        name,
        attributes: {},
        innerBlocks: [
          {
            name: "core/list-item",
            attributes: {},
          },
        ],
      };
    case "core/quote":
    case "core/code":
    case "core/separator":
    case "core/paragraph":
      return {
        name,
        attributes: {},
      };
    default:
      return {
        name: "core/paragraph",
        attributes: {},
      };
  }
}

export function initialBlockSpecsFromText(text) {
  const trimmed = (text || "").trim();
  if (!trimmed) {
    return [blockSpecForType("core/paragraph")];
  }

  const lines = trimmed.split(/\r?\n/);
  const first = lines[0].match(/^#\s+(.+)/);
  if (first) {
    const specs = [
      {
        name: "core/heading",
        attributes: {
          level: 1,
          content: escapeHTML(first[1]),
        },
      },
    ];
    const rest = lines.slice(1).join("\n").trim();
    if (rest) {
      specs.push({
        name: "core/paragraph",
        attributes: {
          content: escapeHTML(rest).replaceAll("\n", "<br>"),
        },
      });
    }
    return specs;
  }

  return [
    {
      name: "core/paragraph",
      attributes: {
        content: escapeHTML(trimmed).replaceAll("\n", "<br>"),
      },
    },
  ];
}

function escapeHTML(text) {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}
