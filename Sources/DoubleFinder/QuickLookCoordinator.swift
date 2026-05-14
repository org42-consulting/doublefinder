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

    final class DataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var urls: [URL] = []

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            urls[index] as NSURL
        }
    }
}
