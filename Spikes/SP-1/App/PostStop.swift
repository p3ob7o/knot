import AVFAudio
import BackgroundTasks
import Foundation
import FoundationModels
import Speech
import UIKit

/// The work after a recording stops: transcribe the saved file, then clean the transcript with
/// the on-device model. It logs durations, counts, availability and error codes only. The
/// transcript stays in memory and is dropped at the end.
enum PostStop {
    static func work(captureID: UUID, url: URL) -> PostStopWork {
        PostStopWork(captureID: captureID) { report in
            try await process(captureID: captureID, url: url, report: report)
        }
    }

    private static func process(
        captureID: UUID, url: URL, report: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let id = captureID.uuidString
        let context = await MainActor.run { BackgroundContext.current() }
        SP1Log.record("post.begin", context.fields(capture: id))

        report(0.05, "Transcribing")
        let started = Date()
        guard SpeechTranscriber.isAvailable else {
            SP1Log.record("transcribe.unavailable", ["capture": id])
            return
        }
        let locale =
            await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        // WP-13's note: `AssetInventory.status` reports an installed model as not installed, so
        // installation is read from `installedLocales`.
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            // A deferral (docs/architecture.md §4): the model is installed from the app, in front.
            SP1Log.record(
                "transcribe.deferred",
                [
                    "capture": id, "installedCount": String(installed.count),
                    "assets": String(describing: await AssetInventory.status(forModules: [transcriber])),
                ])
            return
        }
        let text: String
        do {
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let collector = Task {
                var parts: [String] = []
                for try await result in transcriber.results where result.isFinal {
                    parts.append(String(result.text.characters))
                }
                return parts.joined(separator: " ")
            }
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            text = try await collector.value
        } catch {
            SP1Log.record("transcribe.error", ["capture": id, "error": SP1Log.code(error)])
            throw error
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        SP1Log.record(
            "transcribe.done",
            [
                "capture": id, "ms": SP1Log.ms(Date().timeIntervalSince(started)), "words": String(words),
                "protectedData": await MainActor.run { String(UIApplication.shared.isProtectedDataAvailable) },
            ])
        report(0.6, "Cleaning up")

        try Task.checkCancellation()
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            SP1Log.record("clean.unavailable", ["capture": id, "availability": String(describing: model.availability)])
            report(1, "Done")
            return
        }
        guard words > 0 else {
            SP1Log.record("clean.skipped", ["capture": id, "reason": "no words"])
            report(1, "Done")
            return
        }
        let cleanStarted = Date()
        do {
            let session = LanguageModelSession(
                model: model,
                instructions:
                    "Add punctuation and paragraph breaks to the user's dictated text. Remove filler words. "
                    + "Do not add, replace or reorder words. Reply with the text only.")
            let response = try await session.respond(to: text)
            SP1Log.record(
                "clean.done",
                [
                    "capture": id, "ms": SP1Log.ms(Date().timeIntervalSince(cleanStarted)),
                    "chars": String(response.content.count),
                    "protectedData": await MainActor.run { String(UIApplication.shared.isProtectedDataAvailable) },
                ])
        } catch {
            SP1Log.record("clean.error", ["capture": id, "error": SP1Log.code(error)])
            throw error
        }
        report(1, "Done")
    }
}

/// What the process knows about its own situation when the work starts.
@MainActor
struct BackgroundContext {
    let appState: String
    let protectedData: Bool
    let timeRemaining: TimeInterval

    static func current() -> BackgroundContext {
        let app = UIApplication.shared
        let state =
            switch app.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "unknown"
            }
        return BackgroundContext(
            appState: state, protectedData: app.isProtectedDataAvailable, timeRemaining: app.backgroundTimeRemaining)
    }

    nonisolated func fields(capture: String) -> [String: String] {
        [
            "capture": capture, "appState": appState, "protectedData": String(protectedData),
            "bgRemaining": SP1Log.ms(timeRemaining),
        ]
    }
}

/// The three other ways of getting time after stop, beside the intent-backed runner.
@MainActor
enum BackgroundRunners {
    static func run(_ work: PostStopWork, with mechanism: PostStopMechanism) {
        switch mechanism {
        case .longRunningIntent, .none:
            // From an intent, `.longRunningIntent` is run by the intent itself. From the app, in
            // front, both just run.
            Task.detached { await runPlain(work, label: mechanism.rawValue) }
        case .continuedProcessing:
            submitContinuedProcessing(work)
        case .backgroundTask:
            runWithBackgroundTask(work)
        }
    }

    nonisolated static func runPlain(_ work: PostStopWork, label: String) async {
        let started = Date()
        SP1Log.record("background.\(label).begin", ["capture": work.captureID.uuidString])
        do {
            try await work.body { _, _ in }
            SP1Log.record(
                "background.\(label).end",
                ["capture": work.captureID.uuidString, "ms": SP1Log.ms(Date().timeIntervalSince(started))])
        } catch {
            SP1Log.record("background.\(label).error", ["error": SP1Log.code(error)])
        }
    }

    /// `UIApplication.beginBackgroundTask`: the classic grace period, about 30 seconds.
    private static func runWithBackgroundTask(_ work: PostStopWork) {
        let app = UIApplication.shared
        let holder = TaskHolder()
        let identifier = app.beginBackgroundTask(withName: "sp1.post-stop") {
            SP1Log.record("background.backgroundTask.expired", ["capture": work.captureID.uuidString])
            holder.cancel()
        }
        SP1Log.record(
            "background.backgroundTask.granted",
            ["valid": String(identifier != .invalid), "bgRemaining": SP1Log.ms(app.backgroundTimeRemaining)])
        holder.task = Task.detached {
            await runPlain(work, label: "backgroundTask")
            await MainActor.run { UIApplication.shared.endBackgroundTask(identifier) }
        }
    }

    /// `BGContinuedProcessingTask` (iOS 26): documented as submitted from the foreground in
    /// response to a person's action. SP-1 tries it after a locked press too and logs the error.
    private static func submitContinuedProcessing(_ work: PostStopWork) {
        let base = Bundle.main.bundleIdentifier ?? "unknown"
        let identifier = "\(base).sp1.process.\(work.captureID.uuidString.prefix(8))"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            let box = BGTaskBox(task)
            Task.detached { await runContinued(work, task: box) }
        }
        SP1Log.record("background.continued.registered", ["ok": String(registered)])
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Knot SP-1", subtitle: "Transcribing a test recording")
        request.strategy = .fail
        Task.detached {
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
                SP1Log.record("background.continued.submitted", ["capture": work.captureID.uuidString])
            } catch {
                SP1Log.record("background.continued.refused", ["error": SP1Log.code(error)])
            }
        }
    }

    nonisolated private static func runContinued(_ work: PostStopWork, task box: BGTaskBox) async {
        let started = Date()
        let progress = box.task.progress
        progress.totalUnitCount = 100
        let runner = Task {
            try await work.body { fraction, _ in progress.completedUnitCount = Int64(fraction * 100) }
        }
        box.task.expirationHandler = {
            SP1Log.record("background.continued.expired", ["capture": work.captureID.uuidString])
            runner.cancel()
        }
        SP1Log.record("background.continued.begin", ["capture": work.captureID.uuidString])
        let result = await runner.result
        if case .failure(let error) = result {
            SP1Log.record("background.continued.error", ["error": SP1Log.code(error)])
        }
        SP1Log.record(
            "background.continued.end",
            ["capture": work.captureID.uuidString, "ms": SP1Log.ms(Date().timeIntervalSince(started))])
        box.task.setTaskCompleted(success: (try? result.get()) != nil)
    }
}

/// Carries the system's task object into the work. BackgroundTasks does not mark it Sendable;
/// the spike only touches its progress, its expiration handler and its completion.
private final class BGTaskBox: @unchecked Sendable {
    let task: BGContinuedProcessingTask
    init(_ task: BGTask) {
        // The scheduler hands this identifier's handler a continued-processing task only.
        self.task = task as! BGContinuedProcessingTask  // swiftlint:disable:this force_cast
    }
}

@MainActor
private final class TaskHolder {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
}
