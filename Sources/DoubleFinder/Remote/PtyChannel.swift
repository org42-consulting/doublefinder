import Foundation
import Darwin

/// A bidirectional bytestream connected to the master side of a pseudo-terminal
/// running an arbitrary child process. Reads and writes are non-blocking.
final class PtyChannel: @unchecked Sendable {

    enum SpawnError: Error, CustomStringConvertible {
        case ptyAllocationFailed(code: Int32)
        case spawnFailed(tool: String, code: Int32)

        var description: String {
            switch self {
            case .ptyAllocationFailed(let code):
                return "could not allocate a pseudo-terminal (\(Self.explain(code)))"
            case .spawnFailed(let tool, let code):
                return "could not launch \(tool) (\(Self.explain(code)))"
            }
        }

        private static func explain(_ code: Int32) -> String {
            String(cString: strerror(code))
        }
    }

    private let masterFD: Int32
    private let pid: pid_t
    private let readQueue = DispatchQueue(label: "PtyChannel.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "PtyChannel.write", qos: .userInitiated)
    private var channel: DispatchIO?
    private var closed = false
    private let onBytes: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private var waitTask: Task<Void, Never>?

    /// - Parameters:
    ///   - executable: absolute path to the program to spawn.
    ///   - arguments: argv (the first element is conventionally executable's basename).
    ///   - environment: extra env vars to set on top of the current process's env.
    ///   - onBytes: invoked with each chunk of bytes read from the master fd. Called on a private queue.
    ///   - onExit: invoked once with the child's exit status when it terminates. Called on a private queue.
    init(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        onBytes: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.onBytes = onBytes
        self.onExit = onExit

        let (master, pid) = try Self.spawn(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        self.masterFD = master
        self.pid = pid

        // Set master fd to non-blocking (DispatchIO needs this for sane behaviour).
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: master,
            queue: readQueue,
            cleanupHandler: { _ in close(master) }
        )
        channel.setLimit(lowWater: 1)
        self.channel = channel

        startReading()
        startWaiting()
    }

    deinit {
        terminate()
    }

    // MARK: - Spawning

    /// Allocate a pseudo-terminal and launch `executable` on its slave side,
    /// returning the master fd and the child's pid.
    ///
    /// Uses `posix_spawn` rather than `fork` + `exec`. That distinction is the
    /// whole reason this file is pure Swift: on Darwin `posix_spawn` is a single
    /// system call, so there is never a child process running *our* code, and
    /// the fork-safety rule — between `fork` and `exec` a child may only call
    /// async-signal-safe functions — simply doesn't apply. Swift offers no way
    /// to guarantee the compiler emits no runtime calls (a retain, an
    /// exclusivity check, an allocation) inside that window, which is why this
    /// used to be a C shim in its own SwiftPM target.
    ///
    /// Reproducing what `forkpty` gave us takes two pieces, because `sftp`
    /// delegates to `ssh`, and `ssh` needs a real **controlling terminal** to
    /// prompt for a password, a key passphrase, or host-key confirmation:
    ///
    /// 1. `POSIX_SPAWN_SETSID` makes the child a session leader (the `setsid()`
    ///    half of `login_tty`).
    /// 2. Opening the slave *by path* as a spawn file action gives it the
    ///    controlling terminal (the `ioctl(TIOCSCTTY)` half). On BSD/Darwin a
    ///    session leader with no controlling terminal that opens a tty without
    ///    `O_NOCTTY` acquires that tty as its controlling terminal.
    ///
    /// Verified end-to-end against the real OpenSSH tools: the child sees
    /// `/dev/tty` open successfully, and `ssh-keygen` prompts for a passphrase
    /// on this pty and accepts a reply written to the master.
    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (master: Int32, pid: pid_t) {
        // Master side stays in this process. O_NOCTTY so *we* never accidentally
        // adopt the pty as our own controlling terminal.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SpawnError.ptyAllocationFailed(code: errno) }
        guard grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            let code = errno
            close(master)
            throw SpawnError.ptyAllocationFailed(code: code)
        }
        let slavePath = String(cString: slaveName)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // stdin is an *open* of the slave path — that open is what confers the
        // controlling terminal. stdout and stderr are then duplicated from it.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)
        // The child has no use for the master end.
        posix_spawn_file_actions_addclose(&actions, master)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // SETSIGDEF alongside SETSID: signal dispositions set to SIG_IGN survive
        // `exec`, and a GUI process commonly ignores SIGPIPE, so the old
        // fork/exec child inherited a signal state we never chose. Resetting
        // every signal to its default also keeps `interruptInFlight()` honest —
        // the ^C it writes into the pty has to reach sftp as an ordinary SIGINT.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF))
        var defaultedSignals = sigset_t()
        sigfillset(&defaultedSignals)
        posix_spawnattr_setsigdefault(&attr, &defaultedSignals)

        // argv / envp as null-terminated C arrays. `posix_spawn` copies them
        // before it returns, so freeing on the way out is safe.
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envMerged = ProcessInfo.processInfo.environment
        for (k, v) in environment { envMerged[k] = v }
        var envp: [UnsafeMutablePointer<CChar>?] = envMerged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        // `posix_spawn` returns an errno as its result rather than setting the
        // global, so a missing or non-executable binary surfaces here as ENOENT
        // / EACCES. `forkpty` + `execve` could only ever report that as the
        // child exiting 127, indistinguishable from sftp dying on startup.
        let rc = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
        guard rc == 0 else {
            close(master)
            throw SpawnError.spawnFailed(tool: executable, code: rc)
        }
        return (master, pid)
    }

    /// Send bytes to the child's tty input.
    func write(_ data: Data) {
        guard !closed else { return }
        let dd = data.withUnsafeBytes { ptr -> DispatchData in
            DispatchData(bytes: UnsafeRawBufferPointer(start: ptr.baseAddress, count: ptr.count))
        }
        channel?.write(offset: 0, data: dd, queue: writeQueue) { _, _, _ in }
    }

    /// Send EOF (close the write side). Useful for cancelling an interactive operation.
    func sendEOF() {
        // Ctrl-D byte (0x04) — the pty driver treats it as EOF when the line is empty.
        write(Data([0x04]))
    }

    /// Force-terminate the child by sending SIGTERM. If still alive after 1s, SIGKILL.
    func terminate() {
        guard !closed else { return }
        closed = true
        kill(pid, SIGTERM)
        // Best-effort hard kill if process doesn't exit in time.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [pid] in
            kill(pid, SIGKILL)
        }
        channel?.close()
        channel = nil
    }

    private func startReading() {
        guard let channel else { return }
        channel.read(offset: 0, length: .max, queue: readQueue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var bytes = Data(count: data.count)
                bytes.withUnsafeMutableBytes { buf in
                    _ = data.copyBytes(to: buf)
                }
                self.onBytes(bytes)
            }
            if done {
                // Read closed (typically because child exited or we terminated).
                self.closed = true
            }
        }
    }

    private func startWaiting() {
        waitTask = Task.detached(priority: .utility) { [pid, onExit] in
            var status: Int32 = 0
            // Block until the child exits.
            _ = waitpid(pid, &status, 0)
            let exitCode: Int32
            if (status & 0x7F) == 0 {
                exitCode = (status >> 8) & 0xFF
            } else {
                exitCode = -1 // killed by signal
            }
            onExit(exitCode)
        }
    }
}
