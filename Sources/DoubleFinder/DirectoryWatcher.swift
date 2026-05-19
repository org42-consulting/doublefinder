import Foundation
import CoreServices

final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    var onChange: (() -> Void)?

    func start(at url: URL) {
        stop()
        let paths = [url.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange?()
        }
        // NoDefer: deliver the FIRST event in a batch immediately, then coalesce
        // subsequent events within the 0.3s latency window. Without this, FSEvents
        // waits a full quiet period after each batch before delivering — stalling
        // refreshes by 300+ms in actively churning directories.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagIgnoreSelf
            | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
