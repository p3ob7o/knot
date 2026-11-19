# SP-1 code half: the recording intents and their ports

The code half of SP-1, 2026-11-19, on the build Mac: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), the iPhoneOS 27.2 SDK. Its code is the spike app on the branch `spike/locked-recording`, in `Spikes/SP-1/`, which is never merged. This note has two readers: WP-02, whose third pull request writes `RecordingActivity`, `RecordingStateStore` and the port for background time, and the orchestrator, which keeps docs/architecture.md.

No iPhone was paired and the team's signing was not on the Mac, so the app was built for the iOS Simulator and, unsigned, for a device. The Simulator's microphone is the build Mac's, so no recording path ran: the recorder refuses the hardware input in the Simulator before it touches the audio session. Everything a recording needs is answered at the owner's sitting, from `Spikes/SP-1/sitting.md`. The report, `docs/spikes/SP-1.md`, follows it.

## In short

The intents of docs/architecture.md §14 fit the SDK, with three additions. The ports fit with changes:

1. **The intents can be pinned to the app process.** OS 27 adds `allowedExecutionTargets`. With `[.main]` the system may run the intent only in the app, though its type is compiled into the widget extension too. The metadata of both bundles records it. This turns "runs in the app process" in §14 from a hope into a declaration.
2. **ToggleRecording is also a `SetValueIntent`,** because a toggle control takes only that kind of intent, and a `LongRunningIntent` with `CancellableIntent`, if that is the mechanism for the work after stop.
3. **`RecordingActivity` holds no `Activity`.** ActivityKit's `Activity` is not `Sendable`. The port is keyed by capture ID, and the implementation finds the activity each time, which also lets a new launch end the activity a dead one left.
4. **`RecordingStateStore` fits as drafted:** a synchronous read and write of one value in the app group's defaults. Reloading the controls is not its job.
5. **The port for background time does not fit as a service.** Background time from an intent exists only inside that intent's `perform()`, through a method of the intent itself. The port has to be a runner the caller passes in, scoped to the call, and both mechanisms that give minutes require progress reports.

| Built | Result |
|---|---|
| `Spikes/SP-1/build.sh check`: the app and the widget extension for the Simulator, and unsigned for a device, Swift 6, complete concurrency checking, warnings as errors | Both build clean |
| `Spikes/SP-1/build.sh sim`: install on the worktree's iPhone simulator and run the self-test | Passes. The log is quoted below. |

## The intents

What each recording intent adopts, as the spike compiles it and as `Metadata.appintents` records it in both the app and the extension:

| Intent | Protocols | Modes | Runs in |
|---|---|---|---|
| ToggleRecording | `SetValueIntent` (value: `Bool`), `AudioRecordingIntent`, `LiveActivityIntent`, `LongRunningIntent`, `CancellableIntent` | `[.background, .foreground(.dynamic)]` | `allowedExecutionTargets = [.main]` |
| StopRecording | `LiveActivityIntent`, `LongRunningIntent`, `CancellableIntent` | `[.background]` | `[.main]` |

Read from the SDK, the metadata and Apple's documentation:

- **Process.** `IntentExecutionTargets` (OS 27) has `.main`, `.appIntentsExtension` and `.widgetKitExtension`, and `.default`, which lets the system pick. Apple's page says that an intent shared through a package or a framework "may" run in the app or an App Intents extension. The spike pins Toggle and Stop to `.main` and leaves a third intent, PressRecording, unpinned, so the sitting shows where the system runs an unpinned recording intent. In both metadata files the pinned intents carry `allowedTargets: [{type: 1}]` and the unpinned ones carry none.
- **Compiled into both.** Both `SP1.app/Metadata.appintents` and `SP1Widgets.appex/Metadata.appintents` list all four intents, with the same system protocols. `LiveActivityIntent` appears as `SessionStarting`, `.foreground(.dynamic)` as `ForegroundContinuable`.
- **Locked device.** `authenticationPolicy` defaults to `.alwaysAllowed` (metadata `authenticationPolicy: 0`), so the recording intents may run on a locked phone without saying so. An intent that reads or picks a note must declare `.requiresAuthentication` (§14 already says it needs authentication).
- **What it can await.** `perform()` is `async throws`, and may await the engine on the main actor and the Live Activity. Outside `performBackgroundTask`, Apple gives an intent 30 seconds in the background.
- **Cancellation.** `CancellableIntent` (OS 26.4) gives `withIntentCancellationHandler(operation:onCancel:)` and the variant of `performBackgroundTask` with `onCancel`, whose `IntentCancellationReason` is `.timeout` or `.userCancelled`.
- **Failure.** `perform()` throws. The spike's error conforms to `CustomLocalizedStringResourceConvertible`, so the system can show its reason. `continueInForeground(_:alwaysConfirm:)` throws `notAllowed` when the app cannot come forward, and `needsToContinueInForegroundError` returns an error to throw instead.
- **Opening the app** when Live Activities are off or the microphone is refused: with `.foreground(.dynamic)` the intent starts in the background and calls `continueInForeground` only in those two cases. Whether that brings Knot up from the Lock Screen after Face ID is a sitting row.
- **Reaching the environment.** `AppDependencyManager` has `add` and no lookup, and `@Dependency` without a default has no failing path. `@Dependency(default: …)` is the accessor §14 asks for: the extension, which registers nothing, gets the unavailable value, and the intent throws a typed error. The spike registers its host in `App.init`, which runs at every launch, in the background too.
- **Press time.** `IntentSystemContext.preciseTimestamp` is recorded only for the Action Button of an Apple Watch Ultra, per Apple's page. On the iPhone the press is timed from outside the app, as product spec §14 says. The spike logs the process start, the start of `perform()` and the first captured buffer, so that a screen recording only has to supply press to process start.

## The ports

### `RecordingActivity`

Fits, keyed by capture ID. The spike's draft, implemented on ActivityKit in `App/LiveRecordingActivity.swift`:

```swift
protocol RecordingActivity: Sendable {
    var isEnabled: Bool { get }  // ActivityAuthorizationInfo().areActivitiesEnabled
    func start(captureID: UUID, startedAt: Date) throws(RecordingActivityError)
    func update(captureID: UUID, _ state: ContentState) async
    func end(captureID: UUID, _ state: ContentState, dismissAfter: TimeInterval) async
    func endAll(except captureID: UUID?) async -> Int  // at launch: activities with no recorder
}
enum RecordingActivityError: Error { case disabled, refused(String), other(String) }
```

- **Streaming.** None. `Activity.request(attributes:content:pushType:)` is synchronous and throws. `update` and `end` are `async` and do not throw. `ActivityAuthorizationInfo().activityEnablementUpdates` is an async sequence, if the app wants to follow the switch.
- **Sendability.** `Activity` is a class that is not `Sendable`. Holding it in an actor and calling its `async` methods sends it across isolation. So the implementation is a stateless `struct` that finds the activity with `Activity<Attributes>.activities` by the capture ID in its attributes. A relaunch finds the dead launch's activity the same way and ends it.
- **Errors.** `ActivityAuthorizationError` has twelve cases, among them `denied`, `globalMaximumExceeded`, `targetMaximumExceeded`, `visibility` and `unentitled`. They map to `refused(name)` and decide whether the intent opens the app.
- **Staleness.** `ActivityContent(state:staleDate:)` carries the stale date of §8. The spike sets it ten seconds ahead and moves it every five seconds while recording.
- **In the Simulator,** from the app in front, `start` and `end` work: the self-test started an activity and ended it with the failed state.

### `RecordingStateStore`

Fits as drafted, in `Shared/DraftPorts.swift`:

```swift
protocol RecordingStateStore: Sendable {
    func read() -> RecordingStateSnapshot
    func write(_ snapshot: RecordingStateSnapshot)
}
// phase (idle, starting, recording, stopping), captureID, startedAt,
// heartbeat, ownerLaunch, ownerPID; isFresh(at:) is "heartbeat under 3 s"
```

- The control's `ControlValueProvider.currentValue()` is `async throws`, so a synchronous read fits inside it. The snapshot is one JSON value under one key, so a reader never sees half a write.
- Telling the controls to refresh is `ControlCenter.shared.reloadControls(ofKind:)`, from WidgetKit. That call belongs to the app shell when the phase changes, not to the store, so the store's implementer (KnotAudio, §5) needs no WidgetKit.
- Whether the group's defaults can be read before the first unlock is a sitting row.

### The port for background time

Does not fit as a service. Three mechanisms exist, and none of them is something the queue can call on its own:

| Mechanism | How it gives time | Limits from the SDK and Apple's pages |
|---|---|---|
| `LongRunningIntent.performBackgroundTask(options:operation:onCancel:)` (OS 27) | Extends the running intent past 30 s, and shows its progress in a system Live Activity | An instance method of the intent: valid only inside that intent's `perform()`. Requires regular progress, or the system cancels. Throws when "the system can't run the operation". |
| `BGContinuedProcessingTaskRequest` (OS 26) | Minutes, with a system progress UI and a cancel button | Submitted "from the foreground", "as a result of a person's action". The task must report progress. With `strategy = .fail` it fails at once when it cannot run. In the Simulator it fails with `BGTaskSchedulerErrorDomain` 1, unavailable. |
| `UIApplication.beginBackgroundTask` | About 30 s | Ends with the expiration handler. |

So the port is a runner that the holder of the time passes in, and the work it runs reports progress:

```swift
protocol BackgroundRunner: Sendable {
    var name: String { get }
    func run(_ work: PostStopWork) async throws
}
struct PostStopWork: Sendable {
    let captureID: UUID
    let body: @Sendable (_ report: @escaping @Sendable (Double, String) -> Void) async throws -> Void
}
```

An intent that stops a recording makes an intent-backed runner from itself, hands it the queue's work for that capture, and awaits it before `perform()` returns. In the spike, `IntentBackgroundRunner<I: LongRunningIntent & CancellableIntent>` wraps `performBackgroundTask` this way and compiles. The queue's deferral "no background time" (§4) is what the runner's cancellation produces: `onCancel` with `.timeout`, or a task's expiration handler. Which of the three actually finishes transcription and cleanup after a locked stop is the sitting's question, and the decision of the report. Until then, `ProcessingQueue` should take a runner and a progress sink per drain, and not own its background time.

### Also found, for other packages

- **WP-12.** `AVAudioNode.installTap(onBus:bufferSize:format:block:)` is deprecated in OS 27, so it fails a build that treats warnings as errors. The replacement is `installAudioTap(onBus:bufferSize:format:tapProvider:)`, which throws and hands a `@Sendable` provider an `AVReadOnlyAudioPCMBuffer`, a `Sendable` struct. `AVAudioFile` is `Sendable` from OS 26 and has `write(from: AVReadOnlyAudioPCMBuffer)` from OS 27. This also answers WP-13's point that `AVAudioPCMBuffer` cannot cross isolation: the recorder can pass read-only buffers.
- **WP-15.** `BGTaskScheduler.submit(_:)` is deprecated in OS 27 for `try await submitTaskRequest(_:)`.
- **WP-13's finding applies here.** `AssetInventory.status(forModules:)` reports an installed model as not installed. The spike first gated transcription on it and now reads `SpeechTranscriber.installedLocales`, on the spike branch.
- **Launch.** `UIApplication.shared.isProtectedDataAvailable` reads `false` inside `App.init` in the Simulator, unlocked. Code that decides by it waits until launch has finished.
- **The Simulator has no file protection.** Every class wrote and read back, and the protection attribute of a written file reads empty, so file protection is answered only on the iPhone.

## What the Simulator showed

The self-test seeds a recording left open by a dead launch, presses twice at once, presses Stop while idle, and runs three mechanisms over one second of synthetic silence. From its log, without the timing fields:

```
app.launch               appState=active protectedData=false defaults=readable
recovery.orphan          capture=BD1F… bytes=missing
launch.stale-state       phase=recording fresh=false
press.received           kind=inApp phase=idle
start.preflight          mic=undetermined liveActivities=true foreground=true
manifest.written         capture=C6ED…
activity.started         capture=C6ED…
start.recorder-failed    error=SP1.RecorderError#0      (hardware input refused)
press.received           kind=inApp phase=starting
activity.ended           phase=failed
selftest.double-press    first=failed(recorder) second=ignored("press while starting")
selftest.stop-idle       outcome=ignored("stop while idle")
transcribe.unavailable   (SpeechTranscriber is unavailable in the Simulator, §20)
background.backgroundTask.granted valid=true
background.continued.refused error=BGTaskSchedulerErrorDomain#1
selftest.end             phase=idle statePhase=idle
```

## The questions of the brief

| Question | Here or on the iPhone |
|---|---|
| Does an intent with `AudioRecordingIntent` and `LiveActivityIntent` start recording from the Action Button and a Lock Screen control, locked, with Knot not running? | Needs the iPhone (rows 3 and 4). The intent compiles and its metadata is in both bundles. |
| What happens when Live Activities are off, or the microphone permission is missing? | Needs the iPhone (rows 10 and 11). Answered here: the code path, `continueInForeground` under `.foreground(.dynamic)`, and that it throws `notAllowed` when the app cannot come forward. |
| How long from the press to the first captured sample? | Needs the iPhone (rows 2 and 3). `preciseTimestamp` does not give the press time on an iPhone. |
| Does transcription finish in the background after stop, with `performBackgroundTask` or a continued-processing task? | Needs the iPhone (rows 3, 6 and 7). Answered here: the shape each one needs, and that a continued-processing task is documented as a foreground request. |
| Does cleanup with the on-device model finish in the background? | Needs the iPhone (rows 3, 6 and 7). |
| Which file protection class? | Needs the iPhone: the Simulator enforces none. The probe writes and reads each class at every press and logs it (rows 3 and 12). |
| A press after a restart before the first unlock, a double press on a cold start, a press after a force quit during a recording | Needs the iPhone (rows 12, 8 and 9). Answered here: the state machine ignores a press while starting, and recovery ends a recording left open by another launch. |
| In which process does each intent run? | Answered here for the pinned intents: the app, by declaration. Needs the iPhone for the unpinned ones (row 5). |
| Does a toggle control's intent carry the value the control showed? | Partly here: a toggle control takes only a `SetValueIntent<Bool>`, so its intent always receives a value. Whether that value is the new state or the shown one, and whether it can disagree with the recorder, needs the iPhone (row 4). |
| ToggleRecording and StopRecording compiled into both the app and the widget extension | Answered here: both bundles' metadata list them. Whether it is required needs the iPhone. |
| The Live Activity lasts as long as the recording, or the system stops it | Needs the iPhone. Apple's page for `AudioRecordingIntent` says so. |
| If Live Activities are off or the microphone permission is missing, the intent opens the app | Needs the iPhone (rows 10 and 11). |
| Starting a recording from a locked iPhone works for third-party apps (§20) | Needs the iPhone (row 3). |
| The mechanism for background execution on iOS | Needs the iPhone. The report decides it. |
| The install procedure on the iPhone and the Watch | Needs the iPhone. `Spikes/SP-1/README.md` says what the device build needs. |

## Changes this asks of the architecture

For the orchestrator, who makes them:

1. **§14, the table.** ToggleRecording adopts `SetValueIntent`, `AudioRecordingIntent` and `LiveActivityIntent`, plus `LongRunningIntent` and `CancellableIntent` if the report picks `performBackgroundTask`. StopRecording adopts `LiveActivityIntent`, plus the same two on the same condition. The column "Runs in" says "App process, declared with `allowedExecutionTargets = [.main]` (OS 27)" for both.
2. **§14, the paragraph on the environment.** "One accessor that fails with a typed error" is `@Dependency(default: <unavailable value>)`, because `AppDependencyManager` has no lookup that can fail. Every intent that writes declares `allowedExecutionTargets = [.main]`, so the system cannot pick the extension.
3. **§14, Shortcuts.** The recording intents declare `supportedModes = [.background, .foreground(.dynamic)]`, and call `continueInForeground` only when Live Activities are off or the microphone is refused.
4. **§5, `RecordingActivity`.** Keyed by capture ID, holding no `Activity`, with `endAll(except:)` for launch. Its errors name ActivityKit's refusal.
5. **§5, `BackgroundRunner`.** A runner passed in by whoever holds the time, scoped to one call, whose work reports progress. `ProcessingQueue` takes a runner and a progress sink per drain. The mechanism waits for the report.
6. **§5 or §13.** Reloading controls when the recording phase changes is the app shell's, with `ControlCenter.shared.reloadControls(ofKind:)`, not the state store's.
7. **§20, new rows.** `allowedExecutionTargets` exists from OS 27 (SDK). An intent's `authenticationPolicy` defaults to `.alwaysAllowed` (SDK and metadata). `preciseTimestamp` is recorded for the Apple Watch Ultra's Action Button only (Apple docs). `BGContinuedProcessingTaskRequest` is submitted from the foreground in response to a person's action (Apple docs), and is unavailable in the Simulator (observed). `installTap` is deprecated in OS 27 for `installAudioTap` with `AVReadOnlyAudioPCMBuffer` (SDK). `BGTaskScheduler.submit(_:)` is deprecated for `submitTaskRequest(_:)` (SDK). `Activity` is not `Sendable` (SDK).

## Declarations and pages read

In the iPhoneOS 27.2 SDK of Xcode 27.2, through `scripts/sdk-path.sh`:

- AppIntents: `AppIntent` (with `supportedModes`, `authenticationPolicy`, `allowedExecutionTargets`), `IntentModes` and `IntentModes.Current`, `IntentExecutionTargets`, `IntentSystemContext` (`preciseTimestamp`, `currentMode`), `continueInForeground(_:alwaysConfirm:)`, `needsToContinueInForegroundError(_:alwaysConfirm:)`, `AudioRecordingIntent`, `LiveActivityIntent`, `SetValueIntent`, `LongRunningIntent` and `performBackgroundTask`, `LongRunningTaskOptions`, `ProgressReportingIntent`, `CancellableIntent`, `IntentCancellationReason`, `AppDependencyManager`, `AppDependency`.
- ActivityKit: `ActivityAttributes`, `Activity` (`request`, `update`, `end`, `activities`), `ActivityContent`, `ActivityUIDismissalPolicy`, `ActivityAuthorizationInfo`, `ActivityAuthorizationError`.
- WidgetKit: `ControlWidgetToggle`, `ControlWidgetButton`, `StaticControlConfiguration`, `ControlValueProvider`, `ControlCenter`.
- BackgroundTasks: `BGContinuedProcessingTaskRequest`, `BGContinuedProcessingTask`, `BGTaskScheduler` (`register`, `submitTaskRequest`), `BGTaskSchedulerErrorCode`.
- AVFAudio: `AVAudioApplication.recordPermission`, `AVAudioNode.installAudioTap`, `AVReadOnlyAudioPCMBuffer`, `AVAudioFile.write(from:)`.
- Speech: `SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`, `AssetInstallationRequest`. FoundationModels: `SystemLanguageModel` and its `Availability`, `LanguageModelSession`.

Apple's pages, as JSON: `AudioRecordingIntent`, `LiveActivityIntent`, `AppIntent/allowedExecutionTargets`, `IntentExecutionTargets`, `IntentModes`, `IntentModes.ForegroundMode.dynamic` and `.deferred`, `AppIntent/supportedModes`, `AppIntent/continueInForeground(_:alwaysConfirm:)`, `IntentSystemContext/preciseTimestamp`, `LongRunningIntent`, `LongRunningIntent/performBackgroundTask(options:operation:)`, `SetValueIntent`, `AppDependency`, `BGContinuedProcessingTaskRequest`, and "Performing long-running tasks on iOS and iPadOS".
