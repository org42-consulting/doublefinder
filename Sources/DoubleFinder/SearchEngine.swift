import Foundation

@MainActor
final class SearchEngine {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var continuation: AsyncStream<[URL]>.Continuation?

    func stream(for text: String, scope: URL) -> AsyncStream<[URL]> {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return AsyncStream { $0.finish() } }

        return AsyncStream { continuation in
            self.continuation = continuation

            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(trimmed)*")
            q.searchScopes = [scope]
            q.notificationBatchingInterval = 0.25

            let nc = NotificationCenter.default
            let handler: (Notification) -> Void = { [weak q] _ in
                guard let q else { return }
                q.disableUpdates()
                let urls = (0..<q.resultCount).compactMap { idx -> URL? in
                    let item = q.result(at: idx) as? NSMetadataItem
                    if let path = item?.value(forAttribute: NSMetadataItemPathKey) as? String {
                        return URL(fileURLWithPath: path)
                    }
                    return nil
                }
                continuation.yield(urls)
                q.enableUpdates()
            }

            let t1 = nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { handler($0) }
            let t2 = nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { handler($0) }
            self.observer = CompositeToken(tokens: [t1, t2])

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stopInternal() }
            }

            self.query = q
            q.start()
        }
    }

    func cancel() {
        continuation?.finish()
        continuation = nil
        stopInternal()
    }

    private func stopInternal() {
        if let q = query {
            q.stop()
            query = nil
        }
        if let observer = observer as? CompositeToken {
            for t in observer.tokens {
                NotificationCenter.default.removeObserver(t)
            }
        }
        observer = nil
    }
}

private final class CompositeToken: NSObject {
    let tokens: [NSObjectProtocol]
    init(tokens: [NSObjectProtocol]) { self.tokens = tokens }
}
