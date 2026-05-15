import Foundation

/// One persistent `sftp` subprocess per (user, host, port). Commands are serialised
/// through the actor's mailbox; only one command is in flight at a time.
actor SFTPSession {

    // MARK: - Public types

    enum State: Equatable {
        case spawning
        case authenticating
        case ready
        case authFailed(reason: String)
        case disconnected(reason: String)
        case closed
    }

    typealias PromptReply = String        // raw bytes (without trailing newline) we'll write back
    typealias PromptHandler = @Sendable (SFTPPrompt) async -> PromptReply?

    enum SessionError: Error, LocalizedError {
        case spawnFailed(String)
        case authFailed(String)
        case disconnected(String)
        case operationFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .spawnFailed(let m), .authFailed(let m), .disconnected(let m), .operationFailed(let m): return m
            case .cancelled: return "Cancelled"
            }
        }
    }

    // MARK: - Stored state

    let endpoint: RemoteEndpoint
    private(set) var state: State = .spawning

    private var channel: PtyChannel!
    private var readBuffer = ""              // raw accumulated bytes (decoded as UTF-8 lossily)
    private var promptHandler: PromptHandler?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    // While in .ready, we serialise commands through this single-slot queue.
    private var commandInFlight: CommandCtx?
    private var commandQueue: [CommandCtx] = []
    private var disconnectObservers: [@Sendable (String) -> Void] = []

    private struct CommandCtx {
        let line: String              // command to send (without trailing newline)
        let progress: Progress?       // optional, for upload/download
        let continuation: CheckedContinuation<String, Error>
    }

    // MARK: - Init / connect

    init(endpoint: RemoteEndpoint, promptHandler: @escaping PromptHandler) {
        self.endpoint = endpoint
        self.promptHandler = promptHandler
    }

    /// Spawn `sftp` and drive auth until either `.ready` or `.authFailed`.
    /// Throws on failure; returns when the session is ready to accept commands.
    func start() async throws {
        var args: [String] = ["sftp"]
        args += ["-o", "StrictHostKeyChecking=ask"]
        args += ["-o", "BatchMode=no"]
        args += ["-o", "PreferredAuthentications=publickey,password,keyboard-interactive"]
        args += ["-o", "ConnectTimeout=15"]
        args += ["-o", "ServerAliveInterval=30"]
        if endpoint.port != 22 {
            args += ["-P", String(endpoint.port)]
        }
        if let id = endpoint.identityFile {
            args += ["-i", id.path]
        }
        args.append("\(endpoint.user)@\(endpoint.host)")

        do {
            channel = try PtyChannel(
                executable: "/usr/bin/sftp",
                arguments: args,
                onBytes: { [weak self] data in
                    Task { await self?.handleBytes(data) }
                },
                onExit: { [weak self] code in
                    Task { await self?.handleExit(code: code) }
                }
            )
            state = .authenticating
        } catch {
            state = .authFailed(reason: "Could not spawn sftp: \(error)")
            throw SessionError.spawnFailed("Could not spawn sftp: \(error)")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
        }
    }

    // MARK: - Disconnect subscription (for TabState mid-session handling)

    func onDisconnect(_ handler: @escaping @Sendable (String) -> Void) {
        disconnectObservers.append(handler)
    }

    // MARK: - Lifecycle

    func close() {
        state = .closed
        channel?.terminate()
        // Fail any pending commands.
        let pending = commandInFlight.map { [$0] } ?? []
        let queued = commandQueue
        commandInFlight = nil
        commandQueue = []
        for ctx in pending + queued {
            ctx.continuation.resume(throwing: SessionError.cancelled)
        }
        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: SessionError.cancelled)
        }
    }

    // MARK: - Sending raw bytes (for prompt replies and command-cancel)

    fileprivate func writeRaw(_ bytes: Data) {
        channel?.write(bytes)
    }

    /// Send a Ctrl-C byte to interrupt the in-flight command (e.g., to cancel a transfer).
    func interruptInFlight() {
        channel?.write(Data([0x03])) // ^C → SIGINT to sftp's foreground job
    }

    // MARK: - Command submission

    /// Send a command, await its full output (everything between command line and the next `sftp> `).
    /// Throws `SessionError.disconnected` if the session is no longer ready.
    func send(_ command: String, progress: Progress? = nil) async throws -> String {
        guard state == .ready else {
            throw SessionError.disconnected("Not connected")
        }
        return try await withCheckedThrowingContinuation { cont in
            let ctx = CommandCtx(line: command, progress: progress, continuation: cont)
            if commandInFlight == nil {
                commandInFlight = ctx
                dispatchInFlight()
            } else {
                commandQueue.append(ctx)
            }
        }
    }

    private func dispatchInFlight() {
        guard let ctx = commandInFlight else { return }
        readBuffer.removeAll(keepingCapacity: true)
        channel?.write(Data("\(ctx.line)\n".utf8))
    }

    // MARK: - Byte stream handling

    private func handleBytes(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return
        }
        readBuffer += chunk

        switch state {
        case .spawning, .authenticating:
            handleAuthBytes()
        case .ready:
            handleCommandBytes()
        case .authFailed, .disconnected, .closed:
            break
        }
    }

    private func handleAuthBytes() {
        // Check for the sftp> prompt first — that means auth succeeded.
        if let promptRange = readBuffer.range(of: "sftp> ") {
            // Drop everything up to and including the prompt; we'll start fresh.
            readBuffer.removeSubrange(readBuffer.startIndex..<promptRange.upperBound)
            state = .ready
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume()
            }
            return
        }
        // Otherwise classify accumulated buffer for a known prompt.
        guard let handler = promptHandler else { return }
        guard let prompt = SFTPPromptClassifier.classify(readBuffer) else { return }

        // We have a prompt; clear the buffer up to where the prompt was matched
        // (best-effort: clear entirely) and dispatch to the handler.
        readBuffer.removeAll(keepingCapacity: true)
        let endpoint = self.endpoint
        Task { [weak self] in
            let reply = await handler(prompt)
            guard let self else { return }
            await self.deliverPromptReply(prompt: prompt, reply: reply, endpoint: endpoint)
        }
    }

    private func deliverPromptReply(prompt: SFTPPrompt, reply: String?, endpoint: RemoteEndpoint) async {
        switch prompt {
        case .hostKeyMismatch:
            // Always refuse and surface error.
            channel?.write(Data("no\n".utf8))
            state = .authFailed(reason: "Host key for \(endpoint.host) has changed. Refusing to connect.")
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(throwing: SessionError.authFailed("Host key for \(endpoint.host) has changed."))
            }
            channel?.terminate()
        case .hostKey:
            // reply == "yes" / "no" / nil (cancel)
            let answer = (reply == "yes") ? "yes\n" : "no\n"
            channel?.write(Data(answer.utf8))
            if reply == nil || reply == "no" {
                state = .authFailed(reason: "User declined host-key verification.")
                if let cont = readyContinuation {
                    readyContinuation = nil
                    cont.resume(throwing: SessionError.authFailed("User declined host-key verification."))
                }
            }
        case .password, .passphrase:
            if let reply {
                channel?.write(Data((reply + "\n").utf8))
            } else {
                // User cancelled
                state = .authFailed(reason: "Authentication cancelled.")
                if let cont = readyContinuation {
                    readyContinuation = nil
                    cont.resume(throwing: SessionError.cancelled)
                }
                channel?.terminate()
            }
        }
    }

    private func handleCommandBytes() {
        guard let ctx = commandInFlight else {
            // Stray bytes — drop them.
            return
        }
        // Update progress for upload/download if the buffer contains a Transferred line.
        if let progress = ctx.progress {
            SFTPParser.updateProgress(progress, from: readBuffer)
        }
        // Look for the prompt at the start of a line.
        if let promptRange = readBuffer.range(of: "\nsftp> ") ?? readBuffer.range(of: "sftp> ", options: .anchored) {
            let output = String(readBuffer[readBuffer.startIndex..<promptRange.lowerBound])
            readBuffer.removeSubrange(readBuffer.startIndex..<promptRange.upperBound)
            commandInFlight = nil

            // Echo cleanup: sftp echoes the command on the first line. Strip it.
            let cleaned = stripCommandEcho(output, command: ctx.line)
            // Did the command error? sftp writes errors that don't start with "Couldn't" sometimes,
            // but the simplest signal is exit status, which we don't get per-command. We treat any
            // line starting with "Couldn't" or "remote " or "Cannot " as an error indicator.
            if let err = extractErrorLine(cleaned) {
                ctx.continuation.resume(throwing: SessionError.operationFailed(err))
            } else {
                ctx.continuation.resume(returning: cleaned)
            }

            // Dispatch next.
            if let next = commandQueue.first {
                commandQueue.removeFirst()
                commandInFlight = next
                dispatchInFlight()
            }
        }
    }

    private func stripCommandEcho(_ output: String, command: String) -> String {
        // sftp echoes "sftp> command\n" before its own output in some configurations.
        if output.hasPrefix(command + "\n") {
            return String(output.dropFirst(command.count + 1))
        }
        return output
    }

    private func extractErrorLine(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("Couldn't ") || s.hasPrefix("Cannot ") || s.hasPrefix("remote ") || s.contains("No such file") || s.contains("Permission denied") {
                return s
            }
        }
        return nil
    }

    private func handleExit(code: Int32) {
        let reason = "sftp exited with code \(code)"
        switch state {
        case .spawning, .authenticating:
            state = .authFailed(reason: reason)
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(throwing: SessionError.authFailed(reason))
            }
        case .ready, .closed:
            state = .disconnected(reason: reason)
            // Notify subscribers.
            for h in disconnectObservers { h(reason) }
            // Fail in-flight + queued commands.
            let all = (commandInFlight.map { [$0] } ?? []) + commandQueue
            commandInFlight = nil
            commandQueue.removeAll()
            for ctx in all { ctx.continuation.resume(throwing: SessionError.disconnected(reason)) }
        case .authFailed, .disconnected:
            break
        }
    }
}
