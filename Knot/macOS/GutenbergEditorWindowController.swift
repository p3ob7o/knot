import AppKit
import CryptoKit
import KnotKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

let gutenbergEditorBuildID = "knot-gutenberg-20260908-v1"
let editorEntryURL = URL(string: "knot-editor://bundle/index.html")!
private let bridgeMessageLimit = 256 * 1_024
private let bridgeDocumentLimit = 8 * 1_024 * 1_024
private let bridgeBlockLimit = 16 * 1_024 * 1_024
private let bridgeChunkLimit = 176 * 1_024
private let bridgeRequestLimit = 32

@MainActor
final class GutenbergEditorWindowController: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private let surfaces: SurfaceCoordinator
    private var window: NSWindow?
    private var previewStore: AssetPreviewStore?
    private var allowsClose = false
    private var activeSessionID: UUID?

    init(model: EditorModel, surfaces: SurfaceCoordinator) {
        self.model = model
        self.surfaces = surfaces
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        Task {
            do {
                let seed = try await model.promoteCurrentDraftToRich()
                present(seed: seed)
            } catch {
                model.status = .error(error.localizedDescription)
            }
        }
    }

    private func present(seed: RichDraftSeed) {
        let sessionID = UUID()
        let previews = AssetPreviewStore(sessionID: sessionID)
        for asset in seed.assets {
            previews.insert(id: asset.id, data: asset.data, mediaType: asset.mediaType)
        }
        activeSessionID = sessionID
        allowsClose = false
        previewStore = previews
        let host = NSHostingController(rootView: GutenbergEditorView(
            model: model,
            seed: seed,
            sessionID: sessionID,
            previewStore: previews,
            onClose: { [weak self] in
                self?.allowsClose = true
                self?.window?.close()
            }
        ))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.title = "Knot Rich Editor"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.setContentSize(NSSize(width: 760, height: 640))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        surfaces.showRegular(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !allowsClose else { return true }
        NotificationCenter.default.post(name: .knotRichCloseRequested, object: activeSessionID)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow { surfaces.regularWindowDidClose(closing) }
        previewStore?.removeAll()
        previewStore = nil
        activeSessionID = nil
        allowsClose = false
        window = nil
    }
}

private struct GutenbergEditorView: View {
    @Bindable var model: EditorModel
    let seed: RichDraftSeed
    let sessionID: UUID
    let previewStore: AssetPreviewStore
    let onClose: () -> Void

    @State private var webView: WKWebView?
    @State private var isReady = false
    @State private var isSaving = false
    @State private var status = "Loading editor..."
    @State private var closeFailurePresented = false
    @State private var closeFailureMessage = ""
    @State private var closeAttemptID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Rich Editor").font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityLabel("Editor status: \(status)")
                Button("Close", action: closeAfterCheckpoint).disabled(isSaving)
                Button {
                    isSaving = true
                    sendCommand("save")
                } label: {
                    if isSaving { ProgressView().controlSize(.small).frame(width: 38) }
                    else { Text("Save").frame(width: 38) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady || isSaving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
            GutenbergWebView(
                model: model,
                seed: seed,
                sessionID: sessionID,
                previewStore: previewStore,
                webView: $webView,
                onState: { value in
                    status = value.message
                    isReady = value.ready
                    isSaving = value.saving
                }
            )
        }
        .frame(minWidth: 640, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .knotRichCloseRequested)) { notification in
            guard notification.object as? UUID == sessionID else { return }
            closeAfterCheckpoint()
        }
        .alert("Local checkpoint failed", isPresented: $closeFailurePresented) {
            Button("Keep Open", role: .cancel) {}
            Button("Export") { Task { await exportDraft() } }
            Button("Discard", role: .destructive) { Task { await discardAndClose() } }
        } message: {
            Text(closeFailureMessage)
        }
    }

    private func closeAfterCheckpoint() {
        guard isReady, let webView else { onClose(); return }
        let attemptID = UUID()
        closeAttemptID = attemptID
        isSaving = true
        status = "Saving locally before close..."
        webView.callAsyncJavaScript(
            "return await window.KnotCheckpointForClose()",
            arguments: [:], in: nil, in: .page
        ) { result in
            Task { @MainActor in
                guard closeAttemptID == attemptID else { return }
                closeAttemptID = nil
                isSaving = false
                switch result {
                case .success: onClose()
                case .failure(let error):
                    closeFailureMessage = "The latest rich draft could not be confirmed locally: " + error.localizedDescription
                    closeFailurePresented = true
                }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard closeAttemptID == attemptID else { return }
            closeAttemptID = nil
            isSaving = false
            closeFailureMessage = "The editor did not acknowledge its local checkpoint. The last acknowledged draft remains recoverable."
            closeFailurePresented = true
        }
    }

    private func exportDraft() async {
        do {
            let data = try await model.exportRichDraft(seed.draftID)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Knot-Rich-Draft.md"
            panel.allowedContentTypes = [.plainText]
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: [.atomic])
            status = "Exported the last acknowledged draft"
        } catch { status = error.localizedDescription }
    }

    private func discardAndClose() async {
        do { try await model.discardRichDraft(seed.draftID); onClose() }
        catch { status = error.localizedDescription }
    }

    private func sendCommand(_ name: String) {
        guard let webView else { isSaving = false; return }
        let message: [String: Any] = [
            "version": 1,
            "sessionID": sessionID.uuidString.lowercased(),
            "draftID": seed.draftID.description,
            "revision": seed.revision.rawValue,
            "requestID": UUID().uuidString.lowercased(),
            "type": "command",
            "payload": ["name": name]
        ]
        webView.callAsyncJavaScript(
            "window.KnotNativeReceive(message)",
            arguments: ["message": message],
            in: nil,
            in: .page,
            completionHandler: { result in
            if case .failure(let error) = result {
                Task { @MainActor in
                    status = "Could not contact editor: \(error.localizedDescription)"
                    isSaving = false
                }
            }
            }
        )
    }
}

extension Notification.Name {
    static let knotRichCloseRequested = Notification.Name("knot.richCloseRequested")
}

struct RichPresentationState: Equatable {
    let message: String
    let ready: Bool
    let saving: Bool
}

private struct GutenbergWebView: NSViewRepresentable {
    let model: EditorModel
    let seed: RichDraftSeed
    let sessionID: UUID
    let previewStore: AssetPreviewStore
    @Binding var webView: WKWebView?
    let onState: (RichPresentationState) -> Void

    func makeCoordinator() -> RichBridgeCoordinator {
        RichBridgeCoordinator(
            model: model,
            seed: seed,
            sessionID: sessionID,
            previewStore: previewStore,
            onState: onState
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        do {
            let manifest = try EditorBundleManifest.load()
            guard manifest.buildID == gutenbergEditorBuildID else { throw RichBridgeError.bundleMismatch }
            let scripts = WKUserContentController()
            scripts.add(context.coordinator, name: "knotEditor")
            let bootstrap: [String: Any] = [
                "version": 1,
                "sessionID": sessionID.uuidString.lowercased(),
                "draftID": seed.draftID.description,
                "revision": seed.revision.rawValue
            ]
            let data = try JSONSerialization.data(withJSONObject: bootstrap)
            guard let json = String(data: data, encoding: .utf8) else { throw RichBridgeError.invalidMessage }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController = scripts
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.setURLSchemeHandler(try EditorBundleSchemeHandler(manifest: manifest, bootstrapJSON: json), forURLScheme: "knot-editor")
            configuration.setURLSchemeHandler(AssetPreviewSchemeHandler(store: previewStore), forURLScheme: "knot-asset")
            let view = WKWebView(frame: .zero, configuration: configuration)
            context.coordinator.webView = view
            view.navigationDelegate = context.coordinator
            view.uiDelegate = context.coordinator
            view.setValue(false, forKey: "drawsBackground")
            DispatchQueue.main.async { webView = view }
            view.load(URLRequest(url: editorEntryURL, cachePolicy: .reloadIgnoringLocalCacheData))
            context.coordinator.startReadinessTimer()
            return view
        } catch {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let fallback = WKWebView(frame: .zero, configuration: configuration)
            DispatchQueue.main.async {
                onState(RichPresentationState(message: "Editor resources failed validation. Source draft is preserved.", ready: false, saving: false))
                webView = fallback
            }
            return fallback
        }
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: RichBridgeCoordinator) {
        coordinator.invalidate()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "knotEditor")
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
    }
}

private enum RichBridgeError: Error, LocalizedError {
    case resourcesMissing, bundleMismatch, invalidResource, invalidMessage, staleMessage
    case requestLimit, revisionConflict, transferInvalid, externalURLDenied

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "Editor resources are missing."
        case .bundleMismatch: "Editor resources do not match this app build."
        case .invalidResource: "An editor resource failed integrity validation."
        case .invalidMessage: "The editor sent an invalid message."
        case .staleMessage: "The editor message belongs to an obsolete session."
        case .requestLimit: "The editor has too many active requests."
        case .revisionConflict: "A newer draft revision is already stored."
        case .transferInvalid: "The attachment transfer failed validation."
        case .externalURLDenied: "That external link is not permitted."
        }
    }
}

struct EditorBundleManifest: Decodable {
    struct Resource: Decodable { let sha256: String; let bytes: Int; let mimeType: String }
    let version: Int
    let buildID: String
    let entry: String
    let files: [String: Resource]
    let root: URL

    private enum CodingKeys: String, CodingKey { case version, buildID, entry, files }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        buildID = try values.decode(String.self, forKey: .buildID)
        entry = try values.decode(String.self, forKey: .entry)
        files = try values.decode([String: Resource].self, forKey: .files)
        root = decoder.userInfo[.editorBundleRoot] as? URL ?? URL(fileURLWithPath: "/")
    }

    static func load() throws -> EditorBundleManifest {
        guard let root = Bundle.main.url(forResource: "dist", withExtension: nil),
              let data = try? Data(contentsOf: root.appending(path: "knot-manifest.json")) else {
            throw RichBridgeError.resourcesMissing
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.editorBundleRoot] = root
        let manifest = try decoder.decode(EditorBundleManifest.self, from: data)
        guard manifest.version == 1, manifest.entry == "index.html", manifest.files[manifest.entry] != nil else {
            throw RichBridgeError.invalidResource
        }
        return manifest
    }

    func data(for path: String) throws -> (Data, Resource) {
        guard !path.isEmpty, !path.contains(".."), !path.contains("\\"), let resource = files[path] else {
            throw RichBridgeError.invalidResource
        }
        let data = try Data(contentsOf: root.appending(path: path), options: [.mappedIfSafe])
        guard data.count == resource.bytes, Self.hash(data) == resource.sha256 else { throw RichBridgeError.invalidResource }
        return (data, resource)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension CodingUserInfoKey {
    static let editorBundleRoot = CodingUserInfoKey(rawValue: "KnotEditorBundleRoot")!
}

final class EditorBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let noncePlaceholder = "__KNOT_CSP_NONCE__"
    private let manifest: EditorBundleManifest
    private let bootstrapScript: Data
    private let cspNonce: String

    init(manifest: EditorBundleManifest, bootstrapJSON: String) throws {
        guard bootstrapJSON.utf8.count <= 16 * 1_024 else { throw RichBridgeError.invalidMessage }
        self.manifest = manifest
        self.bootstrapScript = Data(("window.KnotBootstrap = " + bootstrapJSON + ";").utf8)
        self.cspNonce = UUID().uuidString.lowercased()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url, url.scheme == "knot-editor", url.host == "bundle",
                  url.query == nil, url.fragment == nil else { throw RichBridgeError.invalidResource }
            let path = url.path == "/" ? manifest.entry : String(url.path.dropFirst())
            let data: Data
            let mimeType: String
            if path == "session-bootstrap.js" {
                data = bootstrapScript
                mimeType = "text/javascript; charset=utf-8"
            } else {
                let resource = try manifest.data(for: path)
                mimeType = resource.1.mimeType
                if path == manifest.entry {
                    guard var html = String(data: resource.0, encoding: .utf8),
                          html.contains(Self.noncePlaceholder) else {
                        throw RichBridgeError.invalidResource
                    }
                    html = html.replacingOccurrences(of: Self.noncePlaceholder, with: cspNonce)
                    data = Data(html.utf8)
                } else {
                    data = resource.0
                }
            }
            let mediaType = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)
            let encoding = mimeType.lowercased().contains("charset=utf-8") ? "utf-8" : nil
            let response = URLResponse(
                url: url, mimeType: mediaType, expectedContentLength: data.count,
                textEncodingName: encoding
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

final class AssetPreviewStore {
    private let lock = NSLock()
    private let sessionID: UUID
    private var values: [AssetID: (Data, String)] = [:]
    init(sessionID: UUID) { self.sessionID = sessionID }

    func insert(id: AssetID, data: Data, mediaType: String) {
        lock.withLock { values[id] = (data, mediaType) }
    }
    func value(session: String, asset: String) -> (Data, String)? {
        guard session.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame,
              let uuid = UUID(uuidString: asset) else { return nil }
        return lock.withLock { values[AssetID(rawValue: uuid)] }
    }
    func removeAll() { lock.withLock { values.removeAll(keepingCapacity: false) } }
}

final class AssetPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: AssetPreviewStore
    init(store: AssetPreviewStore) { self.store = store }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "knot-asset", let session = url.host,
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2,
              let value = store.value(session: session, asset: url.lastPathComponent),
              task.request.value(forHTTPHeaderField: "Range") == nil else {
            task.didFailWithError(RichBridgeError.invalidResource)
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: value.1, expectedContentLength: value.0.count, textEncodingName: nil))
        task.didReceive(value.0)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
final class RichBridgeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private struct OutgoingInitialization {
        let data: Data
        let sha256: String
        let expiresAt: ContinuousClock.Instant
    }

    private struct Transfer {
        let filename: String
        let mediaType: String
        let totalBytes: Int
        let sha256: String
        let expiresAt: ContinuousClock.Instant
        var nextSequence = 0
        var data = Data()
    }

    private let model: EditorModel
    private let sessionID: UUID
    private let draftID: DraftID
    private let previewStore: AssetPreviewStore
    private let onState: (RichPresentationState) -> Void
    private var revision: Revision
    private var markdown: String
    private var blocksJSON: Data?
    private var opaqueSourcesJSON: Data?
    private var assetIDs = Set<AssetID>()
    private var transfers: [UUID: Transfer] = [:]
    private var initializationTransfers: [UUID: OutgoingInitialization] = [:]
    private let checkpointTransfers = RichCheckpointTransferStore()
    private var recentRequests: [UUID] = []
    private var ready = false
    private var valid = true
    private var readinessTask: Task<Void, Never>?
    weak var webView: WKWebView?

    init(model: EditorModel, seed: RichDraftSeed, sessionID: UUID, previewStore: AssetPreviewStore, onState: @escaping (RichPresentationState) -> Void) {
        self.model = model
        self.sessionID = sessionID
        self.draftID = seed.draftID
        self.revision = seed.revision
        self.markdown = seed.markdown
        self.blocksJSON = seed.blocksJSON
        self.opaqueSourcesJSON = seed.opaqueSourcesJSON
        self.assetIDs = Set(seed.assets.map(\.id))
        self.previewStore = previewStore
        self.onState = onState
    }

    func startReadinessTimer() {
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !self.ready, self.valid else { return }
            self.onState(RichPresentationState(message: "Editor startup timed out. Source draft is preserved; close and retry.", ready: false, saving: false))
        }
    }

    func invalidate() {
        valid = false
        readinessTask?.cancel()
        transfers.removeAll()
        initializationTransfers.removeAll()
        checkpointTransfers.removeAll()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard valid, let sourceView = message.webView, sourceView === webView,
              message.frameInfo.isMainFrame,
              sourceView.url == editorEntryURL,
              let body = message.body as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: body), encoded.count <= bridgeMessageLimit,
              (body["version"] as? Int) == 1,
              (body["sessionID"] as? String)?.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame,
              (body["draftID"] as? String) == draftID.description,
              let requestText = body["requestID"] as? String, let requestID = UUID(uuidString: requestText),
              let type = body["type"] as? String,
              let messageRevision = (body["revision"] as? NSNumber)?.int64Value,
              messageRevision >= 0, messageRevision <= 9_007_199_254_740_991,
              let payload = body["payload"] as? [String: Any] else { return }
        guard !recentRequests.contains(requestID) else {
            sendError(requestID: requestID, code: "duplicateRequest", message: "Duplicate request ignored.")
            return
        }
        recentRequests.append(requestID)
        if recentRequests.count > bridgeRequestLimit { recentRequests.removeFirst() }
        cleanupTransfers()

        switch type {
        case "ready": handleReady(requestID: requestID, payload: payload)
        case "initializeChunkRequested": handleInitializeChunk(requestID: requestID, payload: payload)
        case "checkpoint": handleCheckpoint(requestID: requestID, payload: payload)
        case "checkpointBegin", "checkpointChunk", "checkpointEnd":
            do {
                if let complete = try checkpointTransfers.accept(type: type, payload: payload) {
                    handleCheckpoint(requestID: requestID, payload: complete)
                } else {
                    send(type: "checkpointAck", requestID: requestID, payload: ["state": "accepted"])
                }
            } catch {
                checkpointTransfers.removeAll()
                sendError(requestID: requestID, code: "checkpointTransfer", message: "Checkpoint transfer failed validation.")
            }
        case "assetPickerRequested": handleAssetPicker(requestID: requestID, payload: payload)
        case "assetImportBegin": handleAssetBegin(requestID: requestID, payload: payload)
        case "assetImportChunk": handleAssetChunk(requestID: requestID, payload: payload)
        case "assetImportEnd": handleAssetEnd(requestID: requestID, payload: payload)
        case "saveRequested": handleSave(requestID: requestID, payload: payload)
        case "openExternal": handleExternal(requestID: requestID, payload: payload)
        case "editorError":
            let category = (payload["category"] as? String ?? "Editor error").prefix(512)
            onState(RichPresentationState(message: String(category), ready: false, saving: false))
            send(type: "recoverableError", requestID: requestID, payload: ["error": errorPayload(code: "editorError", message: "Source draft remains available.")])
        default: sendError(requestID: requestID, code: "unknownType", message: "Unknown editor request.")
        }
    }

    private func handleReady(requestID: UUID, payload: [String: Any]) {
        guard payload["buildID"] as? String == gutenbergEditorBuildID,
              (payload["supportedVersions"] as? [Int])?.contains(1) == true else {
            sendError(requestID: requestID, code: "bundleMismatch", message: RichBridgeError.bundleMismatch.localizedDescription)
            return
        }
        let limits: [String: Any] = [
            "markdownBytes": bridgeDocumentLimit, "blockJSONBytes": bridgeBlockLimit,
            "assetChunkBytes": bridgeChunkLimit
        ]
        let initialization: [String: Any] = [
            "markdown": markdown,
            "blocksJSON": blocksJSON.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull(),
            "opaqueSourcesJSON": opaqueSourcesJSON.flatMap { String(data: $0, encoding: .utf8) } ?? NSNull(),
            "buildID": gutenbergEditorBuildID, "assetIDs": assetIDs.map(\.description).sorted(),
            "limits": limits
        ]
        guard JSONSerialization.isValidJSONObject(initialization),
              let encoded = try? JSONSerialization.data(withJSONObject: initialization),
              encoded.count <= bridgeDocumentLimit + bridgeBlockLimit else {
            sendError(requestID: requestID, code: "initializeInvalid", message: "The stored rich draft exceeds its limits.")
            return
        }
        ready = true
        readinessTask?.cancel()
        onState(RichPresentationState(message: "Ready", ready: true, saving: false))
        if encoded.count <= 200 * 1_024 {
            send(type: "initialize", requestID: requestID, payload: initialization)
            return
        }
        initializationTransfers.removeAll()
        let transferID = UUID()
        initializationTransfers[transferID] = OutgoingInitialization(
            data: encoded, sha256: Self.hash(encoded), expiresAt: .now + .seconds(10)
        )
        send(type: "initialize", requestID: requestID, payload: [
            "buildID": gutenbergEditorBuildID, "transferID": transferID.uuidString.lowercased(),
            "totalBytes": encoded.count, "sha256": Self.hash(encoded),
            "chunkCount": Int(ceil(Double(encoded.count) / Double(bridgeChunkLimit))),
            "limits": limits
        ])
    }

    private func handleInitializeChunk(requestID: UUID, payload: [String: Any]) {
        guard let transferText = payload["transferID"] as? String,
              let transferID = UUID(uuidString: transferText),
              let transfer = initializationTransfers[transferID], transfer.expiresAt > .now,
              let sequence = payload["sequence"] as? Int, sequence >= 0 else {
            sendError(requestID: requestID, code: "initializeTransfer", message: "Initialization transfer expired.")
            return
        }
        let offset = sequence * bridgeChunkLimit
        guard offset < transfer.data.count else {
            sendError(requestID: requestID, code: "initializeTransfer", message: "Initialization chunk is invalid.")
            return
        }
        let end = min(offset + bridgeChunkLimit, transfer.data.count)
        let isLast = end == transfer.data.count
        let chunk = transfer.data.subdata(in: offset..<end)
        send(type: "initializeChunk", requestID: requestID, payload: [
            "sequence": sequence, "dataBase64": chunk.base64EncodedString(), "isLast": isLast
        ])
        if isLast { initializationTransfers.removeValue(forKey: transferID) }
    }

    private func handleCheckpoint(requestID: UUID, payload: [String: Any]) {
        guard let base = (payload["baseRevision"] as? NSNumber)?.int64Value,
              let next = (payload["nextRevision"] as? NSNumber)?.int64Value,
              base == revision.rawValue, next == base + 1,
              let markdown = payload["markdown"] as? String,
              let blockString = payload["blocksJSON"] as? String,
              let opaqueString = payload["opaqueSourcesJSON"] as? String,
              let blockData = blockString.data(using: .utf8), blockData.count <= bridgeBlockLimit,
              let opaqueData = opaqueString.data(using: .utf8), opaqueData.count <= bridgeBlockLimit,
              markdown.utf8.count <= bridgeDocumentLimit,
              let blockNodes = Self.validJSONNodeCount(blockData),
              let opaqueNodes = Self.validJSONNodeCount(opaqueData),
              blockNodes + opaqueNodes <= 20_000,
              let nextRevision = try? Revision(next) else {
            sendError(requestID: requestID, code: "revisionConflict", message: RichBridgeError.revisionConflict.localizedDescription)
            return
        }
        let requestedAssets = (payload["assetIDs"] as? [String] ?? []).compactMap { UUID(uuidString: $0).map { AssetID(rawValue: $0) } }
        guard requestedAssets.count <= 50, Set(requestedAssets).isSubset(of: assetIDs) else {
            sendError(requestID: requestID, code: "assetOwnership", message: "A referenced attachment does not belong to this draft.")
            return
        }
        Task {
            do {
                let stored = try await model.checkpointRichDraft(
                    draftID: draftID, baseRevision: revision, nextRevision: nextRevision,
                    markdown: markdown, blocksJSON: blockData, opaqueSourcesJSON: opaqueData,
                    assetIDs: requestedAssets
                )
                self.revision = stored
                self.markdown = markdown
                self.blocksJSON = blockData
                self.opaqueSourcesJSON = opaqueData
                send(type: "checkpointAck", requestID: requestID, payload: ["revision": stored.rawValue, "documentHash": Self.hash(Data(markdown.utf8))])
            } catch {
                sendError(requestID: requestID, code: "checkpointFailed", message: error.localizedDescription)
            }
        }
    }

    private func handleAssetPicker(requestID: UUID, payload: [String: Any]) {
        guard payload["kind"] as? String == "image",
              payload["multiple"] as? Bool == true else {
            sendError(requestID: requestID, code: "assetPicker", message: RichBridgeError.invalidMessage.localizedDescription)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic]
        Task {
            guard await panel.begin() == .OK else {
                send(type: "assetPickerResult", requestID: requestID, payload: [
                    "state": "cancelled", "assets": []
                ])
                return
            }
            do {
                var results: [[String: Any]] = []
                for url in panel.urls.prefix(50) {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    guard let mediaType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                          mediaType.hasPrefix("image/") else {
                        throw AssetStagingError.unsupportedType
                    }
                    let metadata = try await model.stageRichAsset(
                        fileURL: url,
                        filename: url.lastPathComponent,
                        mediaType: mediaType,
                        draftID: draftID
                    )
                    let previewData = try Data(contentsOf: url, options: [.mappedIfSafe])
                    assetIDs.insert(metadata.id)
                    previewStore.insert(id: metadata.id, data: previewData, mediaType: metadata.mediaType)
                    results.append([
                        "assetID": metadata.id.description,
                        "previewURL": "knot-asset://" + sessionID.uuidString.lowercased() + "/" + metadata.id.description,
                        "mediaType": metadata.mediaType,
                        "byteCount": metadata.byteCount,
                        "width": metadata.width ?? NSNull(),
                        "height": metadata.height ?? NSNull(),
                        "filename": String(url.lastPathComponent.prefix(255))
                    ])
                }
                send(type: "assetPickerResult", requestID: requestID, payload: [
                    "state": "imported", "assets": results
                ])
            } catch {
                sendError(requestID: requestID, code: "assetRejected", message: error.localizedDescription)
            }
        }
    }

    private func handleAssetBegin(requestID: UUID, payload: [String: Any]) {
        guard transfers.count < 4,
              let idText = payload["transferID"] as? String, let id = UUID(uuidString: idText), transfers[id] == nil,
              let filename = payload["filename"] as? String, !filename.isEmpty, filename.utf8.count <= 255,
              let mediaType = payload["mediaType"] as? String, mediaType.hasPrefix("image/"), mediaType.utf8.count <= 64,
              let total = (payload["totalBytes"] as? NSNumber)?.intValue, total > 0, total <= 25 * 1_024 * 1_024,
              let sha256 = payload["sha256"] as? String, sha256.count == 64,
              (payload["chunkBytes"] as? Int) == bridgeChunkLimit else {
            sendError(requestID: requestID, code: "assetBegin", message: RichBridgeError.transferInvalid.localizedDescription)
            return
        }
        transfers[id] = Transfer(filename: filename, mediaType: mediaType, totalBytes: total, sha256: sha256.lowercased(), expiresAt: .now + .seconds(10))
        send(type: "assetImportResult", requestID: requestID, payload: ["state": "accepted"])
    }

    private func handleAssetChunk(requestID: UUID, payload: [String: Any]) {
        guard let idText = payload["transferID"] as? String, let id = UUID(uuidString: idText),
              var transfer = transfers[id], transfer.expiresAt > .now,
              let sequence = payload["sequence"] as? Int, sequence == transfer.nextSequence,
              let base64 = payload["dataBase64"] as? String, base64.utf8.count <= 240 * 1_024,
              let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= bridgeChunkLimit,
              transfer.data.count + data.count <= transfer.totalBytes else {
            sendError(requestID: requestID, code: "assetChunk", message: RichBridgeError.transferInvalid.localizedDescription)
            return
        }
        transfer.data.append(data)
        transfer.nextSequence += 1
        transfers[id] = transfer
        send(type: "assetImportResult", requestID: requestID, payload: ["state": "accepted", "sequence": sequence])
    }

    private func handleAssetEnd(requestID: UUID, payload: [String: Any]) {
        guard let idText = payload["transferID"] as? String, let id = UUID(uuidString: idText),
              let transfer = transfers.removeValue(forKey: id), transfer.expiresAt > .now,
              transfer.data.count == transfer.totalBytes,
              payload["sha256"] as? String == transfer.sha256,
              Self.hash(transfer.data) == transfer.sha256 else {
            sendError(requestID: requestID, code: "assetEnd", message: RichBridgeError.transferInvalid.localizedDescription)
            return
        }
        Task {
            do {
                let metadata = try await model.stageRichAsset(
                    data: transfer.data, filename: transfer.filename,
                    mediaType: transfer.mediaType, draftID: draftID
                )
                assetIDs.insert(metadata.id)
                previewStore.insert(id: metadata.id, data: transfer.data, mediaType: metadata.mediaType)
                let preview = "knot-asset://\(sessionID.uuidString.lowercased())/\(metadata.id.description)"
                send(type: "assetImportResult", requestID: requestID, payload: [
                    "assetID": metadata.id.description, "previewURL": preview,
                    "mediaType": metadata.mediaType, "byteCount": metadata.byteCount,
                    "width": metadata.width ?? NSNull(), "height": metadata.height ?? NSNull()
                ])
            } catch { sendError(requestID: requestID, code: "assetRejected", message: error.localizedDescription) }
        }
    }

    private func handleSave(requestID: UUID, payload: [String: Any]) {
        guard (payload["acknowledgedRevision"] as? NSNumber)?.int64Value == revision.rawValue,
              payload["destination"] as? String == "inbox" else {
            sendError(requestID: requestID, code: "staleSave", message: RichBridgeError.revisionConflict.localizedDescription)
            return
        }
        onState(RichPresentationState(message: "Saving locally...", ready: true, saving: true))
        Task {
            let captureID: CaptureID
            do {
                captureID = try await model.enqueueRichDraft(
                    draftID: draftID,
                    revision: revision,
                    assetIDs: Array(assetIDs)
                )
            } catch {
                onState(RichPresentationState(message: error.localizedDescription, ready: true, saving: false))
                sendError(requestID: requestID, code: "localEnqueueFailed", message: error.localizedDescription)
                return
            }

            guard valid else { return }
            onState(RichPresentationState(message: "Saved locally, writing to vault...", ready: true, saving: true))
            send(type: "saveAccepted", requestID: requestID, payload: [
                "state": "pending",
                "captureID": captureID.description
            ])

            do {
                let receipt = try await model.publishRichCapture(captureID)
                guard valid else { return }
                onState(RichPresentationState(message: "Saved to vault", ready: true, saving: false))
                send(type: "saveResult", requestID: requestID, payload: [
                    "state": "committed",
                    "captureID": captureID.description,
                    "relativeTarget": receipt.notePath.string
                ])
            } catch {
                guard valid else { return }
                let state = await model.richCaptureState(captureID)
                let resultState = state == .needsReview ? "needsReview" : "retryable"
                onState(RichPresentationState(message: error.localizedDescription, ready: true, saving: false))
                send(type: "saveResult", requestID: requestID, payload: [
                    "state": resultState,
                    "captureID": captureID.description,
                    "error": errorPayload(code: "saveFailed", message: error.localizedDescription)
                ])
            }
        }
    }

    private func handleExternal(requestID: UUID, payload _: [String: Any]) {
        sendError(
            requestID: requestID,
            code: "externalURLDenied",
            message: "Open external links by activating them directly in the editor."
        )
    }

    nonisolated static func permittedExternalURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 2_048,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "mailto" {
            guard raw.dropFirst("mailto:".count).isEmpty == false else { return nil }
        } else {
            guard url.host?.isEmpty == false else { return nil }
        }
        return url
    }

    private func cleanupTransfers() {
        transfers = transfers.filter { $0.value.expiresAt > .now }
        initializationTransfers = initializationTransfers.filter { $0.value.expiresAt > .now }
    }

    private func sendError(requestID: UUID, code: String, message: String) {
        send(type: "recoverableError", requestID: requestID, payload: ["error": errorPayload(code: code, message: message)])
    }
    private func errorPayload(code: String, message: String) -> [String: Any] {
        ["code": code, "message": String(message.prefix(512)), "retryable": true]
    }
    private func send(type: String, requestID: UUID, payload: [String: Any]) {
        guard valid, let webView else { return }
        let envelope: [String: Any] = [
            "version": 1, "sessionID": sessionID.uuidString.lowercased(),
            "draftID": draftID.description, "revision": revision.rawValue,
            "requestID": requestID.uuidString.lowercased(), "type": type, "payload": payload
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let size = try? JSONSerialization.data(withJSONObject: envelope).count,
              size <= bridgeMessageLimit else { return }
        webView.callAsyncJavaScript(
            "window.KnotNativeReceive(message)", arguments: ["message": envelope],
            in: nil, in: .page, completionHandler: nil
        )
    }
    nonisolated static func validJSONNodeCount(_ data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var stack: [(Any, Int)] = [(root, 0)]
        var count = 0
        while let (value, depth) = stack.popLast() {
            count += 1
            guard count <= 20_000, depth <= 64 else { return nil }
            if let values = value as? [Any] {
                for child in values { stack.append((child, depth + 1)) }
            } else if let values = value as? [String: Any] {
                for child in values.values { stack.append((child, depth + 1)) }
            }
        }
        return count
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let raw = navigationAction.request.url?.absoluteString,
           let externalURL = Self.permittedExternalURL(raw) {
            NSWorkspace.shared.open(externalURL)
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.targetFrame?.isMainFrame != false,
              navigationAction.request.url == editorEntryURL else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onState(RichPresentationState(message: "Editor load failed. Source draft is preserved.", ready: false, saving: false))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onState(RichPresentationState(message: "Editor resources could not load. Source draft is preserved.", ready: false, saving: false))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        onState(RichPresentationState(message: "Editor restarted from the last saved local revision.", ready: false, saving: false))
        startReadinessTimer()
        webView.reloadFromOrigin()
    }
}
