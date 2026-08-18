import Foundation

/// Maximum number of results extracted per batch. A 3-letter Spotlight query
/// against "This Mac" can return 50k+ results in a single batch; past 2k there
/// is no UI value and the extra allocations stall the consumer.
private let kSearchMaxResults = 2000

@MainActor
final class SearchEngine {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var continuation: AsyncStream<[URL]>.Continuation?
    private var workQueue: OperationQueue?

    func stream(for text: String, scopes: [Any], kind: SearchKind = .byName) -> AsyncStream<[URL]> {
        if scopes.contains(where: { ($0 as? URL)?.isRemote == true }) {
            return AsyncStream { continuation in continuation.finish() }
        }
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return AsyncStream { $0.finish() } }

        return AsyncStream { continuation in
            self.continuation = continuation

            // Dedicated background queue: NSMetadataQuery delivers its
            // notifications here, and NSMetadataItem access happens on the
            // same queue as the query — keeping all URL extraction off-main.
            // Only the final continuation.yield([URL]) crosses to consumers.
            let queue = OperationQueue()
            queue.name = "SearchEngine.NSMetadataQuery"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            self.workQueue = queue

            let q = NSMetadataQuery()
            switch kind {
            case .byName:
                q.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(trimmed)*")
            case .byTag:
                q.predicate = NSPredicate(format: "kMDItemUserTags ==[c] %@", trimmed)
            }
            q.searchScopes = scopes
            q.notificationBatchingInterval = 0.25
            q.operationQueue = queue

            let nc = NotificationCenter.default
            let handler: (Notification) -> Void = { [weak q] _ in
                guard let q else { return }
                q.disableUpdates()
                let count = min(q.resultCount, kSearchMaxResults)
                var urls: [URL] = []
                urls.reserveCapacity(count)
                for idx in 0..<count {
                    let item = q.result(at: idx) as? NSMetadataItem
                    if let path = item?.value(forAttribute: NSMetadataItemPathKey) as? String {
                        urls.append(URL(fileURLWithPath: path))
                    }
                }
                #if DEBUG
                if q.resultCount > kSearchMaxResults {
                    NSLog("SearchEngine: truncated \(q.resultCount) results to \(kSearchMaxResults)")
                }
                #endif
                continuation.yield(urls)
                q.enableUpdates()
            }

            let t1 = nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: queue) { handler($0) }
            let t2 = nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: queue) { handler($0) }
            self.observers = [t1, t2]

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stopInternal() }
            }

            self.query = q
            q.start()
        }
    }

    func cancel() {
        // Finishing the continuation triggers onTermination, which calls
        // stopInternal() on the main actor — avoids double-stop and the
        // stale-yield window between stopping the query and finishing the stream.
        continuation?.finish()
        continuation = nil
    }

    private func stopInternal() {
        if let q = query {
            q.stop()
            query = nil
        }
        for t in observers {
            NotificationCenter.default.removeObserver(t)
        }
        observers = []
        workQueue = nil
    }
}
