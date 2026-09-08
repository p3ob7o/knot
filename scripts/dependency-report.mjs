#!/usr/bin/env node
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const lockPath = resolve(root, "Knot/macOS/GutenbergWeb/package-lock.json");
const resolvedPath = resolve(root, "Packages/KnotKit/Package.resolved");
const lockBytes = readFileSync(lockPath);
const resolvedBytes = readFileSync(resolvedPath);
const lock = JSON.parse(lockBytes);
const swift = JSON.parse(resolvedBytes);
const licenseOverrides = new Map([
  ["computed-style", "MIT"],
  ["format", "MIT"],
  ["gradient-parser", "MIT"],
]);

const npmPackages = [...new Map(Object.entries(lock.packages)
  .filter(([path, item]) => path && item.dev !== true && item.link !== true)
  .map(([path, item]) => {
    const name = item.name || path.split("node_modules/").at(-1);
    const license = item.license || licenseOverrides.get(name);
    if (!item.version || !license) {
      throw new Error(`runtime lock entry is incomplete: ${path}`);
    }
    if (path.startsWith("vendor/")) {
      const directory = resolve(root, "Knot/macOS/GutenbergWeb", path);
      const bytes = Buffer.concat([
        readFileSync(resolve(directory, "package.json")),
        readFileSync(resolve(directory, "index.js")),
      ]);
      return [`${name}@${item.version}`, {
        name,
        version: item.version,
        license,
        source: `local:${path}`,
        integrity: `sha256-${createHash("sha256").update(bytes).digest("hex")}`,
      }];
    }
    if (!item.resolved || !item.integrity) {
      throw new Error(`runtime lock entry is incomplete: ${path}`);
    }
    if (!item.resolved.startsWith("https://registry.npmjs.org/")) {
      throw new Error(`runtime dependency has an unapproved source: ${path}`);
    }
    return [`${name}@${item.version}`, {
      name,
      version: item.version,
      license,
      source: item.resolved,
      integrity: item.integrity,
    }];
  })).values()].sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));

const swiftLicenses = new Map([
  ["grdb.swift", "MIT"],
  ["swift-cmark", "BSD-2-Clause"],
  ["swift-markdown", "Apache-2.0"],
]);
const swiftPackages = swift.pins.map((pin) => {
  const license = swiftLicenses.get(pin.identity);
  if (!license || !pin.state.version || !pin.state.revision || !pin.location.startsWith("https://github.com/")) {
    throw new Error(`Swift dependency entry is incomplete: ${pin.identity}`);
  }
  return {
    name: pin.identity,
    version: pin.state.version,
    revision: pin.state.revision,
    license,
    source: pin.location,
  };
}).sort((a, b) => a.name.localeCompare(b.name));

const report = {
  schemaVersion: 1,
  generatedFrom: {
    npmLockSHA256: createHash("sha256").update(lockBytes).digest("hex"),
    swiftResolvedSHA256: createHash("sha256").update(resolvedBytes).digest("hex"),
  },
  npmRuntimePackages: npmPackages,
  swiftPackages,
};

let jsonOutput;
let noticesOutput;
for (let index = 2; index < process.argv.length; index += 2) {
  const flag = process.argv[index];
  const value = process.argv[index + 1];
  if (!value) throw new Error("usage: dependency-report.mjs [--json FILE] [--notices FILE]");
  if (flag === "--json") jsonOutput = value;
  else if (flag === "--notices") noticesOutput = value;
  else throw new Error(`unknown argument: ${flag}`);
}

if (jsonOutput) writeFileSync(jsonOutput, JSON.stringify(report, null, 2) + "\n");
if (noticesOutput) {
  const lines = [
    "# Third-Party Notices",
    "",
    "Knot is distributed under GPL-2.0. The bundled rich editor and native core include the locked third-party packages below. License identifiers are taken from package metadata, with explicit overrides for three legacy MIT packages whose registry metadata omits the field. Registry source archives and integrity hashes are recorded in `package-lock.json` and `Package.resolved`; the local safe raw-paste adapter is content-hashed by the generated report.",
    "",
    "## Swift Packages",
    "",
    "| Package | Version | License |",
    "| --- | --- | --- |",
    ...swiftPackages.map((item) => `| ${item.name} | ${item.version} | ${item.license} |`),
    "",
    "## Bundled Web Runtime Packages",
    "",
    "| Package | Version | License |",
    "| --- | --- | --- |",
    ...npmPackages.map((item) => `| ${item.name.replaceAll("|", "\\|")} | ${item.version} | ${item.license.replaceAll("|", "\\|")} |`),
    "",
    "Complete license texts remain available from each package source and its installed package metadata. Release artifacts include this notice alongside Knot's GPL-2.0 license.",
    "",
  ];
  writeFileSync(noticesOutput, lines.join("\n"));
}
console.log(`PASS dependencies: ${swiftPackages.length} Swift and ${npmPackages.length} web runtime packages are pinned with licenses and integrity`);
