import AppKit
import SwiftUI
import WebKit

private let gutenbergEditorBuildID = "wk-shell-20260607-bridge"

@MainActor
final class GutenbergEditorWindowController: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private var window: NSWindow?

    init(model: EditorModel) {
        self.model = model
        super.init()
    }

    func show(initialContent: String) {
        let host = NSHostingController(rootView: GutenbergEditorView(
            model: model,
            initialContent: initialContent,
            promotedContent: initialContent,
            onClose: { [weak self] in
                self?.close()
            }
        ))
        host.sizingOptions = []

        let window = self.window ?? NSWindow(contentViewController: host)
        if self.window == nil {
            window.title = "Knot Block Editor"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.contentMinSize = NSSize(width: 640, height: 480)
            window.setContentSize(NSSize(width: 760, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        } else {
            window.contentViewController = host
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct GutenbergEditorView: View {
    @Bindable var model: EditorModel
    let initialContent: String
    let promotedContent: String?
    let onClose: () -> Void

    @State private var webView: WKWebView?
    @State private var isSaving = false
    @State private var editorStatus = "Preparing editor \(gutenbergEditorBuildID)..."

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if editorStatus != "Ready" {
                Text(editorStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary)
            }
            GutenbergWebView(
                initialContent: initialContent,
                webView: $webView,
                onSave: handleSavePayload,
                onCancel: onClose,
                onError: handleEditorError,
                onStatus: { editorStatus = $0 }
            )
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Block Editor")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button("Cancel") {
                onClose()
            }
            .disabled(isSaving)
            Button {
                requestSave()
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 38)
                } else {
                    Text("Save")
                        .frame(width: 38)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func requestSave() {
        isSaving = true
        guard let webView else {
            isSaving = false
            return
        }
        webView.evaluateJavaScript("window.KnotEditor ? (window.KnotEditor.save(), true) : false") { result, error in
            if error != nil || (result as? Bool) != true {
                Task { @MainActor in
                    isSaving = false
                }
            }
        }
    }

    private func handleSavePayload(_ payload: GutenbergSavePayload) {
        var attachments: [EditorAttachment] = []
        for attachment in payload.attachments {
            guard let data = Data(base64Encoded: attachment.dataBase64) else {
                isSaving = false
                model.status = .error("Could not read image data.")
                return
            }
            attachments.append(EditorAttachment(
                token: attachment.token,
                filename: attachment.filename,
                data: data
            ))
        }

        model.sendInboxMarkdown(
            payload.markdown,
            attachments: attachments,
            promotedContent: promotedContent
        ) { success in
            isSaving = false
            if success {
                onClose()
            }
        }
    }

    private func handleEditorError(_ message: String) {
        isSaving = false
        editorStatus = message
        model.status = .error(message)
    }
}

private struct GutenbergSavePayload: Decodable {
    let markdown: String
    let attachments: [GutenbergAttachmentPayload]
}

private struct GutenbergAttachmentPayload: Decodable {
    let token: String
    let filename: String
    let dataBase64: String
}

private struct GutenbergWebView: NSViewRepresentable {
    let initialContent: String
    @Binding var webView: WKWebView?
    let onSave: (GutenbergSavePayload) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSave: onSave,
            onCancel: onCancel,
            onError: onError,
            onStatus: onStatus
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "knotEditor")
        userContentController.addUserScript(WKUserScript(
            source: "window.KnotInitialContent = \(jsonString(initialContent));",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")

        DispatchQueue.main.async {
            webView = view
        }

        loadEditor(in: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "knotEditor")
        nsView.navigationDelegate = nil
    }

    private func loadEditor(in view: WKWebView) {
        guard let distURL = Bundle.main.url(
            forResource: "dist",
            withExtension: nil,
            subdirectory: nil
        ),
              Bundle.main.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "dist"
              ) != nil else {
            view.loadHTMLString(
                "<html><body><p>Block editor resources were not found.</p></body></html>",
                baseURL: nil
            )
            onError("Block editor resources were not found.")
            return
        }

        guard let scriptSource = bundledEditorScriptSource(distURL: distURL) else {
            view.loadHTMLString(
                "<html><body><p>Block editor script was not found.</p></body></html>",
                baseURL: nil
            )
            onError("Block editor script was not found.")
            return
        }

        let shellHTML = editorShellHTML(scriptSource: scriptSource)
        onStatus("Loading editor shell \(gutenbergEditorBuildID)...")
        view.loadHTMLString(shellHTML, baseURL: distURL)
        scheduleStartupProbe(in: view)
    }

    private func bundledEditorScriptSource(distURL: URL) -> String? {
        let assetsURL = distURL.appendingPathComponent("assets", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return files
            .map(\.lastPathComponent)
            .first { filename in
                filename.hasPrefix("index-") && filename.hasSuffix(".js")
            }
            .map { "./assets/\($0)" }
    }

    private func editorShellHTML(scriptSource: String) -> String {
        let buildID = gutenbergEditorBuildID
        let escapedScriptSource = scriptSource
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        return """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta
              http-equiv="Content-Security-Policy"
              content="default-src 'self' blob: data:; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' blob: data:; connect-src 'none'; font-src 'self' data:;"
            />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>Knot Block Editor</title>
            <script>
              (function () {
                function post(message) {
                  try {
                    window.webkit.messageHandlers.knotEditor.postMessage(message);
                  } catch (_) {}
                }
                window.KnotEditorShellBuild = "\(buildID)";
                post({ type: "status", message: "Editor shell \(buildID) running..." });
                window.addEventListener("error", function (event) {
                  post({ type: "error", message: "Editor shell error: " + (event.message || "unknown error") });
                });
                window.addEventListener("unhandledrejection", function (event) {
                  post({ type: "error", message: "Editor shell promise error: " + String(event.reason || "unknown error") });
                });
                document.addEventListener("DOMContentLoaded", function () {
                  post({ type: "status", message: "Editor DOM ready \(buildID)..." });
                });
                window.addEventListener("load", function () {
                  post({ type: "status", message: "Editor window loaded \(buildID)..." });
                });
              })();
            </script>
            <script defer src="\(escapedScriptSource)"></script>
          </head>
          <body>
            <div id="root">
              <div style="font: 13px -apple-system, BlinkMacSystemFont, sans-serif; color: CanvasText; padding: 18px 20px;">
                Starting editor...
              </div>
            </div>
          </body>
        </html>
        """
    }

    private func scheduleStartupProbe(in view: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            onStatus("Checking editor startup \(gutenbergEditorBuildID)...")
            runStartupProbe(in: view, label: "Editor startup probe")
        }
    }

    private func runStartupProbe(in view: WKWebView, label: String) {
        view.evaluateJavaScript(startupProbeScript(label: label), completionHandler: nil)
    }

    private func startupProbeScript(label: String) -> String {
        """
        (function () {
            function post(message) {
                try {
                    window.webkit.messageHandlers.knotEditor.postMessage(message);
                } catch (_) {}
            }
            var root = document.getElementById('root');
            var rootText = root && root.innerText ? String(root.innerText).slice(0, 120) : "";
            var info = {
                readyState: String(document.readyState || ""),
                hasRoot: !!root,
                rootText: rootText,
                scriptCount: document.scripts ? document.scripts.length : 0,
                shellBuild: window.KnotEditorShellBuild || null,
                hasKnotEditor: !!window.KnotEditor
            };
            if (info.hasKnotEditor) {
                post({ type: "ready" });
            } else {
                post({ type: "status", message: \(jsonString(label)) + ": " + JSON.stringify(info) });
            }
        })();
        true;
        """
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onSave: (GutenbergSavePayload) -> Void
        let onCancel: () -> Void
        let onError: (String) -> Void
        let onStatus: (String) -> Void

        init(
            onSave: @escaping (GutenbergSavePayload) -> Void,
            onCancel: @escaping () -> Void,
            onError: @escaping (String) -> Void,
            onStatus: @escaping (String) -> Void
        ) {
            self.onSave = onSave
            self.onCancel = onCancel
            self.onError = onError
            self.onStatus = onStatus
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            if type == "cancel" {
                onCancel()
                return
            }

            if type == "error" {
                if let message = body["message"] as? String {
                    onError(message)
                }
                return
            }

            if type == "ready" {
                onStatus("Ready")
                return
            }

            if type == "status" || type == "log" {
                if let message = body["message"] as? String {
                    onStatus(message)
                }
                return
            }

            guard type == "save",
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let payload = try? JSONDecoder().decode(GutenbergSavePayload.self, from: data) else {
                return
            }
            onSave(payload)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let scheme = navigationAction.request.url?.scheme else {
                decisionHandler(.cancel)
                return
            }
            let allowedSchemes = ["about", "blob", "data", "file"]
            decisionHandler(allowedSchemes.contains(scheme) ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onStatus("WebKit started loading editor shell...")
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onStatus("WebKit committed editor shell...")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onStatus("Starting editor...")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onError("Editor navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onError("Editor load failed: \(error.localizedDescription)")
        }
    }
}
