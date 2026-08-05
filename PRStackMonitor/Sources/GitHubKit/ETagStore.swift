import Foundation

/// Remembers the `ETag` a REST resource was last served with, so the next request for it
/// can be conditional.
///
/// A `304` costs nothing against the REST allowance, which is what makes this worth having
/// for the release tracker's `compare` calls (M6): the same tag/commit pair is compared
/// repeatedly across polls, and only the first of those has to spend a request. GraphQL
/// has no equivalent — it is a single POST endpoint and is metered in points instead
/// (see ``PointBudget``).
public protocol ETagStore: AnyObject {
    func etag(for key: String) -> String?
    func setETag(_ etag: String?, for key: String)
}

/// The default store: in memory, lost on relaunch.
///
/// Losing it costs one uncached request per resource after a launch, which is the right
/// trade for M2. M6 can persist it alongside the rest of `state.json` if that ever matters.
public final class InMemoryETagStore: ETagStore {
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
