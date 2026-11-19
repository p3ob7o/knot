import AVFoundation
import Speech
import SwiftUI

// Runs the probe once at launch, prints one JSON object per line on standard output with the
// prefix "probe:", and exits. `simctl launch --console-pty` shows the lines.
@main
struct SpeechProbeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Speech probe")
                .task {
                    await SpeechProbe.run()
                    exit(0)
                }
        }
    }
}

enum SpeechProbe {
    static func emit(_ step: String, _ fields: [String: Any]) {
        var object = fields
        object["step"] = step
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        print("probe: " + String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }

    static func describe(_ error: any Error) -> [String: Any] {
        let ns = error as NSError
        return ["errorType": String(describing: type(of: error)), "domain": ns.domain, "code": ns.code,
                "message": ns.localizedDescription]
    }

    static func status(_ value: AssetInventory.Status) -> String {
        switch value {
        case .unsupported: "unsupported"
        case .supported: "supported"
        case .downloading: "downloading"
        case .installed: "installed"
        @unknown default: "unknown"
        }
    }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let locale = Locale(identifier: "en_US")
        emit("device", [
            "simulator": env["SIMULATOR_MODEL_IDENTIFIER"] != nil,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "model": env["SIMULATOR_MODEL_IDENTIFIER"] ?? "device",
        ])
        emit("availability", [
            "speechTranscriberIsAvailable": SpeechTranscriber.isAvailable,
            "supportedEnglish": await SpeechTranscriber.supportedLocales.map(\.identifier).filter { $0.hasPrefix("en") }.sorted(),
            "installed": await SpeechTranscriber.installedLocales.map(\.identifier).sorted(),
            "dictationSupportedEnglish": await DictationTranscriber.supportedLocales.map(\.identifier).filter { $0.hasPrefix("en") }.sorted(),
            "dictationInstalled": await DictationTranscriber.installedLocales.map(\.identifier).sorted(),
            "onDeviceRecognizer": SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false,
        ])

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let dictation = DictationTranscriber(locale: locale, preset: .longDictation)
        emit("status", [
            "speechTranscriber": status(await AssetInventory.status(forModules: [transcriber])),
            "dictationTranscriber": status(await AssetInventory.status(forModules: [dictation])),
            "speechFormats": await transcriber.availableCompatibleAudioFormats.map(\.description),
        ])

        // The one install the proof is allowed, bounded to two minutes.
        if env["KNOT_PROBE_INSTALL"] == "1" {
            let start = Date()
            do {
                let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                if let request {
                    emit("install", ["request": "returned", "unitCount": request.progress.totalUnitCount])
                    let download = Task { try await request.downloadAndInstall() }
                    let timer = Task { try await Task.sleep(for: .seconds(120)); download.cancel() }
                    do {
                        try await download.value
                        emit("install", ["result": "done", "seconds": Date().timeIntervalSince(start)])
                    } catch {
                        emit("install", ["result": "failed", "seconds": Date().timeIntervalSince(start)].merging(describe(error)) { a, _ in a })
                    }
                    timer.cancel()
                } else {
                    emit("install", ["request": "nil", "seconds": Date().timeIntervalSince(start)])
                }
            } catch {
                emit("install", ["request": "threw", "seconds": Date().timeIntervalSince(start)].merging(describe(error)) { a, _ in a })
            }
            emit("statusAfterInstall", [
                "speechTranscriber": status(await AssetInventory.status(forModules: [transcriber])),
                "installed": await SpeechTranscriber.installedLocales.map(\.identifier).sorted(),
                "reserved": await AssetInventory.reservedLocales.map(\.identifier),
            ])
        }

        if let path = env["KNOT_PROBE_AUDIO"] {
            let url = URL(fileURLWithPath: path)
            await transcribe(url, module: SpeechTranscriber(locale: locale, preset: .transcription), label: "speechTranscriber")
            await transcribe(url, module: DictationTranscriber(locale: locale, preset: .longDictation), label: "dictationTranscriber")
        }
    }

    static func transcribe(_ url: URL, module: some SpeechModule, label: String) async {
        let start = Date()
        do {
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [module])
            let words = Task { () throws -> Int in
                var count = 0
                for try await result in module.results {
                    if let text = (result as? SpeechTranscriber.Result)?.text ?? (result as? DictationTranscriber.Result)?.text {
                        count += String(text.characters).split(separator: " ").count
                    }
                }
                return count
            }
            let last = try await analyzer.analyzeSequence(from: file)
            if let last { try await analyzer.finalizeAndFinish(through: last) } else { await analyzer.cancelAndFinishNow() }
            emit("transcribe", ["module": label, "result": "ok", "words": try await words.value,
                                "seconds": Date().timeIntervalSince(start)])
        } catch {
            emit("transcribe", ["module": label, "result": "failed", "seconds": Date().timeIntervalSince(start)]
                .merging(describe(error)) { a, _ in a })
        }
    }
}
