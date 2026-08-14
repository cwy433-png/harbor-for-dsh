import AppKit
import WebKit

/// The window the harness web UI runs in.
///
/// A `WKWebView` is not a browser, and the gaps show up as features silently
/// doing nothing: JavaScript dialogs are ignored unless the host implements
/// them, file pickers never open, and `target="_blank"` links go nowhere. Each
/// delegate method below fills one of those gaps.
final class MainWindowController: NSWindowController, WKUIDelegate, WKNavigationDelegate {
    private(set) var webView: WKWebView!
    private var onReload: (() -> Void)?

    convenience init(onReload: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Paths.appName
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("HarborMainWindow")
        self.init(window: window)
        self.onReload = onReload
        buildWebView()
    }

    private func buildWebView() {
        let configuration = WKWebViewConfiguration()
        // The default store is already persistent, but naming it makes the
        // dependency explicit: the harness UI keeps settings and drafts in
        // localStorage, which survives quitting only because of this.
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        // Right-click → Inspect Element. The harness is a developer preview;
        // when something misbehaves, a usable console is the difference between
        // a useful bug report and "it broke".
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        window?.contentView = webView
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    @objc func reload(_ sender: Any?) {
        if webView.url == nil { onReload?() } else { webView.reload() }
    }

    // MARK: - Links that leave the harness

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let isLocal = url.host == "127.0.0.1" || url.host == "localhost" || url.isFileURL
        if isLocal {
            decisionHandler(.allow)
            return
        }
        // Documentation, Discord, GitHub: these belong in a real browser, where
        // the user has their sessions, extensions, and history.
        decisionHandler(.cancel)
        NSWorkspace.shared.open(url)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: - JavaScript dialogs

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// Directories are selectable because choosing a workspace is the first
    /// thing the harness UI asks for, and a workspace is a folder.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window ?? NSApp.keyWindow ?? NSWindow()) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: - Load failures

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A server that died after the window opened lands here; the app
        // delegate's own supervision reports why, so this only avoids a blank
        // window with no explanation.
        Log.write("web view failed to load: \(error.localizedDescription)")
    }
}
