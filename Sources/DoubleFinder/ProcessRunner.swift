import Foundation

/// Outcome of running a subprocess to completion.
struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
    /// True when the watchdog killed the process rather than it exiting on its own.
    let timedOut: Bool

    var stdoutText: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderrText: String { String(decoding: standardError, as: UTF8.self) }
    var succeeded: Bool { !timedOut && status == 0 }
}

/// Runs short-lived helper tools (`git`, `curl`, `unzip`, `tar`, `codesign`, …)
/// without the deadlock that `Process` + `Pipe` invites.
///
/// The trap: a pipe holds ~64 KB. If the parent calls `waitUntilExit()` before
/// reading, a child that produces more than that blocks forever on `write(2)`,
/// so it never exits and the parent never returns. `git status --porcelain` in
/// a repo with a few thousand untracked files clears 64 KB easily, so this is a
/// live failure mode, not a theoretical one.
///
/// Every path here drains stdout and stderr on their own queues *while* the
/// child runs, so neither pipe can fill. A watchdog bounds the total wall time,
/// and `timedOut` reports which way the process ended so callers can tell a
/// genuine non-zero exit from a kill.
enum ProcessRunner {

    enum Failure: Error, LocalizedError {
        case launchFailed(tool: String, underlying: String)
        case timedOut(tool: String, seconds: TimeInterval)
        case exited(tool: String, status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let tool, let underlying):
                return "Could not run \(tool): \(underlying)"
            case .timedOut(let tool, let seconds):
                return "\(tool) did not finish within \(Int(seconds))s and was stopped."
            case .exited(let tool, let status, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "\(tool) failed with exit code \(status)."
                    : "\(tool) failed: \(trimmed)"
            }
        }
    }

    /// Run `executable` to completion and return its output. Never throws on a
    /// non-zero exit — inspect `ProcessResult.succeeded` — so callers that treat
    /// failure as "no data" (git decoration, `exists` probes) stay branch-free.
    ///
    /// - Parameters:
    ///   - stdin: written to the child's standard input, which is then closed.
    ///     Use this for secrets: process arguments are world-readable via `ps`,
    ///     standard input is not.
    ///   - timeout: wall-clock bound. On expiry the child gets `SIGTERM` and the
    ///     result comes back with `timedOut == true`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(tool: executable, underlying: error.localizedDescription)
        }

        // Drain both pipes concurrently with the child's execution. `readDataToEndOfFile`
        // returns when the write end closes, which happens on child exit.
        let out = DataBox()
        let err = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "df.process.io", attributes: .concurrent)

        group.enter()
        queue.async {
            out.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        queue.async {
            err.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if let inPipe, let stdin {
            group.enter()
            queue.async {
                inPipe.fileHandleForWriting.write(stdin)
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }
        }

        let killed = FlagBox()
        let watchdog = DispatchWorkItem {
            killed.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: out.value,
            standardError: err.value,
            timedOut: killed.value
        )
    }

    /// `run` hopped off the caller's actor. Use from `async` contexts so the
    /// blocking wait never lands on the main actor.
    static func runAsync(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try run(executable, arguments, currentDirectory: currentDirectory, stdin: stdin, timeout: timeout)
        }.value
    }

    /// `runAsync`, but a timeout or non-zero exit throws `Failure` with the
    /// child's stderr attached. For callers that surface errors to the user.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let result = try await runAsync(
            executable, arguments,
            currentDirectory: currentDirectory, stdin: stdin, timeout: timeout
        )
        if result.timedOut {
            throw Failure.timedOut(tool: executable, seconds: timeout)
        }
        guard result.status == 0 else {
            throw Failure.exited(tool: executable, status: result.status, stderr: result.stderrText)
        }
        return result.stdoutText
    }
}

// MARK: - Small thread-safe boxes
//
// The drain closures run on a concurrent queue and hand their results back to
// the calling thread after `group.wait()`. These boxes make that handoff
// explicit rather than relying on `nonisolated(unsafe)` captures.

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
