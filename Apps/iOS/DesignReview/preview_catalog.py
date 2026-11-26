"""Generate the simulator app's view switch and image index from the iPhone #Preview bodies."""

import json
import re
import sys
from pathlib import Path


def phone_previews(source):
    pattern = r'^        #Preview\("iPhone \| ([^"]+)"\) \{\n(.*?)^        }'
    matches = re.findall(pattern, source, re.MULTILINE | re.DOTALL)
    if len(matches) != source.count('#Preview("iPhone | '):
        raise ValueError("Could not read all iPhone #Preview declarations")
    for cell, body in matches:
        group = re.fullmatch(r"\s*Group \{\n(.*?)\n\s*}\s*", body, re.DOTALL)
        variants = group[1].strip().splitlines() if group else [body]
        for index, variant in enumerate(variants, 1):
            name = cell if len(variants) == 1 else f"{cell} ({index})"
            yield name, cell, variant.strip()


def catalog(source, destination):
    rows = []
    branches = []
    for index, (name, cell, body) in enumerate(phone_previews(source.read_text())):
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        rows.append((index, name, cell, slug))
        branches.append(f"        case {index}:\n            AnyView({body})")
    if len({row[3] for row in rows}) != len(rows):
        raise ValueError("Generated screenshot file names must be unique")
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "catalog.json").write_text(json.dumps(rows, indent=2) + "\n")
    (destination / "PhonePreviewCatalog.swift").write_text(
        "import SwiftUI\n\n"
        "@MainActor func phonePreview(_ index: Int) -> AnyView {\n"
        "    switch index {\n"
        + "\n".join(branches)
        + '\n        default: AnyView(Text("Unknown preview"))\n    }\n}\n'
    )


if __name__ == "__main__":
    source, destination = map(Path, sys.argv[1:])
    catalog(source, destination)
