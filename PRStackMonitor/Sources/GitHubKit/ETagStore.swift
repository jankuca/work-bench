import Foundation

/// Remembers the `ETag` a REST resource was last served with, so the next request for it
/// can be conditional.
///
/// A `304` costs nothing against the REST allowance, which is what makes this worth having
/// for the release tracker's `compare` calls (M6): the same tag/commit pair is compared
/// repeatedly across polls, and only the first of those has to spend a request. GraphQL
/// has no equivalent — it is a single POST endpoint and is metered in points instead
/// (see ``PointBudget``).
/// `Sendable` because the release tracker's poll runs off the main actor and the store
/// outlives it — one store for the life of the app is what makes a repeated comparison
/// cost a 304 rather than a request. The implementation below takes a lock that never spans
/// a suspension point, which is what makes the unchecked conformance true rather than
/// merely declared.
public protocol ETagStore: AnyObject, Sendable {
    func etag(for key: String) -> String?
    func setETag(_ etag: String?, for key: String)
}

/// The default store: in memory, lost on relaunch.
///
/// Losing it costs one uncached request per resource after a launch. That stays cheap
/// because M6's durable negatives (``UnboundMerge/comparedTags``) already keep a comparison
/// from being repeated across launches; the validators only save the repeats *within* one.
public final class InMemoryETagStore: ETagStore, @unchecked Sendable {
    private var entries: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func etag(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    public func setETag(_ etag: String?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = etag
    }
}

/// The outcome of a conditional GET.
public enum ConditionalPayload: Equatable, Sendable {
    /// The server answered `304`: whatever the caller already had is still current.
    case unchanged
    case changed(Data)

    public var data: Data? {
        switch self {
        case .unchanged: return nil
        case .changed(let data): return data
        }
    }

    public var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

public struct RESTResult: Equatable, Sendable {
    public var payload: ConditionalPayload
    public var rateLimit: RESTRateLimit?

    public init(payload: ConditionalPayload, rateLimit: RESTRateLimit? = nil) {
        self.payload = payload
        self.rateLimit = rateLimit
    }
}
