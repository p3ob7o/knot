"""The checks behind scripts/verify.sh that read the plan, the diff and the sources.

Run it from the repository root, through the scripts. It needs Python 3.9 or later and
nothing outside the standard library, so the /usr/bin/python3 that ships with macOS will do.

    python3 scripts/lib/knot_tool.py package [--package <ID>] [--branch <name>]
    python3 scripts/lib/knot_tool.py owns <ID>
    python3 scripts/lib/knot_tool.py ownership --package <ID> --base <ref> [--allow <path>]…
    python3 scripts/lib/knot_tool.py depth --base <ref>
    python3 scripts/lib/knot_tool.py core-api-rule --package <ID>
    python3 scripts/lib/knot_tool.py named-tests [--merged-from github|git] [--package <ID>] [--branch <name>]
    python3 scripts/lib/knot_tool.py lint [--files <path>]… [--as <folder>/] [--manifest <privacy manifest>]
    python3 scripts/lib/knot_tool.py team-id --team-config <path>
    python3 scripts/lib/knot_tool.py links
    python3 scripts/lib/knot_tool.py status [--write]

Each command prints one line per finding and exits 1 when anything is wrong.
"""

import fnmatch
import json
import os
import plistlib
import re
import subprocess
import sys

BRIEFS = "docs/plan"
NAMED_TESTS = os.path.join(BRIEFS, "named-tests.txt")
# The scripts' own folder. The gate may run main's scripts against another tree: then the
# plan and the sources come from the current folder, the tree under test, and the lists that
# only the orchestrator edits come from the scripts' checkout.
SCRIPTS = os.environ.get("KNOT_SCRIPTS", "scripts")
CONCURRENCY_ESCAPES = os.path.join(SCRIPTS, "concurrency-escapes.txt")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def lines(text):
    return [line for line in text.splitlines() if line]


# ---------------------------------------------------------------- the plan


def brief_path(package):
    return os.path.join(BRIEFS, package + ".md")


def section(package, heading):
    """The lines under one '## ' heading of a brief."""
    with open(brief_path(package)) as f:
        text = f.read()
    match = re.search(r"^## " + re.escape(heading) + r"\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return match.group(1).splitlines() if match else []


def packages():
    """The packages in the order of PLAN.md: WP-00 to WP-06, the spikes, then WP-10 on."""
    def key(package):
        kind, number = package.split("-")
        number = int(number)
        if kind == "SP":
            return (7, number)
        return (number, 0) if number <= 6 else (100 + number, 0)
    return sorted((name[:-3] for name in os.listdir(BRIEFS) if re.match(r"^(WP|SP)-\d+\.md$", name)), key=key)


NOTE_ROWS = ("Proof step", "Notes")


def plan_rows(package):
    """The pull requests a brief plans: the first cell of every row of its 'Starts after'
    table, as in "Proof step", "Notes", "1", "2" or "40a"."""
    rows = []
    for line in section(package, "Starts after"):
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not line.startswith("|") or not cells or cells[0] in ("PR", "") or set(cells[0]) <= set("-: "):
            continue
        rows.append(cells[0])
    return rows or ["1"]


def is_note_branch(branch):
    """A proof step's note merges from wp/<number>-note, and a spike's from spike/<name>-note."""
    branch = re.sub(r"^(refs/heads/|origin/)", "", branch or "")
    return bool(re.match(r"^wp/\d+-note$", branch) or re.match(r"^spike/.+-note$", branch))


def merge_state(package, merged):
    """How many of a package's planned pull requests have merged, out of how many.

    `merged` is a list of (package, is_note) for every merged pull request. A note fills the
    brief's "Proof step" or "Notes" row; every other pull request fills the next of its
    other rows, "1", "2" or "40a" to "40d"."""
    rows = plan_rows(package)
    note_rows = sum(1 for row in rows if row in NOTE_ROWS)
    other_rows = len(rows) - note_rows
    notes = sum(1 for p, note in merged if p == package and note)
    others = sum(1 for p, note in merged if p == package and not note)
    return min(notes, note_rows) + min(others, other_rows), len(rows)


def has_merged(package, merged):
    done, total = merge_state(package, merged)
    return done >= total


PATH_TOKEN = re.compile(r"`([^`\s]+)`")
PART = re.compile(r"\b(\w+) step of `([^`\s]+)`", re.I)


def top_level(token):
    """Whether a path starts at the repository's root, as `docs/x.md` does and `Preview/`
    does not."""
    return os.path.exists(token.split("/")[0]) or token.split("/")[0] in ("Packages", "Apps", "docs", "scripts",
                                                                          "Fixtures", "Resources", "Spikes")


def owned_paths(package):
    """The paths a brief's 'Owns' section names, the ones its 'except' clauses take out, and
    the parts of files it owns.

    An 'except' path that is not from the root, as in "`KnotFakes/`, except its `Preview/`
    folder", is resolved against the folder the same line owns. A path named after "of", as
    in "the soak step of `scripts/verify.sh`", is a part of that file: the package owns the
    lines between the part's markers, not the file. scripts/ownership-extra.txt adds paths.
    """
    owned, excluded, parts = [], [], []
    for line in section(package, "Owns"):
        if not line.startswith("- "):
            continue
        index = line.find(" except ")
        head, tail = (line[:index], line[index:]) if index >= 0 else (line, "")
        for match in PART.finditer(head):
            parts.append((match.group(2), match.group(1).lower()))
        part_paths = {path for path, _ in parts}
        folder = None
        for match in PATH_TOKEN.finditer(head):
            token = match.group(1)
            if token in part_paths or not ("/" in token or "." in token):
                continue
            owned.append(token)
            if folder is None and token.endswith("/"):
                folder = token
        for match in PATH_TOKEN.finditer(tail):
            before = tail[:match.start()].rstrip()
            if before.endswith(" of") or before.endswith(" in"):
                continue
            token = match.group(1)
            if not top_level(token) and folder:
                token = folder + token
            excluded.append(token)
    for fields in extra_lines():
        if fields[0] == package:
            owned.append(fields[1])
    return owned, excluded, parts


def extra_lines():
    path = os.path.join(SCRIPTS, "ownership-extra.txt")
    found = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                fields = line.rstrip("\n").split("\t")
                if not line.startswith("#") and len(fields) >= 2:
                    found.append(fields)
    return found


def matches(path, pattern):
    if pattern.endswith("/"):
        return path.startswith(pattern)
    if any(c in pattern for c in "*?["):
        return fnmatch.fnmatch(path, pattern)
    return path == pattern


def package_of_branch(branch):
    """The package a branch belongs to: wp/01-tooling is WP-01, wp/13-note is WP-13; a spike
    branch, or its -note branch, is the spike whose brief owns it; a contract branch is
    'contract'."""
    branch = re.sub(r"^(refs/heads/|origin/)", "", branch)
    match = re.match(r"^wp/(\d+)-", branch)
    if match:
        return "WP-%02d" % int(match.group(1))
    if branch.startswith("contract/"):
        return "contract"
    if branch.startswith("spike/"):
        name = re.sub(r"-note$", "", branch)
        for package in packages():
            if any(token == name for token in PATH_TOKEN.findall("\n".join(section(package, "Owns")))):
                return package
    return None


# ---------------------------------------------------------------- the diff


def changed_files(base):
    """Paths that differ from the merge base with `base`: committed, staged, unstaged and new."""
    merge_base = git("merge-base", base, "HEAD").strip()
    found = set(lines(git("diff", "--name-only", merge_base)))
    found |= set(lines(git("ls-files", "--others", "--exclude-standard")))
    return sorted(found)


def contract_owned(path):
    """A contract branch changes KnotCore's API, the fakes, and in a breaking change every
    conformer and call site (PLAN.md §8.5)."""
    return path.startswith(("Packages/KnotKit/Sources/", "Packages/KnotKit/Tests/", "Apps/"))


def owners_of(path):
    """Every package but WP-00 whose brief or ownership-extra line owns the path, whole or in
    part."""
    found = []
    for package in packages():
        if package == "WP-00":
            continue
        owned, excluded, parts = owned_paths(package)
        if (any(matches(path, p) for p in owned) and not any(matches(path, p) for p in excluded)) \
                or any(path == part for part, _ in parts):
            found.append(package)
    return found


def part_markers(text, name):
    """The line numbers (from 1) of the two markers that bound a part of a file, such as
    `# ---- The soak step.` and `# ---- End of the soak step.`, or None."""
    begin = end = None
    for number, line in enumerate(text.splitlines(), 1):
        if begin is None and re.match(r"^\s*# ---- The " + re.escape(name) + r" step\b", line, re.I):
            begin = number
        elif begin is not None and re.match(r"^\s*# ---- End of the " + re.escape(name) + r" step\b", line, re.I):
            end = number
            break
    return (begin, end) if begin is not None and end is not None else None


def inside_part(path, name, base):
    """Whether every change to `path` since `base` lies between the markers of its part."""
    merge_base = git("merge-base", base, "HEAD").strip()
    try:
        old = git("show", f"{merge_base}:{path}")
    except subprocess.CalledProcessError:
        return False, "the file is new, so it has no part to change"
    with open(path) as f:
        new = f.read()
    old_part, new_part = part_markers(old, name), part_markers(new, name)
    if not old_part or not new_part:
        return False, f"the markers of the {name} step are missing"
    for hunk in re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", git("diff", "-U0", merge_base, "--", path), re.M):
        old_start, old_count = int(hunk.group(1)), int(hunk.group(2) or 1)
        new_start, new_count = int(hunk.group(3)), int(hunk.group(4) or 1)
        if old_count and not (old_part[0] < old_start and old_start + old_count - 1 < old_part[1]):
            return False, f"lines {old_start} to {old_start + old_count - 1} of the base lie outside the {name} step"
        if new_count and not (new_part[0] < new_start and new_start + new_count - 1 < new_part[1]):
            return False, f"lines {new_start} to {new_start + new_count - 1} lie outside the {name} step"
    return True, ""


def cmd_ownership(package, base, allowed):
    """Holds the diff to the paths the package owns.

    WP-00, the orchestrator's own package, owns what PLAN.md §8.5 gives the orchestrator
    (its lines in scripts/ownership-extra.txt) and every path that no brief owns. A path that
    no brief owns fails for every other package. `allowed` are paths that the orchestrator
    allows by hand for this pull request: a shared file it arranged inside a package's
    paths, or the mechanical edits of a breaking contract change.
    """
    files = changed_files(base)
    if package != "contract" and not os.path.exists(brief_path(package)):
        print(f"ownership: no brief for {package} in {BRIEFS}")
        return 1
    if package != "contract":
        owned, excluded, parts = owned_paths(package)

    def refusal(path):
        """Why the package may not change the path, or None when it may."""
        if package == "contract":
            return None if contract_owned(path) else "is not a path that a contract branch changes"
        if any(matches(path, p) for p in excluded):
            return f"is excepted from what {package} owns"
        if any(matches(path, p) for p in owned):
            return None
        part = next((name for part_path, name in parts if part_path == path), None)
        if part:
            ok, why = inside_part(path, part, base)
            return None if ok else f"is owned by {package} only in its {part} step, and {why}"
        owners = owners_of(path)
        if package == "WP-00" and not owners:
            return None
        if owners:
            return f"is owned by {', '.join(owners)}, not {package}"
        return "is owned by no brief. Ask the orchestrator, who owns it"

    bad, by_hand, unneeded = [], [], []
    for path in files:
        why = refusal(path)
        allowance = next((p for p in allowed if matches(path, p)), None)
        if why and allowance:
            by_hand.append(path)
        elif why:
            bad.append((path, why))
        elif allowance:
            unneeded.append(path)
    # An allowance that matched no changed path is a mistake in the gate's command.
    unmatched = [p for p in allowed if not any(matches(path, p) for path in files)]
    for path in by_hand:
        print(f"ownership: allowed by hand: {path}")
    for path in unneeded:
        print(f"ownership: {path} needed no allowance: {package} owns it")
    for pattern in unmatched:
        print(f"ownership: --allow {pattern} matches no changed path")
    for path, why in bad:
        print(f"ownership: {path} {why}")
    print(f"ownership: {len(files)} changed paths, {len(bad)} outside what {package} owns, "
          f"{len(by_hand)} allowed by hand")
    return 1 if bad or unmatched else 0


# The gate's depth (docs/architecture.md §18). The first table that a changed path meets,
# in this order, decides; the deepest depth that any path needs wins.
EVERYTHING = [
    "Packages/KnotKit/Sources/KnotCore/", "Packages/KnotKit/Sources/KnotStore/",
    "Packages/KnotKit/Sources/KnotCapture/", "Packages/KnotKit/Sources/KnotAudio/",
    "Packages/KnotKit/Sources/KnotSync/", "Packages/KnotKit/Sources/KnotUI/",
    "Packages/KnotKit/Sources/KnotApp/", "Packages/KnotKit/Sources/KnotFakes/",
    "Packages/KnotKit/Sources/KnotTestSupport/", "Packages/KnotKit/Sources/KnotUIPreviews/",
    "Packages/KnotKit/Sources/KnotStoreCrashHost/", "Packages/KnotKit/Sources/KnotAudioCrashHost/",
    "Packages/KnotKit/Sources/KnotSoakChild/",
    "Packages/KnotKit/Tests/KnotCoreTests/", "Packages/KnotKit/Tests/KnotStoreTests/",
    "Packages/KnotKit/Tests/KnotCaptureTests/", "Packages/KnotKit/Tests/KnotAudioTests/",
    "Packages/KnotKit/Tests/KnotSyncTests/", "Packages/KnotKit/Tests/KnotUITests/",
    "Packages/KnotKit/Tests/KnotAppTests/", "Packages/KnotKit/Tests/KnotFakesTests/",
    "Packages/KnotKit/Tests/KnotTestSupportTests/", "Packages/KnotKit/Tests/KnotUIPreviewsTests/",
    "Packages/KnotKit/Tests/KnotEndToEndTests/", "Packages/KnotKit/Tests/KnotSoak/",
    "Packages/KnotKit/Package.swift", "Packages/KnotKit/Package.resolved",
    "project.yml", "scripts/", "Apps/iOS/", "Apps/macOS/", "Apps/watchOS/", "Apps/Shared/", "Apps/Config/",
    "Fixtures/", ".swift-format", ".xcode-version",
]
LEAF = [
    "Packages/KnotKit/Sources/KnotSpeech/", "Packages/KnotKit/Sources/KnotCleanup/",
    "Packages/KnotKit/Sources/KnotInk/", "Packages/KnotKit/Sources/KnotExport/",
    "Packages/KnotKit/Sources/KnotLink/", "Packages/KnotKit/Sources/KnotIntents/",
    "Packages/KnotKit/Sources/KnotAgent/", "Packages/KnotKit/Sources/knot/",
    "Packages/KnotKit/Sources/knot-eval/", "Packages/KnotKit/Sources/KnotLinkCrashHost/",
    "Packages/KnotKit/Sources/KnotInkCrashHost/",
    "Packages/KnotKit/Tests/KnotSpeechTests/", "Packages/KnotKit/Tests/KnotCleanupTests/",
    "Packages/KnotKit/Tests/KnotInkTests/", "Packages/KnotKit/Tests/KnotExportTests/",
    "Packages/KnotKit/Tests/KnotLinkTests/", "Packages/KnotKit/Tests/KnotIntentsTests/",
    "Packages/KnotKit/Tests/KnotAgentTests/", "Packages/KnotKit/Tests/knotTests/",
    "Packages/KnotKit/Tests/knot-evalTests/", "Apps/Extensions/",
]
# The soak runs where docs/architecture.md §17 asks for it.
SOAK = [
    "Packages/KnotKit/Sources/KnotCore/", "Packages/KnotKit/Sources/KnotStore/",
    "Packages/KnotKit/Sources/KnotCapture/", "Packages/KnotKit/Sources/KnotAudio/",
    "Packages/KnotKit/Sources/KnotApp/", "Packages/KnotKit/Sources/KnotSoakChild/",
    "Packages/KnotKit/Tests/KnotSoak/", "Packages/KnotKit/Package.resolved",
]
# The tests hosted in the iOS app run where the diff reaches a module whose contract suite
# runs only there (docs/architecture.md §5): KnotAudio for RecordingStateStore, KnotInk for
# InkRecogniser, and the iOS app for RecordingActivity.
HOSTED = [
    "Packages/KnotKit/Sources/KnotAudio/", "Packages/KnotKit/Sources/KnotInk/",
    "Packages/KnotKit/Sources/KnotTestSupport/", "Packages/KnotKit/Sources/KnotFakes/",
    "Packages/KnotKit/Tests/KnotAudioTests/", "Packages/KnotKit/Tests/KnotInkTests/",
    "Apps/iOS/", "Packages/KnotKit/Package.swift", "project.yml",
]
# Mac UI tests run where the diff reaches the Mac app or KnotUI, the scripts that run them,
# or the Xcode that builds them (the orchestrator's ruling on the review of PR 38).
MAC_UI = [
    "Apps/macOS/", "Apps/Shared/", "Apps/Config/", "project.yml", "Packages/KnotKit/Package.swift",
    "Packages/KnotKit/Sources/KnotUI/", "Packages/KnotKit/Sources/KnotApp/",
    "scripts/", ".xcode-version", "Apps/UITestSupport/",
]


def is_document(path):
    return path.endswith(".md") or path.startswith("docs/") or path in ("LICENSE", "TODOS.md")


def classify(files, base="origin/main"):
    reasons, depth = [], "documents"
    order = {"documents": 0, "leaf": 1, "everything": 2}
    for path in files:
        if any(path.startswith(p) or path == p for p in EVERYTHING) or path.endswith(".entitlements"):
            need = "everything"
        elif any(path.startswith(p) for p in LEAF):
            need = "leaf"
        elif is_document(path):
            need = "documents"
        else:
            # A path the table does not name is treated as the deepest case.
            need = "everything"
        if order[need] > order[depth]:
            depth = need
            reasons = [path]
        elif need == depth and len(reasons) < 3:
            reasons.append(path)
    if not files:
        reasons = ["no change from the base"]
    soak = any(any(path.startswith(p) or path == p for p in SOAK) for path in files)
    if "Packages/KnotKit/Package.swift" in files:
        merge_base = git("merge-base", base, "HEAD").strip()
        if "grdb" in git("diff", "--unified=0", merge_base, "--", "Packages/KnotKit/Package.swift").lower():
            soak = True
    mac_ui = any(any(path.startswith(p) or path == p for p in MAC_UI) for path in files)
    hosted = any(any(path.startswith(p) or path == p for p in HOSTED) for path in files)
    return depth, reasons, soak, mac_ui, hosted


def cmd_depth(base):
    files = changed_files(base)
    depth, reasons, soak, mac_ui, hosted = classify(files, base)
    print(f"depth={depth}")
    print(f"hosted={'1' if hosted else '0'}")
    print(f"soak={'1' if soak else '0'}")
    print(f"mac_ui={'1' if mac_ui else '0'}")
    print(f"changed={len(files)}")
    print("reason=" + ", ".join(reasons))
    return 0


# ---------------------------------------------------------------- KnotCore's API


# The package that writes KnotCore's public API. Its brief: "After WP-02 merges, the public
# API of KnotCore changes only through a contract PR".
CORE_API_WRITER = "WP-02"


def core_api_exemption(package, merged):
    """Why a pull request of `package` may change KnotCore's public API, or None when it is
    held to the base's API.

    A contract branch may, by design. WP-02 may, as long as its last pull request has not
    merged; `merged` lists the merged pull requests as (package, is_note), and the pull
    request under test is not among them, so WP-02's last pull request may too. After that,
    a branch of WP-02 is held like any other."""
    if package == "contract":
        return "a contract branch changes KnotCore's public API by design (PLAN.md §8.5)"
    if package == CORE_API_WRITER and not has_merged(package, merged):
        done, total = merge_state(package, merged)
        return (f"{package} writes KnotCore's public API until its last pull request has merged, "
                f"and {done} of its {total} have")
    return None


def cmd_core_api_rule(package, source):
    reason = core_api_exemption(package, merged_prs(source)) if package else None
    if reason:
        print(f"core-api: {reason}")
        return 0
    print(f"core-api: {package or 'this branch'} is held to the base's KnotCore API")
    return 1


# ---------------------------------------------------------------- named tests


def merged_prs(source):
    """Every merged pull request of a package, as (package, is_note)."""
    found = []
    if source == "github":
        try:
            out = subprocess.run(["gh", "pr", "list", "--state", "merged", "--base", "main", "--limit", "1000",
                                  "--json", "headRefName"], check=True, capture_output=True, text=True).stdout
            for pr in json.loads(out):
                package = package_of_branch(pr["headRefName"])
                if package and package != "contract":
                    found.append((package, is_note_branch(pr["headRefName"])))
            return found
        except (OSError, subprocess.CalledProcessError, ValueError):
            pass
    # Without GitHub: the squash subjects on origin/main, which start with the package ID. A
    # note's subject names its proof step or the spike's code half.
    for subject in lines(git("log", "origin/main", "--format=%s")):
        match = re.match(r"^((?:WP|SP)-\d+)\b", subject)
        if match:
            found.append((match.group(1), bool(re.search(r"proof step|code half|\bnote\b", subject, re.I))))
    return found


def code_text():
    """Every tracked text file outside docs/, as one string per path."""
    found = {}
    for path in lines(git("ls-files")):
        if is_document(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                found[path] = f.read()
        except (UnicodeDecodeError, OSError):
            continue
    return found


def named_test_pr(owner, description):
    """The pull request that docs/plan/named-tests.txt gives a named test to, as in "2" or
    "40a": from an owner field such as "WP-11 PR 2", or from a description that names its
    owner's pull request, as "WP-11 PR 2 adds …" does. None when it gives it to the package."""
    match = re.match(r"^((?:WP|SP)-\d+)\s+PR\s+(\w+)$", owner.strip())
    if match:
        return match.group(2)
    match = re.search(r"\b" + re.escape(owner.strip()) + r"\s+PR\s+(\w+)\b", description)
    return match.group(1) if match else None


def named_test_required(owner, pr, merged):
    """Whether a named test is required: one given to a pull request once that pull request
    has merged, counted by the brief's rows in order; one given to the package once the
    package's last pull request has merged."""
    package = re.match(r"^((?:WP|SP)-\d+)", owner.strip()).group(1)
    if pr is None:
        return has_merged(package, merged)
    rows = [row for row in plan_rows(package) if row not in NOTE_ROWS]
    if pr not in rows:
        return has_merged(package, merged)
    others = sum(1 for p, note in merged if p == package and not note)
    return others >= rows.index(pr) + 1


def cmd_named_tests(source, package=None, branch=None):
    """Every named test must exist once what it is given to has merged: a test given to a
    pull request (named_test_pr) once that pull request has, and any other once its package's
    last pull request has. The pull request under test counts as merged, so it is held to its
    own tests at its own gate."""
    merged = merged_prs(source)
    if package and package != "contract":
        if not branch:
            print(f"named-tests: no branch was named, so this pull request counts as {package}'s code, not as a note")
        merged.append((package, is_note_branch(branch)))
    code = code_text()
    missing, required = [], 0
    with open(NAMED_TESTS) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            owner, slug, description = line.rstrip("\n").split("\t", 2)
            if not named_test_required(owner, named_test_pr(owner, description), merged):
                continue
            required += 1
            if not any(slug in text for text in code.values()):
                missing.append((owner, slug))
    for owner, slug in missing:
        print(f"named-tests: {slug}, which {owner} owns, is in no test, script or workflow, and {owner} has merged")
    print(f"named-tests: {required} required because their pull request or their package has merged"
          f"{' or merges with this pull request' if package else ''}, {len(missing)} missing")
    return 1 if missing else 0


# ---------------------------------------------------------------- lint


SWIFT_SOURCES = ("Packages/KnotKit/Sources/", "Apps/")
# The package's tests, which the lint reads for one rule alone: no test cancels itself.
SWIFT_TESTS = ("Packages/KnotKit/Tests/",)
# A test that cancels itself, or one of its cases. Swift Testing prints a cancelled case of a
# test with arguments as passed, so the gate could not tell it from a run (finding 51); a
# test that cannot run here says so by a trait, which is printed as skipped.
TEST_CANCEL = re.compile(r"\bTest\s*(?:\.\s*Case\s*)?\.\s*cancel\s*\(")
LIBRARY_EXEMPT = ("Packages/KnotKit/Sources/knot/", "Packages/KnotKit/Sources/knot-eval/",
                  "Packages/KnotKit/Sources/KnotStoreCrashHost/", "Packages/KnotKit/Sources/KnotAudioCrashHost/",
                  "Packages/KnotKit/Sources/KnotLinkCrashHost/", "Packages/KnotKit/Sources/KnotInkCrashHost/",
                  "Packages/KnotKit/Sources/KnotSoakChild/")

REQUIRED_REASON = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|@AppStorage\b|\bNSUserDefaults\b",
    "NSPrivacyAccessedAPICategoryFileTimestamp":
        r"\bcreationDate\b|\bmodificationDate\b|contentModificationDate|attributesOfItem|\bfileModificationDate\b"
        r"|\b(?:creation|contentModification|attributeModification|contentAccess)DateKey\b"
        r"|\bf?getattrlist(?:bulk|at)?\(|(?<![\w.])[fl]?stat(?:at)?\(",
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|\bmach_absolute_time\(",
    "NSPrivacyAccessedAPICategoryDiskSpace":
        r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|\bsystemSize\b|\bf?statv?fs\(",
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"\bactiveInputModes\b",
}

# What each app and extension links, for the required-reason check: its own folder, and
# the package modules its target file names (KnotApp brings every module).
MANIFESTS = {
    "Apps/iOS/PrivacyInfo.xcprivacy": ["Apps/iOS/", "Apps/Shared/", "*"],
    "Apps/macOS/PrivacyInfo.xcprivacy": ["Apps/macOS/", "Apps/Shared/", "*"],
    "Apps/watchOS/PrivacyInfo.xcprivacy": ["Apps/watchOS/", "Apps/Shared/", "KnotAudio", "KnotCore", "KnotIntents",
                                           "KnotLink", "KnotUI"],
    "Apps/Extensions/Widgets-iOS/PrivacyInfo.xcprivacy": ["Apps/Extensions/Widgets-iOS/", "KnotCore", "KnotIntents",
                                                          "KnotUI"],
    "Apps/Extensions/Widgets-watchOS/PrivacyInfo.xcprivacy": ["Apps/Extensions/Widgets-watchOS/", "KnotCore",
                                                              "KnotIntents", "KnotUI"],
}


def code_lines(path):
    """The statements of a Swift file, as (first line number, code, raw text). The code has its
    comments blanked; the raw text keeps them, for the `knot-lint: allow` marker. A call that
    runs over several lines is joined into one statement, by its parentheses."""
    with open(path, encoding="utf-8") as f:
        raw_text = f.read()
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), raw_text, flags=re.S)
    start, parts, raws, depth = None, [], [], 0
    for number, (line, raw) in enumerate(zip(text.splitlines(), raw_text.splitlines()), 1):
        if line.strip().startswith("//"):
            line = ""
        line = re.sub(r"\s//.*$", "", line)
        if start is None:
            if not line.strip():
                continue
            start = number
        parts.append(line.strip())
        raws.append(raw.strip())
        # Parentheses inside a string literal, interpolations included, open no call: they
        # are counted only outside the literals, so that a "(" in a string does not join the
        # lines after it into one statement.
        bare = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
        depth += bare.count("(") - bare.count(")")
        if depth <= 0:
            yield start, " ".join(parts), " ".join(raws)
            start, parts, raws, depth = None, [], [], 0
    if start is not None:
        yield start, " ".join(parts), " ".join(raws)


LOG_CALL = re.compile(r"\.\s*(?:debug|info|notice|error|fault|warning|trace|critical|log)\s*\(\s*(?:level:[^,]*,\s*)?\"")
# A value that `privacy: .public` may show: an ID, a count, a code, a duration or a state,
# judged by its name. One component of the expression must be such a name, as in
# `captureID`, `note.id` or `elapsed`, and every component after it must only format it, as
# `uuidString` or `formatted()` do. The lint cannot know what a value holds.
PUBLIC_VALUE = re.compile(r"(?i)^(?:\w*(?:id|ids)|count|code|codes|\w*duration|elapsed|latency|interval|seconds"
                          r"|milliseconds|kind|state|status|version|build|step|attempts?|deaths|index|number|bytes|size"
                          r"|reason|rawValue)$|^\w+(?:ID|Id|IDs|Count|Code|Duration|Kind|State|Status|Reason)$")
FORMATTING = re.compile(r"^(?:uuidString|description|rawValue|formatted|count|components|seconds|milliseconds)$")


def public_value_allowed(value):
    parts = [re.sub(r"\(.*$", "", part) for part in re.split(r"\.(?![^()]*\))", value.strip())]
    for index, part in enumerate(parts):
        if PUBLIC_VALUE.search(part) and all(FORMATTING.search(after) for after in parts[index + 1:]):
            return True
    return False


def interpolations(text):
    """The expressions of every \\( … ) in a statement, with balanced parentheses."""
    found, i = [], 0
    while True:
        i = text.find("\\(", i)
        if i < 0:
            return found
        depth, j = 1, i + 2
        while j < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        found.append(text[i + 2:j - 1])
        i = j


def log_problems(statement):
    """Why a statement logs too much, or nothing. The lint cannot know what a value holds: it
    checks that every interpolated value of a log line states its privacy, and that a value
    shown as public is named like an ID, a count or a code."""
    found = []
    if re.search(r"(?<![\w.])os_log\s*\(|(?<![\w.])NSLog\s*\(", statement):
        found.append("os_log and NSLog cannot state each value's privacy: use Logger")
    if LOG_CALL.search(statement):
        for expression in interpolations(statement):
            if "privacy:" not in expression:
                found.append(f"the logged value \\({expression.strip()}) states no privacy")
            elif re.search(r"privacy:\s*\.public\b", expression):
                value = expression.split(",")[0].strip()
                if not public_value_allowed(value):
                    found.append(f"\\({value}) is shown as public, and its name is not an ID, a count or a code")
    return found


def copy_problem(path):
    """A path with a component whose name ends in " 2", the mark of a cloud provider's copy."""
    return any(re.search(r" 2(\.[^/.]+)?$", part) for part in path.split("/"))


def swift_files(prefixes=SWIFT_SOURCES):
    found = []
    for path in lines(git("ls-files")) + lines(git("ls-files", "--others", "--exclude-standard")):
        if path.endswith(".swift") and path.startswith(prefixes) and os.path.isfile(path):
            found.append(path)
    return sorted(set(found))


def module_of(path):
    match = re.match(r"^Packages/KnotKit/Sources/([^/]+)/", path)
    return match.group(1) if match else None


def cmd_team_id(team_config):
    """The signing team's ID, from the owner's local configuration, in no tracked file.

    Exits 3 when there is no local configuration with a team ID: the check did not run, and
    scripts/verify.sh counts it as skipped, never as passed."""
    team = None
    if team_config and os.path.exists(team_config):
        with open(team_config) as f:
            match = re.search(r"^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$", f.read(), re.M)
            team = match.group(1) if match else None
    if not team:
        print(f"team-id: no local configuration with a team ID at {team_config or 'KNOT_TEAM_CONFIG or KNOT_LOCAL_CONFIG'}, so the check did not run")
        return 3
    found = lines(subprocess.run(["git", "grep", "-l", "-F", team], capture_output=True, text=True).stdout)
    for path in found:
        print(f"team-id: {path} holds the signing team's ID from the local configuration")
    print(f"team-id: looked for the team ID in every tracked file, {len(found)} holding it")
    return 1 if found else 0


def cmd_lint(only=None, as_prefix=None, manifest=None):
    """The gate's lint (docs/architecture.md §18). With `only`, it reads those files alone;
    with `as_prefix`, it judges each of them as if it sat in that folder; with `manifest`, it
    judges required-reason APIs against that privacy manifest alone, never the tree's. That
    is how the self-test runs it on its fixture, whatever the real manifests come to hold."""
    problems = []

    def problem(path, number, rule, message):
        problems.append(f"lint: {path}:{number}: [{rule}] {message}")

    files = only if only else swift_files()
    tests = [] if only else swift_files(SWIFT_TESTS)
    escapes = {}
    used = {}
    for path in files + tests:
        if TEST_CANCEL.search("".join(line for _, line, _ in code_lines(path))):
            for number, line, _ in code_lines(path):
                if TEST_CANCEL.search(line):
                    problem(path, number, "test-cancel",
                            "a test that cannot run here says so by a trait, which is printed as skipped; a "
                            "cancelled case of a test with arguments is printed as passed")
        if path in tests:
            continue
        place = (as_prefix + os.path.basename(path)) if as_prefix else path
        # A fake outside KnotFakes is named Fake… and compiles only under
        # `#if DEBUG || KNOT_FAKES`; the release scan finds such a type by its name.
        guards = []
        for number, line, raw in code_lines(path):
            directive = line.strip()
            if directive.startswith("#if"):
                guards.append(re.sub(r"\s", "", directive[3:]) in ("DEBUG||KNOT_FAKES", "KNOT_FAKES||DEBUG"))
                continue
            if directive.startswith("#elseif") or directive.startswith("#else"):
                if guards:
                    guards[-1] = False
                continue
            if directive.startswith("#endif"):
                if guards:
                    guards.pop()
                continue
            fake = re.search(r"\b(?:class|struct|enum|actor|protocol|typealias)\s+(Fake\w*)", line)
            if fake and not place.startswith("Packages/KnotKit/Sources/KnotFakes/") and not any(guards):
                problem(path, number, "fake-unguarded",
                        f"{fake.group(1)} is a fake by its name: outside KnotFakes it compiles only under "
                        "#if DEBUG || KNOT_FAKES")
            # The marker sits in a comment, so it is read from the raw line.
            allowed = re.findall(r"knot-lint: allow ([\w-]+)", raw)
            if re.search(r"UserDefaults\s*\.\s*standard|UserDefaults\(\)"
                         r"|(?::\s*UserDefaults\??\s*=|\bstore:|defaultAppStorage\()\s*\.standard\b", line):
                problem(path, number, "standard-defaults", "v1 keeps its settings in a named defaults suite")
            if "@AppStorage(" in line and "store:" not in line:
                problem(path, number, "app-storage", "@AppStorage needs a named store")
            for name in re.findall(r"(?:[Aa]utosaveName|FrameAutosaveName)\s*[:=(]\s*\"([^\"]*)\"", line):
                if not name.startswith("v1."):
                    problem(path, number, "autosave-name", f'the autosave name "{name}" needs the v1. prefix')
            if "eraseDatabaseOnSchemaChange" in line:
                problem(path, number, "erase-database", "eraseDatabaseOnSchemaChange erases the store")
            if re.search(r"\bURLSession\b|\bURLRequest\b|\bNW(?:Connection|Listener|Browser|Endpoint)\b|\bnw_(?:connection|listener)_"
                         r"|\bCFStream|\bCFSocket|https?://", line) and "network" not in allowed:
                problem(path, number, "network", "Knot contacts no host but CloudKit and Apple's model downloads")
            if "logged-text" not in allowed:
                for why in log_problems(line):
                    problem(path, number, "logged-text", why)
                if not place.startswith(LIBRARY_EXEMPT) and \
                        re.search(r"(?<![\w.])(?:print|debugPrint|dump)\(|\bSwift\.(?:print|debugPrint|dump)\(", line):
                    problem(path, number, "logged-text", "an app or a library logs through Logger, never print or dump")
            for escape in ("@unchecked Sendable", "nonisolated(unsafe)", "@preconcurrency"):
                escapes[(path, escape)] = escapes.get((path, escape), 0) + line.count(escape)
            for category, pattern in REQUIRED_REASON.items():
                if re.search(pattern, line):
                    used.setdefault(category, []).append((path, place, number))

    # Concurrency escapes stay on a reviewed list: path, escape, count, reason.
    reviewed = {}
    if os.path.exists(CONCURRENCY_ESCAPES):
        with open(CONCURRENCY_ESCAPES) as f:
            for line in f:
                fields = line.rstrip("\n").split("\t")
                if line.startswith("#") or len(fields) < 4:
                    continue
                reviewed[(fields[0], fields[1])] = int(fields[2])
    for (path, escape), count in sorted(escapes.items()):
        if count > reviewed.get((path, escape), 0):
            problem(path, "-", "concurrency-escape",
                    f"{count} × {escape}, {reviewed.get((path, escape), 0)} on {CONCURRENCY_ESCAPES}")

    # A required-reason API must have its reason in the manifest of every target that holds it.
    manifests = {manifest: [as_prefix or ""]} if manifest else MANIFESTS
    for manifest, reach in manifests.items():
        with open(manifest, "rb") as f:
            declared = {entry["NSPrivacyAccessedAPIType"] for entry in plistlib.load(f).get("NSPrivacyAccessedAPITypes", [])
                        if entry.get("NSPrivacyAccessedAPITypeReasons")}
        for category, places in used.items():
            for path, place, number in places:
                module = module_of(place)
                in_reach = any(place.startswith(r) for r in reach if r.endswith("/")) or \
                    (module is not None and not place.startswith(LIBRARY_EXEMPT) and ("*" in reach or module in reach))
                if in_reach and category not in declared:
                    problem(path, number, "required-reason", f"{category} has no reason in {manifest}")

    # A path with a component whose name ends in " 2", the mark of a cloud provider's copy.
    paths = only if only else lines(git("ls-files")) + lines(git("ls-files", "--others", "--exclude-standard"))
    for path in paths:
        if copy_problem(path):
            problem(path, "-", "copy-file", 'a file or folder whose name ends in " 2"')

    for line in problems:
        print(line)
    print(f"lint: {len(files)} Swift files{f' and {len(tests)} test files' if tests else ''}, {len(problems)} problems")
    return 1 if problems else 0


# ---------------------------------------------------------------- tests that started


# Swift Testing's event lines: the glyph, two spaces, "Test ", the name, and the event. A test
# with arguments ends as "Test f(x:) with 3 test cases passed after …".
TEST_EVENT = re.compile(r"^[^\x00-\x7f]+  Test (.+?)(?: with \d+ test cases?)? "
                        r"(started\.|passed after .*|failed after .*|skipped(?:\.|: .*)?|was cancelled after .*)$")


def cmd_unended_tests(log):
    """The tests of a Swift Testing log that started and did not end, one a line, for a run
    that reached its limit; and the ones that failed. The names are counted, since a suite's
    targets run one after another and a name can recur."""
    from collections import Counter
    open_tests, failed = Counter(), []
    with open(log, errors="replace") as f:
        for line in f:
            match = TEST_EVENT.match(line.rstrip("\n"))
            if not match:
                continue
            name, event = match.groups()
            if name == "run" or name.startswith("run with ") or name.startswith("case passing "):
                # The run's own lines, "Test run started." and "Test run with N tests …"; and
                # the cases of a test with arguments, whose start is printed and whose end is
                # not: the test's own lines say whether it ended.
                continue
            if event == "started.":
                open_tests[name] += 1
            else:
                open_tests[name] -= 1
                if event.startswith("failed"):
                    failed.append(name)
    for name, count in open_tests.items():
        for _ in range(max(count, 0)):
            print(f"started, not ended: {name}")
    for name in failed:
        print(f"failed: {name}")
    return 0


# ---------------------------------------------------------------- workflows


NIGHTLY = ".github/workflows/nightly.yml"


def workflow_jobs(text):
    """The jobs of a workflow, as {job: [step]}, each step a dict of its keys, with a block
    value such as `run: |` joined into one string. It reads the plain layout of this
    repository's workflows (two spaces a level, a step as `- name:` or `- uses:`), not every
    form YAML allows, and comment lines count for nothing."""
    jobs, job, steps, step, block, in_jobs = {}, None, None, None, None, False
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if block is not None:
            if indent > block[1]:
                step[block[0]] = (step[block[0]] + "\n" + line.strip()).strip()
                continue
            block = None
        if indent == 0:
            in_jobs = line.startswith("jobs:")
            continue
        if not in_jobs:
            continue
        if indent == 2 and line.rstrip().endswith(":"):
            job = line.strip()[:-1]
            jobs[job], steps, step = [], None, None
            continue
        if job and indent == 4 and line.strip() == "steps:":
            steps = jobs[job]
            continue
        if steps is not None and line.lstrip().startswith("- "):
            step = {}
            steps.append(step)
            line = line.replace("- ", "  ", 1)
            indent += 2
        if step is not None and steps is not None and ":" in line:
            key, value = line.strip().split(":", 1)
            value = value.strip()
            step[key] = "" if value in ("|", ">") else value
            if value in ("|", ">"):
                block = (key, indent)
    return jobs


def cmd_workflows(path=NIGHTLY):
    """The tree's nightly workflow makes the tree's audio before the package tests under
    Thread Sanitizer: in the job that runs `scripts/verify.sh --only tsan`, a step whose run
    is `scripts/verify.sh --only fixtures` comes first, and neither step has a condition.
    `--only tsan` has no fixtures step, and the tests that read the audio need it. The gate's
    lint step runs this on the tree; the self-test, on wrong workflows of its own."""
    problems = []
    if not os.path.exists(path):
        print(f"workflows: {path} is missing")
        return 1
    jobs = workflow_jobs(open(path).read())
    found = False
    for job, steps in jobs.items():
        runs = [step.get("run", "").strip() for step in steps]
        if "scripts/verify.sh --only tsan" not in runs:
            continue
        found = True
        tsan = runs.index("scripts/verify.sh --only tsan")
        fixtures = runs.index("scripts/verify.sh --only fixtures") if "scripts/verify.sh --only fixtures" in runs else None
        if fixtures is None:
            problems.append(f"the job {job} runs the tsan step with no fixtures step in it")
        elif fixtures > tsan:
            problems.append(f"the job {job} runs the tsan step before the fixtures step")
        for name, at in (("fixtures", fixtures), ("tsan", tsan)):
            if at is not None and "if" in steps[at]:
                problems.append(f"the {name} step of the job {job} has a condition, if: {steps[at]['if']}")
    if not found:
        problems.append("no job runs scripts/verify.sh --only tsan")
    for problem in problems:
        print(f"workflows: {path}: {problem}")
    if problems:
        return 1
    print(f"workflows: {path} makes the audio before the package tests under Thread Sanitizer")
    return 0


# ---------------------------------------------------------------- links


LINK = re.compile(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def cmd_links():
    broken = 0
    documents = [p for p in lines(git("ls-files", "*.md")) if os.path.isfile(p)]
    for path in documents:
        with open(path, encoding="utf-8") as f:
            text = re.sub(r"```.*?```", "", f.read(), flags=re.S)
        for target in LINK.findall(text):
            if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("#"):
                continue
            file_part = target.split("#", 1)[0]
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), file_part))
            if not os.path.exists(resolved):
                print(f"links: {path}: {target} does not exist")
                broken += 1
    print(f"links: {len(documents)} documents, {broken} broken links")
    return 1 if broken else 0


# ---------------------------------------------------------------- status


def cmd_status(write):
    """The status table (PLAN.md §8.7): package, state, thread, pull requests, milestone
    evidence. The briefs give the packages and their PR counts, GitHub the pull requests,
    their labels and statuses, the journal folder the threads."""
    try:
        out = subprocess.run(["gh", "pr", "list", "--state", "all", "--base", "main", "--limit", "500", "--json",
                              "number,headRefName,state,isDraft,labels,headRefOid"],
                             check=True, capture_output=True, text=True).stdout
        prs = json.loads(out)
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"status: GitHub could not be read: {error}", file=sys.stderr)
        return 1
    threads = {}
    folder = os.environ.get("KNOT_BUILD_FOLDER", os.path.expanduser("~/knot-build"))
    thread_file = os.path.join(folder, "threads.tsv")
    if os.path.exists(thread_file):
        with open(thread_file) as f:
            for line in f:
                fields = line.rstrip("\n").split("\t")
                if len(fields) >= 2 and not line.startswith("#"):
                    threads[fields[0]] = fields[1]
    evidence = {}
    if os.path.exists("docs/status.md"):
        with open("docs/status.md") as f:
            for line in f:
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                if len(cells) >= 5 and re.match(r"^(WP|SP)-\d+$", cells[0]):
                    evidence[cells[0]] = cells[4]
    rows = ["| Package | State | Thread | Pull requests | Milestone evidence |", "|---|---|---|---|---|"]
    for package in packages():
        mine = [pr for pr in prs if package_of_branch(pr["headRefName"]) == package]
        merged, total = merge_state(package, [(package, is_note_branch(pr["headRefName"]))
                                              for pr in mine if pr["state"] == "MERGED"])
        open_prs = [pr for pr in mine if pr["state"] == "OPEN"]
        if merged >= total:
            state = "merged"
        elif open_prs:
            pr = open_prs[0]
            labels = [label["name"] for label in pr.get("labels", [])]
            gate = gate_status(pr["headRefOid"])
            state = "PR %d of %d %s%s%s" % (merged + 1, total, "draft" if pr["isDraft"] else "open",
                                            (", " + ", ".join(labels)) if labels else "",
                                            (", gate " + gate) if gate else "")
        elif merged:
            state = f"{merged} of {total} merged"
        else:
            state = "not started"
        numbers = ", ".join("#%d" % pr["number"] for pr in sorted(mine, key=lambda p: p["number"])) or "-"
        rows.append(f"| {package} | {state} | {threads.get(package, '-')} | {numbers} | {evidence.get(package, '-')} |")
    table = "\n".join(rows) + "\n"
    if write:
        with open("docs/status.md", "w") as f:
            f.write("# Status\n\nWritten by `scripts/status.sh --write`, on `main` at milestones only.\n\n" + table)
    sys.stdout.write(table)
    return 0


def gate_status(sha):
    try:
        out = subprocess.run(["gh", "api", f"repos/{{owner}}/{{repo}}/commits/{sha}/statuses"],
                             check=True, capture_output=True, text=True).stdout
        for status in json.loads(out):
            if status.get("context") == "knot/gate":
                return status.get("state", "")
    except (OSError, subprocess.CalledProcessError, ValueError):
        pass
    return ""


# ---------------------------------------------------------------- main


def option(args, name, default=None):
    if name in args:
        index = args.index(name)
        if index + 1 < len(args):
            return args[index + 1]
    return default


# ---------------------------------------------------------------- starts that have a limit

# The helpers that bound a command: each is the command word of a simple command, and the
# command it bounds is among its arguments.
LIMIT_HELPERS = ("knot_limit", "knot_run_limited", "knot_sim_call", "knot_swift_test_limited",
                 "knot_start_tool", "knot_start_app")
LIMIT_MARKER = re.compile(r"#\s*limit:\s*([A-Za-z_][\w-]*)\s*$")
OTHER_PARTS = ("soak",)
# Words that may stand before the command word of a simple command.
RESERVED_WORDS = {"if", "then", "elif", "else", "fi", "while", "until", "do", "done", "!", "{", "}",
                  "time", "case", "esac", "in", "function", "select", "for"}
PREFIX_WORDS = {"command", "builtin", "exec", "nohup", "env", "sudo", "nice", "caffeinate", "time", "arch", "xargs",
                "coproc", "stdbuf"}
# The options of a prefix that take the next word as their value.
PREFIX_VALUE_OPTIONS = ("-u", "-n", "-g", "-C", "-arch", "-I", "-J", "-L", "-P", "-s", "-E", "-R", "-a")
# A parameter expansion with a default, as in "${XCODEBUILD:-xcodebuild}": the default is the
# word when the variable is unset, so the check reads it.
DEFAULT_EXPANSION = re.compile(r"^\$\{([A-Za-z_]\w*):?[-=]([^}]*)\}(.*)$")
# An assignment by a default, as in : "${XC:=xcodebuild}".
DEFAULT_ASSIGNMENT = re.compile(r"\$\{([A-Za-z_]\w*):?=([\w./ -]+)\}")
# Words whose command only looks a name up, and starts nothing.
LOOKUP_WORDS = {"type", "hash", "which", "whence"}
FUNCTION_DEF = re.compile(r"^(\s*)(?:function\s+([A-Za-z_][\w-]*)\s*(?:\(\))?|([A-Za-z_][\w-]*)\s*\(\))\s*\{(.*)$")
# A here-document: `<<` or `<<-`, not `<<<`, and a word that starts with a letter, an
# underscore or a quote, so that an arithmetic shift such as $((1 << 3)) is none.
HEREDOC = re.compile(r"(?<!<)<<-?(?!<)\s*(['\"]?)([A-Za-z_]\w*)\1")
SHELL_HEREDOC = re.compile(r"^\s*(?:[\w./-]*/)?(?:bash|sh|zsh)\b[^|;&]*<<")


def shell_segments(text, first_line=1):
    """The simple commands of a piece of shell, as (first line, last line, text), split outside
    quotes at newlines, ;, &&, ||, | and &, with a backslash-newline read as a space. What a
    command substitution, $(…) or backticks, holds is read as commands of its own, at the line
    where it starts; arithmetic, $((…)) and ((…)), holds none. A case pattern, which stands
    after `case … in` and after `;;`, names values, so it is no command, whatever its
    alternatives and however it is spelled."""
    segments = []
    current, start, line = [], first_line, first_line
    i, n = 0, len(text)
    quote = None
    parens = 0
    pattern_next = False
    CASE_HEAD = re.compile(r"^\s*case\s+.+\s+in$")

    def close(end_line):
        nonlocal current, start, pattern_next
        body = "".join(current).strip()
        if body:
            segments.append((start, end_line, body))
            if CASE_HEAD.match(body):
                pattern_next = True
        current = []
        start = end_line

    def pattern_end(at):
        """The index of the ) that ends a case pattern starting at text[at], and the newlines
        it crosses."""
        k, depth, crossed = at + (text[at] == "("), 0, 0
        while k < n:
            ch = text[k]
            if ch == "\\" and k + 1 < n:
                crossed += text[k + 1] == "\n"
                k += 2
                continue
            if ch in "'\"":
                close_at = text.find(ch, k + 1)
                k = n if close_at < 0 else close_at + 1
                continue
            if ch == "\n":
                crossed += 1
            elif ch == "(":
                depth += 1
            elif ch == ")":
                if depth == 0:
                    return k, crossed
                depth -= 1
            k += 1
        return n, crossed

    def matching(at, opener, closer):
        """The index just past the closer that matches an opener at text[at]."""
        depth, k, q = 0, at, None
        while k < n:
            c = text[k]
            if q:
                if c == "\\" and q == '"':
                    k += 2
                    continue
                if c == q:
                    q = None
            elif c in "'\"":
                q = c
            elif text.startswith(opener, k):
                depth += 1
                k += len(opener)
                continue
            elif text.startswith(closer, k):
                depth -= 1
                if depth == 0:
                    return k + len(closer)
            k += 1
        return n

    while i < n:
        c = text[i]
        if pattern_next and not quote and c not in " \t\n#":
            pattern_next = False
            if not re.match(r"esac\b", text[i:i + 5]):
                end, crossed = pattern_end(i)
                line += crossed
                current, start = [], line
                i = end + 1
                continue
        if not quote and c in " \t" and CASE_HEAD.match("".join(current)):
            # `case x in` followed on the same line by its first pattern.
            close(line)
            i += 1
            continue
        if c == "\\" and i + 1 < n and text[i + 1] == "\n" and quote != "'":
            current.append(" ")
            line += 1
            i += 2
            continue
        if c == "\n":
            line += 1
            if quote:
                current.append(c)
            else:
                close(line - 1)
                start = line
            i += 1
            continue
        if quote == "'":
            current.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            current.append(text[i:i + 2])
            i += 2
            continue
        if text.startswith("$((", i):
            end = matching(i + 1, "((", "))")
            line += text.count("\n", i, end)
            current.append("0")
            i = end
            continue
        if text.startswith("$(", i) or c == "`":
            if c == "`":
                end = text.find("`", i + 1)
                end = n if end < 0 else end + 1
                inner = text[i + 1:end - 1]
            else:
                end = matching(i + 1, "(", ")")
                inner = text[i + 2:end - 1]
            segments.extend(shell_segments(inner, line))
            line += text.count("\n", i, end)
            current.append("SUBSTITUTION")
            i = end
            continue
        if quote == '"':
            current.append(c)
            if c == '"':
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
            current.append(c)
            i += 1
            continue
        if c == "#" and (not current or "".join(current)[-1:].isspace()):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("((", i):
            end = matching(i, "((", "))")
            line += text.count("\n", i, end)
            i = end
            continue
        if text.startswith("&&", i) or text.startswith("||", i):
            close(line)
            i += 2
            continue
        if c == "(" and text[i - 1:i] == "=":
            # An array's literal, as in `cmd=(xcrun simctl list)`, is a word, not a subshell.
            end = matching(i, "(", ")")
            current.append(text[i:end])
            line += text.count("\n", i, end)
            i = end
            continue
        if c == "&" and (text[i - 1:i] == ">" or text[i + 1:i + 2] == ">"):
            current.append(c)
            i += 1
            continue
        if c == ")" and parens == 0:
            # A ) with no ( open ends a case pattern, such as `xcodebuild)`: no command.
            current = []
            i += 1
            continue
        if c in "()":
            parens += 1 if c == "(" else -1
            close(line)
            i += 1
            continue
        if text.startswith(";;", i) or text.startswith(";&", i):
            # The end of a case item: a pattern or esac comes next.
            close(line)
            pattern_next = True
            i += 3 if text.startswith(";;&", i) else 2
            continue
        if c in ";|&":
            close(line)
            i += 1
            continue
        current.append(c)
        i += 1
    close(line)
    return segments


def shell_words(segment):
    """The words of a simple command, with quotes removed and redirections dropped."""
    import shlex
    try:
        words = shlex.split(segment, posix=True)
    except ValueError:
        words = segment.split()
    kept, skip = [], False
    for word in words:
        if skip:
            skip = False
            continue
        if re.match(r"^\d*(>>?|<|&>)$", word):
            skip = True
            continue
        if re.match(r"^\d*(>>?|<|&>)", word):
            continue
        kept.append(word)
    return kept


def command_words(words, scalars, arrays):
    """The command word of a simple command and the words after it: past assignments,
    reserved words and prefixes such as env or exec, and with a command word held in a
    variable or an array of the same file put in its place."""
    k = 0
    while k < len(words):
        word = words[k]
        if word in ("case", "for", "select"):
            # `case x in`, `for x in …`: the words name values, not a command.
            return []
        if re.match(r"^[A-Za-z_]\w*(\[[^]]*\])?\+?=", word) or word in RESERVED_WORDS:
            k += 1
            if word == "time":
                # time's own options, as in `time -p`.
                while k < len(words) and words[k].startswith("-"):
                    k += 1
            continue
        if os.path.basename(word) in PREFIX_WORDS:
            if word == "command" and k + 1 < len(words) and words[k + 1] in ("-v", "-V"):
                return []
            k += 1
            if word == "coproc" and k + 1 < len(words) and re.match(r"^[A-Za-z_]\w*$", words[k]) and words[k + 1] == "{":
                # `coproc NAME { …; }`: the name is the coprocess's, not a command.
                k += 1
                continue
            while k < len(words) and (words[k].startswith("-") or re.match(r"^[A-Za-z_]\w*=", words[k])):
                if os.path.basename(word) == "env" and words[k] in ("-S", "--split-string") and k + 1 < len(words):
                    # env -S splits its next word into the command and its arguments.
                    return command_words(shell_words(words[k + 1]) + words[k + 2:], scalars, arrays)
                k += 1 + (words[k] in PREFIX_VALUE_OPTIONS)
            continue
        if word in LOOKUP_WORDS:
            return []
        break
    rest = words[k:]
    if rest:
        variable = re.match(r"^\$\{?([A-Za-z_]\w*)(\[[@*]\])?\}?$", rest[0])
        default = DEFAULT_EXPANSION.match(rest[0])
        if variable and variable.group(1) in arrays:
            rest = arrays[variable.group(1)] + rest[1:]
        elif variable and variable.group(1) in scalars:
            rest = scalars[variable.group(1)].split() + rest[1:]
        elif default:
            held = scalars.get(default.group(1))
            rest = (held.split() if held else (default.group(2) + default.group(3)).split()) + rest[1:]
    return rest


def limited_call(words):
    """What a command calls among the starts that need a limit: xcodebuild, xcb, swift test,
    and xcrun simctl, xcrun xcodebuild or xcrun swift test, past xcrun's options. None
    otherwise."""
    if not words:
        return None
    name = os.path.basename(words[0])
    args = [w for w in words[1:]]
    if name in ("xcodebuild", "xcb"):
        return name
    if name == "swift" and [w for w in args if not w.startswith("-")][:1] == ["test"]:
        return "swift test"
    if name == "xcrun":
        k = 0
        while k < len(args) and args[k].startswith("-"):
            if args[k] in ("-f", "-find", "--find") or args[k].startswith("--show-") or args[k] in ("--version", "-h", "--help"):
                return None
            k += 1 + (args[k] in ("--sdk", "-sdk", "--toolchain", "-toolchain"))
        rest = args[k:]
        if rest[:1] == ["simctl"]:
            return "xcrun simctl"
        return limited_call(rest)
    return None


def cmd_unbounded_calls(files):
    """Fails on a call of swift test, xcrun simctl, xcodebuild or xcb in the scripts that is
    not bounded. A call is bounded when a limit helper (LIMIT_HELPERS) is the command word of
    its own simple command, as in `knot_limit 10 xcodebuild -version`. A call inside a wrapper,
    such as xcb's own xcodebuild, carries `# limit: <wrapper>`, where <wrapper> is the function
    that holds the line; then every call of the wrapper must be bounded in its turn. The file
    is read as shell: its simple commands, split outside quotes; what command substitutions,
    eval, bash -c, env -S, a trap's action and find's -exec hold; and a command word held in a
    variable or array of the same file, or given as a default, as in ${XCODEBUILD:-xcodebuild}.
    What it cannot see: a command word built at run time, such as one read from a file or put
    together from pieces; an alias; a command that another runs from its arguments, such as
    script; a script that a call runs; and a function named in a variable that is assigned in
    another file. The steps other packages own (OTHER_PARTS) are
    listed and left to them."""
    findings, wrappers, calls = set(), {}, []
    for path in files:
        with open(path) as f:
            text = f.read()
        raw = text.splitlines()
        # Heredoc bodies hold no commands of this file.
        # A here-document fed to a shell is read as commands; any other's body is not.
        lines, terminator, shell_body = [], None, False
        for line in raw:
            if terminator:
                ended = line.strip() == terminator
                lines.append(line if shell_body and not ended else "")
                if ended:
                    terminator = None
                continue
            bare = re.sub(r"\$?\(\((?:[^()]|\([^()]*\))*\)\)", "0", line.split("#", 1)[0]) if "<<" in line else ""
            heredoc = HEREDOC.search(bare)
            lines.append(line)
            if heredoc:
                terminator = heredoc.group(2)
                shell_body = bool(SHELL_HEREDOC.match(bare))
        # The function that holds each line, by the definitions' indentation.
        holder, stack = {}, []
        for number, line in enumerate(lines, 1):
            definition = FUNCTION_DEF.match(line)
            if definition:
                name, rest = definition.group(2) or definition.group(3), definition.group(4)
                holder[number] = name
                if not re.search(r"\}\s*(#.*)?$", rest):
                    stack.append((len(definition.group(1)), name))
                lines[number - 1] = definition.group(1) + "{" + rest
                continue
            holder[number] = stack[-1][1] if stack else None
            if stack and re.match(r"^\s*\}", line) and len(line) - len(line.lstrip()) == stack[-1][0]:
                stack.pop()
        defined = set(holder.values()) - {None}
        markers = {n: m.group(1) for n, line in enumerate(raw, 1) if (m := LIMIT_MARKER.search(line))}
        others = [part_markers(text, name) for name in OTHER_PARTS]
        segments = shell_segments("\n".join(lines))
        # Simple assignments of a word or an array, for a command word held in a variable. An
        # array may be built by `+=`. A `for` loop's variable is held as the value of its list
        # that is a start, if one is, so that `for tool in xcodebuild; do "$tool" …` is read.
        scalars, arrays = {}, {}
        for _, _, segment in segments:
            assign = re.match(r"^(?:(?:local|readonly|declare|typeset)(?:\s+-\w+)*\s+)?([A-Za-z_]\w*)(\+?)=\((.*)\)$", segment)
            if assign:
                held = arrays.get(assign.group(1), []) if assign.group(2) else []
                arrays[assign.group(1)] = held + shell_words(assign.group(3))
                continue
            loop = re.match(r"^for\s+([A-Za-z_]\w*)\s+in\s+(.*)$", segment)
            if loop:
                values = shell_words(loop.group(2))
                if values:
                    scalars[loop.group(1)] = next((v for v in values if limited_call(v.split())), values[0])
                continue
            for word in shell_words(segment):
                assign = re.match(r"^([A-Za-z_]\w*)=([\w./ -]+)$", word)
                if assign:
                    scalars[assign.group(1)] = assign.group(2)
                for assign in DEFAULT_ASSIGNMENT.finditer(word):
                    scalars.setdefault(assign.group(1), assign.group(2))

        def commands(segment, words=None):
            """The commands a simple command runs: itself, and what eval, bash -c, a trap's
            action and find's -exec hold."""
            if words is None:
                words = shell_words(segment)
            words = command_words(words, scalars, arrays)
            yield words
            name = os.path.basename(words[0]) if words else ""
            held = []
            if name == "eval":
                held.append(" ".join(words[1:]))
            if name in ("bash", "sh", "zsh") and "-c" in words:
                at = words.index("-c")
                if at + 1 < len(words):
                    held.append(words[at + 1])
            if name == "trap":
                action = [w for w in words[1:] if w != "--"]
                if action and not action[0].startswith("-"):
                    held.append(action[0])
            for text in held:
                for inner in shell_segments(text):
                    yield from commands(inner[2])
            if name == "find":
                at = 1
                while at < len(words):
                    if words[at] in ("-exec", "-execdir", "-ok", "-okdir"):
                        end = next((e for e in range(at + 1, len(words)) if words[e] in (";", "+")), len(words))
                        yield from commands("", words[at + 1:end])
                        at = end
                    at += 1

        for first, last, segment in segments:
            part = next((name for name, span in zip(OTHER_PARTS, others) if span and span[0] <= first <= span[1]), None)
            marker = next((markers[n] for n in range(first, last + 1) if n in markers), None)
            for words in commands(segment):
                if not words or words[0] in LIMIT_HELPERS:
                    continue
                call = limited_call(words)
                if not call:
                    continue
                if part:
                    print(f"{path}:{first}: in the {part} step, which its package bounds: {segment[:100]}")
                    continue
                if marker and marker == holder.get(first):
                    wrappers.setdefault(marker, (path, first))
                    continue
                if marker:
                    whose = holder.get(first) or "no function"
                    why = "names no function" if marker not in defined else "names another function"
                    findings.add((path, first, f"the marker `# limit: {marker}` {why}; the line is in {whose}: {segment[:100]}"))
                else:
                    findings.add((path, first, f"no limit: {call}: {segment[:100]}"))
        for first, _, segment in segments:
            for words in commands(segment):
                if words:
                    calls.append((path, first, holder.get(first), words, segment))
    # Every call of a wrapper, in any of the files, must be bounded in its turn, and a wrapper
    # must have a call that can be seen: a function called only by a name built at run time,
    # such as a step called as "step_${step}", cannot carry the marker.
    seen = {name: 0 for name in wrappers}
    for path, first, inside, words, segment in calls:
        if words[0] in wrappers and inside != words[0]:
            seen[words[0]] += 1
            where = wrappers[words[0]]
            findings.add((path, first, f"{words[0]}, which wraps the call at {os.path.basename(where[0])}:{where[1]}, "
                                       f"is called with no limit: {segment[:100]}"))
        elif words[0] in LIMIT_HELPERS:
            for name in wrappers:
                if name in words[1:]:
                    seen[name] += 1
    for name, (path, first) in wrappers.items():
        if not seen[name]:
            findings.add((path, first, f"the wrapper {name} has no call that can be seen: a function called by a name "
                                       f"built at run time cannot carry the marker; bound the call inside it"))
    for path, first, message in sorted(findings):
        print(f"{path}:{first}: {message}")
    found = len(findings)
    if found:
        print(f"unbounded-calls: {found} calls with no limit")
        return 1
    print(f"unbounded-calls: every call in {', '.join(files)} has a limit")
    return 0


# ---------------------------------------------------------------- this tree's audio fixtures


AUDIO_STAMP = "verify-stamp.txt"  # under Fixtures/generated/, beside the audio
NOT_AUDIO = ("about", "expectedSeconds", "toleranceSeconds")


def audio_stamp(committed):
    """A hash of everything in the committed manifest that decides the audio: the generator's
    version, the speech rate and the voices, and each clip's entry, its text's checksum,
    voice, format and seeds among it, all but its description and its expected length."""
    import hashlib
    decides = {
        "generatorVersion": committed.get("generatorVersion"),
        "speechRate": committed.get("speechRate"),
        "voices": committed.get("voices"),
        "audio": [{key: value for key, value in entry.items() if key not in NOT_AUDIO}
                  for entry in committed.get("audio", [])],
    }
    return hashlib.sha256(json.dumps(decides, sort_keys=True).encode()).hexdigest()


def cmd_fixtures_audio(fixtures, write_stamp=False):
    """Whether this tree holds its generated audio, as the fixtures step wants it:
    Fixtures/generated/manifest.json made by the generator's version that the committed
    manifest names; every clip that the committed manifest lists, present and matching the
    checksum the local manifest records; and the step's stamp beside the audio, which says
    that nothing in the committed manifest that decides the audio, such as a clip's text, its
    voice or the speech rate, has changed since the audio was spoken. Prints what is missing
    and exits 1 when the audio is not all there, so the step speaks it again. With
    --write-stamp, the step records the stamp after it has spoken the audio."""
    import hashlib
    fixtures = fixtures or "Fixtures"
    try:
        with open(os.path.join(fixtures, "manifest.json")) as f:
            committed = json.load(f)
    except (OSError, ValueError):
        print("Fixtures/manifest.json is missing or unreadable")
        return 1
    generated = os.path.dirname(os.path.join(fixtures, committed.get("generatedAudio", "generated/manifest.json")))
    stamp_path = os.path.join(generated, AUDIO_STAMP)
    if write_stamp:
        os.makedirs(generated, exist_ok=True)
        with open(stamp_path, "w") as f:
            f.write(audio_stamp(committed) + "\n")
    try:
        with open(os.path.join(generated, "manifest.json")) as f:
            local = json.load(f)
    except (OSError, ValueError):
        print("no local audio")
        return 1
    if local.get("generatorVersion") != committed.get("generatorVersion"):
        print("the local audio was made by generator version %s, not %s"
              % (local.get("generatorVersion"), committed.get("generatorVersion")))
        return 1
    sums = {entry.get("file"): entry.get("sha256") for entry in local.get("audio", [])}
    for entry in committed.get("audio", []):
        name = entry.get("file")
        path = os.path.join(fixtures, name)
        if name not in sums or not os.path.isfile(path):
            print("the local audio lacks %s" % name)
            return 1
        with open(path, "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() != sums[name]:
                print("the local %s does not match its manifest" % name)
                return 1
    try:
        with open(stamp_path) as f:
            stamp = f.read().strip()
    except OSError:
        print("the local audio has no stamp from the fixtures step")
        return 1
    if stamp != audio_stamp(committed):
        print("what decides the audio in Fixtures/manifest.json, a clip's text, voice or format or the speech rate, "
              "has changed since the local audio was spoken")
        return 1
    print("local audio present: %d clips, stamped" % len(committed.get("audio", [])))
    return 0


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    command, args = argv[0], argv[1:]
    if command == "package":
        package = option(args, "--package")
        branch = option(args, "--branch")
        if package:
            print(package)
            return 0
        if not branch:
            branch = subprocess.run(["git", "symbolic-ref", "--quiet", "--short", "HEAD"],
                                    capture_output=True, text=True).stdout.strip()
        found = package_of_branch(branch) if branch else None
        if not found:
            return 1
        print(found)
        return 0
    if command == "owns":
        owned, excluded, parts = owned_paths(args[0])
        for path in owned:
            print(path)
        for path in excluded:
            print("except " + path)
        for path, name in parts:
            print(f"the {name} step of {path}")
        return 0
    if command == "ownership":
        allowed = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == "--allow"]
        return cmd_ownership(option(args, "--package"), option(args, "--base", "origin/main"), allowed)
    if command == "depth":
        return cmd_depth(option(args, "--base", "origin/main"))
    if command == "core-api-rule":
        return cmd_core_api_rule(option(args, "--package"), option(args, "--merged-from", "github"))
    if command == "named-tests":
        return cmd_named_tests(option(args, "--merged-from", "github"), option(args, "--package"),
                               option(args, "--branch"))
    if command == "unended-tests":
        return cmd_unended_tests(args[0])
    if command == "workflows":
        return cmd_workflows(option(args, "--file", NIGHTLY))
    if command == "lint":
        only = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == "--files"]
        return cmd_lint(only or None, option(args, "--as"), option(args, "--manifest"))
    if command == "team-id":
        return cmd_team_id(option(args, "--team-config"))
    if command == "links":
        return cmd_links()
    if command == "unbounded-calls":
        return cmd_unbounded_calls(args)
    if command == "fixtures-audio":
        return cmd_fixtures_audio(option(args, "--fixtures"), "--write-stamp" in args)
    if command == "status":
        return cmd_status("--write" in args)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
