import Foundation

// Diagnostic harness: drives the real RuntimeManager.installHarness with the
// real ChildProcess spawn, outside AppKit, so a failing install can be observed
// without a GUI in the way. Not part of the app.

let arguments = CommandLine.arguments

// `probe promote <version>` exercises only the symlink swap, which is the step
// that decides what actually runs.
if arguments.count > 2, arguments[1] == "promote" {
    let target = arguments[2]
    print("probe: before, current -> \(RuntimeManager.activeVersion() ?? "<none>")")
    do {
        try RuntimeManager.promote(version: target)
        print("probe: after,  current -> \(RuntimeManager.activeVersion() ?? "<none>")")
        print("probe: entry point resolves = \(FileManager.default.isReadableFile(atPath: Paths.current.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js").path))")
        exit(0)
    } catch {
        print("probe: promote FAILED — \(error)")
        exit(1)
    }
}

/// Waits for a callback-driven step while keeping the main run loop turning,
/// which the server controller needs to deliver its readiness callback.
func waitUntil(_ label: String, timeout: TimeInterval, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if done() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    print("probe: TIMED OUT waiting for \(label)")
    return false
}

// `probe updateflow <target>` replays the exact sequence the app's update
// performs — stop, snapshot, seeded install, promote, restart, prune — using the
// same types, so the ordering can be verified without driving the interface.
if arguments.count > 2, arguments[1] == "updateflow" {
    let target = arguments[2]
    let node = URL(fileURLWithPath: "/opt/homebrew/bin/node")
    let controller = ServerController()
    let home = FileManager.default.homeDirectoryForCurrentUser
    var failed = false

    func boot(_ label: String) -> Bool {
        guard let active = RuntimeManager.activeVersion() else { print("probe: no active version"); return false }
        print("probe: [\(label)] starting \(active)")
        var ready = false
        controller.start(
            node: node,
            entryPoint: RuntimeManager.entryPoint(in: RuntimeManager.slot(for: active)),
            workingDirectory: home,
            onReady: { url in print("probe: [\(label)] ready at \(url)"); ready = true },
            onFailure: { error in print("probe: [\(label)] FAILED — \(error.summary): \(error.detail)"); failed = true }
        )
        return waitUntil("\(label) readiness", timeout: 60) { ready || failed } && !failed
    }

    guard ServerController.isPortAvailable() else {
        print("probe: port \(ServerController.port) is busy; nothing to test against")
        exit(1)
    }

    let before = RuntimeManager.activeVersion()
    print("probe: === step 1: run the version being replaced ===")
    guard boot("before") else { exit(1) }

    print("probe: === step 2: stop it ===")
    controller.stop()
    print("probe: port free after stop = \(ServerController.isPortAvailable())")

    print("probe: === step 3: snapshot ~/.dsh ===")
    let snapshot = try? RuntimeManager.snapshotDshHome()
    print("probe: snapshot = \((snapshot ?? nil)?.lastPathComponent ?? "<none>")")

    print("probe: === step 4: seeded install of \(target) ===")
    let seed = before.flatMap { RuntimeManager.isInstalled(version: $0) ? RuntimeManager.slot(for: $0) : nil }
    do {
        try RuntimeManager.installHarness(
            version: target, node: node, seedFrom: seed,
            progress: { message, _ in if !message.contains("packages") { print("probe: \(message)") } },
            cancellation: { false }
        )
    } catch {
        print("probe: install FAILED — \(error)")
        exit(1)
    }

    print("probe: === step 5: promote ===")
    do { try RuntimeManager.promote(version: target) } catch {
        print("probe: promote FAILED — \(error)")
        exit(1)
    }

    print("probe: === step 6: restart on the new version ===")
    guard boot("after") else { exit(1) }
    print("probe: active = \(RuntimeManager.activeVersion() ?? "<none>")")

    print("probe: === step 7: prune, keeping \(target) and \(before ?? "<none>") ===")
    RuntimeManager.pruneSlots(keeping: Set([target, before].compactMap { $0 }))
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: Paths.runtimesRoot.path)) ?? []
    print("probe: slots remaining = \(remaining.sorted())")

    print("probe: === step 8: shut down ===")
    controller.stop()
    print("probe: port free = \(ServerController.isPortAvailable())")
    print("probe: UPDATE FLOW OK")
    exit(0)
}

let version = arguments.count > 1 ? arguments[1] : "0.1.0-rc.6"
let node = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "/opt/homebrew/bin/node")

print("probe: node=\(node.path) version=\(version)")
print("probe: npm-cli=\(RuntimeManager.npmCLI(for: node).path)")
print("probe: slot=\(RuntimeManager.slot(for: version).path)")

let environment = RuntimeManager.childEnvironment(node: node)
for key in ["PATH", "HOME", "DSH_HOME", "TMPDIR"] {
    print("probe: env \(key)=\(environment[key] ?? "<unset>")")
}

do {
    try Paths.ensureDirectories()
    let seed = arguments.count > 3 ? RuntimeManager.slot(for: arguments[3]) : nil
    print("probe: seed=\(seed?.lastPathComponent ?? "<none>")")
    try RuntimeManager.installHarness(
        version: version,
        node: node,
        seedFrom: seed,
        progress: { message, _ in print("probe: \(message)") },
        cancellation: { false }
    )
    print("probe: install reported success")
    print("probe: entry point present = \(RuntimeManager.isInstalled(version: version))")
} catch let error as HarborError {
    print("probe: FAILED — \(error.summary)")
    print("probe: detail —\n\(error.detail)")
    exit(1)
} catch {
    print("probe: FAILED — \(error)")
    exit(1)
}
