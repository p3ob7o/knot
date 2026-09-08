function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export class Converter {
  makeHtml(value) {
    return `<p>${escapeHTML(value).replaceAll(/\r\n?|\n/g, "<br>")}</p>`;
  }
}

export default { Converter };
