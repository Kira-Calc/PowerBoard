import CoreServices
import Foundation

/// Watches log directories recursively with FSEvents and calls `onChange` when files change (SPEC 4.3).
/// Directories that do not exist when `start()` is called are not watched; the periodic fallback scan covers them.
public final class LogWatcher: @unchecked Sendable {
    // Mutable state is only touched on `queue`.
    private let queue = DispatchQueue(label: "LogWatcher.events")
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                existing as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
