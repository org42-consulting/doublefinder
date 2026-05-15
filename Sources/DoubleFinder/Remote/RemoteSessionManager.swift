import Foundation
import SwiftUI

/// Owns one `SFTPSession` per (user, host, port). Tabs `acquire` and `release` to refcount.
@MainActor
final class RemoteSessionManager: ObservableObject {

    static let shared = RemoteSessionManager()

    private init() {}

    private struct Slot {
        let session: SFTPSession
        var refcount: Int
    }

    /// Key is `RemoteEndpoint` minus identityFile / displayName.
    private struct Key: Hashable {
        let host: String
        let user: String
        let port: Int
        init(_ e: RemoteEndpoint) { host = e.host; user = e.user; port = e.port }
    }

    private var slots: [Key: Slot] = [:]

    /// Get the existing session for an endpoint without acquiring a ref.
    func existingSession(for endpoint: RemoteEndpoint) -> SFTPSession? {
        slots[Key(endpoint)]?.session
    }

    /// Acquire (or reuse) a session. Increments the refcount. The returned session is in `.ready`.
    /// Authentication sheets are presented via `window`.
    func acquire(_ endpoint: RemoteEndpoint, in window: WindowState) async throws -> SFTPSession {
        let key = Key(endpoint)
        if var slot = slots[key] {
            let state = await slot.session.state
            if state == .ready {
                slot.refcount += 1
                slots[key] = slot
                return slot.session
            }
            // Stale slot — drop it.
            slots[key] = nil
        }

        let handler: SFTPSession.PromptHandler = { [weak window] prompt in
            guard let window else { return nil }
            return await window.presentRemotePrompt(prompt, endpoint: endpoint)
        }
        let session = SFTPSession(endpoint: endpoint, promptHandler: handler)
        try await session.start()
        slots[key] = Slot(session: session, refcount: 1)
        return session
    }

    /// Release a previously acquired session. Closes the underlying session at refcount 0.
    func release(_ endpoint: RemoteEndpoint) {
        let key = Key(endpoint)
        guard var slot = slots[key] else { return }
        slot.refcount -= 1
        if slot.refcount <= 0 {
            slots[key] = nil
            Task { await slot.session.close() }
        } else {
            slots[key] = slot
        }
    }
}
