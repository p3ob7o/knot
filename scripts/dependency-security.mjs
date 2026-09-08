#!/usr/bin/env node
import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const reportPath = process.argv[2] || "/private/tmp/knot-dependencies.json";
const report = JSON.parse(readFileSync(reportPath, "utf8"));
const packages = new Map(report.npmRuntimePackages.map((item) => [item.name, item]));

for (const absent of ["browserslist", "image-size", "react-native", "shell-quote"]) {
  if (packages.has(absent)) throw new Error(`unused vulnerable runtime graph remains installed: ${absent}`);
}

const exact = new Map([
  ["nanoid", "3.3.18"],
  ["postcss", "8.5.28"],
  ["showdown", "2.1.1-knot.0"],
]);
for (const [name, version] of exact) {
  if (packages.get(name)?.version !== version) {
    throw new Error(`reviewed security pin changed for ${name}`);
  }
}
if (packages.get("showdown")?.source !== "local:vendor/showdown-safe") {
  throw new Error("WordPress raw paste must use Knot's reviewed local adapter");
}

const assets = resolve(root, "Knot/macOS/GutenbergWeb/dist/assets");
const javaScript = readdirSync(assets)
  .filter((name) => name.endsWith(".js"))
  .map((name) => readFileSync(resolve(assets, name), "utf8"))
  .join("\n");
if (javaScript.includes("showdown") || !javaScript.includes("&amp;")) {
  throw new Error("the built bundle does not contain only the safe raw-paste adapter");
}

console.log(`PASS dependency security: ${packages.size} reviewed runtime packages; vulnerable peer graph absent; safe raw-paste adapter bundled`);
