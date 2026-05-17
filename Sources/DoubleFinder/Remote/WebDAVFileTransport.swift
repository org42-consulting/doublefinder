import Foundation

/// URLSession-backed WebDAV transport. Operates on `webdav://` (plain) and
/// `webdavs://` (TLS) URLs by translating each verb to its WebDAV HTTP method.
/// Credentials are looked up in Keychain via `RemoteServerStore` keyed by
/// host + user.
struct WebDAVFileTransport: FileTransport {
    let endpoint: RemoteEndpoint
    let canTrash = false

    private var session: URLSession { URLSession.shared }

    private var httpScheme: String { endpoint.scheme == "webdavs" ? "https" : "http" }

    private func httpURL(for url: URL) -> URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var copy = comps
        copy.scheme = httpScheme
        copy.user = nil
        copy.password = nil
        return copy.url
    }

    private func authHeader() -> String? {
        // Keychain calls are thread-safe; bypass the @MainActor RemoteServerStore
        // wrapper so the transport's HTTP verbs stay synchronous-callable from
        // background tasks.
        guard !endpoint.user.isEmpty,
              let password = Keychain.getPassword(service: Keychain.serviceSFTP, account: endpoint.canonicalAccount) else {
            return nil
        }
        let creds = "\(endpoint.user):\(password)"
        guard let data = creds.data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    private func request(_ url: URL, method: String, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        if let auth = authHeader() { r.setValue(auth, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func list(_ url: URL) async throws -> [FSNode] {
        guard let httpURL = httpURL(for: url) else { throw FileTransportError.notSupported("Bad URL") }
        let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propfind xmlns:D="DAV:">
              <D:prop>
                <D:resourcetype/>
                <D:getcontentlength/>
                <D:getlastmodified/>
              </D:prop>
            </D:propfind>
            """.data(using: .utf8)!
        var req = request(httpURL, method: "PROPFIND", headers: [
            "Depth": "1",
            "Content-Type": "application/xml; charset=utf-8"
        ])
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        try validate(response, for: "PROPFIND")
        return try parsePropfind(data, baseURL: url)
    }

    func exists(_ url: URL) async -> Bool {
        guard let httpURL = httpURL(for: url) else { return false }
        let req = request(httpURL, method: "PROPFIND", headers: ["Depth": "0"])
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return true
            }
        } catch {}
        return false
    }

    func mkdir(_ url: URL) async throws {
        guard let httpURL = httpURL(for: url) else { throw FileTransportError.notSupported("Bad URL") }
        let req = request(httpURL, method: "MKCOL")
        let (_, response) = try await session.data(for: req)
        try validate(response, for: "MKCOL")
    }

    func remove(_ url: URL) async throws {
        guard let httpURL = httpURL(for: url) else { throw FileTransportError.notSupported("Bad URL") }
        let req = request(httpURL, method: "DELETE")
        let (_, response) = try await session.data(for: req)
        try validate(response, for: "DELETE")
    }

    func rename(_ from: URL, to dest: URL) async throws {
        guard let fromHTTP = httpURL(for: from), let destHTTP = httpURL(for: dest) else {
            throw FileTransportError.notSupported("Bad URL")
        }
        let req = request(fromHTTP, method: "MOVE", headers: [
            "Destination": destHTTP.absoluteString,
            "Overwrite": "T"
        ])
        let (_, response) = try await session.data(for: req)
        try validate(response, for: "MOVE")
    }

    func trash(_ url: URL) async throws -> URL? {
        try await remove(url)
        return nil
    }

    func download(_ remote: URL, to localTmp: URL, progress: Progress) async throws {
        guard let httpURL = httpURL(for: remote) else { throw FileTransportError.notSupported("Bad URL") }
        let req = request(httpURL, method: "GET")
        let (tmp, response) = try await session.download(for: req)
        try validate(response, for: "GET")
        try? FileManager.default.removeItem(at: localTmp)
        try FileManager.default.moveItem(at: tmp, to: localTmp)
    }

    func upload(_ local: URL, to remote: URL, progress: Progress) async throws {
        guard let httpURL = httpURL(for: remote) else { throw FileTransportError.notSupported("Bad URL") }
        var req = request(httpURL, method: "PUT")
        let data = try Data(contentsOf: local)
        req.httpBody = data
        let (_, response) = try await session.data(for: req)
        try validate(response, for: "PUT")
    }

    private func validate(_ response: URLResponse, for verb: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FileTransportError.notSupported("\(verb): no HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return }
        throw FileTransportError.notSupported("\(verb) failed: HTTP \(http.statusCode)")
    }

    /// Parse a PROPFIND multistatus response into FSNodes. The response is XML;
    /// we use XMLParser delegate-style aggregation. The first <D:response>
    /// usually describes the collection itself — we skip it so the returned
    /// listing contains only children.
    private func parsePropfind(_ data: Data, baseURL: URL) throws -> [FSNode] {
        let parser = PropfindParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else {
            throw FileTransportError.notSupported("PROPFIND: failed to parse response")
        }
        guard let basePath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            return []
        }
        var out: [FSNode] = []
        for entry in parser.responses {
            // Skip the collection itself — recognise it by its href matching
            // the base path (with or without a trailing slash).
            let href = entry.href
            let normalizedSelf = basePath.hasSuffix("/") ? basePath : basePath + "/"
            let normalizedHref = href.hasSuffix("/") ? href : href + "/"
            if normalizedHref == normalizedSelf || href == basePath { continue }

            // Build the child URL using the base URL's host/port and the
            // returned href (which is server-rooted, percent-encoded).
            guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { continue }
            comps.percentEncodedPath = href
            guard let childURL = comps.url else { continue }
            out.append(FSNode(
                url: childURL,
                isDirectory: entry.isCollection,
                size: entry.size,
                modified: entry.modified,
                tags: []
            ))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// XMLParser delegate that pulls just the fields we care about out of a
/// PROPFIND multistatus body. Only handles the common Apache/nginx/Nextcloud
/// shape — exotic CardDAV/CalDAV servers may need adjustments.
private final class PropfindParser: NSObject, XMLParserDelegate {
    struct Entry {
        var href: String = ""
        var size: Int64?
        var modified: Date?
        var isCollection: Bool = false
    }

    var responses: [Entry] = []
    private var current: Entry?
    private var elementStack: [String] = []
    private var currentText: String = ""
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    private static func localName(_ name: String) -> String {
        if let colon = name.firstIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    func parser(_ p: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let local = Self.localName(elementName).lowercased()
        elementStack.append(local)
        currentText = ""
        if local == "response" {
            current = Entry()
        }
        if local == "collection" {
            current?.isCollection = true
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) {
        currentText += s
    }

    func parser(_ p: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = Self.localName(elementName).lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "href":           current?.href = trimmed.removingPercentEncoding ?? trimmed
        case "getcontentlength":
            if let n = Int64(trimmed) { current?.size = n }
        case "getlastmodified":
            current?.modified = Self.dateFormatter.date(from: trimmed)
        case "response":
            if let e = current { responses.append(e) }
            current = nil
        default: break
        }
        elementStack.removeLast()
        currentText = ""
    }
}
