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

    /// Every remote scheme DoubleFinder speaks, with the port it defaults to.
    /// Single source of truth for the Connect sheet's picker, the bookmark
    /// editor, and URL round-tripping — those each used to carry their own copy
    /// of this table.
    static let supportedSchemes: [(scheme: String, label: String, defaultPort: Int)] = [
        ("sftp",    "SFTP",            22),
        ("webdav",  "WebDAV (http)",   80),
        ("webdavs", "WebDAV (https)", 443),
        ("ftp",     "FTP",             21),
        ("ftps",    "FTPS",           990),
    ]

    static func defaultPort(for scheme: String) -> Int {
        supportedSchemes.first { $0.scheme == scheme }?.defaultPort ?? 22
    }

    static func isSupportedScheme(_ scheme: String?) -> Bool {
        guard let scheme else { return false }
        return supportedSchemes.contains { $0.scheme == scheme }
    }

    /// True when reaching this endpoint means standing up a long-lived,
    /// separately-authenticated session — today that is only SFTP, whose
    /// `sftp(1)` subprocess `RemoteSessionManager` acquires and refcounts.
    /// WebDAV and FTP authenticate every request from Keychain instead, so
    /// there is nothing to acquire, nothing to eject, and no server-side home
    /// directory to resolve `~` against.
    ///
    /// One predicate rather than a scheme comparison per call site: the Connect
    /// sheet and the sidebar's bookmark row both have to answer this question,
    /// and the sidebar used to assume the answer was always yes.
    var usesPersistentSession: Bool { scheme == "sftp" }

    // MARK: - Input validation

    /// Reject hosts that start with `-` (OpenSSH option injection like `-oProxyCommand=`),
    /// are empty, or contain characters that cannot appear in a safe hostname token.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        // A leading `-` would be parsed as an SSH option flag.
        guard !host.hasPrefix("-") else { return false }
        // These characters either break shell tokenization or are protocol-illegal in hostnames.
        let forbidden: [Character] = [" ", "\t", "\r", "\n", "/", "=", "\0"]
        return !host.contains(where: { forbidden.contains($0) })
    }

    /// Reject usernames that start with `-` (would be passed positionally and treated as an SSH
    /// flag), are empty, or contain characters that cannot appear safely in `user@host` tokens.
    static func isValidUser(_ user: String) -> Bool {
        guard !user.isEmpty else { return false }
        guard !user.hasPrefix("-") else { return false }
        let forbidden: [Character] = [" ", "\t", "\r", "\n", "@", "\0"]
        return !user.contains(where: { forbidden.contains($0) })
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
    ///
    /// Prefer this over `isRemoteSFTP` for anything that asks "is this URL on
    /// another machine" — local-filesystem services (FSEvents, `git`, xattr
    /// tags, QuickLook thumbnails, Spotlight) must not be handed a remote URL,
    /// because they would silently operate on its `path` component as if it
    /// were a local path. Reserve `isRemoteSFTP` for genuinely SFTP-specific
    /// mechanisms: the `sftp(1)` session, `ssh -t`, Edit Locally.
    var isRemote: Bool { RemoteEndpoint.isSupportedScheme(scheme) }

    /// Returns the endpoint encoded in this URL for any supported remote
    /// scheme, or nil for local file URLs.
    var remoteEndpoint: RemoteEndpoint? {
        guard let s = scheme, RemoteEndpoint.isSupportedScheme(s), let host, let user else { return nil }
        guard RemoteEndpoint.isValidHost(host), RemoteEndpoint.isValidUser(user) else { return nil }
        return RemoteEndpoint(
            host: host,
            user: user,
            port: port ?? RemoteEndpoint.defaultPort(for: s),
            scheme: s
        )
    }

    /// Returns the endpoint encoded in this URL, or nil if not an sftp:// URL.
    /// Note: identityFile and displayName are never carried in URLs.
    var sftpEndpoint: RemoteEndpoint? {
        guard scheme == "sftp", let host, let user else { return nil }
        guard RemoteEndpoint.isValidHost(host), RemoteEndpoint.isValidUser(user) else { return nil }
        return RemoteEndpoint(host: host, user: user, port: port ?? 22)
    }

    /// Path on the server for any remote scheme. Always absolute (starts with
    /// "/"); an empty path is reported as "/". Falls back to `path` for local
    /// URLs so callers can use it unconditionally.
    var remotePath: String {
        let p = path
        return p.isEmpty ? "/" : p
    }

    /// Path component on the remote side. Always absolute (starts with "/").
    /// Empty string is returned as "/".
    var sftpPath: String { remotePath }

    /// Construct a remote URL from an endpoint and an absolute path on the
    /// server. The port is omitted when it matches the scheme's default so the
    /// URL round-trips back to the same endpoint.
    static func remote(endpoint: RemoteEndpoint, path: String) -> URL? {
        // Endpoints parsed out of a URL are already validated, but ones loaded
        // from `servers.json` are not: the connections editor lets you type
        // anything into Host and User. Validating here means a malformed
        // bookmark yields nil at the one place URLs are built, instead of a
        // half-formed URL reaching a transport.
        guard RemoteEndpoint.isValidHost(endpoint.host),
              RemoteEndpoint.isValidUser(endpoint.user) else { return nil }
        var comps = URLComponents()
        comps.scheme = endpoint.scheme
        comps.user = endpoint.user
        comps.host = endpoint.host
        if endpoint.port != RemoteEndpoint.defaultPort(for: endpoint.scheme) {
            comps.port = endpoint.port
        }
        // URLComponents percent-encodes the path correctly when set as `path`.
        comps.path = path.hasPrefix("/") ? path : "/" + path
        return comps.url
    }

    /// Construct an sftp:// URL from an endpoint and an absolute remote path.
    ///
    /// Returns nil for a host or user that can't form a valid URL. This used to
    /// force-unwrap on the grounds that callers hold an endpoint parsed from a
    /// URL — true for most of them, but not for the sidebar and the connections
    /// editor, which hand over whatever is stored in `servers.json`.
    static func sftp(endpoint: RemoteEndpoint, path: String) -> URL? {
        var sftpEndpoint = endpoint
        sftpEndpoint.scheme = "sftp"
        return remote(endpoint: sftpEndpoint, path: path)
    }

    /// Returns a new URL with the same remote endpoint but `component` appended
    /// to the path. Nil for local URLs.
    func remoteAppending(path component: String) -> URL? {
        guard let endpoint = remoteEndpoint else { return nil }
        var newPath = remotePath
        if !newPath.hasSuffix("/") { newPath += "/" }
        newPath += component
        return .remote(endpoint: endpoint, path: newPath)
    }

    /// Parent directory of a remote URL. Returns nil at the root or for local URLs.
    var remoteParent: URL? {
        guard let endpoint = remoteEndpoint else { return nil }
        let p = remotePath
        if p == "/" || p.isEmpty { return nil }
        var parts = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        let parent = parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
        return .remote(endpoint: endpoint, path: parent)
    }

    /// Returns a new URL with the same endpoint but a different path.
    func sftpAppending(path component: String) -> URL? { remoteAppending(path: component) }

    /// Parent directory of an sftp:// URL. Returns nil at the root.
    var sftpParent: URL? { remoteParent }

    // MARK: - Scheme-agnostic path arithmetic
    //
    // Local and remote URLs need the same two operations everywhere in
    // `FileOps` / `CopyMoveCoordinator` / undo, but `appendingPathComponent`
    // and `deletingLastPathComponent` produce trailing-slash artefacts on
    // non-file URLs. These two route each kind to the right implementation so
    // call sites don't have to branch.

    /// Enclosing directory, for local *and* remote URLs. Nil at a remote root.
    var parentDirectory: URL? {
        isRemote ? remoteParent : deletingLastPathComponent()
    }

    /// Child URL named `name`, for local *and* remote URLs.
    func childURL(named name: String) -> URL? {
        isRemote ? remoteAppending(path: name) : appendingPathComponent(name)
    }

    /// Human-readable label for a location: remote URLs read `host: /path`,
    /// local ones are tilde-abbreviated.
    ///
    /// One definition so the path bar's recents menu and the Inspector's
    /// selection aggregate can't drift into formatting the same thing two ways.
    /// Note this is *not* `TabState.displayTitle`, which deliberately shows only
    /// the basename because it has a tab pill's width to work with.
    var locationLabel: String {
        if isRemote, let endpoint = remoteEndpoint {
            return "\(endpoint.host): \(remotePath)"
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
