import CryptoKit
import Foundation

/// Progress reported to whatever is showing a window: a human-readable step and
/// an optional completion fraction. `nil` means indeterminate.
typealias ProgressHandler = @Sendable (String, Double?) -> Void

/// Acquires and updates the two things the app needs but does not ship: a Node
/// runtime and the harness itself.
///
/// Both live under Application Support in version-keyed directories, and the
/// active harness is chosen by a single `current` symlink. Installing writes
/// only into a fresh directory; the symlink swap at the end is the one step
/// that changes what runs, so a failed or cancelled install leaves the previous
/// version untouched and still current.
enum RuntimeManager {
    static let packageName = "@deepseek-ai/dsh"

    // MARK: - Node

    /// Well-known absolute locations for a Node this machine already has.
    ///
    /// Absolute paths rather than a PATH search, because a Finder-launched app
    /// inherits a minimal PATH that contains none of these. Version-manager
    /// installs (nvm, fnm, asdf) are deliberately not probed: they live behind
    /// shell shims whose selected version changes per directory and per shell,
    /// so a GUI app cannot depend on getting the same one twice.
    private static let systemNodeCandidates = [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ]

    /// A Node already on this machine that satisfies the harness engine range.
    ///
    /// Preferred over downloading one. Re-checked on every launch rather than
    /// remembered, so a Node that is upgraded out of range, or uninstalled,
    /// simply stops being chosen and the managed runtime takes over.
    static func systemNodeExecutable() -> URL? {
        for path in systemNodeCandidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            guard let reported = try? runTool(path, ["--version"]) else { continue }
            let version = Version(reported.trimmingCharacters(in: .whitespacesAndNewlines))
            guard version.satisfiesHarnessEngines else {
                Log.write("skipping \(path): Node \(version) is outside the harness engine range")
                continue
            }
            // npm ships with Node, and the installer needs it; a runtime
            // without it is unusable here even if `node` itself works.
            let node = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: npmCLI(for: node).path) else {
                Log.write("skipping \(path): no npm alongside it")
                continue
            }
            Log.write("using system Node \(version) at \(path)")
            return node
        }
        return nil
    }

    /// The Node this app downloaded for itself. Used only when the machine has
    /// no suitable one of its own.
    static func managedNodeExecutable() -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Paths.nodeRoot, includingPropertiesForKeys: nil
        ) else { return nil }
        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("v") }
            .sorted { Version($0.lastPathComponent) < Version($1.lastPathComponent) }
        for dir in candidates.reversed() {
            let executable = dir.appendingPathComponent("bin/node")
            if FileManager.default.isExecutableFile(atPath: executable.path),
               Version(dir.lastPathComponent).satisfiesHarnessEngines {
                return executable
            }
        }
        return nil
    }

    private static var systemArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// Latest Node LTS satisfying the harness engine range. LTS rather than
    /// current: this runtime is invisible to the user, so the only useful
    /// property is that it keeps working.
    private static func latestNodeLTS() async throws -> String {
        let url = URL(string: "https://nodejs.org/dist/index.json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkHTTP(response, what: "Node version index")
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HarborError("Could not read the Node version index",
                              detail: "nodejs.org returned a response this app did not understand.")
        }
        let versions = entries.compactMap { entry -> String? in
            guard let version = entry["version"] as? String else { return nil }
            // `lts` is the codename string for an LTS line, and `false` otherwise.
            guard entry["lts"] as? String != nil else { return nil }
            guard Version(version).satisfiesHarnessEngines else { return nil }
            return version
        }
        guard let newest = versions.max(by: { Version($0) < Version($1) }) else {
            throw HarborError("No suitable Node version is available",
                              detail: "nodejs.org lists no LTS release matching the harness requirement (Node 22.19+ or 24+).")
        }
        return newest
    }

    /// Downloads, verifies, and unpacks Node. The checksum is not optional:
    /// this app runs whatever lands in that directory, so an unverified
    /// download would be an open door.
    static func installNode(progress: @escaping ProgressHandler) async throws -> URL {
        progress("Looking up the latest Node runtime…", nil)
        let version = try await latestNodeLTS()
        let base = "https://nodejs.org/dist/\(version)"
        let archiveName = "node-\(version)-darwin-\(systemArchitecture).tar.gz"

        progress("Fetching checksums…", nil)
        let (sumsData, sumsResponse) = try await URLSession.shared.data(from: URL(string: "\(base)/SHASUMS256.txt")!)
        try checkHTTP(sumsResponse, what: "Node checksums")
        guard let expected = parseChecksum(String(decoding: sumsData, as: UTF8.self), for: archiveName) else {
            throw HarborError("Node checksum is missing",
                              detail: "\(archiveName) is not listed in the official SHASUMS256.txt for \(version).")
        }

        let staging = Paths.nodeRoot.appendingPathComponent("staging-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(archiveName)
        try await download(URL(string: "\(base)/\(archiveName)")!, to: archive) { fraction in
            progress("Downloading Node \(version)…", fraction)
        }

        progress("Verifying download…", nil)
        let actual = try sha256(of: archive)
        guard actual == expected else {
            throw HarborError(
                "The Node download failed verification",
                detail: "Expected \(expected), got \(actual). The file was discarded and nothing was installed.",
                recovery: "This usually means the download was interrupted or altered in transit. Try again, and if it keeps failing, check whether something on your network is intercepting HTTPS."
            )
        }

        progress("Unpacking Node…", nil)
        try runTool("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path])
        let unpacked = staging.appendingPathComponent("node-\(version)-darwin-\(systemArchitecture)", isDirectory: true)
        let destination = Paths.nodeRoot.appendingPathComponent(version, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: unpacked, to: destination)

        let executable = destination.appendingPathComponent("bin/node")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HarborError("The Node download was incomplete",
                              detail: "No executable was found at \(executable.path) after unpacking.")
        }
        Log.write("installed node \(version)")
        return executable
    }

    // MARK: - Harness

    /// The npm registry's current `latest` for the harness.
    static func latestHarnessVersion() async throws -> String {
        var request = URLRequest(url: URL(string: "https://registry.npmjs.org/@deepseek-ai%2Fdsh/latest")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response, what: "harness release information")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String
        else {
            throw HarborError("Could not read the harness release information",
                              detail: "The npm registry returned a response this app did not understand.")
        }
        return version
    }

    /// npm's entry script, which sits at a fixed offset from the `node` binary
    /// in both official tarballs and Homebrew installs.
    static func npmCLI(for node: URL) -> URL {
        node.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
    }

    /// The install currently in flight, if any.
    ///
    /// Tracked so that quitting the app during an install stops it. Without
    /// this, Cmd+Q mid-install would leave npm running unattended — the exact
    /// orphaned-process behaviour this app exists to prevent, just with a
    /// different process.
    private static let installLock = NSLock()
    private static var activeInstall: ChildProcess?

    static func stopActiveInstall() {
        installLock.lock()
        let child = activeInstall
        installLock.unlock()
        child?.shutdown(graceSeconds: 3)
    }

    static func slot(for version: String) -> URL {
        Paths.runtimesRoot.appendingPathComponent(version, isDirectory: true)
    }

    /// The harness entry point inside an installed slot.
    static func entryPoint(in slot: URL) -> URL {
        slot.appendingPathComponent("node_modules/\(packageName)/lib/bin.js")
    }

    static func isInstalled(version: String) -> Bool {
        FileManager.default.isReadableFile(atPath: entryPoint(in: slot(for: version)).path)
    }

    /// Installs a harness version into its own slot without touching the active
    /// one. Promotion is a separate step, so an install that fails halfway
    /// leaves nothing to clean up but a directory.
    static func installHarness(
        version: String,
        node: URL,
        seedFrom: URL? = nil,
        progress: @escaping ProgressHandler,
        cancellation: @escaping () -> Bool = { false }
    ) throws {
        let destination = slot(for: version)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        if let seedFrom {
            progress("Reusing the packages you already have…", nil)
            seed(destination, from: seedFrom)
        }

        let npmCli = npmCLI(for: node)
        guard FileManager.default.isReadableFile(atPath: npmCli.path) else {
            throw HarborError("The Node runtime is missing npm",
                              detail: "Expected npm at \(npmCli.path).")
        }

        progress("Installing DeepSeek Harness \(version)… this takes a few minutes.", nil)
        let child = try ChildProcess(
            executable: node.path,
            arguments: [
                npmCli.path, "install",
                "--prefix", destination.path,
                "\(packageName)@\(version)",
                "--no-audit", "--no-fund", "--loglevel", "http",
            ],
            environment: childEnvironment(node: node),
            workingDirectory: destination.path
        )
        installLock.lock()
        activeInstall = child
        installLock.unlock()
        defer {
            installLock.lock()
            activeInstall = nil
            installLock.unlock()
        }

        // npm's own progress bar is a TTY animation that degrades to nothing
        // when piped, so the package count is the only honest signal available.
        var packagesSeen = 0
        child.readLines { line in
            if line.contains("http fetch") {
                packagesSeen += 1
                progress("Installing DeepSeek Harness \(version)… \(packagesSeen) packages", nil)
            }
        }

        while !child.hasExited {
            if cancellation() {
                Log.write("install of \(version) cancelled by request")
                child.shutdown(graceSeconds: 2)
                throw HarborError("Installation cancelled")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        Log.write("npm install of \(version) finished with status \(child.exitStatus)")
        guard child.exitStatus == 0 else {
            throw HarborError(
                "Installing the harness failed",
                detail: child.recentOutput,
                recovery: "This is almost always a network problem. Check your connection and try again."
            )
        }
        guard isInstalled(version: version) else {
            throw HarborError("The harness installed incompletely",
                              detail: "No entry point at \(entryPoint(in: destination).path).")
        }
        Log.write("installed harness \(version)")
    }

    /// Copies an existing slot's package tree into a new one before installing
    /// over it.
    ///
    /// Slots are fully isolated so that a version can be rolled back by moving
    /// one symlink, and the price of that isolation is that every update would
    /// otherwise be a full install of ~600 packages. Almost all of those
    /// packages are third-party dependencies that did not change between two
    /// harness releases, so npm reconciles a seeded tree by fetching only what
    /// actually differs.
    ///
    /// `cp -c` asks APFS for a clone: the copy shares storage with the original
    /// until one of them is written to, so seeding costs neither the disk space
    /// nor the time of a real copy. It fails rather than falling back on a
    /// filesystem that cannot clone, which is why the result is advisory —
    /// a failed seed just means npm does the full install it would have done
    /// anyway.
    private static func seed(_ destination: URL, from source: URL) {
        for item in ["node_modules", "package.json", "package-lock.json"] {
            let from = source.appendingPathComponent(item)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            do {
                try runTool("/bin/cp", ["-c", "-R", from.path, destination.path])
            } catch {
                Log.write("seed of \(item) failed; falling back to a full install")
                try? FileManager.default.removeItem(at: destination.appendingPathComponent("node_modules"))
                return
            }
        }
        Log.write("seeded \(destination.lastPathComponent) from \(source.lastPathComponent)")
    }

    /// Points `current` at a slot. Written as a replace-by-rename so a crash
    /// mid-swap leaves either the old target or the new one, never neither.
    static func promote(version: String) throws {
        guard isInstalled(version: version) else {
            throw HarborError("DeepSeek Harness \(version) is not installed",
                              detail: "No entry point at \(entryPoint(in: slot(for: version)).path).")
        }
        let temporary = Paths.support.appendingPathComponent("current.staging")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: slot(for: version))

        // rename(2), not FileManager.replaceItemAt: the latter treats the
        // destination as a file or directory to swap and fails outright when it
        // is a symlink, which this always is. rename replaces the link itself,
        // atomically, so a crash mid-swap leaves either the old target or the
        // new one and never a missing `current`.
        guard rename(temporary.path, Paths.current.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw HarborError("Could not switch to DeepSeek Harness \(version)",
                              detail: reason,
                              recovery: "The version you were using is unchanged and still starts normally.")
        }
        Log.write("promoted harness \(version)")
    }

    static func activeVersion() -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.current.path)
        else { return nil }
        return URL(fileURLWithPath: target).lastPathComponent
    }

    /// Clones `~/.dsh` before an update.
    ///
    /// This is not belt-and-braces. The harness stores sessions in SQLite with a
    /// monotonic schema version and rejects on-disk formats it does not know, so
    /// once a newer harness has written to `~/.dsh`, going back to the older one
    /// can leave it unable to read its own data. Rolling back the code without
    /// rolling back the data would be a rollback in name only.
    ///
    /// `cp -c` asks APFS to clone rather than copy, so this is near-instant and
    /// costs no extra disk until one of the copies is modified.
    @discardableResult
    static func snapshotDshHome() throws -> URL? {
        guard FileManager.default.fileExists(atPath: Paths.dshHome.path) else { return nil }
        let stamp = ISO8601DateFormatter.filenameSafe.string(from: Date())
        let destination = Paths.snapshots.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: Paths.snapshots, withIntermediateDirectories: true)
        try runTool("/bin/cp", ["-c", "-R", Paths.dshHome.path, destination.path])
        Log.write("snapshotted \(Paths.dshHome.path) -> \(destination.path)")
        return destination
    }

    /// Keeps the active slot and one predecessor. Each slot is around 350 MB,
    /// so an unbounded history would quietly consume gigabytes; one predecessor
    /// is what a rollback actually needs.
    static func pruneSlots(keeping keep: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Paths.runtimesRoot, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where !keep.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
            Log.write("pruned slot \(entry.lastPathComponent)")
        }
    }

    /// Keeps the most recent snapshots only; older ones are clones of data the
    /// user still has, so they cost nothing until they diverge, but they do
    /// accumulate directory entries.
    static func pruneSnapshots(keepingNewest count: Int) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Paths.snapshots, includingPropertiesForKeys: nil
        ) else { return }
        let sorted = entries.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for entry in sorted.dropFirst(count) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Child environment

    /// The environment every managed child gets.
    ///
    /// A Finder-launched app inherits a minimal PATH that contains neither the
    /// managed Node nor Homebrew, so the harness would find no `node`, and the
    /// agent it runs would find none of the command-line tools it expects. The
    /// managed Node goes first so the harness cannot accidentally re-enter a
    /// different runtime than the one this app verified.
    static func childEnvironment(node: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let nodeBin = node.deletingLastPathComponent().path
        let searchPath = [
            nodeBin,
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        environment["PATH"] = searchPath.joined(separator: ":")
        // Left inherited, a stale value from a development shell would silently
        // redirect the app's data directory.
        environment["DSH_HOME"] = Paths.dshHome.path
        return environment
    }

    // MARK: - Helpers

    private static func checkHTTP(_ response: URLResponse, what: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw HarborError(
                "Could not download \(what)",
                detail: "The server responded with HTTP \(http.statusCode).",
                recovery: "Check your internet connection and try again."
            )
        }
    }

    private static func parseChecksum(_ text: String, for filename: String) -> String? {
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            if fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "* ")) == filename {
                return String(fields[0])
            }
        }
        return nil
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func download(
        _ url: URL, to destination: URL, progress: @escaping (Double?) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        try checkHTTP(response, what: url.lastPathComponent)
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = 0
        var lastReport = Date.distantPast
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    progress(expected > 0 ? Double(written) / Double(expected) : nil)
                }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        progress(1)
    }
}

extension ISO8601DateFormatter {
    /// Timestamps used as directory names, so they must sort lexically and
    /// contain nothing a filesystem objects to.
    static let filenameSafe: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
