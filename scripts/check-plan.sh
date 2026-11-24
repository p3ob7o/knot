#!/bin/bash
# Checks that the plan is one consistent text.
#
#   scripts/check-plan.sh           check, and exit non-zero on the first kind of failure found
#   scripts/check-plan.sh --write   regenerate the generated parts, then check
#
# The plan is PLAN.md and one brief for each package in docs/plan/. Three parts are
# generated from the briefs and from docs/plan/named-tests.txt, so that they cannot drift:
#   - the table of start conditions in PLAN.md §6,
#   - the index of packages in PLAN.md §7,
#   - the "Named tests" section of each brief.
#
# docs/plan/amendments.md records where each item of the five amendment lists went when
# the plan was folded. The check keeps that record complete, and it fails when a text
# that an item replaced is back in PLAN.md or in a brief.
#
# The script needs python3, which comes with Xcode.

set -euo pipefail
scripts_dir="$(cd "$(dirname "$0")" && pwd -P)"
# Every failure is reported through scripts/lib/fail.sh, after the check's own lines.
source "$scripts_dir/lib/fail.sh"
# It checks the plan of the tree that KNOT_TREE names, or else of its own checkout. It takes
# the tree as every script does, in lib/tree.sh, and refuses one that another checkout's
# scripts exported: started through that checkout's build-slot.sh, it would check that
# checkout's plan, and with --write write into it. It needs no Xcode, so no common.sh.
KNOT_SCRIPTS="$scripts_dir"
source "$scripts_dir/lib/tree.sh"
cd "$KNOT_ROOT"

PYTHON="$(command -v python3 || true)"
if [ -z "$PYTHON" ]; then
  knot_fail "infra-python-missing" "check-plan: python3 not found." \
    "It comes with Xcode: run 'xcode-select --install'." "safe" "nothing"
fi

WROTE="nothing"
case " $* " in *" --write "*) WROTE="the generated parts of PLAN.md and of the briefs, if they were out of date" ;; esac

status=0
"$PYTHON" - "$@" <<'PY' || status=$?
import os
import re
import sys

WRITE = "--write" in sys.argv[1:]
PLAN = "PLAN.md"
BRIEFS = "docs/plan"
AMENDMENTS = os.path.join(BRIEFS, "amendments.md")
NAMED_TESTS = os.path.join(BRIEFS, "named-tests.txt")

PACKAGES = (
    ["WP-%02d" % n for n in range(0, 7)]
    + ["SP-%d" % n for n in range(1, 6)]
    + ["WP-%02d" % n for n in range(10, 23)]
    + ["WP-%02d" % n for n in range(30, 36)]
    + ["WP-%02d" % n for n in range(40, 45)]
)
HEADINGS = [
    "Goal", "Owns", "Starts after", "Build", "Merge criteria",
    "Milestone evidence", "Prior art", "Failure rules", "Named tests",
]
# The five amendment lists, as they stood when the plan was approved.
LISTS = [("ceo", 51, 2), ("design", 23, 2), ("dx", 22, 2), ("eng", 109, 3), ("owner", 8, 1)]
# No part that may be cut can hold up these milestones.
MILESTONES_WITHOUT_HELD_PARTS = ["M1", "M2", "M3", "M4"]
HELD_BY = "the ruling"

errors = []


def fail(message):
    errors.append(message)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def squash(text):
    return re.sub(r"\s+", " ", text).strip()


def table_rows(lines):
    """The cells of each row of the first Markdown table in the lines, header and rule left out."""
    rows = []
    seen_rule = False
    for line in lines:
        if not line.startswith("|"):
            if rows or seen_rule:
                break
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if all(re.fullmatch(r":?-{3,}:?", cell) for cell in cells):
            seen_rule = True
            continue
        if seen_rule:
            rows.append(cells)
    return rows


# ---------------------------------------------------------------- the briefs

class Brief:
    def __init__(self, package):
        self.package = package
        self.path = os.path.join(BRIEFS, package + ".md")
        self.name = ""
        self.facts = {}
        self.sections = {}
        self.rows = []      # (label, what it holds, starts after)
        self.ok = False


def load_brief(package):
    brief = Brief(package)
    if not os.path.isfile(brief.path):
        fail("%s: the brief is missing" % brief.path)
        return brief
    lines = read(brief.path).split("\n")
    title = re.fullmatch(r"# %s · (.+)" % re.escape(package), lines[0].strip())
    if not title:
        fail("%s: the first line must be '# %s · <name>'" % (brief.path, package))
        return brief
    brief.name = title.group(1)

    found = [line[3:].strip() for line in lines if line.startswith("## ")]
    if found != HEADINGS:
        fail("%s: its '##' headings must be exactly, in order: %s. Found: %s"
             % (brief.path, ", ".join(HEADINGS), ", ".join(found) or "none"))
        return brief

    head = []
    current = None
    for line in lines[1:]:
        if line.startswith("## "):
            current = line[3:].strip()
            brief.sections[current] = []
        elif current is None:
            head.append(line)
        else:
            brief.sections[current].append(line)

    facts = table_rows(head)
    header = [cell.strip() for cell in next((l for l in head if l.startswith("|")), "").strip().strip("|").split("|")]
    if header != ["Size", "Wave", "Run by"] or len(facts) != 1 or len(facts[0]) != 3:
        fail("%s: under the title there must be one table 'Size | Wave | Run by' with one row" % brief.path)
        return brief
    brief.facts = dict(zip(header, facts[0]))

    for heading in HEADINGS:
        if not squash("\n".join(brief.sections[heading])):
            fail("%s: '## %s' is empty. A heading with nothing under it holds the line 'None.'"
                 % (brief.path, heading))

    rows = table_rows(brief.sections["Starts after"])
    if not rows:
        fail("%s: '## Starts after' needs its table, with one row for each pull request" % brief.path)
        return brief
    labels = set()
    for cells in rows:
        if len(cells) != 3:
            fail("%s: a row of the 'Starts after' table must have three cells: %s" % (brief.path, cells))
            return brief
        label = cells[0]
        if not re.fullmatch(r"\d+|Proof step|Notes|Campaign|%s[a-z]" % re.escape(package[3:]), label):
            fail("%s: '%s' is not a row label. Use a number, 'Proof step', 'Notes', 'Campaign' or a sub-package such as '40a'"
                 % (brief.path, label))
        if label in labels:
            fail("%s: the row '%s' appears twice" % (brief.path, label))
        labels.add(label)
        brief.rows.append((label, cells[1], cells[2]))
    brief.ok = True
    return brief


briefs = {package: load_brief(package) for package in PACKAGES}
for name in sorted(os.listdir(BRIEFS)) if os.path.isdir(BRIEFS) else []:
    if re.fullmatch(r"(WP-\d\d|SP-\d)\.md", name) and name[:-3] not in briefs:
        fail("%s/%s: no such package" % (BRIEFS, name))

REFERENCE = re.compile(r"\b(WP-\d\d|SP-\d)([a-z])?\b(?: (PR (\d+)|proof step|notes))?")


def numbered(brief):
    return [label for label, _, _ in brief.rows if re.fullmatch(r"\d+|\d\d[a-z]", label)]


def resolve(match, where):
    """The (package, row label) that a reference names, or None after reporting why not."""
    package, sub, qualifier, number = match.group(1), match.group(2), match.group(3), match.group(4)
    text = match.group(0)
    brief = briefs.get(package)
    if brief is None:
        fail("%s: '%s' names a package that does not exist" % (where, text))
        return None
    if not brief.ok:
        return None
    labels = [label for label, _, _ in brief.rows]
    if sub:
        label = package[3:] + sub
    elif number:
        label = number
    elif qualifier == "proof step":
        label = "Proof step"
    elif qualifier == "notes":
        label = "Notes" if "Notes" in labels else labels[0]
    else:
        choices = numbered(brief)
        if len(choices) > 1:
            last = choices[-1]
            example = "%s%s" % (package, last[2:]) if last[-1].isalpha() else "%s PR %s" % (package, last)
            fail("%s: '%s' ships in several pull requests (%s). Name the one that is meant, as in '%s'"
                 % (where, package, ", ".join(choices), example))
            return None
        label = choices[0] if choices else labels[-1]
    if label not in labels:
        fail("%s: '%s' names a row that %s does not have" % (where, text, brief.path))
        return None
    return (package, label)


graph = {}
conditions = {}
for package in PACKAGES:
    brief = briefs[package]
    for label, _, starts_after in brief.rows:
        node = (package, label)
        where = "%s, row %s" % (brief.path, label)
        conditions[node] = starts_after
        graph[node] = []
        if re.search(r"\b[Ii]ts (PR|proof|first|second|third|fourth)\b", starts_after):
            fail("%s: write the package in full, as in '%s PR 1', not 'its PR 1'" % (where, package))
        for match in REFERENCE.finditer(starts_after):
            target = resolve(match, where)
            if target is not None:
                graph[node].append(target)

# Milestones are nodes too: a milestone needs pull requests, and a pull request may wait for a milestone.
MILESTONE = re.compile(r"\bM([0-7])\b")
milestone_targets = {}
plan = read(PLAN) if os.path.isfile(PLAN) else ""
needs = re.search(r"<!-- milestone-needs:begin -->(.*?)<!-- milestone-needs:end -->", plan, re.S)
for cells in table_rows(needs.group(1).split("\n")) if needs else []:
    milestone = cells[0]
    if not MILESTONE.fullmatch(milestone) or len(cells) < 3:
        fail("%s: a row of the table of milestone builds must read 'M<n> | owning package | also needs'" % PLAN)
        continue
    where = "%s, milestone builds, row %s" % (PLAN, milestone)
    targets = []
    # The owning package may be named whole: its thread makes the build, and the build needs all of it.
    for match in REFERENCE.finditer(cells[1]):
        package = match.group(1)
        whole = not (match.group(2) or match.group(3))
        if whole and package in briefs and briefs[package].ok:
            targets += [(package, label) for label in numbered(briefs[package])]
        else:
            targets.append(resolve(match, where))
    for match in REFERENCE.finditer(cells[2]):
        targets.append(resolve(match, where))
    for match in MILESTONE.finditer(cells[2]):
        targets.append(("M" + match.group(1), ""))
    milestone_targets[milestone] = [target for target in targets if target is not None]
    graph[(milestone, "")] = milestone_targets[milestone]
    conditions[(milestone, "")] = ""
for node in [node for node in graph if node[1]]:
    for match in MILESTONE.finditer(conditions[node]):
        graph[node].append(("M" + match.group(1), ""))

# No cycle.
state = {}


def visit(node, trail):
    state[node] = "open"
    for target in graph.get(node, []):
        if state.get(target) == "open":
            loop = trail[trail.index(target):] + [target] if target in trail else [node, target]
            fail("the start conditions form a cycle: " + " -> ".join(("%s %s" % pair).strip() for pair in loop))
        elif target not in state:
            visit(target, trail + [target])
    state[node] = "done"


for node in graph:
    if node not in state:
        visit(node, [node])

# Held parts: whatever waits for the ruling, directly or through what it waits for.
held = {}


def is_held(node, seen=()):
    if node in held:
        return held[node]
    if node in seen:
        return False
    result = HELD_BY in conditions.get(node, "").lower() or any(
        is_held(target, seen + (node,)) for target in graph.get(node, []))
    held[node] = result
    return result


for node in graph:
    is_held(node)

# ---------------------------------------------------------------- the generated parts


def start_table():
    lines = ["| Package | PR | What it holds | Starts after |", "|---|---|---|---|"]
    for package in PACKAGES:
        brief = briefs[package]
        for label, holds, starts_after in brief.rows:
            lines.append("| %s | %s | %s | %s |" % (package, label, holds, starts_after))
    return "\n".join(lines)


def package_index():
    lines = ["| Package | Name | Size | Wave | Run by | Brief |", "|---|---|---|---|---|---|"]
    for package in PACKAGES:
        brief = briefs[package]
        lines.append("| %s | %s | %s | %s | %s | [%s](%s) |" % (
            package, brief.name, brief.facts.get("Size", ""), brief.facts.get("Wave", ""),
            brief.facts.get("Run by", ""), brief.path, brief.path))
    return "\n".join(lines)


def block(text, name, path):
    begin, end = "<!-- %s:begin -->" % name, "<!-- %s:end -->" % name
    if text.count(begin) != 1 or text.count(end) != 1 or text.index(begin) > text.index(end):
        fail("%s: the lines '%s' and '%s' must each appear once, in that order" % (path, begin, end))
        return None
    start = text.index(begin) + len(begin)
    return start, text.index(end)


def generated(text, name, content, path):
    span = block(text, name, path)
    if span is None:
        return text
    wanted = "\n\n" + content + "\n\n"
    if text[span[0]:span[1]] != wanted:
        if WRITE:
            return text[:span[0]] + wanted + text[span[1]:]
        fail("%s: the part between the '%s' lines is out of date. Run 'scripts/check-plan.sh --write'"
             % (path, name))
    return text


tests = {package: [] for package in PACKAGES}
if not os.path.isfile(NAMED_TESTS):
    fail("%s is missing" % NAMED_TESTS)
else:
    slugs = set()
    for number, line in enumerate(read(NAMED_TESTS).split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not all(field.strip() for field in fields):
            fail("%s:%d: a line holds three fields separated by tabs: owner, slug, test" % (NAMED_TESTS, number))
            continue
        owner, slug, sentence = (field.strip() for field in fields)
        # The owner is a package, or one of its pull requests, as in "WP-11 PR 1": the gate
        # then requires the test once that pull request has merged.
        given = re.fullmatch(r"((?:WP|SP)-\d+)\s+PR\s+(\w+)", owner)
        if given:
            owner, pr = given.group(1), given.group(2)
            if owner in briefs and briefs[owner].ok and pr not in [label for label, _, _ in briefs[owner].rows]:
                fail("%s:%d: %s has no pull request %s in its 'Starts after' table" % (NAMED_TESTS, number, owner, pr))
                continue
        if owner not in tests:
            fail("%s:%d: '%s' is not a package" % (NAMED_TESTS, number, owner))
            continue
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug):
            fail("%s:%d: the slug '%s' must be lower-case words joined by hyphens" % (NAMED_TESTS, number, slug))
        if slug in slugs:
            fail("%s:%d: the slug '%s' appears twice" % (NAMED_TESTS, number, slug))
        slugs.add(slug)
        tests[owner].append((slug, sentence))


def named_tests_section(package):
    if not tests[package]:
        return "\nNone.\n"
    return "\n" + "\n".join("- `%s`: %s" % pair for pair in tests[package]) + "\n"


for package in PACKAGES:
    brief = briefs[package]
    if not brief.ok:
        continue
    text = read(brief.path)
    marker = "\n## Named tests\n"
    head = text[:text.index(marker) + len(marker)]
    wanted = head + named_tests_section(package)
    if text != wanted:
        if WRITE:
            with open(brief.path, "w", encoding="utf-8") as handle:
                handle.write(wanted)
        else:
            fail("%s: '## Named tests' does not match %s. Run 'scripts/check-plan.sh --write'"
                 % (brief.path, NAMED_TESTS))

# ---------------------------------------------------------------- PLAN.md

if not plan:
    fail("%s is missing" % PLAN)
else:
    for leftover in ("autoplan-accepted", "owner-answers:", "## Review record", "## Decision Audit Trail"):
        if leftover in plan:
            fail("%s still holds '%s'. The plan is one text: amendment lists and the review record are not part of it"
                 % (PLAN, leftover))
    new_plan = generated(plan, "start-table", start_table(), PLAN)
    new_plan = generated(new_plan, "package-index", package_index(), PLAN)
    if WRITE and new_plan != plan:
        with open(PLAN, "w", encoding="utf-8") as handle:
            handle.write(new_plan)
        plan = new_plan

    if block(plan, "milestone-needs", PLAN) is not None and not milestone_targets:
        fail("%s: the table of milestone builds is missing between the 'milestone-needs' lines" % PLAN)
    for milestone in MILESTONES_WITHOUT_HELD_PARTS:
        for target in milestone_targets.get(milestone, []):
            if held.get(target):
                fail("%s, milestone builds, row %s: %s needs %s, which waits for the ruling. "
                     "No part that may be cut holds up %s"
                     % (PLAN, milestone, milestone, ("%s %s" % target).strip(),
                        ", ".join(MILESTONES_WITHOUT_HELD_PARTS)))

# ---------------------------------------------------------------- the amendments

ITEM = re.compile(r"\b(?:ceo|design|dx|eng)-\d{2,3}\b|\bowner-\d\b")
expected = ["%s-%0*d" % (name, width, position)
            for name, count, width in LISTS for position in range(1, count + 1)]
replaced = []
if not os.path.isfile(AMENDMENTS):
    fail("%s is missing" % AMENDMENTS)
else:
    found = []
    for line in read(AMENDMENTS).split("\n"):
        if not line.startswith("| "):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if not ITEM.fullmatch(cells[0]):
            continue
        if len(cells) != 4:
            fail("%s: the row of %s must have four cells: item, what it asks, where it went, what it replaced"
                 % (AMENDMENTS, cells[0]))
            continue
        found.append(cells[0])
        if not cells[2] or cells[2] == "–":
            fail("%s: %s does not say where it went, or why it was dropped" % (AMENDMENTS, cells[0]))
        for quote in re.findall(r"“([^”]+)”", cells[3]):
            replaced.append((cells[0], quote))
    if found != expected:
        missing = [item for item in expected if item not in found]
        extra = [item for item in found if item not in expected]
        twice = sorted({item for item in found if found.count(item) > 1})
        if missing:
            fail("%s: no row for %s" % (AMENDMENTS, ", ".join(missing)))
        if extra:
            fail("%s: no such item: %s" % (AMENDMENTS, ", ".join(extra)))
        if twice:
            fail("%s: more than one row for %s" % (AMENDMENTS, ", ".join(twice)))
        if not (missing or extra or twice):
            fail("%s: the rows are out of order. They follow the lists, and each list its positions" % AMENDMENTS)

documents = [(PLAN, plan)] + [(briefs[p].path, read(briefs[p].path)) for p in PACKAGES if os.path.isfile(briefs[p].path)]
for path, text in documents:
    flat = squash(text)
    for item, quote in replaced:
        if squash(quote) in flat:
            fail("%s still holds text that %s replaced: “%s”" % (path, item, quote))
    cited = sorted(set(ITEM.findall(text)))
    if cited:
        fail("%s cites amendment items (%s). The plan states the rule; %s keeps the history"
             % (path, ", ".join(cited), AMENDMENTS))

# ---------------------------------------------------------------- result

if errors:
    for message in errors:
        print("check-plan: " + message, file=sys.stderr)
    print("check-plan: %d problem%s" % (len(errors), "" if len(errors) == 1 else "s"), file=sys.stderr)
    sys.exit(1)

rows = sum(len(briefs[p].rows) for p in PACKAGES)
count = sum(len(tests[p]) for p in PACKAGES)
print("check-plan: ok. %d briefs, %d start rows, %d named tests, %d amendment items, %d replaced texts"
      % (len(PACKAGES), rows, count, len(expected), len(replaced)))
PY

if [ "$status" -eq 1 ]; then
  knot_fail "plan-check" "The plan check found the problems listed above." \
    "Fix each one. For a generated part that is out of date, run scripts/check-plan.sh --write." "safe" "$WROTE"
elif [ "$status" -ne 0 ]; then
  knot_fail "infra-plan-check-crashed" "The plan check stopped with status $status before it finished." \
    "Read the Python error above." "safe" "$WROTE"
fi
