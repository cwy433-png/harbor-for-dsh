import Foundation

/// Where everything the app manages lives. Nothing is ever written inside the
/// .app bundle: modifying a signed bundle invalidates its signature, and an
/// app in /Applications is not writable by a normal user anyway.
enum Paths {
    static let appName = "Harbor for DeepSeek Harness"

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    /// Node runtimes, keyed by version: `node/v24.19.0/bin/node`.
    static var nodeRoot: URL { support.appendingPathComponent("node", isDirectory: true) }
    /// Harness slots, keyed by version: `runtimes/0.1.0-rc.6/node_modules/...`.
    static var runtimesRoot: URL { support.appendingPathComponent("runtimes", isDirectory: true) }
    /// Symlink to the active slot. Swapped atomically; the only thing that
    /// decides which harness version runs.
    static var current: URL { support.appendingPathComponent("current") }
    /// Copies of `~/.dsh` taken immediately before an update.
    static var snapshots: URL { support.appendingPathComponent("snapshots", isDirectory: true) }
    static var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    static var state: URL { support.appendingPathComponent("state.json") }

    /// The harness data directory. Shared with a terminal `dsh`, deliberately:
    /// sessions and credentials belong to the user, not to this launcher.
    static var dshHome: URL {
        if let override = ProcessInfo.processInfo.environment["DSH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh", isDirectory: true)
    }

    /// Records the server this app owns, so a force-killed app can reap its
    /// orphan on the next launch instead of leaving it holding the port.
    static var pidFile: URL { support.appendingPathComponent("server.pid") }

    static func ensureDirectories() throws {
        for dir in [support, nodeRoot, runtimesRoot, snapshots, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Append-only log, mirrored to stderr so `Console.app` and a terminal launch
/// both show it. Kept deliberately dumb: a launcher that needs a logging
/// framework to explain why it will not start has failed at its one job.
enum Log {
    private static let queue = DispatchQueue(label: "harbor.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let url = Paths.logs.appendingPathComponent("harbor.log")
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// A failure with something the user can actually do about it. Every error the
/// app shows carries a recovery suggestion, because the audience for this app
/// is explicitly not developers.
struct HarborError: LocalizedError {
    let summary: String
    let detail: String
    let recovery: String?

    var errorDescription: String? { summary }
    var failureReason: String? { detail }
    var recoverySuggestion: String? { recovery }

    init(_ summary: String, detail: String = "", recovery: String? = nil) {
        self.summary = summary
        self.detail = detail
        self.recovery = recovery
    }
}

/// Semantic-version comparison good enough for Node's `vMAJOR.MINOR.PATCH` and
/// npm's `MAJOR.MINOR.PATCH-rc.N`. Prerelease tags sort before their release,
/// and are compared numerically where both sides are numeric so `rc.10` sorts
/// after `rc.9` rather than lexically before it.
struct Version: Comparable, CustomStringConvertible {
    let raw: String
    let numbers: [Int]
    let prerelease: [String]

    init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        self.numbers = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        self.prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    var major: Int { numbers.first ?? 0 }
    var minor: Int { numbers.count > 1 ? numbers[1] : 0 }
    var description: String { raw }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        // A prerelease precedes the release it leads to; absence sorts higher.
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for i in 0..<max(a.prerelease.count, b.prerelease.count) {
            let x = i < a.prerelease.count ? a.prerelease[i] : ""
            let y = i < b.prerelease.count ? b.prerelease[i] : ""
            if x == y { continue }
            if let xi = Int(x), let yi = Int(y) { return xi < yi }
            return x < y
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    /// The harness engine range: `^22.19.0 || >=24.0.0`.
    var satisfiesHarnessEngines: Bool {
        if major == 22 { return minor >= 19 }
        return major >= 24
    }
}

/// Persisted across launches: which harness version is active, which one we
/// rolled back from, and whether the user pointed the app at a checkout.
struct AppState: Codable {
    var harnessVersion: String?
    var nodeVersion: String?
    var previousHarnessVersion: String?
    var developerCheckoutPath: String?
    var lastUpdateCheck: Date?
    /// Optional so a state file written before this existed still decodes.
    var autoCheckDisabled: Bool?
    /// The version the user has already been told about, so a release that
    /// they decided not to install does not ask again on every launch.
    var notifiedVersion: String?

    var autoCheckEnabled: Bool { autoCheckDisabled != true }

    static func load() -> AppState {
        guard let data = try? Data(contentsOf: Paths.state),
              let decoded = try? JSONDecoder().decode(AppState.self, from: data)
        else { return AppState() }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }
}

/// Runs a bundled tool (`tar`, `cp`) and collects its output. Only ever used
/// with absolute paths from /usr/bin, never with a PATH lookup: a Finder-
/// launched app inherits a minimal PATH, so a bare tool name is a coin flip.
@discardableResult
func runTool(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw HarborError(
            "\(URL(fileURLWithPath: executable).lastPathComponent) failed",
            detail: output.isEmpty ? "exit status \(process.terminationStatus)" : output
        )
    }
    return output
}
