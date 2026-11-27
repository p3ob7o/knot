"""Index rendered PNGs by matrix cell and the handoff check's iPhone evidence."""

import argparse
import json
import re
from pathlib import Path


HANDOFF = Path("docs/design/handoff")

# The matrix gives these complete cells a verdict but does not repeat their file names
# in the gap or rule tables. These are the corresponding artboards and components.
DRAWINGS = {
    "Capture, typing": "screens/Main.dc.html",
    "Capture inside an older note": "screens/iPhone-Note.dc.html",
    "Recording, live": "screens/iPhone-Recording.dc.html",
    "Stream, populated": "screens/iPhone-Stream.dc.html",
    "Stream, rows pending and failed": "screens/iPhone-Stream.dc.html",
    "Stream, captures arrived late": "screens/iPhone-Stream.dc.html",
    "Stream, notes could not be opened": "system/components/Notice/preview.html",
    "Note, mixed segments": "system/components/Segment/preview.html",
    "Voice segment, each of its six states": "system/components/VoiceStates/preview.html",
    "Segment from the command line; from a newer Knot": "system/components/Segment/preview.html",
    "Delete with undo; share": "system/components/SegmentMenu/preview.html",
}


def table(section):
    for line in section.splitlines():
        if line.startswith("| "):
            yield [
                value.strip().replace(r"\|", "|")
                for value in re.split(r"(?<!\\)\|", line.strip("|"))
            ]


def cited_files(evidence, repo):
    names = re.findall(r"[\w./-]+\.(?:html|md)\b", evidence)
    candidates = [file.relative_to(repo / HANDOFF).as_posix() for file in (repo / HANDOFF).rglob("*")]
    paths = []
    for name in names:
        name = name.split("handoff/")[-1]
        matches = [path for path in candidates if path == name or path.endswith("/" + name)]
        if len(matches) == 1 and matches[0] not in paths:
            paths.append(matches[0])
    return paths


def section(check, start, end):
    return check.split(start, 1)[1].split(end, 1)[0]


def handoff_references(repo):
    check = (repo / "docs/design/handoff-check.md").read_text()
    matrix = section(check, "## The matrix, filled in", "## The list for the designer")
    gap = section(check, "\n### iPhone\n", "\n### iPad\n")
    rules = section(check, "## Cells with a rule and no picture", "## What the draft brief changes")
    evidence = {row[0]: row[1] for row in table(gap) if len(row) == 3}
    evidence.update({row[0]: row[2] for row in table(rules) if len(row) == 3 and row[1] == "iPhone"})
    files = {}
    for row in table(matrix):
        if len(row) != 7 or row[0] == "State" or row[1] == "–":
            continue
        cell, status = row[:2]
        status = status.strip("*")
        if status == "Not designed":
            paths = []
        elif cell in evidence:
            paths = cited_files(evidence[cell], repo)
            if status != "Stated":
                paths.sort(key=lambda path: not path.endswith(".html"))
        else:
            paths = [DRAWINGS[cell]]
        if status != "Not designed" and not paths:
            raise ValueError(f"No handoff evidence for {cell} ({status})")
        files[cell] = (status, paths)
    if any(files[cell][0] not in ("Drawn", "Component") for cell in DRAWINGS):
        raise ValueError("A drawing's handoff verdict has changed")
    return files


def write_index(catalog, output, repo, *, previews_only=False):
    references = handoff_references(repo)
    lines = [
        "# WP-40a iPhone preview renders",
        "",
        "The note menu, segment menu and share sheet are system presentations that the previews cannot open.",
        "",
        "The matrix's phone-sized iPad cell, “Two columns do not fit; keyboard up”, is a stand-in until WP-40b.",
        "",
        "The stopped-at-the-limit cell is a dismissible stand-in until WP-21 wires the engine reason.",
        "",
        "| Image | Preview and matrix cell | Handoff |",
        "|---|---|---|",
    ]
    coverage = {}
    for _, name, cell, slug, appearances in json.loads(catalog.read_text()):
        status, paths = references[cell]
        if cell == "First run: microphone, model downloading, Action Button":
            component = "FirstRun" if name.endswith("(1)") else "Notice"
            primary = next(path for path in paths if path.endswith(f"/{component}/preview.html"))
        else:
            primary = paths[0] if paths else None
        handoff = str(HANDOFF / primary) if primary else "not designed"
        if primary and not (repo / handoff).is_file():
            raise FileNotFoundError(handoff)
        coverage[cell] = (status, paths)
        for appearance in appearances:
            filename = f"{slug}-{appearance}.png"
            if not (output / filename).is_file():
                raise FileNotFoundError(filename)
            lines.append(f"| [{filename}]({filename}) | {name} | {handoff} |")
    keyboard_proofs = [
        ("capture-keyboard-controls-live-light-default.png", "Default text size"),
        ("capture-keyboard-controls-live-light-ax5.png", "Largest accessibility text size"),
    ]
    if previews_only:
        lines.extend(["", "The two running-app keyboard screenshots are recorded separately."])
    else:
        for filename, _ in keyboard_proofs:
            if not (output / filename).is_file():
                raise FileNotFoundError(filename)
        lines.extend(["", "## Capture controls in the running iPhone app", ""])
        lines.extend(f"- [{size}]({filename})" for filename, size in keyboard_proofs)
    lines.extend(["", "## Coverage recorded in the handoff check", ""])
    for cell, (status, paths) in coverage.items():
        evidence = ", ".join(f"`{HANDOFF / path}`" for path in paths)
        lines.append(f"- {cell}. {status}." + (f" {evidence}" if evidence else ""))
    (output / "index.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("repo", type=Path)
    parser.add_argument("--previews-only", action="store_true")
    write_index(**vars(parser.parse_args()))
