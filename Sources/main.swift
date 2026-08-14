import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server = ServerController()
    private var state = AppState.load()
    private var mainWindow: MainWindowController?
    private var setupWindow: SetupWindowController?
    private var nodeExecutable: URL?
    private var installCancelled = false
    private var updateMenuItem: NSMenuItem?
    private var autoCheckMenuItem: NSMenuItem?
    private var updateTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    /// Set by the background check; drives the menu title so the offer is
    /// visible without a dialog demanding attention.
    private var availableUpdate: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installSignalHandlers()
        buildMenus()
        Task { await startUp() }
    }

    /// Stops the server when the app is killed by a signal rather than quit.
    ///
    /// `applicationWillTerminate` covers Cmd+Q and the Dock's Quit, but nothing
    /// else: a SIGTERM from Activity Monitor, `kill`, logout, or shutdown ends
    /// the process without the delegate ever hearing about it, which leaves the
    /// harness running and holding the port. Ignoring the default action and
    /// handling the signal on a dispatch source makes those paths behave like a
    /// quit. SIGKILL and a crash remain uncatchable by definition, which is what
    /// the pid file and `reapOrphanedServer` exist for.
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Log.write("received signal \(number); stopping server")
                self?.server.stop()
                RuntimeManager.stopActiveInstall()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The whole reason this app exists. Blocking here is deliberate: the app
    /// must not vanish while the server it started is still running, because
    /// then Cmd+Q would leave the same orphaned process that made a plain
    /// browser tab unsatisfactory in the first place.
    func applicationWillTerminate(_ notification: Notification) {
        Log.write("terminating; stopping server")
        server.stop()
        // An install in flight is a process this app started too, and quitting
        // must not leave npm running unattended.
        RuntimeManager.stopActiveInstall()
    }

    // MARK: - Start-up

    private func startUp() async {
        do {
            try Paths.ensureDirectories()
        } catch {
            presentError(HarborError("Could not create the application support folder",
                                     detail: error.localizedDescription), fatal: true)
            return
        }

        ServerController.reapOrphanedServer()

        guard ServerController.isPortAvailable() else {
            presentError(HarborError(
                "Port \(ServerController.port) is already in use",
                detail: "Something else on this Mac is already listening on 127.0.0.1:\(ServerController.port).",
                recovery: "If you started the harness in a terminal, quit it there and reopen this app. This app deliberately will not take over a server it did not start, because it could not then shut it down cleanly."
            ), fatal: true)
            return
        }

        // Work out what is actually missing before doing anything, so the user
        // is asked once and the list is accurate. On a machine that already has
        // a usable Node, nothing is said about Node at all.
        let systemNode = RuntimeManager.systemNodeExecutable()
        let managedNode = RuntimeManager.managedNodeExecutable()
        let needsNodeDownload = systemNode == nil && managedNode == nil
        let harnessReady = state.developerCheckoutPath != nil
            || (RuntimeManager.activeVersion().map { RuntimeManager.isInstalled(version: $0) } ?? false)

        if needsNodeDownload || !harnessReady {
            guard confirmFirstInstall(needsNode: needsNodeDownload, needsHarness: !harnessReady) else {
                NSApp.terminate(nil)
                return
            }
        }

        let setup = SetupWindowController(title: Paths.appName)
        setupWindow = setup
        setup.showCentred()

        do {
            let node = try await resolveNode(system: systemNode, managed: managedNode, reporting: setup)
            nodeExecutable = node
            let entryPoint = try await resolveHarness(node: node, reporting: setup)
            setup.report("Starting the harness…", fraction: nil)
            setup.setCancellation(nil)
            launchServer(node: node, entryPoint: entryPoint)
        } catch let error as HarborError {
            setup.close()
            setupWindow = nil
            presentError(error, fatal: true)
        } catch {
            setup.close()
            setupWindow = nil
            presentError(HarborError("Setup failed", detail: error.localizedDescription), fatal: true)
        }
    }

    /// Asks once, listing only what is genuinely about to be downloaded.
    private func confirmFirstInstall(needsNode: Bool, needsHarness: Bool) -> Bool {
        var items: [String] = []
        if needsNode {
            items.append("• Node.js — this Mac has no version the harness can use. Downloaded from the official nodejs.org releases and verified against their published checksums.")
        }
        if needsHarness {
            items.append("• DeepSeek Harness — installed from the npm registry. About 350 MB, and it takes a few minutes.")
        }
        let alert = NSAlert()
        alert.messageText = "First-time setup"
        alert.informativeText = """
        \(Paths.appName) needs to download:

        \(items.joined(separator: "\n\n"))

        Everything is installed inside this app's own folder. Nothing is installed system-wide, and nothing already on this Mac is modified.
        """
        alert.addButton(withTitle: "Download and Install")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A Node already on this machine wins. Downloading a second copy of a
    /// runtime that is installed and working would waste the user's bandwidth
    /// and disk to arrive at the same place.
    private func resolveNode(
        system: URL?, managed: URL?, reporting setup: SetupWindowController
    ) async throws -> URL {
        if let system {
            let reported = (try? runTool(system.path, ["--version"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            state.nodeVersion = "\(reported) (already on this Mac, at \(system.path))"
            state.save()
            return system
        }
        if let managed {
            state.nodeVersion = "\(managed.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent) (downloaded by this app)"
            state.save()
            return managed
        }
        let node = try await RuntimeManager.installNode { message, fraction in
            setup.report(message, fraction: fraction)
        }
        state.nodeVersion = "\(node.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent) (downloaded by this app)"
        state.save()
        return node
    }

    private func resolveHarness(node: URL, reporting setup: SetupWindowController) async throws -> URL {
        if let checkout = state.developerCheckoutPath {
            let entry = URL(fileURLWithPath: checkout).appendingPathComponent("apps/cli/lib/bin.js")
            guard FileManager.default.isReadableFile(atPath: entry.path) else {
                throw HarborError(
                    "The local checkout is not built",
                    detail: "No entry point at \(entry.path).",
                    recovery: "Run “pnpm install && pnpm run build” in \(checkout), or switch back to the released version from the Harness menu."
                )
            }
            return entry
        }

        if let active = RuntimeManager.activeVersion(), RuntimeManager.isInstalled(version: active) {
            return RuntimeManager.entryPoint(in: RuntimeManager.slot(for: active))
        }

        setup.report("Checking for the latest harness release…", fraction: nil)
        let version = try await RuntimeManager.latestHarnessVersion()
        installCancelled = false
        setup.setCancellation { [weak self] in self?.installCancelled = true }
        try await runOffMainThread {
            try RuntimeManager.installHarness(
                version: version, node: node,
                progress: { message, fraction in setup.report(message, fraction: fraction) },
                cancellation: { [weak self] in self?.installCancelled ?? false }
            )
        }
        try RuntimeManager.promote(version: version)
        state.harnessVersion = version
        state.save()
        return RuntimeManager.entryPoint(in: RuntimeManager.slot(for: version))
    }

    private func launchServer(node: URL, entryPoint: URL) {
        server.start(
            node: node,
            entryPoint: entryPoint,
            // The harness treats its working directory as the default
            // filesystem location. Home is the one directory that always
            // exists and that the user recognises; the UI still requires them
            // to choose a workspace explicitly before anything can run.
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            onReady: { [weak self] url in
                guard let self else { return }
                self.setupWindow?.close()
                self.setupWindow = nil
                let window = self.mainWindow ?? MainWindowController(onReload: { [weak self] in
                    if let url = self?.server.url { self?.mainWindow?.load(url) }
                })
                self.mainWindow = window
                window.load(url)
                window.showWindow(nil)
                window.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                Log.write("harness ready at \(url)")
                self.scheduleUpdateChecks()
            },
            onFailure: { [weak self] error in
                self?.setupWindow?.close()
                self?.setupWindow = nil
                presentError(error, fatal: true)
            }
        )
    }

    // MARK: - Updating

    /// Checks in the background on launch and every few hours.
    ///
    /// Detection is automatic; installation is not. The harness publishes
    /// several preview releases a day with no compatibility promise, so
    /// swapping the runtime under a running session without being asked would
    /// be a good way to lose someone's afternoon. The menu carries the offer,
    /// and each new version is announced once.
    private func scheduleUpdateChecks() {
        guard state.developerCheckoutPath == nil else { return }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.runUpdateCheck(userInitiated: false) }
        }
        Task { await runUpdateCheck(userInitiated: false) }
    }

    private func runUpdateCheck(userInitiated: Bool) async {
        guard state.developerCheckoutPath == nil else {
            if userInitiated {
                let alert = NSAlert()
                alert.messageText = "Using a local checkout"
                alert.informativeText = "Update it yourself with git, or switch to the released version from this menu."
                alert.runModal()
            }
            return
        }
        guard userInitiated || state.autoCheckEnabled else { return }

        let current = RuntimeManager.activeVersion()
        do {
            let latest = try await RuntimeManager.latestHarnessVersion()
            state.lastUpdateCheck = Date()
            state.save()

            guard current == nil || Version(latest) > Version(current!) else {
                availableUpdate = nil
                refreshUpdateMenuItem()
                if userInitiated {
                    let alert = NSAlert()
                    alert.messageText = "You are up to date"
                    alert.informativeText = "DeepSeek Harness \(current ?? latest) is the latest release."
                    alert.runModal()
                }
                return
            }

            availableUpdate = latest
            refreshUpdateMenuItem()
            // A version already declined stays in the menu but stops
            // interrupting.
            if userInitiated || state.notifiedVersion != latest {
                state.notifiedVersion = latest
                state.save()
                offerUpdate(to: latest, from: current)
            }
        } catch let error as HarborError {
            // A failed background check is not worth a dialog; the network
            // being down is not something the user asked about.
            if userInitiated { presentError(error, fatal: false) } else { Log.write("update check failed: \(error.summary)") }
        } catch {
            if userInitiated {
                presentError(HarborError("Could not check for updates", detail: error.localizedDescription), fatal: false)
            }
        }
    }

    private func refreshUpdateMenuItem() {
        updateMenuItem?.title = availableUpdate.map { "Update to \($0)…" } ?? "Check for Updates…"
        autoCheckMenuItem?.state = state.autoCheckEnabled ? .on : .off
    }

    @objc private func toggleAutomaticChecks(_ sender: Any?) {
        state.autoCheckDisabled = state.autoCheckEnabled
        state.save()
        refreshUpdateMenuItem()
        if state.autoCheckEnabled { scheduleUpdateChecks() } else { updateTimer?.invalidate() }
    }

    @objc private func checkForHarnessUpdates(_ sender: Any?) {
        Task { await runUpdateCheck(userInitiated: true) }
    }

    private func offerUpdate(to latest: String, from current: String?) {
        Task {
            guard let node = nodeExecutable else { return }
            let alert = NSAlert()
            alert.messageText = "Update to DeepSeek Harness \(latest)?"
            alert.informativeText = """
            Installed: \(current ?? "none")

            DeepSeek Harness is a developer preview and states that releases may break compatibility. Before updating, this app copies your sessions and settings so you can roll back.

            The harness will restart. Any running task will be stopped.
            """
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Later")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await performUpdate(to: latest, node: node, from: current)
        }
    }

    private func performUpdate(to version: String, node: URL, from current: String?) async {
        let setup = SetupWindowController(title: "Updating DeepSeek Harness")
        setupWindow = setup
        setup.showCentred()
        mainWindow?.close()

        do {
            setup.report("Stopping the harness…", fraction: nil)
            server.stop()

            setup.report("Copying your sessions and settings…", fraction: nil)
            try RuntimeManager.snapshotDshHome()

            installCancelled = false
            setup.setCancellation { [weak self] in self?.installCancelled = true }
            // The version being replaced is the closest thing on disk to the
            // one being installed, so it is what the new slot starts from.
            let seed = current.flatMap { version in
                RuntimeManager.isInstalled(version: version) ? RuntimeManager.slot(for: version) : nil
            }
            try await runOffMainThread {
                try RuntimeManager.installHarness(
                    version: version, node: node, seedFrom: seed,
                    progress: { message, fraction in setup.report(message, fraction: fraction) },
                    cancellation: { [weak self] in self?.installCancelled ?? false }
                )
            }

            try RuntimeManager.promote(version: version)
            state.previousHarnessVersion = current
            state.harnessVersion = version
            state.lastUpdateCheck = Date()
            state.save()

            RuntimeManager.pruneSlots(keeping: Set([version, current].compactMap { $0 }))
            RuntimeManager.pruneSnapshots(keepingNewest: 5)
            availableUpdate = nil
            refreshUpdateMenuItem()

            setup.report("Restarting…", fraction: nil)
            setup.setCancellation(nil)
            launchServer(node: node, entryPoint: RuntimeManager.entryPoint(in: RuntimeManager.slot(for: version)))
        } catch let error as HarborError {
            // The previous version is still installed and still what `current`
            // points at, so recovery is just starting it again.
            setup.close()
            setupWindow = nil
            presentError(error, fatal: false)
            if let current {
                launchServer(node: node, entryPoint: RuntimeManager.entryPoint(in: RuntimeManager.slot(for: current)))
            }
        } catch {
            setup.close()
            setupWindow = nil
            presentError(HarborError("Update failed", detail: error.localizedDescription), fatal: false)
        }
    }

    @objc private func rollBack(_ sender: Any?) {
        guard let node = nodeExecutable,
              let previous = state.previousHarnessVersion,
              RuntimeManager.isInstalled(version: previous)
        else {
            let alert = NSAlert()
            alert.messageText = "No previous version to roll back to"
            alert.informativeText = "A previous version is kept only after an in-app update."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Roll back to DeepSeek Harness \(previous)?"
        alert.informativeText = """
        The harness stores sessions in a database whose format moves forward only. If the newer version has already written to it, the older version may refuse to read it.

        A copy of your data was made before the update. If the older version cannot start, that copy is in this app's Snapshots folder.
        """
        alert.addButton(withTitle: "Roll Back")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            server.stop()
            try RuntimeManager.promote(version: previous)
            let rolledBackFrom = state.harnessVersion
            state.harnessVersion = previous
            state.previousHarnessVersion = rolledBackFrom
            state.save()
            mainWindow?.close()
            launchServer(node: node, entryPoint: RuntimeManager.entryPoint(in: RuntimeManager.slot(for: previous)))
        } catch let error as HarborError {
            presentError(error, fatal: false)
        } catch {
            presentError(HarborError("Roll back failed", detail: error.localizedDescription), fatal: false)
        }
    }

    // MARK: - Developer mode

    @objc private func useLocalCheckout(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a built deepseek-harness checkout."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        state.developerCheckoutPath = directory.path
        state.save()
        restartAfterSourceChange()
    }

    @objc private func useReleasedVersion(_ sender: Any?) {
        state.developerCheckoutPath = nil
        state.save()
        restartAfterSourceChange()
    }

    private func restartAfterSourceChange() {
        Task {
            server.stop()
            mainWindow?.close()
            mainWindow = nil
            await startUp()
        }
    }

    // MARK: - Folders and logs

    @objc private func revealDataFolder(_ sender: Any?) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.dshHome.path)
    }

    @objc private func revealAppFolder(_ sender: Any?) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Paths.support.path)
    }

    @objc private func showLog(_ sender: Any?) {
        NSWorkspace.shared.selectFile(
            Paths.logs.appendingPathComponent("harbor.log").path,
            inFileViewerRootedAtPath: Paths.logs.path
        )
    }

    @objc private func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = Paths.appName
        alert.informativeText = """
        An unofficial desktop launcher for DeepSeek Harness.
        Not affiliated with, endorsed by, or supported by DeepSeek.

        Harness: \(RuntimeManager.activeVersion() ?? "not installed")\
        \(state.developerCheckoutPath.map { "\nSource: local checkout at \($0)" } ?? "")
        Node: \(state.nodeVersion ?? "not installed")
        """
        alert.runModal()
    }

    // MARK: - Menus

    private func buildMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(Paths.appName)", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(Paths.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(Paths.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(MainWindowController.reload(_:)), keyEquivalent: "r")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let harnessMenuItem = NSMenuItem()
        let harnessMenu = NSMenu(title: "Harness")
        let updateItem = harnessMenu.addItem(
            withTitle: "Check for Updates…", action: #selector(checkForHarnessUpdates(_:)), keyEquivalent: ""
        )
        updateMenuItem = updateItem
        let autoItem = harnessMenu.addItem(
            withTitle: "Check Automatically", action: #selector(toggleAutomaticChecks(_:)), keyEquivalent: ""
        )
        autoItem.state = state.autoCheckEnabled ? .on : .off
        autoCheckMenuItem = autoItem
        harnessMenu.addItem(withTitle: "Roll Back to Previous Version…", action: #selector(rollBack(_:)), keyEquivalent: "")
        harnessMenu.addItem(.separator())
        harnessMenu.addItem(withTitle: "Use Local Checkout…", action: #selector(useLocalCheckout(_:)), keyEquivalent: "")
        harnessMenu.addItem(withTitle: "Use Released Version", action: #selector(useReleasedVersion(_:)), keyEquivalent: "")
        harnessMenu.addItem(.separator())
        harnessMenu.addItem(withTitle: "Reveal Sessions Folder", action: #selector(revealDataFolder(_:)), keyEquivalent: "")
        harnessMenu.addItem(withTitle: "Reveal App Support Folder", action: #selector(revealAppFolder(_:)), keyEquivalent: "")
        harnessMenu.addItem(withTitle: "Show Log", action: #selector(showLog(_:)), keyEquivalent: "")
        harnessMenuItem.submenu = harnessMenu
        mainMenu.addItem(harnessMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

/// Runs blocking work off the main thread while keeping `throws` propagation.
/// The installer is a synchronous process wait by design — it polls so it can
/// notice a cancellation — so it must not run where the UI lives.
private func runOffMainThread(_ work: @escaping () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

let application = NSApplication.shared
// Top-level code already runs on the main thread; the compiler cannot infer
// that on its own, and the delegate is main-actor isolated.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
