"""Index the rendered PNGs against the iPhone handoff inventory."""

import json
import re
import sys
from pathlib import Path


def handoff_references(repo):
    references = {}
    check = (repo / "docs/design/handoff-check.md").read_text()
    has_design = {}
    for line in check.split("## The list for the designer", 1)[0].splitlines():
        if line.startswith("| "):
            columns = [item.strip() for item in line.strip("|").split("|")]
            if len(columns) == 7:
                has_design[columns[0]] = columns[1]
    iphone = check.split("## The list for the designer", 1)[1]
    iphone = iphone.split("### iPhone", 1)[1].split("\n### ", 1)[0]
    for line in iphone.splitlines():
        columns = [item.strip() for item in line.strip("|").split("|")]
        if not line.startswith("| ") or len(columns) != 3:
            continue
        cell, designed, _ = columns
        if designed == "Nothing" or "Not designed" in has_design.get(cell, ""):
            references[cell] = []
        else:
            references[cell] = re.findall(
                r"(?:screens|system|components)/[\w./-]+\.(?:html|md)", designed
            )
    return references


def file_for(cell, references):
    if cell in references and not references[cell]:
        return "not designed"
    if cell in references:
        path = references[cell][0]
    elif cell.startswith("Capture,"):
        path = "screens/Main.dc.html"
    elif cell.startswith("Recording,"):
        path = "screens/iPhone-Recording.dc.html"
    elif cell.startswith("Stream,"):
        path = "screens/iPhone-Stream.dc.html"
    elif cell.startswith("Voice segment"):
        path = "components/VoiceStates/preview.html"
    elif cell.startswith(("Note,", "Capture inside")):
        path = "screens/iPhone-Note.dc.html"
    elif cell.startswith("Delete with undo"):
        path = "components/SegmentMenu/preview.html"
    elif cell.startswith("Segment from"):
        path = "system/02-states.md"
    elif cell.startswith("Short recording"):
        path = "system/02-states.md"
    elif cell.startswith("First run:"):
        path = "components/FirstRun/preview.html"
    else:
        return "not designed"
    if path.startswith("components/"):
        path = "system/" + path
    return "docs/design/handoff/" + path


def write_index(catalog, output, repo):
    references = handoff_references(repo)
    lines = [
        "# WP-40a iPhone preview renders",
        "",
        "| Image | Preview and matrix cell | Handoff |",
        "|---|---|---|",
    ]
    for _, name, cell, slug in json.loads(catalog.read_text()):
        handoff = file_for(cell, references)
        for appearance in ("light-default", "dark-default", "light-ax5"):
            filename = f"{slug}-{appearance}.png"
            if not (output / filename).is_file():
                raise FileNotFoundError(filename)
            if handoff != "not designed" and not (repo / handoff).is_file():
                raise FileNotFoundError(handoff)
            lines.append(f"| [{filename}]({filename}) | {name} | {handoff} |")
    (output / "index.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    write_index(*map(Path, sys.argv[1:]))
