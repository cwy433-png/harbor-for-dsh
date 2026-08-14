import Darwin
import Foundation

/// A child process in its own process group, with stdout and stderr merged into
/// one pipe.
///
/// `Foundation.Process` is not used here for one specific reason: it offers no
/// way to put the child in a new process group, so the child would share this
/// app's group. The harness spawns shells and tool subprocesses of its own, and
/// killing only the direct child orphans all of them — but signalling the shared
/// group would kill the app itself. A dedicated group makes "stop everything I
/// started, and nothing else" expressible as a single signal.
final class ChildProcess {
    let pid: pid_t
    private let outputFD: Int32
    private var lineHandler: ((String) -> Void)?
    private let lock = NSLock()
    private var _exitStatus: Int32?
    private var _recentOutput: [String] = []

    /// Whether the child has been reaped. Polled rather than awaited so callers
    /// can interleave a cancellation check.
    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return _exitStatus != nil
    }

    var exitStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        return _exitStatus ?? -1
    }

    /// The tail of the child's output, for error messages. Bounded, because a
    /// failing child can produce output indefinitely.
    var recentOutput: String {
        lock.lock(); defer { lock.unlock() }
        return _recentOutput.joined(separator: "\n")
    }

    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) throws {
        var fileDescriptors: [Int32] = [0, 0]
        guard pipe(&fileDescriptors) == 0 else {
            throw HarborError("Could not create a pipe to the harness process",
                              detail: String(cString: strerror(errno)))
        }
        let readEnd = fileDescriptors[0]
        let writeEnd = fileDescriptors[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, writeEnd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, readEnd)
        posix_spawn_file_actions_addclose(&fileActions, writeEnd)
        posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A pgroup of 0 means "the child's own pid", so the group id equals the
        // pid returned below and `kill(-pid, …)` reaches the whole tree.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var spawnedPID: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { argvBuffer in
            (envp + [nil]).withUnsafeBufferPointer { envpBuffer in
                posix_spawn(
                    &spawnedPID, executable, &fileActions, &attributes,
                    UnsafeMutablePointer(mutating: argvBuffer.baseAddress),
                    UnsafeMutablePointer(mutating: envpBuffer.baseAddress)
                )
            }
        }
        close(writeEnd)
        guard result == 0 else {
            close(readEnd)
            throw HarborError(
                "Could not start the harness process",
                detail: "\(executable): \(String(cString: strerror(result)))"
            )
        }

        self.pid = spawnedPID
        self.outputFD = readEnd
        Log.write("spawned pid \(spawnedPID): \(executable) \(arguments.joined(separator: " "))")
        startReading()
        startReaping()
    }

    /// Delivers each output line as it arrives. Installed after construction so
    /// a caller can attach before the child produces anything meaningful; lines
    /// that arrive first are still captured in `recentOutput`.
    func readLines(_ handler: @escaping (String) -> Void) {
        lock.lock()
        lineHandler = handler
        let backlog = _recentOutput
        lock.unlock()
        backlog.forEach(handler)
    }

    private func startReading() {
        Thread.detachNewThread { [outputFD] in
            var pending = ""
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(outputFD, &buffer, buffer.count)
                if count <= 0 { break }
                pending += String(decoding: buffer[0..<count], as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    let line = String(pending[pending.startIndex..<newline])
                    pending = String(pending[pending.index(after: newline)...])
                    self.deliver(line)
                }
            }
            if !pending.isEmpty { self.deliver(pending) }
            close(outputFD)
        }
    }

    private func deliver(_ line: String) {
        lock.lock()
        _recentOutput.append(line)
        if _recentOutput.count > 200 { _recentOutput.removeFirst(_recentOutput.count - 200) }
        let handler = lineHandler
        lock.unlock()
        handler?(line)
    }

    private func startReaping() {
        Thread.detachNewThread { [pid] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR { continue }
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
            self.lock.lock()
            self._exitStatus = code
            self.lock.unlock()
            Log.write("pid \(pid) exited with \(code)")
        }
    }

    /// Stops the whole process group: SIGTERM first so the harness can close
    /// its SQLite handles and flush session state, then SIGKILL for anything
    /// still standing once the grace period expires.
    func shutdown(graceSeconds: Double) {
        guard !hasExited else { return }
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(graceSeconds)
        while !hasExited && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !hasExited {
            Log.write("pid \(pid) did not exit within \(graceSeconds)s; sending SIGKILL")
            kill(-pid, SIGKILL)
            let hardDeadline = Date().addingTimeInterval(2)
            while !hasExited && Date() < hardDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}

/// Owns the harness server process for the lifetime of the app.
final class ServerController {
    /// Fixed, not chosen dynamically. The web UI keeps its state in the
    /// browser's per-origin storage, and the origin includes the port, so a
    /// port that changes between launches would silently discard the user's
    /// theme, layout, and drafts every time.
    static let port = 3080

    private var child: ChildProcess?
    private(set) var url: URL?

    var isRunning: Bool { child != nil && !(child?.hasExited ?? true) }

    /// Kills a server left behind by a previous run of this app.
    ///
    /// Only a process this app recorded is ever signalled. The pid file holds
    /// the process's start time as well as its pid, because pids are recycled:
    /// without that check, a stale file could name a pid the system has since
    /// handed to something else entirely.
    static func reapOrphanedServer() {
        guard let data = try? Data(contentsOf: Paths.pidFile),
              let record = try? JSONDecoder().decode(PIDRecord.self, from: data)
        else { return }
        defer { try? FileManager.default.removeItem(at: Paths.pidFile) }

        guard kill(record.pid, 0) == 0 else { return }
        guard processStartTime(record.pid) == record.startTime else {
            Log.write("pid \(record.pid) was recycled; leaving it alone")
            return
        }
        Log.write("reaping orphaned server pid \(record.pid)")
        kill(-record.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while kill(record.pid, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(record.pid, 0) == 0 { kill(-record.pid, SIGKILL) }
    }

    /// Whether the fixed port is free.
    ///
    /// If it is not, the app refuses to start rather than attaching to whatever
    /// is there. Adopting a stranger's server would mean either killing a
    /// process the user started in a terminal, or — far more likely, since a
    /// leftover harness is exactly what motivated this app — quietly declining
    /// to shut down on quit, which is the one thing the app exists to do.
    static func isPortAvailable() -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// Starts the harness and calls back once it is ready to serve.
    ///
    /// Readiness is the URL line the harness prints on stdout, not a successful
    /// HTTP connection. The harness prints that line only after its plugin tree
    /// has settled, and it documents the line as the signal supervisors should
    /// wait for; a socket that accepts connections can still be a tree with
    /// half its routes unmounted.
    func start(
        node: URL,
        entryPoint: URL,
        workingDirectory: URL,
        onReady: @escaping (URL) -> Void,
        onFailure: @escaping (HarborError) -> Void
    ) {
        do {
            let child = try ChildProcess(
                executable: node.path,
                arguments: [entryPoint.path, "--profile", "web", "--port", String(Self.port)],
                environment: RuntimeManager.childEnvironment(node: node),
                workingDirectory: workingDirectory.path
            )
            self.child = child
            recordPID(child.pid)

            var reported = false
            child.readLines { line in
                guard !reported, let range = line.range(of: "dsh web: ") else { return }
                let remainder = line[range.upperBound...]
                let address = remainder.split(separator: " ").first.map(String.init) ?? ""
                guard let resolved = URL(string: address) else { return }
                reported = true
                self.url = resolved
                DispatchQueue.main.async { onReady(resolved) }
            }

            // A child that dies before printing its URL has failed to start;
            // without this the app would wait on a signal that is never coming.
            DispatchQueue.global().async {
                while !child.hasExited && !reported {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard !reported, child.hasExited else { return }
                let error = HarborError(
                    "The harness stopped before it finished starting",
                    detail: child.recentOutput,
                    recovery: "Try “Reinstall Harness” from the Harness menu. If it keeps happening, the installed version may be broken — roll back to the previous one."
                )
                DispatchQueue.main.async { onFailure(error) }
            }
        } catch let error as HarborError {
            onFailure(error)
        } catch {
            onFailure(HarborError("Could not start the harness", detail: error.localizedDescription))
        }
    }

    /// Stops the server and waits for it. Called from `applicationWillTerminate`,
    /// where blocking is correct: the app must not disappear before the process
    /// it started is actually gone, or Cmd+Q leaves exactly the orphan this app
    /// was built to prevent.
    func stop() {
        guard let child else { return }
        child.shutdown(graceSeconds: 5)
        self.child = nil
        self.url = nil
        try? FileManager.default.removeItem(at: Paths.pidFile)
    }

    private func recordPID(_ pid: pid_t) {
        let record = PIDRecord(pid: pid, startTime: Self.processStartTime(pid) ?? 0)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: Paths.pidFile, options: .atomic)
    }

    private struct PIDRecord: Codable {
        let pid: pid_t
        /// Seconds since the epoch, from the kernel process table. Distinguishes
        /// the process this app started from a later one that reused its pid.
        let startTime: Int64
    }

    private static func processStartTime(_ pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&name, u_int(name.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return Int64(info.kp_proc.p_starttime.tv_sec)
    }
}
