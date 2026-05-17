import Foundation

/// Identifies a remote SFTP location's connection coordinates.
/// Does NOT include the path on the remote — paths are carried in URLs.
struct RemoteEndpoint: Codable, Hashable, Sendable {
    var host: String
    var user: String
    var port: Int                  // 22 if unspecified
    var identityFile: URL?         // optional explicit -i
    var displayName: String?       // user-chosen label (UI only)
    /// One of "sftp", "webdav", "webdavs", "ftp", "ftps". Default "sftp" so
    /// existing on-disk bookmarks load unchanged.
    var scheme: String = "sftp"

    init(host: String, user: String, port: Int = 22, identityFile: URL? = nil, displayName: String? = nil, scheme: String = "sftp") {
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.displayName = displayName
        self.scheme = scheme
    }

    /// "user@host" or "user@host:port" when port != 22. Used for Keychain account key, sheet titles.
    var canonicalAccount: String {
        port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
    }

    /// True when both endpoints address the same remote connection. Compares only the
    /// fields that define the wire connection (host/user/port). Differences in
    /// identityFile or displayName don't count — they affect *how* we connect, not
    /// *what* we connect to.
    func sameConnection(as other: RemoteEndpoint) -> Bool {
        host == other.host && user == other.user && port == other.port
    }

    /// What we render in tab titles and bookmark labels by default.
    var defaultDisplayName: String {
        displayName ?? canonicalAccount
    }
}

extension URL {
    /// True when this URL refers to an SFTP location.
    var isRemoteSFTP: Bool { scheme == "sftp" }

    /// True when this URL refers to a WebDAV location (plain or TLS).
    var isRemoteWebDAV: Bool { scheme == "webdav" || scheme == "webdavs" }

    /// True for any remote scheme DoubleFinder supports.
    var isRemote: Bool { isRemoteSFTP || isRemoteWebDAV || scheme == "ftp" || scheme == "ftps" }

    /// Returns the endpoint encoded in this URL for any supported remote
    /// scheme, or nil for local file URLs.
    var remoteEndpoint: RemoteEndpoint? {
        guard let s = scheme, let host, let user else { return nil }
        switch s {
        case "sftp": return RemoteEndpoint(host: host, user: user, port: port ?? 22, scheme: s)
        case "webdav": return RemoteEndpoint(host: host, user: user, port: port ?? 80, scheme: s)
        case "webdavs": return RemoteEndpoint(host: host, user: user, port: port ?? 443, scheme: s)
        case "ftp": return RemoteEndpoint(host: host, user: user, port: port ?? 21, scheme: s)
        case "ftps": return RemoteEndpoint(host: host, user: user, port: port ?? 990, scheme: s)
        default: return nil
        }
    }

    /// Returns the endpoint encoded in this URL, or nil if not an sftp:// URL.
    /// Note: identityFile and displayName are never carried in URLs.
    var sftpEndpoint: RemoteEndpoint? {
        guard scheme == "sftp", let host, let user else { return nil }
        return RemoteEndpoint(host: host, user: user, port: port ?? 22)
    }

    /// Path component on the remote side. Always absolute (starts with "/").
    /// Empty string is returned as "/".
    var sftpPath: String {
        guard scheme == "sftp" else { return path }
        let p = path
        return p.isEmpty ? "/" : p
    }

    /// Construct an sftp:// URL from an endpoint and an absolute remote path.
    static func sftp(endpoint: RemoteEndpoint, path: String) -> URL {
        var comps = URLComponents()
        comps.scheme = "sftp"
        comps.user = endpoint.user
        comps.host = endpoint.host
        if endpoint.port != 22 {
            comps.port = endpoint.port
        }
        // URLComponents percent-encodes the path correctly when set as `path`.
        comps.path = path.hasPrefix("/") ? path : "/" + path
        return comps.url!
    }

    /// Returns a new URL with the same endpoint but a different path.
    func sftpAppending(path component: String) -> URL? {
        guard let endpoint = sftpEndpoint else { return nil }
        var newPath = sftpPath
        if !newPath.hasSuffix("/") { newPath += "/" }
        newPath += component
        return .sftp(endpoint: endpoint, path: newPath)
    }

    /// Parent directory of an sftp:// URL. Returns nil at the root.
    var sftpParent: URL? {
        guard let endpoint = sftpEndpoint else { return nil }
        let p = sftpPath
        if p == "/" || p.isEmpty { return nil }
        var parts = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        let parent = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        return .sftp(endpoint: endpoint, path: parent)
    }
}
