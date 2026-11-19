# SP-2 code half: `WCSession` and the draft link ports

The code half of SP-2, 2026-11-19, on the build Mac: macOS 27.3 (26C5047e), Xcode 27.2 (27B52), the iOS 27.2 and watchOS 27.2 simulators, paired. The spike's apps are on the branch `spike/watch-delivery`, under `Spikes/SP-2/`, and never merge. This note has one reader, WP-02 PR 3, which writes the `WatchLink` port, and WP-17, which writes `LinkTransport` behind it. The report, `docs/spikes/SP-2.md`, follows the owner's sitting with the Watch and the iPhone.

The declarations are read in the pinned SDK: `WCSession.h`, `WCSessionFile.h`, `WCSessionUserInfoTransfer.h` and `WCError.h` of WatchConnectivity, identical in the iOS and watchOS 27.2 SDKs. The simulator results come from the spike's two apps, driven by launch arguments, with every delegate call written to an event log. No test opened a microphone.

## What the simulator can and cannot show

The paired simulators deliver less than the API promises. These results are the simulator's, and the sitting repeats each one on hardware.

| Path | In the simulator |
|---|---|
| `transferFile`, Watch to iPhone | The Watch gets `didFinish` with no error 0.4 to 0.5 s after queueing, in queue order. The iPhone app never gets `didReceive`. |
| `transferUserInfo`, either way | Never reaches the other app. The sender gets no error. The iPhone's framework logs that it failed to load the transfer's stored result. |
| `updateApplicationContext`, iPhone to Watch | Works. Five updates in a row reached the running Watch app as five callbacks, in order. |
| `sendMessage`, Watch to iPhone | Works, about 3 s to the reply. It launched an iPhone app that was not running, in the background. |
| Installing | Installing the iPhone app does not install its Watch app. Installed separately, the Watch app counts as not installed on the iPhone for several seconds, and the iPhone drops what arrives meanwhile ("counterpart app not installed"). |
| `isReachable` on the Watch | Read true while the iPhone simulator was shut down. |
| Microphone | The Mac's. The spike's recorder refuses to start in the simulator. |

So no simulator test can prove a delivery, an acknowledgement or a wake. The Watch side's queueing, cancelling, failing and relaunching can be seen, because they happen before anything crosses. `docs/architecture.md` §12 already says that delivery is tested on hardware. It is true of user info as well as of files.

## How a transfer behaves

**Progress.** A `WCSessionFileTransfer` has an `NSProgress` (iOS 12, watchOS 5). Its total is 100 units, a percentage, whatever the file's size. In the simulator its completed count stayed at 0 while queued, through a relaunch, and read 100 at `didFinish`. There is no stream of the file's content and no partial delivery: a file arrives whole or not at all.

**The end.** `session(_:didFinish:error:)` comes on the sender once per transfer, with `error` nil or a `WCErrorDomain` error. It is not a delivery. In the simulator it came, without error, for files that the iPhone app never received. Only the iPhone's acknowledgement says that a capture arrived, which is the design §12 already has.

**A failure.** A file that does not exist fails at once: `isTransferring` is false on return, and `didFinish` follows with `WCErrorDomain 7013`. `sendMessage` before the session was reachable failed at once with `7007`. A 2 MB user-info payload was accepted without an error in the simulator; the limit is a question for the hardware. `WCErrorCode` is an imported `NS_ENUM`, not frozen, so a mapping needs a default case.

**Cancelling.** `cancel()` on a file transfer acts at once: `isTransferring` reads false straight after, the transfer leaves `outstandingFileTransfers`, and **no delegate call ever comes for it**. A cancelled capture can be queued again with the same file, and that transfer behaves like any other.

**Before activation.** `transferFile` is accepted before activation completes, and the transfer waits in the queue. `activationState` can read `.activated` before the delegate's activation callback has run, while `isReachable` is still false. Anything that depends on the session's state waits for the callback.

**A relaunch of the Watch app.** Ten transfers queued with the iPhone simulator shut down stayed queued. After the Watch app was terminated and launched again, `outstandingFileTransfers` held all ten, as new objects whose `file.metadata` was intact, so each could be matched to its capture ID. With the Watch app terminated and the iPhone back, the ten finished while the app was not running, and their `didFinish` calls arrived at the next launch, straight after activation, in queue order, with the queue empty. `receivedApplicationContext` held the latest context at each launch. The `didReceiveApplicationContext` call that the header promises "on startup" did not come at a relaunch, so the property is read at activation.

**The iPhone app not running.** Whether files and user info that arrive while the iPhone app is not running wake it, or wait for its next launch, needs the hardware (sitting row 10).

**Order and duplication.** The header promises no order. In the simulator the sender's `didFinish` calls came in queue order, for twenty files queued in a row with sizes falling from 400 KB to 20 KB, and for ten delivered while the app was not running. The order of arrival on the iPhone needs the hardware. The API never merges two transfers: each `transferFile` is a separate delivery, so a re-send of a capture whose acknowledgement was lost arrives twice. Ingest is idempotent by capture ID, which §12 already requires.

**The delegate.** Every delegate call comes on one private serial queue. `WCSession`, `WCSessionFile` and the transfer objects have no `Sendable` annotation in the 27.2 SDK. The spike's link is a `@MainActor` class with `nonisolated` delegate methods: each method decodes its `Sendable` values on the delegate queue and then hops to the main actor. It compiles under Swift 6 strict concurrency with warnings as errors, with no `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency`. A closure given to `sendMessage` must be made outside an actor, because the session calls it on its own queue.

**The Watch's background task.** SwiftUI's `.backgroundTask(.watchConnectivity)` is the watchOS 9 hook for `WKWatchConnectivityRefreshBackgroundTask`. The task ends when its closure returns, so the closure waits while `hasContentPending` is true. The simulator never woke the Watch app this way.

## For WP-02 and WP-17: do the drafts fit?

**`WatchLink`** (§5: "Send a capture, receive acknowledgements, publish how many captures wait and how many failed") fits, with three changes.

1. Sending returns nothing about delivery. It writes the capture to the outbox and queues it. Waiting and failed are counted from the outbox and its acknowledgements, never from the session's queue, which empties on `didFinish` whether or not the iPhone app has the file.
2. It needs an operation to resume at launch and on the system's events: wait for activation, adopt `outstandingFileTransfers` by the capture ID in their metadata, take any `didFinish` that arrives, and queue again each outbox capture that is neither acknowledged nor outstanding. A capture that is still outstanding is not sent again, so a relaunch makes no duplicate. §12 lists when it runs.
3. It needs an operation for the Watch's background task: run until the session has no content pending, with a time limit.

**`LinkTransport`** (WP-17: "everything in §12 sits behind it") has no signature yet. The real API asks for this shape:

```swift
public protocol LinkTransport: Sendable {
    /// Resolves when the session's activation callback has run, not when `activationState` first reads activated.
    func activate() async -> LinkSessionState
    var state: LinkSessionState { get }   // activated, reachable, paired and installed, content pending
    var events: AsyncStream<LinkEvent> { get }

    /// Sender. The file stays in the outbox; the transport keeps no copy.
    func queueFile(_ url: URL, manifest: CaptureManifest, attempt: Int)
    func outstandingFiles() -> [OutstandingFile]   // capture ID, attempt, fraction, isTransferring
    /// Synchronous, with no delegate call afterwards: the transport emits `.fileCancelled` itself.
    func cancelFile(captureID: CaptureID, attempt: Int)

    /// Receiver. Called on the delegate's queue, before the system deletes the file. It must
    /// move the file durably and return; the transport sends the acknowledgement it returns.
    func setFileReceiver(_ receive: @escaping @Sendable (ReceivedFile) -> Acknowledgement?)

    func send(_ message: LinkMessage)                    // transferUserInfo: acknowledgements only
    func updateContext(_ context: LinkContext) throws    // latest wins; read again at activation
}

public enum LinkEvent: Sendable {
    case stateChanged(LinkSessionState)
    case fileFinished(captureID: CaptureID, attempt: Int, error: LinkError?)   // not a delivery
    case fileCancelled(captureID: CaptureID, attempt: Int)
    case message(LinkMessage)                            // an acknowledgement, on the Watch
    case context(LinkContext)                            // on the Watch
}
```

The receiver is a synchronous handler, not an event in the stream, because the system deletes the file when the delegate call returns (§12, "Receive"). The fake transport implements the same protocol, and it can lose, repeat and reorder each kind of event, and finish a file that never arrives, as the simulator did.

**Streaming.** None: a file is delivered whole, and progress is a percentage that the simulator never moved before the end. The stall rule of §12 ("no progress for a set time") cannot rest on progress until the hardware shows progress moving. Until then it rests on time: a capture queued for longer than a set time with no `didFinish` and no acknowledgement, while the session is activated and reachable, is cancelled and queued again. The sitting (rows 1 and 9) says whether progress can replace that.

**Errors.** The transport maps `WCErrorDomain` codes to the taxonomy, with a default for codes it does not know:

| Code | Meaning | Class | Port case |
|---|---|---|---|
| 7004 session not activated, 7016 session inactive | No session yet, or the iPhone is switching watches | Deferral | link not ready |
| 7005 device not paired, 7006 Watch app not installed, 7018 companion app not installed | The other side is missing | Deferral | counterpart missing, shown as waiting |
| 7007 not reachable | Only for `sendMessage`, which the port does not use | — | — |
| 7013 file access denied | The outbox file is missing or unreadable, at once | Failure | outbox file missing: the capture fails and keeps its manifest |
| 7015 insufficient space | No room on the receiving side | Deferral | counterpart full |
| 7014 delivery failed, 7017 transfer timed out, 7001 generic, any other | The transfer did not complete | Attempt | delivery failed: queued again |
| 7008 invalid parameter, 7009 payload too large, 7010 unsupported types | A payload the code built wrongly | Failure | programming error; the manifest is bounded at 64 KiB (§4) |

**Cancellation** is the transport's `cancelFile`, synchronous, and the only cancellation there is: there is no task to cancel, and the system goes on transferring after the app exits. Since the session never reports a cancel, the transport reports it itself, so the outbox never waits for a call that will not come.

## Changes this asks of the architecture

- **§5, ports.** Add `LinkTransport` to the table, with the responsibility above, and the three changes to `WatchLink`.
- **§5, error taxonomy.** Add the link's cases: link not ready, counterpart missing, counterpart full and delivery failed (deferrals or attempts), and outbox file missing (a failure).
- **§12, Send.** `didFinish` without an error is not a delivery: in the simulator it came for files that never reached the iPhone app. Only the acknowledgement moves a capture out of the outbox.
- **§12, Retry.** Add: at launch, adopt `outstandingFileTransfers` by capture ID before queueing anything again, and never queue again a capture that is still outstanding. Cancelling gives no delegate call. The stall rule rests on time since queueing until the sitting shows that progress moves.
- **§12, Back channel.** The Watch reads `receivedApplicationContext` at activation and does not wait for a callback at launch.
- **§12, Testing.** Neither files nor user info reach the other app in the 27.2 simulators, in either direction, while application context (iPhone to Watch) and `sendMessage` (Watch to iPhone) do. The real transport has no simulator test.
- **§20, platform facts.** Add, as "simulator, 2026-11-19": `didFinish` without delivery; cancel without a callback; progress in percent units; finishes delivered at the next launch; transfers accepted before activation; `sendMessage` launches the iPhone app in the background; the Watch app installed apart and the iPhone's few seconds of "not installed". The two rows already marked SP-2 stay open for the sitting.

## The questions of the brief

| Question | Where |
|---|---|
| Does recording continue with the wrist down and the screen off? | Needs the Watch, sitting row 11 |
| How long from a complication tap to the first sample? | Needs the Watch, rows 2 and 3 |
| Can a watch control or `AudioRecordingIntent` start a recording without bringing the app forward? | Needs the Watch, rows 6 and 8. The SDK allows it to be asked: `AudioRecordingIntent` is on watchOS 11, `supportedModes` with `.background` on watchOS 26, and `ControlWidgetButton` takes any `AppIntent` on watchOS 26. `allowedExecutionTargets`, which SP-1's note found, is on watchOS 27 too, and the spike's two intents set it to `.main`, so a control or Siri may run them only in the Watch app. |
| Can a watch intent start a recording at all? | Needs the Watch, rows 6 and 8 |
| Does Double Tap start a recording when Knot is not the app in front? | Needs the Watch, row 5 (a Smart Stack widget's button with `handGestureShortcut(.primaryAction)`, which compiles in a widget) |
| Does a control bound to the Ultra's Action Button start a recording directly? | Needs the Watch, rows 0 and 7 |
| How long does `transferFile` take, and how often does it stall: phone near, away and back, iPhone app terminated? | Needs the Watch, rows 1, 9 and 10: no file reaches the iPhone app in the simulator |
| Is the iPhone app woken to receive the file? | Needs the Watch, row 10. In the simulator only `sendMessage` reached the iPhone app, and it did launch it in the background. |
| How much background time does a locked phone grant, and does transcription finish in it? | Needs the Watch, row 10. `SpeechTranscriber` is unavailable in the simulator (§20). |
| §20: `transferFile` stalls until Bluetooth is toggled | Needs the Watch, row 9 |
| §20: a recording continues with the wrist down once started in front | Needs the Watch, row 11 |
| The 60-second Watch target | Needs the Watch, rows 2, 3 and 10 |
| The install procedure on the iPhone and the Watch | Needs the Watch, row 0. The steps are in `Spikes/SP-2/README.md`. |
| Do the draft ports fit `WCSession`: progress, end, failure, cancellation, relaunch, order, duplication? | Answered here, for the sending side. The receiving side's order and wake need the Watch. |
