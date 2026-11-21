#!/bin/bash
# The second file of the wiring check's fixture: a wrapper marked here and called from
# Unbounded.sh. scripts/self-test.sh runs the check on both files at once. Never run.
lib_build() {
    # expect: nothing
    xcodebuild "$@" # limit: lib_build
}
