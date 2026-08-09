import Foundation

/// Where ``LocalState`` is read from and written to between launches.
///
/// Derivation stays pure — nothing here is reachable from ``Derivation/derive(snapshot:local:previous:now:)``,
/// which still takes its `local` as an argument. This is the layer *above* it, and it lives
/// in `PRStackCore` for the same reason `LinearProjectCacheStore` lives in `LinearKit`: the
/// module that owns the type owns the shape it takes on disk, and CI can then exercise the
/// round trip without a Mac (IMPLEMENTATION_PLAN §1, §7).
///
/// **One writer.** `LocalState` is a single value owned by the main actor and written
/// whole, so the release tracker hands its bindings back to be merged there rather than
/// writing the file from its own task — two writers holding partial copies is how a
/// dismissal disappears behind a binding (IMPLEMENTATION_PLAN §3).
public protocol StateStore: AnyObject, Sendable {
    func load() -> StateLoad
    func save(_ state: LocalState) throws
}

/// What a load produced, and what it had to do to get there.
///
/// The quarantine is reported rather than swallowed: it is the one outcome where the user
/// silently loses dismissal tombstones, which is the only part of the file nothing
/// re-derives (IMPLEMENTATION_PLAN §3).
public struct StateLoad: Equatable, Sendable {
    public var state: LocalState
    /// Why the stored state could not be used, if it could not be.
    public var failure: String?
    /// Where the unreadable file was moved to, when it was moved.
    public var quarantinedTo: URL?

    public init(state: LocalState, failure: String? = nil, quarantinedTo: URL? = nil) {
        self.state = state
        self.failure = failure
        self.quarantinedTo = quarantinedTo
    }

    public static let empty = StateLoad(state: .empty)
}

public enum StateStoreError: Error, Equatable, CustomStringConvertible {
    /// The file could not be read *and* could not be moved aside, so writing over it would
    /// destroy state nothing else can supply. The store refuses every write until the user
    /// deals with the file.
    case sealed(URL, reason: String)
    case write(URL, reason: String)

    public var description: String {
        switch self {
        case .sealed(let url, let reason):
            return "refusing to overwrite '\(url.path)': it could not be read (\(reason)) "
                + "and could not be moved aside"
        case .write(let url, let reason):
            return "could not write '\(url.path)': \(reason)"
        }
    }
}

extension StateStoreError: LocalizedError {
    public var errorDescription: String? { description }
}

/// The default store: in memory, lost on relaunch. Used by tests, previews and the debug
/// dump when no path is given.
public final class InMemoryStateStore: StateStore, @unchecked Sendable {
    private var state: LocalState
    private let lock = NSLock()

    public init(_ state: LocalState = .empty) {
        self.state = state
    }

    public func load() -> StateLoad {
        lock.lock()
        defer { lock.unlock() }
        return StateLoad(state: state)
    }

    public func save(_ state: LocalState) throws {
        lock.lock()
        defer { lock.unlock() }
        self.state = state
    }
}

/// `state.json` — atomic writes, sorted keys, schema-versioned.
///
/// The file holds dismissals, snooze deadlines, read digests, release bindings and the
/// unbound merges that give the merged-pull-request query its lower bound. Only part of it
/// re-derives if it is lost: bindings and unbound merges come back from the next poll
/// (except a merge older than that query's cold-start floor, which stays stranded), read
/// digests cost one burst of false unread, and a lost snooze wakes its row early.
/// Dismissal tombstones re-derive from nothing at all, which is why an unreadable file is
/// moved aside rather than overwritten.
public final class FileStateStore: StateStore, @unchecked Sendable {
    /// Bumped when the on-disk shape changes in a way this build could not read back. A
    /// file carrying an unknown version is quarantined, exactly like one that fails to
    /// decode: a newer build's state is not something this one can safely half-read.
    public static let schemaVersion = 1

    private let url: URL
    private let lock = NSLock()
    /// Set when the file could not be read *and* could not be moved aside. Every write is
    /// refused from then on, because the alternative is destroying the only copy of the
    /// tombstones.
    private var seal: String?

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/PRStackMonitor/state.json`, and the equivalent
    /// wherever else Foundation puts application support (IMPLEMENTATION_PLAN §3).
    public static func defaultURL(
        fileManager: FileManager = .default,
        fileName: String = "state.json"
    ) -> URL {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("PRStackMonitor", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func load() -> StateLoad {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .empty }

        guard let data = fileManager.contents(atPath: url.path) else {
            return quarantine(reason: "the file could not be read")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            return quarantine(reason: "the file is not readable state (\(error))")
        }
        guard envelope.version == FileStateStore.schemaVersion else {
            return quarantine(
                reason: "the file carries schema version \(envelope.version), "
                    + "and this build reads version \(FileStateStore.schemaVersion)"
            )
        }
        return StateLoad(state: envelope.state)
    }

    public func save(_ state: LocalState) throws {
        lock.lock()
        defer { lock.unlock() }

        if let seal { throw StateStoreError.sealed(url, reason: seal) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // `LocalState` encodes its three maps as JSON objects, whose key order comes from
        // `Dictionary` iteration and varies per process. Sorting here is what makes two
        // writes of the same state the same bytes, and the file diffable by hand.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(Envelope(version: FileStateStore.schemaVersion, state: state))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Atomic: a half-written file is never reachable, so a crash mid-save costs the
            // last change rather than every dismissal the user has ever made.
            try data.write(to: url, options: .atomic)
        } catch {
            throw StateStoreError.write(url, reason: String(describing: error))
        }
    }

    /// Moves the unreadable file aside and starts from empty.
    ///
    /// Moving comes *first*. Starting from empty and then saving over the file in place
    /// would destroy state nothing else can supply, so if the move fails the store seals
    /// itself instead and refuses to write at all — the user still has their file, and the
    /// app still runs, on an empty state it will not persist.
    private func quarantine(reason: String) -> StateLoad {
        let destination = FileStateStore.quarantineURL(for: url, at: Date())
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return StateLoad(state: .empty, failure: reason, quarantinedTo: destination)
        } catch {
            seal = reason
            return StateLoad(
                state: .empty,
                failure: reason + "; it could not be moved aside either (\(error)), "
                    + "so nothing will be written until it is dealt with"
            )
        }
    }

    /// `state.corrupt-20260109T150000Z.json`, beside the original.
    ///
    /// A counter is appended if that name is taken, so two quarantines in the same second
    /// — a relaunch loop over the same bad file — cannot overwrite each other's evidence.
    static func quarantineURL(
        for url: URL,
        at now: Date,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        let stamp = timestamp(now)

        var candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp).\(ext)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// `20260109T150000Z`, in UTC.
    ///
    /// Assembled from date components rather than with a `DateFormatter` so the stamp
    /// cannot pick up the user's locale or calendar — this is a file name, not a date
    /// anybody reads, and a Buddhist-calendar year in it would be a surprise.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        func pad(_ value: Int?, width: Int) -> String {
            let text = String(value ?? 0)
            return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
        }

        return pad(parts.year, width: 4) + pad(parts.month, width: 2) + pad(parts.day, width: 2)
            + "T"
            + pad(parts.hour, width: 2) + pad(parts.minute, width: 2) + pad(parts.second, width: 2)
            + "Z"
    }

    /// `{ "version": 1, "state": { … } }`.
    ///
    /// The version sits outside the state rather than inside it so that reading it never
    /// depends on `LocalState` decoding successfully — which is the case a version check
    /// exists for.
    private struct Envelope: Codable {
        var version: Int
        var state: LocalState
    }
}
