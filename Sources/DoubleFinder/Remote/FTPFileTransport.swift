import Foundation

/// FTP transport implemented on top of `/usr/bin/curl`. curl handles plain FTP
/// (`ftp://`) and implicit FTPS (`ftps://`) without extra dependencies, and is
/// available on every macOS install. Credentials are looked up in Keychain via
/// the same scheme as WebDAV / SFTP.
struct FTPFileTransport: FileTransport {
    let endpoint: RemoteEndpoint
    let canTrash = false

    private func credentialsArg() -> [String] {
        let pw = Keychain.getPassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount) ?? ""
        return ["-u", "\(endpoint.user):\(pw)"]
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
        var args = credentialsArg()
        args.append(curlURL.absoluteString)
        let output = try await capture("/usr/bin/curl", args)
        return parseUnixListing(output, baseURL: url)
    }

    func exists(_ url: URL) async -> Bool {
        guard let curlURL = curlURL(for: url) else { return false }
        var args = credentialsArg()
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
        guard let baseURL = curlURL(for: from) else { throw FileTransportError.notSupported("Bad URL") }
        let parent = baseURL.deletingLastPathComponent()
        var args = credentialsArg()
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
        var args = credentialsArg()
        args.append("-o")
        args.append(localTmp.path)
        args.append(curlURL.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        guard let curlURL = curlURL(for: remote) else { throw FileTransportError.notSupported("Bad URL") }
        var args = credentialsArg()
        args.append("-T")
        args.append(local.path)
        args.append(curlURL.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    // MARK: - Helpers

    /// Issue a raw FTP command (MKD / RMD / DELE / etc.) against the parent
    /// directory of `url`. curl needs the URL to be a directory it can CWD to,
    /// hence the trailing slash on the parent path.
    private func quote(_ url: URL, command: String, path: String) async throws {
        guard let curlURL = curlURL(for: url) else { throw FileTransportError.notSupported("Bad URL") }
        let parent = curlURL.deletingLastPathComponent()
        var args = credentialsArg()
        args.append("-Q")
        args.append("\(command) \(path)")
        args.append(parent.absoluteString)
        _ = try await capture("/usr/bin/curl", args)
    }

    private func capture(_ launchPath: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            proc.terminationHandler = { p in
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let text = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: text)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "DoubleFinder.FTP",
                        code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "FTP command failed with exit \(p.terminationStatus)"]
                    ))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
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
