#!/bin/bash
# The fixture of knot_tool.py unbounded-calls. scripts/self-test.sh runs the check on this file:
# every "expect: unbounded" line must be answered by a finding on the line below it, and
# every "expect: nothing" line by none. This file is never run. The cases are the review's of
# pull request 46 at a5c11159, wiring/evasions.sh and wiring/markers.sh, and the forms that
# the scripts use.
step_one() {
    # expect: nothing
    cmd=(xcrun simctl boot X)
    # expect: unbounded
    "${cmd[@]}"
    # expect: unbounded
    tool=xcodebuild; $tool build
    # expect: unbounded
    command xcodebuild build
    # expect: unbounded
    env FOO=1 xcodebuild build
    # expect: unbounded
    exec swift test
    # expect: unbounded
    xcodebuild \
        build
    # expect: unbounded
    swift \
        test
    # expect: unbounded
    swift  test
    # expect: unbounded
    swift test --filter x
    # expect: unbounded
    "xcodebuild" build
    # expect: unbounded
    x=$(xcrun simctl list)
    # expect: unbounded
    echo hi && xcodebuild build
    # expect: unbounded
    knot_fail_unrelated=1; xcodebuild build
    # expect: unbounded
    : knot_limit; xcodebuild build
    # expect: unbounded
    swift build --build-tests; swift test
    # expect: unbounded
    xcrun --sdk iphoneos simctl list
    # expect: unbounded
    /usr/bin/xcrun simctl list
    # expect: unbounded
    eval "xcodebuild build"
    # expect: unbounded
    bash -c 'xcodebuild build'
    # expect: unbounded
    sudo xcodebuild build
    # expect: unbounded
    xcb "$log" -scheme X build
    # expect: unbounded
    printf '%s\n' "$(swift test)"
    # expect: unbounded
    knot_fail "code" "$(xcodebuild -version)" "fix" "safe" "nothing"
    # expect: unbounded
    printf x | xcrun simctl list
    # expect: unbounded
    xcodebuild -scheme knot_limit_tests build
    # expect: unbounded
    swift test --filter knot_run_limited
}
mywrap() {
    # expect: nothing
    xcodebuild "$@" # limit: mywrap
}
step_two() {
    # expect: unbounded
    mywrap build
    # expect: unbounded
    foo=mywrap; $foo build
    # expect: unbounded
    knot_limit 10 true; mywrap build
    # expect: unbounded
    knot_limit 10 xcodebuild -version; swift test
    # expect: unbounded
    xcodebuild build # limit: knot_limit
    # expect: unbounded
    swift test # limit: nobody_calls_this
    # expect: nothing
    knot_run_limited "the build" 60 mywrap build
}
step_three() {
    # expect: nothing
    echo "xcodebuild exited with 65; swift test failed; xcrun simctl stuck"
    # expect: nothing
    knot_fail "code" "xcrun simctl did not answer" "Rerun xcodebuild." "safe" "nothing"
    # expect: nothing
    knot_limit 10 xcodebuild -version
    # expect: nothing
    knot_sim_call 30 "list" "x" xcrun simctl list
    # expect: nothing
    knot_swift_test_limited package-test swift test --filter x
    # expect: nothing
    knot_run_limited "the build" 60 xcb "$log" -scheme X build
    # expect: nothing
    swift build --build-tests
    # expect: nothing
    version="$(knot_limit 10 xcodebuild -version | head -n 1)"
}
step_four() {
    bash <<'SH'
# expect: unbounded
xcodebuild -version
SH
    # expect: unbounded
    arch -arm64 xcodebuild -version
    # expect: unbounded
    /usr/bin/time xcodebuild -version
    # expect: unbounded
    echo a | xargs xcrun simctl delete
    # expect: unbounded
    declare -a cmd2=(swift test); "${cmd2[@]}"
    # expect: nothing
    flags=$((1 << 3))
    # expect: unbounded
    xcodebuild -version
    # expect: unbounded
    lib_build -scheme X build
    # expect: unbounded
    legacy
    # expect: unbounded
    run=xcodebuild; "$run" -version
}
function legacy {
    # expect: nothing
    xcodebuild -version # limit: legacy
}
step_five() {
    # expect: unbounded
    xcodebuild build # limit: step_five
}
step_six() {
    # expect: nothing
    knot_limit 10 legacy
    # expect: nothing
    command -v xcodebuild >/dev/null || echo "no Xcode"
    # expect: nothing
    xcrun -f xcodebuild
    # expect: nothing
    xcrun --find swift
    # expect: nothing
    type xcodebuild
    # expect: nothing
    hash xcodebuild 2>/dev/null
    # expect: nothing
    case $tool in
        # expect: nothing
        xcodebuild) limit=$KNOT_BUILD_LIMIT ;;
        # expect: nothing
        swift) limit=$KNOT_SWIFT_TEST_LIMIT ;;
    esac
    cat <<EOT
Run xcodebuild -version to see it.
EOT
    # expect: nothing
    printf '%s\n' "xcodebuild"
}
# The forms of the re-check of pull request 51 at 904821a4 (finding 44), and what is near them.
step_seven() {
    # expect: unbounded
    trap 'xcrun simctl shutdown all' EXIT
    # expect: unbounded
    trap -- "xcrun simctl shutdown all" INT TERM
    # expect: nothing
    trap 'rm -f "$scratch"' EXIT
    # expect: unbounded
    time -p xcodebuild -version
    # expect: nothing
    SIMCTL="xcrun simctl"
    # expect: unbounded
    $SIMCTL list
    # expect: nothing
    export XCRUN_SIMCTL="xcrun simctl"
    # expect: unbounded
    $XCRUN_SIMCTL list
    # expect: unbounded
    "${XCODEBUILD:-xcodebuild}" -version
    # expect: unbounded
    ${XCODEBUILD-xcodebuild} -list
    # expect: nothing
    : "${XC:=xcodebuild}"
    # expect: unbounded
    "$XC" -version
    # expect: nothing
    knot_limit 10 "${XCODEBUILD:-xcodebuild}" -version
    # expect: unbounded
    find . -name '*.xcodeproj' -exec xcodebuild -list -project {} \;
    # expect: unbounded
    find . -name '*.xcodeproj' -execdir xcodebuild -list +
    # expect: nothing
    find . -name '*.log' -exec rm {} \;
    # expect: unbounded
    coproc xcodebuild -version
    # expect: unbounded
    coproc XB { xcodebuild -version; }
    # expect: unbounded
    exec -a xb xcodebuild -version
    # expect: unbounded
    env -S 'xcodebuild -version'
}
for step in five six seven; do "step_${step}"; done
xcb() {
    # expect: nothing
    xcodebuild -project x "$@" 2>&1 | cat >>"$log" # limit: xcb
}
