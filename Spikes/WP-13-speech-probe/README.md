# WP-13 speech probe

The proof step of WP-13 repeats, inside an app, the probe that found `SpeechTranscriber`
unavailable in the iOS Simulator (docs/architecture.md §20). The first probe was a bare
executable. This one is a SwiftUI app with an Info.plist and a bundle ID, launched with
`simctl`. It lives on `wp/13-proof` only and never merges. docs/notes/WP-13.md reports what it found.

It prints only counts and system facts: the word count of a synthetic clip, never its words.

```
cd Spikes/WP-13-speech-probe
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project SpeechProbe.xcodeproj \
  -scheme SpeechProbe -sdk iphonesimulator -destination "id=$(../../scripts/sim.sh udid iphone)" \
  -derivedDataPath ../../.build/spike-speech-probe build
../../scripts/sim.sh boot iphone
xcrun simctl install "$(../../scripts/sim.sh udid iphone)" \
  ../../.build/spike-speech-probe/Build/Products/Debug-iphonesimulator/SpeechProbe.app
SIMCTL_CHILD_KNOT_PROBE_INSTALL=1 \
SIMCTL_CHILD_KNOT_PROBE_AUDIO="$PWD/../../Fixtures/generated/audio/clean.wav" \
  xcrun simctl launch --console-pty --terminate-running-process "$(../../scripts/sim.sh udid iphone)" \
  com.p3ob7o.knot.dev.spike.speechprobe
```
