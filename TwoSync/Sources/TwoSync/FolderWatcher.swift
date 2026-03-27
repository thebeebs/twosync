import Foundation
import CoreServices

// ─── Placed-By-Us Registry ────────────────────────────────────────────────────
// Tracks files that TwoSync itself wrote, so the watcher can ignore
// the events those writes generate and avoid feedback loops.

class PlacedByUsRegistry {
    private var entries: [String: Date] = [:]
    private let lock = NSLock()
    private let ignoreDuration: TimeInterval = 4.0  // seconds to ignore after a write

    /// Call this BEFORE copying a file into a folder.
    func register(path: String) {
        lock.lock()
        entries[path] = Date()
        lock.unlock()
    }

    /// Returns true if this path was recently placed by TwoSync and should be ignored.
    func shouldIgnore(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let placed = entries[path] else { return false }
        if Date().timeIntervalSince(placed) < ignoreDuration {
            return true
        }
        entries.removeValue(forKey: path)
        return false
    }

    /// Periodically sweep expired entries (call from a timer).
    func purgeExpired() {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-ignoreDuration)
        entries = entries.filter { $0.value > cutoff }
        lock.unlock()
    }
}

// ─── Folder Watcher ───────────────────────────────────────────────────────────

class FolderWatcher {
    private let folderA: URL
    private let folderB: URL
    private let registry: PlacedByUsRegistry
    private let onChange: (URL, URL) -> Void  // (sourceFile, destinationFolder)

    private var streamA: FSEventStreamRef?
    private var streamB: FSEventStreamRef?
    private var debounceWorkItems: [String: DispatchWorkItem] = [:]
    private let debounceDelay: TimeInterval = 1.0
    private let queue = DispatchQueue(label: "com.user.twosync.watcher", qos: .utility)
    private var purgeTimer: DispatchSourceTimer?

    init(folderA: URL, folderB: URL, registry: PlacedByUsRegistry, onChange: @escaping (URL, URL) -> Void) {
        self.folderA = folderA
        self.folderB = folderB
        self.registry = registry
        self.onChange = onChange
    }

    func start() {
        streamA = makeStream(for: folderA, peer: folderB)
        streamB = makeStream(for: folderB, peer: folderA)
        startPurgeTimer()
    }

    func stop() {
        [streamA, streamB].compactMap { $0 }.forEach {
            FSEventStreamStop($0)
            FSEventStreamInvalidate($0)
            FSEventStreamRelease($0)
        }
        streamA = nil
        streamB = nil
        purgeTimer?.cancel()
        purgeTimer = nil
    }

    // ── FSEventStream ─────────────────────────────────────────────────────────

    private func makeStream(for folder: URL, peer: URL) -> FSEventStreamRef? {
        let paths = [folder.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)

            for i in 0..<numEvents {
                guard let rawPath = paths[i] as? String else { continue }
                let flags = eventFlags[i]

                // Skip directory-only events, renames of temp files, hidden files
                let name = (rawPath as NSString).lastPathComponent
                if name.hasPrefix(".") || name.hasPrefix("~") || name.hasSuffix(".tmp") {
                    continue
                }

                // Only care about creates/modifies/deletes
                let relevant = UInt32(kFSEventStreamEventFlagItemCreated) |
                               UInt32(kFSEventStreamEventFlagItemModified) |
                               UInt32(kFSEventStreamEventFlagItemRemoved) |
                               UInt32(kFSEventStreamEventFlagItemRenamed)
                guard flags & relevant != 0 else { continue }

                watcher.handleEvent(path: rawPath, sourceFolder: watcher.folderA, peer: watcher.folderB)
            }
        }

        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,   // latency seconds — batches events
            flags
        )

        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        return stream
    }

    // ── Event handling ────────────────────────────────────────────────────────

    private func handleEvent(path: String, sourceFolder: URL, peer: URL) {
        // Was this file placed here by TwoSync? If so, ignore it.
        if registry.shouldIgnore(path: path) {
            return
        }

        // Debounce — wait for writes to settle before syncing
        debounceWorkItems[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceWorkItems.removeValue(forKey: path)
            let fileURL = URL(fileURLWithPath: path)

            // Figure out relative path and destination
            guard path.hasPrefix(sourceFolder.path) else { return }
            let rel = String(path.dropFirst(sourceFolder.path.count + 1))
            let destFolder = peer
            let destPath = destFolder.appendingPathComponent(rel).path

            // Register destination as placed-by-us BEFORE we copy
            self.registry.register(path: destPath)

            DispatchQueue.main.async {
                self.onChange(fileURL, destFolder)
            }
        }
        debounceWorkItems[path] = work
        queue.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    // ── Purge timer ───────────────────────────────────────────────────────────

    private func startPurgeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.registry.purgeExpired() }
        timer.resume()
        purgeTimer = timer
    }
}
