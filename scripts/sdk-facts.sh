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

python3 -I - "${roots[@]}" <<'PY'
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
# 7
fact("LiveActivityIntent is available on macOS 27.3.",
     "macOS 27.3" in (attributes_before(intents_ios, r"protocol LiveActivityIntent\b") or ""))
# 8
fact("The notes schema offers createNote, updateNote and appendText.",
     all(re.search(rf"var {n}: some AppIntents::AppSchemaIntent", intents_ios) for n in ["createNote", "updateNote", "appendText"]))
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

print("sdk-facts: every row holds" if failures == 0 else f"sdk-facts: {failures} rows do not hold")
sys.exit(1 if failures else 0)
PY
