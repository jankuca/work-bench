import Foundation
import PRStackCore

/// The identifier → issue mapping, cached indefinitely and refreshed once a day.
///
/// "Indefinitely" is the important half. IMPLEMENTATION_PLAN §2: **when Linear is
/// unavailable, cached mappings are still used** — rows keep their project headings and
/// only identifiers with no cached entry fall into `Other`. So an entry past its refresh
/// interval is still an answer; the interval decides what gets *re-asked*, never what gets
/// *used*. A Linear outage must never make project sections appear to empty out.
public struct LinearProjectCache: Equatable, Sendable {
    /// One identifier's answer, and when it was obtained.
    public struct Entry: Equatable, Sendable, Codable {
        /// `nil` records that Linear was asked and does not have this identifier.
        ///
        /// Caching a negative is not an optimisation, it is the thing that keeps the scan's
        /// false positives free. `UTF-8` in a pull request title has the exact shape of a
        /// Linear identifier; without this it would be re-queried on every poll of every
        /// pull request that mentions it, forever.
        public var issue: IssueRef?
        public var refreshedAt: Date

        public init(issue: IssueRef?, refreshedAt: Date) {
            self.issue = issue
            self.refreshedAt = refreshedAt
        }
    }

    /// Once a day (IMPLEMENTATION_PLAN §2). A ticket moves between projects rarely enough
    /// that a day-old answer is worth more than the request it would take to confirm it.
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public static let empty = LinearProjectCache()

    public func entry(for identifier: String) -> Entry? { entries[identifier] }

    /// The issue for `identifier`, at any age. This is the lookup rows are built from.
    public func issue(for identifier: String) -> IssueRef? { entries[identifier]?.issue }

    /// Whether this identifier's answer is recent enough not to re-ask.
    ///
    /// An entry from the future — a state file written before a clock correction — counts
    /// as fresh rather than being re-fetched on every poll until the clock catches up.
    public func isFresh(_ identifier: String, now: Date) -> Bool {
        guard let entry = entries[identifier] else { return false }
        return now.timeIntervalSince(entry.refreshedAt) < LinearProjectCache.refreshInterval
    }

    /// Which of `identifiers` need a request, in the order they were given.
    public func staleOrMissing(among identifiers: [String], now: Date) -> [String] {
        identifiers.filter { !isFresh($0, now: now) }
    }

    public mutating func record(_ issue: IssueRef, for identifier: String, at now: Date) {
        entries[identifier] = Entry(issue: issue, refreshedAt: now)
    }

    public mutating func recordUnknown(_ identifier: String, at now: Date) {
        entries[identifier] = Entry(issue: nil, refreshedAt: now)
    }

    /// Drops entries no pull request references any more, so the file cannot grow without
    /// bound across the life of the app. Never called from resolution: a poll that fetched
    /// nothing must not empty the cache it is meant to be falling back on.
    public mutating func retainOnly<S: Sequence>(_ identifiers: S) where S.Element == String {
        let keep = Set(identifiers)
        entries = entries.filter { keep.contains($0.key) }
    }
}

extension LinearProjectCache: Codable {
    /// Schema-versioned, like the state file it will eventually live inside
    /// (IMPLEMENTATION_PLAN §3 puts the Linear project cache in `state.json`; M7 moves it
    /// there and this shape goes with it). An unrecognised version is treated as an empty
    /// cache rather than as an error: the worst it costs is one poll's worth of requests,
    /// where throwing would leave the app unable to read its own state file at all.
    public static let schemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case version
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? LinearProjectCache.schemaVersion
        guard version == LinearProjectCache.schemaVersion else {
            self.init()
            return
        }
        self.init(entries: try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(LinearProjectCache.schemaVersion, forKey: .version)
        try container.encode(entries, forKey: .entries)
    }
}

/// Where the cache is read from and written to.
///
/// A protocol rather than a concrete file, because M7 folds this into `state.json` and the
/// resolver should not have to change when it does.
///
/// `Sendable` because the panel's poll runs off the main actor and the store outlives it.
/// Both implementations below take a lock that never spans a suspension point, which is
/// what makes the unchecked conformance true rather than merely declared.
public protocol LinearProjectCacheStore: AnyObject, Sendable {
    func load() -> LinearProjectCache
    func save(_ cache: LinearProjectCache)
}

/// The default store: in memory, lost on relaunch. Costs one poll's worth of resolution
/// after a launch.
public final class InMemoryLinearProjectCacheStore: LinearProjectCacheStore, @unchecked Sendable {
    private var cache: LinearProjectCache
    private let lock = NSLock()

    public init(_ cache: LinearProjectCache = .empty) {
        self.cache = cache
    }

    public func load() -> LinearProjectCache {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    public func save(_ cache: LinearProjectCache) {
        lock.lock()
        defer { lock.unlock() }
        self.cache = cache
    }
}

/// A JSON file. Atomic writes and sorted keys, so two runs over the same data produce the
/// same bytes and a corrupt half-written file is not reachable.
public final class FileLinearProjectCacheStore: LinearProjectCacheStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    /// A cache that cannot be read is an empty cache, never a crash. It holds nothing the
    /// user typed and nothing that cannot be fetched again.
    public func load() -> LinearProjectCache {
        lock.lock()
        defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: url.path) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LinearProjectCache.self, from: data)) ?? .empty
    }

    public func save(_ cache: LinearProjectCache) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
