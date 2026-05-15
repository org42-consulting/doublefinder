import Foundation
import Darwin
import DoubleFinderC

/// A bidirectional bytestream connected to the master side of a pseudo-terminal
/// running an arbitrary child process. Reads and writes are non-blocking.
final class PtyChannel: @unchecked Sendable {

    enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
        case alreadyClosed
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

        // Build argv and envp as null-terminated C arrays.
        // strdup so the memory stays alive across the synchronous spawn call.
        let argvStorage: [UnsafeMutablePointer<CChar>?] =
            arguments.map { strdup($0) } + [nil]
        defer { for p in argvStorage where p != nil { free(p) } }

        var envMerged = ProcessInfo.processInfo.environment
        for (k, v) in environment { envMerged[k] = v }
        let envpStorage: [UnsafeMutablePointer<CChar>?] =
            envMerged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in envpStorage where p != nil { free(p) } }

        var master: Int32 = -1
        let pid = argvStorage.withUnsafeBufferPointer { argvBuf in
            envpStorage.withUnsafeBufferPointer { envpBuf in
                df_spawn_pty(
                    &master,
                    executable,
                    UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                    UnsafeMutablePointer(mutating: envpBuf.baseAddress)
                )
            }
        }
        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

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
