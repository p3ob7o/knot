import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotSpeech

// The real transcriber where it needs no speech model: the order of its checks, the files it
// refuses, readiness, the install and its retry, and live text that cannot start. The speech
// system is a script, and every file is made here from synthetic samples, so these tests take
// nothing from Fixtures/generated/ and run on any Mac, the hosted runner included.
#if canImport(Speech)
    import AVFoundation
    import Speech

    /// A speech system that says what a test scripts, and counts what it was asked.
    final class ScriptedSpeechSystem: SpeechSystem {
        struct Script {
            var isAvailable = true
            var supported = ["en_US", "en_GB"]
            var installed: [String] = ["en_US"]
            var status: SpeechFacts.AssetStatus = .supported
            var installFailure: (any Error & Sendable)?
            var installHold: Duration = .zero
            var questions = 0
            var installs = 0
        }

        let script = Mutex(Script())

        var questions: Int { script.withLock { $0.questions } }
        var installs: Int { script.withLock { $0.installs } }

        var isAvailable: Bool {
            script.withLock {
                $0.questions += 1
                return $0.isAvailable
            }
        }

        func supportedLocales() async -> [Locale] {
            script.withLock {
                $0.questions += 1
                return $0.supported.map { Locale(identifier: $0) }
            }
        }

        func installedLocales() async -> [Locale] {
            script.withLock {
                $0.questions += 1
                return $0.installed.map { Locale(identifier: $0) }
            }
        }

        func status(of locale: Locale) async -> SpeechFacts.AssetStatus {
            script.withLock {
                $0.questions += 1
                return $0.status
            }
        }

        func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
            let (failure, hold) = script.withLock {
                $0.installs += 1
                return ($0.installFailure, $0.installHold)
            }
            if hold > .zero { try await Task.sleep(for: hold) }
            if let failure { throw failure }
            progress(0.5)
            script.withLock { $0.installed.append(SpeechLocaleChoice.key(locale)) }
            return true
        }
    }

    /// A log sink that keeps each line.
    final class ScriptedLogSink: LogSink {
        private let kept = Mutex<[String]>([])
        var lines: [String] { kept.withLock { $0 } }
        func write(_ record: LogRecord) { kept.withLock { $0.append(record.line) } }
    }

    /// Files made of synthetic samples, in a folder of the test's own that it removes.
    struct SpeechScratch: ~Copyable {
        let folder: URL

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appending(path: "knot-speech-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        func url(_ name: String) -> URL { folder.appending(path: name) }

        /// A tone of `seconds`, in 16-bit PCM WAV or AAC in `.m4a`, by the file's extension.
        func tone(_ name: String, seconds: Double) throws -> URL {
            let url = url(name)
            let rate = 16_000.0
            let settings: [String: Any] =
                url.pathExtension == "m4a"
                ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
                : [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(seconds * rate)
            if frames > 0 {
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                let channel = try #require(buffer.floatChannelData?[0])
                for frame in 0..<Int(frames) { channel[frame] = 0.2 * Float(sin(Double(frame) * 0.05)) }
                buffer.frameLength = frames
                try file.write(from: buffer)
            }
            file.close()
            return url
        }
    }

    private func transcriber(_ system: ScriptedSpeechSystem, locale: String = "en_US") -> SpeechAnalyzerTranscriber {
        SpeechAnalyzerTranscriber(source: .fixed(Locale(identifier: locale)), system: system)
    }

    /// The error a run throws, or nil when it returns. A run throws only `KnotError`.
    private func failure(_ work: () async throws -> TranscriptionRun) async -> KnotError? {
        do {
            _ = try await work()
            return nil
        } catch {
            #expect(error is KnotError, "A run throws only KnotError.")
            return error as? KnotError
        }
    }

    @Suite struct TheFileComesBeforeTheModel {
        // Each case below answers before the transcriber asks the speech system anything, so
        // none reaches the model. The script says speech is unavailable: had the transcriber
        // asked first, these would be `speech_unavailable`.
        let system: ScriptedSpeechSystem = {
            let system = ScriptedSpeechSystem()
            system.script.withLock { $0.isAvailable = false }
            return system
        }()

        @Test func aMissingFileIsUnreadable() async throws {
            let scratch = try SpeechScratch()
            let error = await failure {
                try await transcriber(system).transcribe(file: scratch.url("missing.m4a"), from: .zero, budget: nil)
            }
            #expect(error?.code == KnotError.audioUnreadable.code)
            #expect(error?.context.engineCode != nil, "The file's error number is kept.")
            #expect(system.questions == 0)
        }

        @Test func aFileThatIsNotAudioIsUnreadable() async throws {
            let scratch = try SpeechScratch()
            let garbage = scratch.url("garbage.m4a")
            try Data(repeating: 7, count: 4096).write(to: garbage)
            let error = await failure {
                try await transcriber(system).transcribe(file: garbage, from: .zero, budget: nil)
            }
            #expect(error?.code == KnotError.audioUnreadable.code)
            #expect(system.questions == 0)
        }

        @Test(arguments: [0.05, 0.5])
        func anM4ACutShortIsUnreadable(_ kept: Double) async throws {
            // As a crash before the file was finalised leaves it. Cut inside its header,
            // AVAudioFile cannot open it. Cut in its audio, AVAudioFile opens it and fails to
            // read its frames, with -50: those are read before the model is asked for too.
            let scratch = try SpeechScratch()
            let whole = try Data(contentsOf: try scratch.tone("whole.m4a", seconds: 4))
            let cut = scratch.url("cut.m4a")
            try whole.prefix(Int(Double(whole.count) * kept)).write(to: cut)
            let error = await failure { try await transcriber(system).transcribe(file: cut, from: .zero, budget: nil) }
            #expect(error?.code == KnotError.audioUnreadable.code)
            #expect(error?.context.engineCode != nil)
            #expect(system.questions == 0)
        }

        @Test func aFileWithNoFramesIsEmptyTextAndFinished() async throws {
            let scratch = try SpeechScratch()
            let empty = try scratch.tone("empty.wav", seconds: 0)
            let run = try await transcriber(system).transcribe(file: empty, from: .zero, budget: .seconds(60))
            #expect(run.pieces.isEmpty && run.resumeAt == nil && run.startsAt == .zero)
            #expect(run.provenance.engine == SpeechAnalyzerTranscriber.engineName)
            #expect(system.questions == 0)
        }

        @Test func aRunFromTheEndOfTheFileIsEmptyAndFinished() async throws {
            let scratch = try SpeechScratch()
            let tone = try scratch.tone("tone.wav", seconds: 2)
            for offset in [Duration.seconds(2), .seconds(60)] {
                let run = try await transcriber(system).transcribe(file: tone, from: offset, budget: .seconds(60))
                #expect(run.pieces.isEmpty && run.resumeAt == nil && run.startsAt == offset)
            }
            #expect(system.questions == 0)
        }

        @Test func aRunCancelledBeforeItStartsYields() async throws {
            let scratch = try SpeechScratch()
            let tone = try scratch.tone("tone.wav", seconds: 2)
            let system = system
            let task = Task { () -> KnotError? in
                withUnsafeCurrentTask { $0?.cancel() }
                return await failure { try await transcriber(system).transcribe(file: tone, from: .zero, budget: nil) }
            }
            #expect(await task.value?.code == KnotError.cancelled.code)
            #expect(system.questions == 0)
        }
    }

    @Test(
        arguments: [
            // A model that is missing or downloading is a deferral: the recording waits.
            (true, ["en_US"], [String](), SpeechFacts.AssetStatus.supported, "speech_model_not_installed"),
            (true, ["en_US"], [], .downloading, "speech_model_not_installed"),
            // No speech here, or a locale the engine does not support, is final on this device.
            (false, ["en_US"], ["en_US"], .installed, "speech_unavailable"),
            (true, ["en_GB"], ["en_GB"], .unsupported, "speech_unavailable"),
        ] as [(Bool, [String], [String], SpeechFacts.AssetStatus, String)])
    func aReadableFileWaitsForTheModel(_ row: (Bool, [String], [String], SpeechFacts.AssetStatus, String)) async throws
    {
        let system = ScriptedSpeechSystem()
        system.script.withLock {
            $0.isAvailable = row.0
            $0.supported = row.1
            $0.installed = row.2
            $0.status = row.3
        }
        let scratch = try SpeechScratch()
        let tone = try scratch.tone("tone.wav", seconds: 2)
        let error = await failure { try await transcriber(system).transcribe(file: tone, from: .zero, budget: nil) }
        #expect(error?.code.rawValue == row.4)
    }

    @Test func readinessIsReadFromTheSystemForTheLocaleInUse() async {
        let system = ScriptedSpeechSystem()
        #expect(await transcriber(system).readiness() == .ready)
        #expect(await transcriber(system, locale: "en_GB").readiness() == .notInstalled)
        #expect(await transcriber(system, locale: "xx_XX").readiness() == .unsupportedLocale)
        system.script.withLock { $0.status = .downloading }
        #expect(await transcriber(system, locale: "en_GB").readiness() == .installing)
        system.script.withLock { $0.isAvailable = false }
        #expect(await transcriber(system).readiness() == .unavailable)
    }

    @Test func theLocaleFollowsTheSettingBeforeEachRun() async {
        let system = ScriptedSpeechSystem()
        let variant = Mutex(EnglishVariant.locale("en_GB"))
        let transcriber = SpeechAnalyzerTranscriber(
            source: .setting(variant: { variant.withLock { $0 } }, region: { "IT" }), system: system)
        #expect(SpeechLocaleChoice.key(transcriber.locale) == "en_US", "US English until the first check.")
        #expect(await transcriber.readiness() == .notInstalled)
        #expect(SpeechLocaleChoice.key(transcriber.locale) == "en_GB")
        variant.withLock { $0 = .followRegion }
        #expect(await transcriber.readiness() == .ready)
        #expect(SpeechLocaleChoice.key(transcriber.locale) == "en_US", "Italy has no English of its own.")
    }

    @Test func installingMakesTheTranscriberReadyAndReportsProgress() async throws {
        let system = ScriptedSpeechSystem()
        let transcriber = transcriber(system, locale: "en_GB")
        let reported = Mutex<[Double]>([])
        try await transcriber.install { fraction in reported.withLock { $0.append(fraction) } }
        #expect(reported.withLock { $0 } == [0.5, 1])
        #expect(await transcriber.readiness() == .ready)
        #expect(system.installs == 1)
    }

    @Test func anInstallLogsItsOutcomeWithNumbersAndCodesOnly() async throws {
        // The install's lines, on the scripted system: no test reaches the real install.
        let system = ScriptedSpeechSystem()
        let sink = ScriptedLogSink()
        let transcriber = SpeechAnalyzerTranscriber(
            source: .fixed(Locale(identifier: "en_GB")), system: system, log: KnotLog(.speech, sink: sink))
        try await transcriber.install { _ in }
        system.script.withLock {
            $0.installed = ["en_US"]
            $0.installFailure = URLError(.notConnectedToInternet)
        }
        _ = try? await transcriber.install { _ in }
        let lines = sink.lines
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("speech_model_installed downloaded=true took_ms=") == true)
        #expect(
            lines.last
                == "speech_model_install_failed code=speech_model_not_installed engine_code=\(URLError.Code.notConnectedToInternet.rawValue)"
        )
    }

    @Test func aTranscriberIsInstallingWhileItsInstallRuns() async throws {
        let system = ScriptedSpeechSystem()
        system.script.withLock { $0.installHold = .seconds(600) }
        let transcriber = transcriber(system, locale: "en_GB")
        let install = Task { try await transcriber.install { _ in } }
        await SuiteWait.until("the install to start") { system.installs == 1 }
        #expect(await transcriber.readiness() == .installing)
        install.cancel()
        _ = await install.result
        #expect(await transcriber.readiness() == .notInstalled)
    }

    @Test(arguments: [
        (false, ["en_US"], "speech_unavailable"),
        (true, ["en_GB"], "speech_unavailable"),
    ])
    func noInstallWhereSpeechCannotRun(_ row: (Bool, [String], String)) async {
        let system = ScriptedSpeechSystem()
        system.script.withLock {
            $0.isAvailable = row.0
            $0.supported = row.1
        }
        do {
            try await transcriber(system).install { _ in }
            Issue.record("The install must fail.")
        } catch {
            #expect(error.code.rawValue == row.2)
        }
        #expect(system.installs == 0)
    }

    @Test func aFailedInstallIsAskedForAgainWhenTheAppComesForward() async throws {
        let system = ScriptedSpeechSystem()
        system.script.withLock { $0.installFailure = URLError(.notConnectedToInternet) }
        let transcriber = transcriber(system, locale: "en_GB")
        do {
            try await transcriber.install { _ in }
            Issue.record("The install must fail.")
        } catch {
            #expect(error.code == KnotError.speechModelNotInstalled.code)
            #expect(error.isDeferral)
        }
        system.script.withLock { $0.installFailure = nil }
        await transcriber.appCameForward()
        #expect(system.installs == 2)
        #expect(await transcriber.readiness() == .ready)
        // Once ready, coming forward installs nothing more.
        await transcriber.appCameForward()
        #expect(system.installs == 2)
    }

    @Test func comingForwardNeverInstallsWhatTheAppDidNotAskFor() async {
        let system = ScriptedSpeechSystem()
        let transcriber = transcriber(system, locale: "en_GB")
        await transcriber.appCameForward()
        #expect(system.installs == 0)
        #expect(await transcriber.readiness() == .notInstalled)
    }

    @Test func aChangeOfReadinessIsPublishedWhenItIsSeen() async throws {
        let system = ScriptedSpeechSystem()
        let transcriber = transcriber(system, locale: "en_GB")
        let seen = Mutex<[TranscriberReadiness]>([])
        let watcher = Task {
            for await readiness in transcriber.readinessChanges() { seen.withLock { $0.append(readiness) } }
        }
        await SuiteWait.until("the readiness now") { seen.withLock { $0 } == [.notInstalled] }
        // The model arrives with no notice. The next check, as the app comes forward, sees it.
        system.script.withLock { $0.installed.append("en_GB") }
        await transcriber.appCameForward()
        await SuiteWait.until("the change") { seen.withLock { $0 } == [.notInstalled, .ready] }
        // A check that sees no change publishes nothing.
        _ = await transcriber.readiness()
        watcher.cancel()
        #expect(seen.withLock { $0 } == [.notInstalled, .ready])
    }

    @Test(arguments: [
        (true, "speech_model_not_installed"),
        (false, "speech_unavailable"),
    ])
    func liveTextThatCannotStartSaysWhyAndEnds(_ row: (Bool, String)) async {
        let system = ScriptedSpeechSystem()
        system.script.withLock { $0.isAvailable = row.0 }
        let (chunks, feed) = AsyncStream.makeStream(of: AudioChunk.self)
        feed.yield(AudioChunk(samples: [0, 0.1, 0.2], sampleRate: 16_000))
        let events: [LiveTranscriptEvent] =
            await SuiteWait.value("the live stream to end") {
                var events: [LiveTranscriptEvent] = []
                for await event in transcriber(system, locale: "en_GB").live(chunks) { events.append(event) }
                return events
            } ?? []
        feed.finish()
        #expect(events.count == 1)
        guard case .failed(let error)? = events.first else {
            Issue.record("Live text that cannot start fails once.")
            return
        }
        #expect(error.code.rawValue == row.1)
    }

    private func process(
        environment: [String: String] = [:], bundles: [String] = ["/Applications/Knot.app"], name: String = "Knot"
    ) -> SpeechInstallPolicy.Process {
        SpeechInstallPolicy.Process(environment: environment, bundlePaths: bundles, processName: name)
    }

    @Test func theInstallPolicyRefusesATestAndAnAgent() {
        // The app itself may install.
        #expect(SpeechInstallPolicy.refusal(for: process()) == nil)
        // An agent's thread, by KNOT_AGENT=1 only.
        #expect(SpeechInstallPolicy.refusal(for: process(environment: ["KNOT_AGENT": "1"])) == .agent)
        #expect(SpeechInstallPolicy.refusal(for: process(environment: ["KNOT_AGENT": "0"])) == nil)
        // A test, by each of its signs.
        for variable in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(SpeechInstallPolicy.refusal(for: process(environment: [variable: "x"])) == .test, "\(variable)")
        }
        for runner in ["xctest", "swiftpm-testing-helper"] {
            #expect(SpeechInstallPolicy.refusal(for: process(name: runner)) == .test, "\(runner)")
        }
        #expect(
            SpeechInstallPolicy.refusal(
                for: process(bundles: ["/Applications/Knot.app", "/tmp/KnotKitPackageTests.xctest"]))
                == .test)
    }

    @Test func aNamedProcessCanAddARefusalAndNeverTakeOneAway() {
        let clean = process()
        let test = process(bundles: ["/tmp/KnotKitPackageTests.xctest"])
        let agent = process(environment: ["KNOT_AGENT": "1"])
        // A clean named process beside a test process is still refused.
        #expect(SpeechInstallPolicy.refusal(named: clean, actual: test) == .test)
        #expect(SpeechInstallPolicy.refusal(named: clean, actual: agent) == .agent)
        // A named refusal beside a clean process is a refusal.
        #expect(SpeechInstallPolicy.refusal(named: agent, actual: clean) == .agent)
        #expect(SpeechInstallPolicy.refusal(named: test, actual: clean) == .test)
        // Only two clean processes may install.
        #expect(SpeechInstallPolicy.refusal(named: clean, actual: clean) == nil)
        // And in this process, whatever a test names, the answer is a refusal.
        #expect(SpeechInstallPolicy.refusal(named: clean, actual: .current) != nil)
    }

    @Test func thisTestProcessMayNotInstall() {
        #expect(SpeechInstallPolicy.refusal(for: .current) != nil, "A test process is refused, whoever started it.")
    }

    @Test(arguments: [SpeechInstallPolicy.Refusal.test, .agent])
    func theLiveSystemsInstallRefusesBeforeItAsksTheSystem(_ sign: SpeechInstallPolicy.Refusal) async {
        // The process is scripted, so a broken check here could not reach the system either way:
        // the refusal comes before any call, and the error says which sign it read.
        let signs =
            sign == .agent
            ? process(environment: ["KNOT_AGENT": "1"]) : process(bundles: ["/tmp/KnotKitPackageTests.xctest"])
        let system = LiveSpeechSystem(process: { signs })
        do {
            _ = try await system.install(Locale(identifier: "en_US")) { _ in }
            Issue.record("The live install must refuse a test and an agent.")
        } catch {
            #expect(error as? SpeechInstallRefused == SpeechInstallRefused(refusal: sign))
        }
        // The transcriber reads the refusal as a model that stays missing: a deferral.
        #expect(SpeechErrorMapping.installError(SpeechInstallRefused(refusal: sign)).isDeferral)
    }

    @Test func theMappingNamesTheSDKsOwnCodes() {
        // SpeechRules names the codes by number, so that it compiles where Speech does not.
        #expect(SFSpeechError.errorDomain == SpeechErrorMapping.speechDomain)
        #expect(SFSpeechError.Code.audioReadFailed.rawValue == SpeechErrorMapping.SpeechCode.audioReadFailed)
        #expect(SFSpeechError.Code.noModel.rawValue == SpeechErrorMapping.SpeechCode.noModel)
        #expect(
            SFSpeechError.Code.assetLocaleNotAllocated.rawValue
                == SpeechErrorMapping.SpeechCode.assetLocaleNotAllocated)
        #expect(
            SFSpeechError.Code.tooManyAssetLocalesAllocated.rawValue
                == SpeechErrorMapping.SpeechCode.tooManyAssetLocalesAllocated)
        #expect(
            SFSpeechError.Code.cannotAllocateUnsupportedLocale.rawValue
                == SpeechErrorMapping.SpeechCode.cannotAllocateUnsupportedLocale)
        #expect(
            SFSpeechError.Code.insufficientResources.rawValue == SpeechErrorMapping.SpeechCode.insufficientResources)
        #expect(SFSpeechError.Code.audioDisordered.rawValue == SpeechErrorMapping.SpeechCode.audioDisordered)
    }

    @Test func theLiveEntryPointWiresTheRealTranscriber() async {
        let environment = KnotSpeechLive.wire(.unavailable)
        #expect(environment.transcriber is SpeechAnalyzerTranscriber)
        // The settings are still the unavailable ones here: the variant falls back to the region.
        #expect(!environment.transcriber.locale.identifier.isEmpty)
    }
#endif

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotSpeechLive.self) == "KnotSpeech.KnotSpeechLive")
}
