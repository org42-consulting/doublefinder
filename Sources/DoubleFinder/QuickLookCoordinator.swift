import AppKit
import Quartz

@MainActor
final class QuickLookCoordinator: NSObject {
    static let shared = QuickLookCoordinator()

    private let dataSource = DataSource()

    func show(_ urls: [URL], startAt url: URL?) {
        guard !urls.isEmpty else { return }
        dataSource.urls = urls
        let startIndex = url.flatMap { urls.firstIndex(of: $0) } ?? 0

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = dataSource
        panel.delegate = dataSource
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Materialise any remote URLs to local cache files, then present Quick Look.
    @MainActor
    func showAsync(_ urls: [URL], startAt url: URL?) async {
        var resolved: [URL] = []
        var resolvedStart: URL? = nil
        for u in urls {
            if u.isRemoteSFTP, let local = await materialiseRemote(u) {
                resolved.append(local)
                if u == url { resolvedStart = local }
            } else {
                resolved.append(u)
                if u == url { resolvedStart = u }
            }
        }
        show(resolved, startAt: resolvedStart)
    }

    @MainActor
    private func materialiseRemote(_ url: URL) async -> URL? {
        guard let endpoint = url.sftpEndpoint else { return url }

        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DoubleFinder/sftp")
            .appendingPathComponent(endpoint.canonicalAccount.replacingOccurrences(of: "/", with: "_"))
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let local = cacheRoot.appendingPathComponent(url.sftpPath.trimmingCharacters(in: .init(charactersIn: "/")))
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: local.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
           (attrs[.size] as? Int64 ?? 0) > 0 {
            return local
        }

        let transport = SFTPFileTransport(endpoint: endpoint)
        let progress = Progress(totalUnitCount: -1)
        do {
            try await transport.download(url, to: local, progress: progress)
            return local
        } catch {
            return nil
        }
    }

    final class DataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var urls: [URL] = []

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            urls[index] as NSURL
        }
    }
}
