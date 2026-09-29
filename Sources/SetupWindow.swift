import AppKit

/// The window shown while the app is acquiring or updating what it runs.
///
/// It exists because the first launch is not instant: the app downloads a Node
/// runtime and roughly 350 MB of harness packages, which takes minutes on a
/// normal connection. An app that showed nothing during that would look broken,
/// and its audience would quit and try again — repeatedly.
final class SetupWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton()
    private var onCancel: (() -> Void)?

    convenience init(title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 168),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        self.init(window: window)
        buildLayout()
    }

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.startAnimation(nil)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let stack = NSStackView(views: [statusLabel, progressBar, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 44),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    /// Confirmed rather than immediate. An install runs for minutes, and a
    /// single stray click should not be able to throw all of it away.
    @objc private func cancelPressed() {
        let alert = NSAlert()
        alert.messageText = "Stop the installation?"
        alert.informativeText = "Nothing already installed is affected — the version you are using now stays as it is."
        alert.addButton(withTitle: "Keep Installing")
        alert.addButton(withTitle: "Stop")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        cancelButton.isEnabled = false
        statusLabel.stringValue = "Cancelling…"
        onCancel?()
    }

    func setCancellation(_ handler: (() -> Void)?) {
        onCancel = handler
        cancelButton.isHidden = handler == nil
    }

    /// Called from background work, so it hops to the main thread itself rather
    /// than making every caller remember to.
    nonisolated func report(_ status: String, fraction: Double?) {
        Task { @MainActor in
            self.statusLabel.stringValue = status
            if let fraction {
                self.progressBar.isIndeterminate = false
                self.progressBar.doubleValue = fraction
                self.detailLabel.stringValue = "\(Int(fraction * 100))%"
            } else {
                self.progressBar.isIndeterminate = true
                self.progressBar.startAnimation(nil)
                self.detailLabel.stringValue = ""
            }
        }
    }

    func showCentred() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Presents a `HarborError` with its recovery text, which every error carries.
@MainActor
func presentError(_ error: HarborError, fatal: Bool) {
    // Logged as well as shown. A dialog is seen once by one person and then
    // gone; without this, diagnosing a failure after the fact depends on
    // whether someone read it carefully enough to repeat it.
    Log.write("error: \(error.summary)\(error.detail.isEmpty ? "" : " | \(error.detail)")")
    let alert = NSAlert()
    alert.alertStyle = fatal ? .critical : .warning
    alert.messageText = error.summary
    alert.informativeText = alertBody(for: error)
    alert.addButton(withTitle: fatal ? "Quit" : "OK")
    alert.addButton(withTitle: "Show Log")
    if alert.runModal() == .alertSecondButtonReturn {
        revealLog()
    }
    if fatal { NSApp.terminate(nil) }
}

/// The detail and recovery text of an error, trimmed to fit a dialog.
func alertBody(for error: HarborError) -> String {
    var body = error.detail
    if let recovery = error.recovery {
        body = body.isEmpty ? recovery : "\(body)\n\n\(recovery)"
    }
    // A wall of npm output helps nobody read the sentence that matters.
    let lines = body.split(separator: "\n")
    if lines.count > 12 {
        body = (["…"] + lines.suffix(12)).joined(separator: "\n")
    }
    return body
}

@MainActor
func revealLog() {
    NSWorkspace.shared.selectFile(
        Paths.logs.appendingPathComponent("harbor.log").path,
        inFileViewerRootedAtPath: Paths.logs.path
    )
}
