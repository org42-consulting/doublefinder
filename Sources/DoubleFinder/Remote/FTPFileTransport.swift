import Foundation

/// FTP transport implemented on top of `/usr/bin/curl`. curl handles plain FTP
/// (`ftp://`) and implicit FTPS (`ftps://`) without extra dependencies, and is
/// available on every macOS install. Credentials are looked up in Keychain via
/// the same scheme as WebDAV / SFTP.
struct FTPFileTransport: FileTransport {
    let endpoint: RemoteEndpoint
    let canTrash = false

    /// Arguments that tell curl to read its configuration — including the
    /// credentials — from standard input.
    ///
    /// Credentials must not travel as process arguments: `argv` is world-readable
    /// through `ps`, so any other user on the machine could harvest the FTP
    /// password while a transfer is running. curl's `-K -` reads the same options
    /// from stdin, which is private to the process.
    private var configArgs: [String] { ["-K", "-"] }

    /// The curl config body carrying `user = "name:password"`.
    private func credentialsConfig() -> Data {
        let pw = Keychain.getPassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount) ?? ""
        return Data("user = \(Self.curlConfigQuote("\(endpoint.user):\(pw)"))\n".utf8)
    }

    /// Quote a value for curl's config-file syntax: wrap in double quotes and
    /// backslash-escape the sequences curl interprets inside them. Without this,
    /// a password containing `"` or `\` would terminate or corrupt the option.
    private static func curlConfigQuote(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:   out.append(ch)
            }
        }
        return "\"\(out)\""
    }

    private func baseURL(scheme: String) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = endpoint.host
        if endpoint.port != (scheme == "ftps" ? 990 : 21) {
            comps.port = endpoint.port
        }
        comps.path = "/"
        return comps.url!
    }

    /// Convert a DoubleFinder ftp:// URL into the URL curl should hit. Strips
    /// embedded credentials (curl gets them via -u).
    private func curlURL(for url: URL, trailingSlashForDir: Bool = false) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.user = nil
        comps.password = nil
        if trailingSlashForDir, let p = comps.path.isEmpty ? "/" : comps.path as String?, !p.hasSuffix("/") {
            comps.path = p + "/"
        }
        return comps.url
    }

    func list(_ url: URL) async throws -> [FSNode] {
        guard let curlURL = curlURL(for: url, trailingSlashForDir: true) else {
            throw FileTransportError.notSupported("Bad URL")
        }
        // Default listing returns Unix-style "ls -la" output for most servers.
        var args = configArgs
        args.append(curlURL.absoluteString)
        let output = try await capture("/usr/bin/curl", args)
        return parseUnixListing(output, baseURL: url)
    }

    func exists(_ url: URL) async -> Bool {
        guard let curlURL = curlURL(for: url) else { return false }
        var args = configArgs
        args.append("--head")
        args.append(curlURL.absoluteString)
        return (try? await capture("/usr/bin/curl", args)) != nil
    }

    func mkdir(_ url: URL) async throws {
        try await quote(url, command: "MKD", path: url.path)
    }

    func remove(_ url: URL) async throws {
        // We don't know if the target is a file or directory at the FTP level
        // without an extra round-trip; try DELE first, fall back to RMD.
        do {
            try await quote(url, command: "DELE", path: url.path)
        } catch {
            try await quote(url, command: "RMD", path: url.path)
        }
    }

    func rename(_ from: URL, to dest: URL) async throws {
        try validateFTPPath(from.path)
        try validateFTPPath(dest.path)
        guard let baseURL = curlURL(for: from) else { throw FileTransportError.notSupported("Bad URL") }
        let parent = baseURL.deletingLastPathComponent()
        var args = configArgs
        args.append("-Q")
        args.append("RNFR \(from.path)")
        args.append("-Q")
        args.append("RNTO \(dest.path)")
        args.append(parent.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    func trash(_ url: URL) async throws -> URL? {
        try await remove(url)
        return nil
    }

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        guard let curlURL = curlURL(for: remote) else { throw FileTransportError.notSupported("Bad URL") }
        try? FileManager.default.removeItem(at: localTmp)
        var args = configArgs
        args.append("-o")
        args.append(localTmp.path)
        args.append(curlURL.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        guard let curlURL = curlURL(for: remote) else { throw FileTransportError.notSupported("Bad URL") }
        var args = configArgs
        args.append("-T")
        args.append(local.path)
        args.append(curlURL.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    // MARK: - Helpers

    /// Reject paths that contain CR, LF, or NUL — these would splice extra FTP
    /// verbs into curl's -Q argument and constitute CRLF injection.
    private func validateFTPPath(_ path: String) throws {
        if path.contains("\r") || path.contains("\n") || path.contains("\0") {
            throw FileTransportError.notSupported("FTP path contains invalid characters (CR, LF, or NUL).")
        }
    }

    /// Issue a raw FTP command (MKD / RMD / DELE / etc.) against the parent
    /// directory of `url`. curl needs the URL to be a directory it can CWD to,
    /// hence the trailing slash on the parent path.
    private func quote(_ url: URL, command: String, path: String) async throws {
        try validateFTPPath(path)
        guard let curlURL = curlURL(for: url) else { throw FileTransportError.notSupported("Bad URL") }
        let parent = curlURL.deletingLastPathComponent()
        var args = configArgs
        args.append("-Q")
        args.append("\(command) \(path)")
        args.append(parent.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    /// Run curl with the credentials fed in on stdin.
    ///
    /// `ProcessRunner` drains both pipes while curl runs and bounds the wall
    /// time. The previous implementation read stdout from `terminationHandler`,
    /// so a listing larger than the 64 KB pipe buffer blocked curl on write and
    /// hung the awaiting continuation forever.
    private func capture(_ launchPath: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.runChecked(
            launchPath, args,
            stdin: credentialsConfig(),
            timeout: 120
        )
    }

    /// Parse Unix-style `ls -la` listings (the default curl emits for FTP).
    /// Lines look like:
    ///   drwxr-xr-x 2 user group  4096 Jan 15 12:34 dirname
    ///   -rw-r--r-- 1 user group   123 Jan 15 12:34 filename
    private func parseUnixListing(_ text: String, baseURL: URL) -> [FSNode] {
        var out: [FSNode] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 30 else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            let perms = parts[0]
            let size = Int64(parts[4]) ?? 0
            let name = parts[8]
            // Skip the conventional "." and ".." links.
            if name == "." || name == ".." { continue }
            let isDir = perms.first == "d"
            // Build a child URL by appending the name to the base path.
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
            let basePath = comps.path.hasSuffix("/") ? comps.path : comps.path + "/"
            comps.path = basePath + name
            guard let childURL = comps.url else { continue }
            out.append(FSNode(
                url: childURL,
                isDirectory: isDir,
                size: isDir ? nil : size,
                modified: nil,
                tags: []
            ))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
