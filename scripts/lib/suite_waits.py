"""Prints the most SuiteWait waits that one test can run in turn, and where.

Each wait ends after SuiteWait.limit, ten minutes. A contract's run counts as all of the
waits in its file, and a wait of `limit: SuiteWait.limit * n` as n. scripts/self-test.sh
checks that KNOT_SWIFT_TEST_LIMIT outlasts that many waits.

    python3 -I scripts/lib/suite_waits.py <the package's folder>
"""

import glob
import re
import sys

WAIT = re.compile(r"SuiteWait\.(?:until|value)\((.*)")


def weight(text):
    total = 0
    for rest in WAIT.findall(text):
        times = re.search(r"limit:\s*SuiteWait\.limit\s*\*\s*(\d+)", rest)
        total += int(times.group(1)) if times else 1
    return total


def main(root):
    runs = {}
    for path in glob.glob(root + "/Sources/KnotTestSupport/Contracts/*Contract.swift"):
        with open(path) as f:
            runs[path.rsplit("/", 1)[1][: -len(".swift")]] = weight(f.read())
    longest, where = 0, "no test"
    for path in sorted(glob.glob(root + "/Tests/**/*.swift", recursive=True)):
        with open(path) as f:
            tests = re.split(r"@Test\b", f.read())[1:]
        for test in tests:
            n = weight(test) + sum(c * len(re.findall(name + r"\.run\b", test)) for name, c in runs.items())
            if n > longest:
                longest, where = n, path.split("/Tests/", 1)[1]
    print(longest, where)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
