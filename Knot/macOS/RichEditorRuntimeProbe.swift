#if DEBUG
import AppKit
import KnotKit
import SwiftUI
import WebKit

@MainActor
final class RichEditorRuntimeProbe {
    private static var active: RichEditorRuntimeProbe?

    private let token: String
    private let mode: String
    private let startedAt = ContinuousClock.now
    private let suiteName: String
    private let defaults: UserDefaults
    private let supportDirectory: URL
    private let model: EditorModel
    private var coordinator: RichBridgeCoordinator?
    private var scripts: WKUserContentController?
    private var webView: WKWebView?
    private var window: NSWindow?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    private var readyMilliseconds: Double?

    static func launchIfRequested() -> Bool {
        guard let token = ProcessInfo.processInfo.environment["KNOT_RUNTIME_PROBE_TOKEN"],
              !token.isEmpty,
              token.count <= 64,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            return false
        }
        let mode = ProcessInfo.processInfo.environment["KNOT_RUNTIME_PROBE_MODE"] ?? "rich"
        guard ["rich", "onboarding", "quick"].contains(mode) else { return false }
        let probe = RichEditorRuntimeProbe(token: token, mode: mode)
        active = probe
        Task { await probe.run() }
        return true
    }

    private init(token: String, mode: String) {
        self.token = token
        self.mode = mode
        self.suiteName = "Knot-RuntimeProbe-" + token
        self.defaults = UserDefaults(suiteName: suiteName)!
        self.supportDirectory = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        self.model = EditorModel(
            vaultStore: VaultStore(defaults: defaults),
            defaults: defaults,
            supportDirectory: supportDirectory
        )
    }

    private func run() async {
        do {
            for _ in 0..<200 {
                if model.storageAvailable { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard model.storageAvailable, let store = model.store else {
                throw ProbeError.storageUnavailable
            }
            if mode != "rich" {
                presentNativeSurface()
                return
            }

            let draftID = DraftID()
            let markdown = "# Runtime fixture\n\n" + String(
                repeating: "chunked initialization remains locally inspectable ",
                count: 8_000
            )
            try await store.checkpointDraft(try DraftCheckpoint(
                id: draftID,
                profileID: nil,
                revision: .zero,
                markdown: Data(markdown.utf8),
                routingChoice: .inbox
            ))
            let seed = RichDraftSeed(
                draftID: draftID,
                revision: .zero,
                markdown: markdown,
                blocksJSON: nil,
                opaqueSourcesJSON: nil,
                assets: []
            )
            try present(seed: seed)
        } catch {
            finish(result: ["ok": false, "error": bounded(error.localizedDescription)])
        }
    }

    private func present(seed: RichDraftSeed) throws {
        let sessionID = UUID()
        let previewStore = AssetPreviewStore(sessionID: sessionID)
        let coordinator = RichBridgeCoordinator(
            model: model,
            seed: seed,
            sessionID: sessionID,
            previewStore: previewStore
        ) { [weak self] state in
            guard state.ready, let self else { return }
            if self.readyMilliseconds == nil { self.readyMilliseconds = self.elapsedMilliseconds() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.inspectRenderedEditor()
            }
        }

        let manifest = try EditorBundleManifest.load()
        guard manifest.buildID == gutenbergEditorBuildID else { throw ProbeError.bundleMismatch }
        let scripts = WKUserContentController()
        scripts.add(coordinator, name: "knotEditor")
        let bootstrap: [String: Any] = [
            "version": 1,
            "sessionID": sessionID.uuidString.lowercased(),
            "draftID": seed.draftID.description,
            "revision": seed.revision.rawValue
        ]
        let bootstrapData = try JSONSerialization.data(withJSONObject: bootstrap)
        guard let bootstrapJSON = String(data: bootstrapData, encoding: .utf8) else {
            throw ProbeError.invalidBootstrap
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = scripts
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(
            try EditorBundleSchemeHandler(manifest: manifest, bootstrapJSON: bootstrapJSON),
            forURLScheme: "knot-editor"
        )
        configuration.setURLSchemeHandler(
            AssetPreviewSchemeHandler(store: previewStore),
            forURLScheme: "knot-asset"
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700),
            configuration: configuration
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        self.coordinator = coordinator
        self.scripts = scripts
        self.webView = webView
        self.window = window
        webView.load(URLRequest(url: editorEntryURL, cachePolicy: .reloadIgnoringLocalCacheData))
        coordinator.startReadinessTimer()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, !self.finished else { return }
            self.finish(result: ["ok": false, "error": "Runtime probe timed out."])
        }
    }

    private func presentNativeSurface() {
        let size: NSSize
        let root: AnyView
        if mode == "onboarding" {
            size = NSSize(width: Theme.onboardingWidth, height: Theme.onboardingHeight)
            root = AnyView(OnboardingView(model: model, onDone: {}))
        } else {
            size = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
            model.content = "A durable quick-capture draft with automatic routing."
            root = AnyView(EditorView(model: model))
        }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentMinSize = size
        window.setContentSize(size)
        window.orderFrontRegardless()
        self.window = window
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            self?.inspectNativeSurface()
        }
    }

    private func inspectNativeSurface() {
        guard !finished, let view = window?.contentView,
              view.bounds.width > 300, view.bounds.height > 250 else {
            finish(result: ["ok": false, "error": "Native surface did not produce a usable layout."])
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            finish(result: ["ok": false, "error": "Native surface could not allocate a snapshot."])
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            finish(result: ["ok": false, "error": "Native surface snapshot encoding failed."])
            return
        }
        do {
            try png.write(to: probeURL(extension: "png"), options: .atomic)
            finish(result: [
                "ok": true, "mode": mode, "width": view.bounds.width,
                "height": view.bounds.height, "screenshotBytes": png.count
            ])
        } catch {
            finish(result: ["ok": false, "error": bounded(error.localizedDescription)])
        }
    }

    private func inspectRenderedEditor() async {
        guard !finished, let webView else { return }
        do {
            let value = try await webView.callAsyncJavaScript(
                """
                const root = document.getElementById("root");
                const editor = document.querySelector(".editor-styles-wrapper");
                const blocks = Array.from(document.querySelectorAll(".block-editor-block-list__block"));
                return {
                  href: location.href,
                  rootChildren: root ? root.childElementCount : 0,
                  textLength: editor ? editor.textContent.length : 0,
                  textPrefix: editor ? editor.textContent.slice(0, 64) : "",
                  viewportWidth: document.documentElement.clientWidth,
                  viewportHeight: document.documentElement.clientHeight,
                  editorWidth: editor ? editor.getBoundingClientRect().width : 0,
                  editorHeight: editor ? editor.getBoundingClientRect().height : 0,
                  blockCount: blocks.length,
                  visibleBlockCount: blocks.filter((item) => {
                    const rect = item.getBoundingClientRect();
                    return rect.width > 0 && rect.height > 0;
                  }).length,
                  resources: Array.from(document.scripts).map((item) => item.src)
                };
                """,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            guard let result = value as? [String: Any],
                  result["href"] as? String == editorEntryURL.absoluteString,
                  (result["rootChildren"] as? NSNumber)?.intValue ?? 0 > 0,
                  (result["textLength"] as? NSNumber)?.intValue ?? 0 > 100_000,
                  (result["textPrefix"] as? String)?.contains("Runtime fixture") == true,
                  (result["viewportWidth"] as? NSNumber)?.doubleValue ?? 0 > 500,
                  (result["viewportHeight"] as? NSNumber)?.doubleValue ?? 0 > 300,
                  (result["editorWidth"] as? NSNumber)?.doubleValue ?? 0 > 400,
                  (result["editorHeight"] as? NSNumber)?.doubleValue ?? 0 > 100,
                  (result["blockCount"] as? NSNumber)?.intValue ?? 0 > 0,
                  (result["visibleBlockCount"] as? NSNumber)?.intValue ?? 0 > 0,
                  let resources = result["resources"] as? [String],
                  !resources.isEmpty,
                  resources.allSatisfy({ $0.hasPrefix("knot-editor://") }) else {
                throw ProbeError.renderingFailed
            }
            let snapshot = try await webView.takeSnapshot(configuration: nil)
            guard let tiff = snapshot.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ProbeError.renderingFailed
            }
            try png.write(to: probeURL(extension: "png"), options: .atomic)
            finish(result: [
                "ok": true,
                "bridgeReady": true,
                "blockCount": result["blockCount"] ?? 0,
                "visibleBlockCount": result["visibleBlockCount"] ?? 0,
                "textLength": result["textLength"] ?? 0,
                "resourceCount": resources.count,
                "externalResourceCount": 0,
                "readyMilliseconds": readyMilliseconds ?? elapsedMilliseconds(),
                "screenshotBytes": png.count
            ])
        } catch {
            finish(result: ["ok": false, "error": bounded(error.localizedDescription)])
        }
    }

    private func finish(result: [String: Any]) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        coordinator?.invalidate()
        scripts?.removeScriptMessageHandler(forName: "knotEditor")
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()

        var payload = result
        payload["version"] = 1
        payload["token"] = token
        payload["mode"] = mode
        let output = probeURL(extension: "json")
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch {
            fputs("Knot runtime probe could not write its result.\n", stderr)
        }

        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: supportDirectory)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.terminate(nil)
        }
    }

    private func probeURL(extension fileExtension: String) -> URL {
        let prefix = mode == "rich" ? "knot-rich-runtime-probe-" : "knot-" + mode + "-runtime-probe-"
        return FileManager.default.temporaryDirectory
            .appending(path: prefix + token + "." + fileExtension)
    }

    private func elapsedMilliseconds() -> Double {
        let values = (ContinuousClock.now - startedAt).components
        return Double(values.seconds) * 1_000
            + Double(values.attoseconds) / 1_000_000_000_000_000
    }

    private func bounded(_ value: String) -> String { String(value.prefix(512)) }

    private enum ProbeError: Error, LocalizedError {
        case storageUnavailable, bundleMismatch, invalidBootstrap, renderingFailed

        var errorDescription: String? {
            switch self {
            case .storageUnavailable: "Disposable storage did not initialize."
            case .bundleMismatch: "Bundled editor identity did not match the native app."
            case .invalidBootstrap: "Native bootstrap could not be encoded."
            case .renderingFailed: "The production editor did not produce visible local content."
            }
        }
    }
}
#endif
