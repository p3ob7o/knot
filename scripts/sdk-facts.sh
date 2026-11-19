#!/bin/bash
# Checks every row of docs/architecture.md §20 marked "SDK" against the SDK of the Xcode
# that .xcode-version pins. WP-01 runs it when the release Xcode is installed, and again
# whenever .xcode-version changes. If the SDK contradicts the document, the SDK wins: say
# so in the PR, and the orchestrator updates the document (§21).
#
#   scripts/sdk-facts.sh
#
# Set KNOT_XCODE=/path/to/Xcode.app to check another Xcode by name.

source "$(dirname "$0")/lib/common.sh"
knot_select_xcode
echo "sdk-facts: $(knot_xcode_label)"

roots=()
for sdk in iphoneos macosx watchos; do
    roots+=("$sdk=$(xcrun --sdk "$sdk" --show-sdk-path)" "$sdk-platform=$(xcrun --sdk "$sdk" --show-sdk-platform-path)")
done

status=0
python3 -I - "${roots[@]}" <<'PY' || status=$?
import glob, os, re, sys

roots = dict(arg.split("=", 1) for arg in sys.argv[1:])
SDK = {"ios": roots["iphoneos"], "macos": roots["macosx"], "watchos": roots["watchos"]}
PLATFORM = {"ios": roots["iphoneos-platform"], "macos": roots["macosx-platform"], "watchos": roots["watchos-platform"]}
ARCH = {"ios": "arm64e-apple-ios", "macos": "arm64e-apple-macos", "watchos": "arm64e-apple-watchos"}

def framework(platform, name, developer=False):
    base = os.path.join(PLATFORM[platform], "Developer/Library/Frameworks") if developer \
        else os.path.join(SDK[platform], "System/Library/Frameworks")
    path = os.path.join(base, name + ".framework")
    return path if os.path.isdir(path) else None

def text(platform, name, developer=False):
    """The Swift interface of a framework, and its headers, as one text."""
    path = framework(platform, name, developer)
    if not path:
        return ""
    files = glob.glob(os.path.join(path, "Modules", name + ".swiftmodule", ARCH[platform] + ".swiftinterface"))
    files += glob.glob(os.path.join(path, "Headers", "*.h"))
    return "\n".join(open(f, errors="replace").read() for f in files)

def attributes_before(source, declaration):
    """The attribute lines just above the first line that matches `declaration`."""
    lines = source.splitlines()
    for i, line in enumerate(lines):
        if re.search(declaration, line):
            j, found = i - 1, []
            while j >= 0 and lines[j].lstrip().startswith(("@", "extension ")):
                found.append(lines[j])
                j -= 1
            return " ".join(found) + " " + line
    return None

failures = 0
def fact(row, holds, detail=""):
    global failures
    if not holds:
        failures += 1
    print(("ok    " if holds else "FAIL  ") + row + (f"  ({detail})" if detail and not holds else ""))

# 1
speech = text("watchos", "Speech")
fact("The Speech framework is absent from watchOS; SpeechAnalyzer and SpeechTranscriber are unavailable there.",
     not speech or all(re.search(r"@available\(watchOS, unavailable\)", attributes_before(speech, rf"(class|struct) {n}\b") or "@available(watchOS, unavailable)")
                       for n in ["SpeechAnalyzer", "SpeechTranscriber"]))
# 2
intents_ios = text("ios", "AppIntents")
fact("watchOS has no ActivityKit, PencilKit or PaperKit.",
     not any(framework("watchos", n) for n in ["ActivityKit", "PencilKit", "PaperKit"]))
fact("LiveActivityIntent is unavailable on watchOS.",
     "watchOS, unavailable" in (attributes_before(intents_ios, r"protocol LiveActivityIntent\b") or ""))
# 3
fact("AudioRecordingIntent is available on watchOS 11 and later.",
     re.search(r"watchOS 11\.0", attributes_before(intents_ios, r"protocol AudioRecordingIntent\b") or "") is not None)
# 4
cloudkit_watch = text("watchos", "CloudKit")
fact("watchOS has CloudKit with CKSyncEngine, SwiftData, WidgetKit, AppIntents, WatchConnectivity and FoundationModels.",
     "CKSyncEngine" in cloudkit_watch and all(framework("watchos", n) for n in
         ["SwiftData", "WidgetKit", "AppIntents", "WatchConnectivity", "FoundationModels"]))
# 5
control = attributes_before(text("ios", "SwiftUI"), r"public protocol ControlWidget \{") or ""
fact("ControlWidget is available on iOS 18, macOS 26 and watchOS 26.",
     all(v in control for v in ["iOS 18.0", "macOS 26.0", "watchOS 26.0"]), control.strip()[:160])
gesture = attributes_before(text("watchos", "SwiftUI"), r"func handGestureShortcut\(") or ""
fact("handGestureShortcut is available on watchOS 11.", "watchOS 11.0" in gesture, gesture.strip()[:160])
# 6
long_running = attributes_before(intents_ios, r"protocol LongRunningIntent\b") or ""
fact("LongRunningIntent exists from OS 27, with performBackgroundTask.",
     "27.0" in long_running and "func performBackgroundTask" in intents_ios, long_running.strip()[:160])
# 7. The row's last sentence, that canImport(ActivityKit) is true on macOS, is compiled
#    after this script, in the shell.
activity_ios = text("ios", "ActivityKit")
live = attributes_before(intents_ios, r"protocol LiveActivityIntent\b") or ""
attributes = attributes_before(activity_ios, r"protocol ActivityAttributes\b") or ""
fact("LiveActivityIntent and ActivityKit's ActivityAttributes are marked unavailable on macOS in the pinned SDK.",
     "macOS, unavailable" in live and "macOS, unavailable" in attributes,
     (live.strip() + " / " + attributes.strip())[:200])
# 8
schema = intents_ios.splitlines()
notes = next((i for i, line in enumerate(schema) if re.search(r"var createNote: some AppIntents::AppSchemaIntent", line)), None)
notes_attributes = " ".join(schema[max(0, notes - 6):notes]) if notes is not None else ""
fact("The notes schema offers createNote, updateNote and appendText. It is unavailable on watchOS.",
     all(re.search(rf"var {n}: some AppIntents::AppSchemaIntent", intents_ios) for n in ["createNote", "updateNote", "appendText"])
     and "watchOS, unavailable" in notes_attributes, notes_attributes.strip()[:200])
# 9
pencil = {p: text(p, "PencilKit") for p in ["ios", "macos"]}
fact("PKStrokeRecognizer exists on iOS and macOS, with an async search.",
     all("PKStrokeRecognizer" in t and re.search(r"func search\([^)]*\) async", t) for t in pencil.values()))
# 10
models = text("ios", "FoundationModels")
fact("SystemLanguageModel exposes availability, contextSize, tokenCount(for:) and supportedLanguages.",
     "class SystemLanguageModel" in models and all(re.search(p, models) for p in
         [r"var availability: FoundationModels::SystemLanguageModel", r"var contextSize: Swift::Int",
          r"func tokenCount\(for ", r"var supportedLanguages"]))
# 11
speech_ios = text("ios", "Speech")
fact("SpeechTranscriber exposes isAvailable, supportedLocales and installedLocales; AssetInventory exposes assetInstallationRequest(supporting:).",
     all(re.search(p, speech_ios) for p in [r"static var isAvailable", r"static var supportedLocales",
                                             r"static var installedLocales", r"func assetInstallationRequest\(supporting"]))
# 12
audits = [attributes_before(text(p, "XCUIAutomation", developer=True), r"public func performAccessibilityAudit\(") or ""
          for p in ["ios", "macos", "watchos"]]
fact("performAccessibilityAudit exists on macOS 14, iOS 17 and watchOS 10.",
     all(all(v in a for v in ["macOS 14.0", "iOS 17.0", "watchOS 10.0"]) for a in audits), audits[0].strip()[:160])
# 13
cloudkit = text("ios", "CloudKit")
body = re.search(r"public struct FetchedRecordZoneChanges : [^{]*\{(.*?)\n  \}", cloudkit, re.S)
fact("CKSyncEngine.Event.FetchedRecordZoneChanges has no public initialiser.",
     body is not None and "public init" not in body.group(1))

sys.exit(1 if failures else 0)
PY

# Check 7, its last sentence: compiled for macOS against the pinned SDK.
probe="$(mktemp -d)"
printf '#if canImport(ActivityKit)\nlet found = true\n#else\nlet found = false\n#endif\nprint(found)\n' >"$probe/probe.swift"
if xcrun --sdk macosx swiftc -target "$(uname -m)-apple-macos27.0" "$probe/probe.swift" -o "$probe/probe" >/dev/null 2>&1 &&
    [[ "$("$probe/probe")" == true ]]; then
    echo "ok    canImport(ActivityKit) is true on macOS."
else
    echo "FAIL  canImport(ActivityKit) is true on macOS."
    ((status == 0)) && status=1
fi

if ((status == 0)); then
    echo "sdk-facts: every row holds"
fi
if ((status == 1)); then
    knot_fail "sdk-facts" "Rows of docs/architecture.md §20 marked SDK do not hold in $(knot_xcode_label)." \
        "The SDK wins: say so in the PR, with each row that failed, and ask the orchestrator to update §20." "safe" "nothing"
elif ((status != 0)); then
    knot_fail "infra-sdk-facts-crashed" "The SDK check stopped with status $status before it finished." \
        "Read the Python error above." "safe" "nothing"
fi
