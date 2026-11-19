"""The checks behind scripts/verify.sh that read the plan, the diff and the sources.

Run it from the repository root, through the scripts. It needs Python 3.9 or later and
nothing outside the standard library, so the /usr/bin/python3 that ships with macOS will do.

    python3 scripts/lib/knot_tool.py package [--package <ID>] [--branch <name>]
    python3 scripts/lib/knot_tool.py owns <ID>
    python3 scripts/lib/knot_tool.py ownership --package <ID> --base <ref>
    python3 scripts/lib/knot_tool.py depth --base <ref>
    python3 scripts/lib/knot_tool.py named-tests [--merged-from github|git]
    python3 scripts/lib/knot_tool.py lint [--team-config <path>]
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
OWNERSHIP_EXTRA = "scripts/ownership-extra.txt"
CONCURRENCY_ESCAPES = "scripts/concurrency-escapes.txt"


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


def pr_count(package):
    """How many pull requests a brief plans: the rows of its 'Starts after' table."""
    rows = [line for line in section(package, "Starts after") if re.match(r"^\|\s*\d+\s*\|", line)]
    return max(1, len(rows))


PATH_TOKEN = re.compile(r"`([^`\s]+)`")


def owned_paths(package):
    """The paths a brief's 'Owns' section names, and the ones its 'except' clauses take out.

    A path named after "of", as in "the soak step of `scripts/verify.sh`", is a part of that
    file that another package owns, so the file stays owned.
    """
    owned, excluded = [], []
    for line in section(package, "Owns"):
        if not line.startswith("- "):
            continue
        index = line.find(" except ")
        head, tail = (line[:index], line[index:]) if index >= 0 else (line, "")
        owned += [token for token in PATH_TOKEN.findall(head) if "/" in token or "." in token]
        for match in PATH_TOKEN.finditer(tail):
            before = tail[:match.start()].rstrip()
            if before.endswith(" of") or before.endswith(" in"):
                continue
            excluded.append(match.group(1))
    if os.path.exists(OWNERSHIP_EXTRA):
        with open(OWNERSHIP_EXTRA) as f:
            for line in f:
                fields = line.rstrip("\n").split("\t")
                if line.startswith("#") or len(fields) < 2:
                    continue
                if fields[0] == package:
                    owned.append(fields[1])
    return owned, excluded


def matches(path, pattern):
    if pattern.endswith("/"):
        return path.startswith(pattern)
    if any(c in pattern for c in "*?["):
        return fnmatch.fnmatch(path, pattern)
    return path == pattern


def package_of_branch(branch):
    """The package a branch belongs to: wp/01-tooling is WP-01; a spike branch is the spike
    whose brief owns it; a contract branch is 'contract'."""
    branch = re.sub(r"^(refs/heads/|origin/)", "", branch)
    match = re.match(r"^wp/(\d+)-", branch)
    if match:
        return "WP-%02d" % int(match.group(1))
    if branch.startswith("contract/"):
        return "contract"
    if branch.startswith("spike/"):
        for package in packages():
            if any(token == branch for token in PATH_TOKEN.findall("\n".join(section(package, "Owns")))):
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


def cmd_ownership(package, base):
    files = changed_files(base)
    if package == "contract":
        bad = [path for path in files if not contract_owned(path)]
        owned_by = "a contract branch"
    else:
        if not os.path.exists(brief_path(package)):
            print(f"ownership: no brief for {package} in {BRIEFS}")
            return 1
        owned, excluded = owned_paths(package)
        bad = [path for path in files
               if not any(matches(path, p) for p in owned) or any(matches(path, p) for p in excluded)]
        owned_by = package
    for path in bad:
        print(f"ownership: {path} is not a path that {owned_by} owns")
    print(f"ownership: {len(files)} changed paths, {len(bad)} outside what {owned_by} owns")
    return 1 if bad else 0


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
# Mac UI tests run where the diff reaches the Mac app or KnotUI.
MAC_UI = [
    "Apps/macOS/", "Apps/Shared/", "Apps/Config/", "project.yml", "Packages/KnotKit/Package.swift",
    "Packages/KnotKit/Sources/KnotUI/", "Packages/KnotKit/Sources/KnotApp/",
]


def is_document(path):
    return path.endswith(".md") or path.startswith("docs/") or path in ("LICENSE", "TODOS.md")


def classify(files):
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
    if "Packages/KnotKit/Package.swift" in files and "grdb" in git("diff", "--unified=0", "--", "Packages/KnotKit/Package.swift").lower():
        soak = True
    mac_ui = any(any(path.startswith(p) or path == p for p in MAC_UI) for path in files)
    return depth, reasons, soak, mac_ui


def cmd_depth(base):
    files = changed_files(base)
    depth, reasons, soak, mac_ui = classify(files)
    print(f"depth={depth}")
    print(f"soak={'1' if soak else '0'}")
    print(f"mac_ui={'1' if mac_ui else '0'}")
    print(f"changed={len(files)}")
    print("reason=" + ", ".join(reasons))
    return 0


# ---------------------------------------------------------------- named tests


def merged_counts(source):
    """How many pull requests of each package have merged into main."""
    counts = {}
    if source == "github":
        try:
            out = subprocess.run(["gh", "pr", "list", "--state", "merged", "--base", "main", "--limit", "500",
                                  "--json", "headRefName"], check=True, capture_output=True, text=True).stdout
            for pr in json.loads(out):
                package = package_of_branch(pr["headRefName"])
                if package and package != "contract":
                    counts[package] = counts.get(package, 0) + 1
            return counts
        except (OSError, subprocess.CalledProcessError, ValueError):
            pass
    # Without GitHub: the squash subjects on origin/main, which start with the package ID.
    for subject in lines(git("log", "origin/main", "--format=%s")):
        match = re.match(r"^((?:WP|SP)-\d+)\b", subject)
        if match:
            counts[match.group(1)] = counts.get(match.group(1), 0) + 1
    return counts


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


def cmd_named_tests(source):
    counts = merged_counts(source)
    code = code_text()
    missing, required = [], 0
    with open(NAMED_TESTS) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            owner, slug, _ = line.rstrip("\n").split("\t", 2)
            if counts.get(owner, 0) < pr_count(owner):
                continue
            required += 1
            if not any(slug in text for text in code.values()):
                missing.append((owner, slug))
    for owner, slug in missing:
        print(f"named-tests: {slug}, which {owner} owns, is in no test, script or workflow, and {owner} has merged")
    print(f"named-tests: {required} required because their package has merged, {len(missing)} missing")
    return 1 if missing else 0


# ---------------------------------------------------------------- lint


SWIFT_SOURCES = ("Packages/KnotKit/Sources/", "Apps/")
LIBRARY_EXEMPT = ("Packages/KnotKit/Sources/knot/", "Packages/KnotKit/Sources/knot-eval/",
                  "Packages/KnotKit/Sources/KnotStoreCrashHost/", "Packages/KnotKit/Sources/KnotAudioCrashHost/",
                  "Packages/KnotKit/Sources/KnotLinkCrashHost/", "Packages/KnotKit/Sources/KnotInkCrashHost/",
                  "Packages/KnotKit/Sources/KnotSoakChild/")

REQUIRED_REASON = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|@AppStorage\b|\bNSUserDefaults\b",
    "NSPrivacyAccessedAPICategoryFileTimestamp":
        r"\bcreationDate\b|\bmodificationDate\b|contentModificationDate|attributesOfItem|\bfileModificationDate\b"
        r"|\bgetattrlist\(|(?<![\w.])l?stat\(",
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|\bmach_absolute_time\(",
    "NSPrivacyAccessedAPICategoryDiskSpace":
        r"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize|\bsystemSize\b|\bstatv?fs\(",
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
    """The lines of a Swift file, with comments blanked, as (number, line)."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        yield number, re.sub(r"\s//.*$", "", line)


def swift_files():
    found = []
    for path in lines(git("ls-files")) + lines(git("ls-files", "--others", "--exclude-standard")):
        if path.endswith(".swift") and path.startswith(SWIFT_SOURCES) and os.path.isfile(path):
            found.append(path)
    return sorted(set(found))


def module_of(path):
    match = re.match(r"^Packages/KnotKit/Sources/([^/]+)/", path)
    return match.group(1) if match else None


def cmd_lint(team_config):
    problems = []

    def problem(path, number, rule, message):
        problems.append(f"lint: {path}:{number}: [{rule}] {message}")

    files = swift_files()
    escapes = {}
    used = {}
    for path in files:
        library = path.startswith("Packages/KnotKit/Sources/") and not path.startswith(LIBRARY_EXEMPT)
        for number, line in code_lines(path):
            allowed = re.findall(r"knot-lint: allow ([\w-]+)", line)
            if re.search(r"UserDefaults\s*\.\s*standard|UserDefaults\(\)", line):
                problem(path, number, "standard-defaults", "v1 keeps its settings in a named defaults suite")
            if "@AppStorage(" in line and "store:" not in line:
                problem(path, number, "app-storage", "@AppStorage needs a named store")
            for name in re.findall(r"(?:[Aa]utosaveName|FrameAutosaveName)\s*[:=(]\s*\"([^\"]*)\"", line):
                if not name.startswith("v1."):
                    problem(path, number, "autosave-name", f'the autosave name "{name}" needs the v1. prefix')
            if "eraseDatabaseOnSchemaChange" in line:
                problem(path, number, "erase-database", "eraseDatabaseOnSchemaChange erases the store")
            if re.search(r"\bURLSession\b|\bNWConnection\b|\bURLRequest\b|\bCFStream|https?://", line) \
                    and "network" not in allowed:
                problem(path, number, "network", "Knot contacts no host but CloudKit and Apple's model downloads")
            if re.search(r"\b(?:logger|log|Logger\([^)]*\))\s*\.\s*(?:debug|info|notice|error|fault|warning|trace|critical|log)\(", line) \
                    and "\\(" in line and "privacy:" not in line and "logged-text" not in allowed:
                problem(path, number, "logged-text", "every interpolated value in a log line states its privacy")
            if library and re.search(r"(?<![\w.])(?:print|NSLog|debugPrint)\(", line) and "logged-text" not in allowed:
                problem(path, number, "logged-text", "a library logs through Logger, never print or NSLog")
            for escape in ("@unchecked Sendable", "nonisolated(unsafe)", "@preconcurrency"):
                escapes[(path, escape)] = escapes.get((path, escape), 0) + line.count(escape)
            for category, pattern in REQUIRED_REASON.items():
                if re.search(pattern, line):
                    used.setdefault(category, []).append((path, number))

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
    for manifest, reach in MANIFESTS.items():
        with open(manifest, "rb") as f:
            declared = {entry["NSPrivacyAccessedAPIType"] for entry in plistlib.load(f).get("NSPrivacyAccessedAPITypes", [])
                        if entry.get("NSPrivacyAccessedAPITypeReasons")}
        for category, places in used.items():
            for path, number in places:
                module = module_of(path)
                in_reach = any(path.startswith(r) for r in reach if r.endswith("/")) or \
                    (module is not None and not path.startswith(LIBRARY_EXEMPT) and ("*" in reach or module in reach))
                if in_reach and category not in declared:
                    problem(path, number, "required-reason", f"{category} has no reason in {manifest}")

    # A file whose name ends in " 2", the mark of a cloud provider's copy.
    for path in lines(git("ls-files")) + lines(git("ls-files", "--others", "--exclude-standard")):
        if re.search(r" 2(\.[^/.]+)?$", os.path.basename(path)):
            problem(path, "-", "copy-file", 'a file whose name ends in " 2"')

    # The signing team's ID, from the local configuration, in no tracked file.
    team = None
    if team_config and os.path.exists(team_config):
        with open(team_config) as f:
            match = re.search(r"^\s*DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10})\s*$", f.read(), re.M)
            team = match.group(1) if match else None
    if team:
        found = subprocess.run(["git", "grep", "-l", "-F", team], capture_output=True, text=True).stdout
        for path in lines(found):
            problem(path, "-", "team-id", "holds the signing team's ID from the local configuration")
        print("lint: looked for the team ID of the local configuration in every tracked file")
    else:
        print("lint: no local configuration with a team ID, so there was no team ID to look for")

    for line in problems:
        print(line)
    print(f"lint: {len(files)} Swift files, {len(problems)} problems")
    return 1 if problems else 0


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
        merged = sum(1 for pr in mine if pr["state"] == "MERGED")
        total = pr_count(package)
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
        owned, excluded = owned_paths(args[0])
        for path in owned:
            print(path)
        for path in excluded:
            print("except " + path)
        return 0
    if command == "ownership":
        return cmd_ownership(option(args, "--package"), option(args, "--base", "origin/main"))
    if command == "depth":
        return cmd_depth(option(args, "--base", "origin/main"))
    if command == "named-tests":
        return cmd_named_tests(option(args, "--merged-from", "github"))
    if command == "lint":
        return cmd_lint(option(args, "--team-config"))
    if command == "links":
        return cmd_links()
    if command == "status":
        return cmd_status("--write" in args)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
