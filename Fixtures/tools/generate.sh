#!/bin/bash
# Generates and checks Knot's synthetic fixtures. See Fixtures/README.md.
#
#   Fixtures/tools/generate.sh                 write the committed files, then speak this Mac's audio
#   Fixtures/tools/generate.sh --audio         only speak the audio, into Fixtures/generated/ (git ignores it)
#   Fixtures/tools/generate.sh --committed     only write the committed files: ink, manifest, long.txt
#   Fixtures/tools/generate.sh --out <dir>     write under <dir> instead of Fixtures/
#   Fixtures/tools/generate.sh --check         compare the committed files with a fresh run, check the
#                                              audio's format and length, and lint the cleanup set,
#                                              the read-aloud documents and the checklists
#
# The audio is never committed: it is spoken by the macOS system voices, whose licence
# does not allow redistributing it. See Fixtures/README.md.
#
# It uses /usr/bin/python3, /usr/bin/say and /usr/bin/afconvert, which ship with macOS and
# the Command Line Tools. It needs no Xcode, no network and no microphone.

set -euo pipefail
PYTHON=/usr/bin/python3
if [ ! -x "$PYTHON" ]; then
  echo "fixtures: $PYTHON not found. Install the Command Line Tools: xcode-select --install" >&2
  exit 2
fi
exec "$PYTHON" -I "$(cd "$(dirname "$0")" && pwd)/fixtures.py" "$@"
