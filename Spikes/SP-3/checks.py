#!/usr/bin/env python3 -I
"""SP-3's checks, run by `Spikes/SP-3/run.sh checks <phase>`. Never merged.

Every run has a time limit, so a run that waits on a consent dialog ends and is reported as
what it is. After each run the script looks in the system log for a consent prompt that the
run raised, and stops at once if it finds one. After the first start of each packaging it
checks that the gate's locally signed knot-dev still starts. Everything it prints goes
through mask(), which writes the team ID as <team>, the home folder as ~ and a certificate's
holder as <holder>.

Phases:
  tool    only the tool, com.p3ob7o.knot.dev.cli, whose container the team may use
  app     the app, com.p3ob7o.knot.dev: its first team-signed start raises a dialog
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

APP, TEAM, LOCAL_TOOL, PHASE, OUT = sys.argv[1:6]
HOME = os.path.expanduser("~")
BARE = f"{APP}/Contents/MacOS/knot-dev"
HELPER = f"{APP}/Contents/Helpers/knot-dev.app/Contents/MacOS/knot-dev"
NOPLIST = f"{APP}/Contents/Helpers/variants/knot-dev-noplist"
INHERIT = f"{APP}/Contents/Helpers/variants/knot-dev-inherit"
APP_EXE = f"{APP}/Contents/MacOS/Knot Dev"
results = []


def mask(text):
    if TEAM:
        text = text.replace(TEAM, "<team>")
    text = text.replace(HOME, "~")
    text = re.sub(r"/Users/[^/ \"]+", "~", text)
    return re.sub(r"(Apple Development|Apple Distribution): [^(]*\([^)]*\)", r"\1: <holder>", text)


def now():
    return datetime.now(timezone.utc)


def prompts_since(start):
    """Consent prompts and refusals the system logged since `start` for the spike's IDs."""
    since = start.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    predicate = (
        '(process == "secinitd" AND eventMessage CONTAINS "prompting") OR '
        '(process == "containermanagerd" AND eventMessage CONTAINS "REJECTED") OR '
        '(process == "tccd" AND eventMessage CONTAINS "knot.dev")'
    )
    out = subprocess.run(
        ["/usr/bin/log", "show", "--start", since, "--style", "compact", "--predicate", predicate],
        capture_output=True, text=True, timeout=60).stdout
    lines = [l for l in out.splitlines()[1:] if "knot" in l]
    prompting = [l for l in lines if "prompting" in l or "tccd" in l]
    rejected = [l for l in lines if "REJECTED" in l]
    return prompting, rejected


def run(name, argv, limit=15, stdin=None, shell=False, env=None):
    start = now()
    t0 = time.monotonic()
    try:
        proc = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=limit,
                              shell=shell, env=env)
        status, out, err = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        status = "timeout"
        out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = (e.stderr or b"").decode() if isinstance(e.stderr, bytes) else (e.stderr or "")
    seconds = round(time.monotonic() - t0, 2)
    prompting, rejected = prompts_since(start)
    record = {
        "check": name, "at": start.strftime("%H:%M:%SZ"), "status": status, "seconds": seconds,
        "stdout": mask(out.strip())[:8000], "stderr": mask(err.strip())[:400],
        "groupRejected": [mask(l)[24:260] for l in rejected][:2],
        "prompted": [mask(l)[24:300] for l in prompting][:2],
    }
    results.append(record)
    print(json.dumps(record, sort_keys=True), flush=True)
    if prompting:
        stop(f"a consent prompt appeared at {start.strftime('%H:%M:%SZ')} during '{name}'")
    return record


def local_tool_starts(after):
    r = run(f"the gate's local knot-dev --version, after {after}", [LOCAL_TOOL, "--version"], limit=10)
    if r["status"] != 0:
        stop(f"the gate's local knot-dev no longer starts, after {after}")


def stop(reason):
    print(json.dumps({"stopped": reason}), flush=True)
    save()
    sys.exit(3)


def save():
    with open(OUT, "w") as f:
        json.dump(results, f, indent=1, sort_keys=True)


def mcp_session(tool, extra):
    """A stand-in MCP client: starts the tool over standard input and output, sends a probe,
    has a second process write while the session is open, probes again, then closes its
    input and waits for the tool to end."""
    start = now()
    proc = subprocess.Popen([tool, "mcp", *extra], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, bufsize=1)
    record = {"check": f"mcp stand-in from a shell: {os.path.basename(tool)} {' '.join(extra)}",
              "at": start.strftime("%H:%M:%SZ")}
    try:
        proc.stdin.write('{"id":1,"method":"probe"}\n')
        proc.stdin.flush()
        first = json.loads(proc.stdout.readline())
        other = subprocess.run([BARE, "add", "synthetic", *extra], capture_output=True, text=True,
                               timeout=15)
        proc.stdin.write('{"id":2,"method":"probe"}\n')
        proc.stdin.flush()
        second = json.loads(proc.stdout.readline())
        proc.stdin.write('{"id":3,"method":"add"}\n')
        proc.stdin.flush()
        third = json.loads(proc.stdout.readline())
        proc.stdin.close()
        status = proc.wait(timeout=5)
        b = lambda r: r.get("result", {}).get("before", {}).get("counter")
        record.update({
            "status": status,
            "counterBefore": b(first),
            "secondProcessWrote": json.loads(other.stdout or "{}").get("after", {}).get("counter"),
            "counterSeenInOpenSession": b(second),
            "sessionWrote": third.get("result", {}).get("after", {}).get("counter"),
            "exitAtEndOfInput": status == 0,
        })
    except Exception as e:  # noqa: BLE001 - the spike reports whatever went wrong
        proc.kill()
        record.update({"status": "failed", "error": mask(repr(e))[:300],
                       "stderr": mask(proc.stderr.read() if proc.stderr else "")[:300]})
    results.append(record)
    print(json.dumps(record, sort_keys=True), flush=True)
    prompting, _ = prompts_since(start)
    if prompting:
        stop(f"a consent prompt appeared at {start.strftime('%H:%M:%SZ')} during the MCP stand-in")


def tool_phase():
    work = tempfile.mkdtemp(prefix="sp3-")
    named = os.path.join(work, "a folder the user names")
    os.mkdir(named)
    home_named = tempfile.mkdtemp(prefix="sp3-export-", dir=os.path.dirname(os.path.dirname(APP)))
    team = ["--team-group"]

    # The bare executable, team-signed, no profile.
    run("bare: --version", [BARE, "--version"], limit=10)
    local_tool_starts("the bare tool's first team-signed start")
    run("bare: probe, group. form", [BARE, "probe"])
    run("bare: probe, Team-ID form", [BARE, "probe", *team])
    run("bare: add, Team-ID form", [BARE, "add", "synthetic", *team])

    # knot export: a folder named on the command line, outside the container.
    run("bare: export into a folder under /private/tmp", [BARE, "export", named, *team])
    run("bare: export into a folder under the home folder", [BARE, "export", home_named, *team])
    target = os.path.join(named, "from-stdout.md")
    r = run("bare: export - , the shell writes the file", f'"{BARE}" export - --team-group > "{target}"',
            shell=True)
    r["fileWrittenByShell"] = os.path.exists(target) and os.path.getsize(target) > 0
    print(json.dumps({"check": r["check"], "fileWrittenByShell": r["fileWrittenByShell"]}), flush=True)
    run("bare: export-group, Team-ID form", [BARE, "export-group", *team])

    # The PATH: a folder of the user's own on PATH, holding a symbolic link to the tool, and
    # a copy of the binary outside the bundle.
    bindir = os.path.join(work, "bin")
    os.mkdir(bindir)
    os.symlink(BARE, os.path.join(bindir, "knot-dev"))
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": HOME, "KNOT_AGENT": "1"}
    run("PATH: knot-dev through a symbolic link on PATH", "knot-dev probe --team-group", shell=True, env=env)
    subprocess.run(["/bin/cp", BARE, os.path.join(bindir, "knot-dev-copy")], check=True)
    run("PATH: a copy of the bare binary outside the bundle", "knot-dev-copy probe --team-group", shell=True,
        env=env)

    # The stand-in MCP client, from a shell, with a second writer while the session is open.
    mcp_session(BARE, team)

    # The helper bundle, started from Terminal, no profile on this round.
    run("helper: --version", [HELPER, "--version"], limit=10)
    local_tool_starts("the helper bundle's first team-signed start")
    run("helper: probe, group. form", [HELPER, "probe"])
    run("helper: probe, Team-ID form", [HELPER, "probe", *team])
    os.symlink(HELPER, os.path.join(bindir, "knot-dev-helper"))
    run("PATH: the helper's executable through a symbolic link", "knot-dev-helper probe --team-group",
        shell=True, env=env)

    # Rule 1's counter-examples, started from Terminal.
    run("noplist: --version", [NOPLIST, "--version"], limit=10)
    local_tool_starts("the no-Info.plist tool's first team-signed start")
    run("noplist: probe, Team-ID form", [NOPLIST, "probe", *team])
    run("inherit: --version, from a shell", [INHERIT, "--version"], limit=10)
    local_tool_starts("the inherit-only tool's first start")

    # Cleanup of what the spike wrote, by name, in both forms of the group.
    run("cleanup, Team-ID form", [BARE, "cleanup", *team])
    run("cleanup, group. form", [BARE, "cleanup"])
    for path in [os.path.join(named, "knot-sp3-export.md"), target,
                 os.path.join(home_named, "knot-sp3-export.md")]:
        if os.path.exists(path):
            os.remove(path)
    for link in ["knot-dev", "knot-dev-copy", "knot-dev-helper"]:
        os.remove(os.path.join(bindir, link))
    for d in [bindir, named, work, home_named]:
        os.rmdir(d)
    local_tool_starts("the last run")


def app_phase():
    # Left for the sitting with the owner at the Mac (each first start raises a dialog).
    run("app: --self-test --spawn, Team-ID form, the tool writing while it runs",
        f'("{APP_EXE}" --self-test --seconds 8 --spawn --team-group &) ; sleep 2 ; '
        f'"{BARE}" add synthetic --team-group ; sleep 7', shell=True, limit=20)
    local_tool_starts("the app's first team-signed start")


if __name__ == "__main__":
    {"tool": tool_phase, "app": app_phase}[PHASE]()
    save()
    print(json.dumps({"done": PHASE, "checks": len(results)}), flush=True)
