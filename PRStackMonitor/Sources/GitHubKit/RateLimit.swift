import Foundation
import NetKit

/// GitHub's own accounting for a GraphQL call, read from the `rateLimit` field every
/// query selects.
///
/// GraphQL bills **points computed from node counts**, not one point per request: the
/// nested `reviews(last: 20)` and `contexts(first: 20)` selections multiply against 50
/// pull requests per page. So the client records what a call actually cost rather than
/// estimating it from a request count (IMPLEMENTATION_PLAN §3).
public struct RateLimit: Equatable, Sendable {
    /// The hourly allowance, 5,000 for a personal access token.
    public var limit: Int
    /// What this call cost.
    public var cost: Int
    /// What is left of the allowance after it.
    public var remaining: Int
    public var resetAt: Date?

    public init(limit: Int, cost: Int, remaining: Int, resetAt: Date? = nil) {
        self.limit = limit
        self.cost = cost
        self.remaining = remaining
        self.resetAt = resetAt
    }

    /// Back off before exhaustion, not at it. Being hard-blocked mid-poll leaves the app
    /// showing a disconnected icon for the rest of the hour; dropping to the idle interval
    /// at 10% keeps it honest and answering (IMPLEMENTATION_PLAN §3).
    public static let floorFraction = 0.10

    /// The 5,000/hr GraphQL allowance, used only when a response omits `limit`.
    public static let assumedHourlyLimit = 5_000

    public var isBelowFloor: Bool {
        let allowance = limit > 0 ? limit : RateLimit.assumedHourlyLimit
        return Double(remaining) < Double(allowance) * RateLimit.floorFraction
    }
}

/// The REST allowance, which is counted in requests and reported in headers rather than
/// in the body. Used by the `compare` calls at M6.
public struct RESTRateLimit: Equatable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var resetAt: Date?

    public init(limit: Int, remaining: Int, resetAt: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }

    public var isBelowFloor: Bool {
        let allowance = limit > 0 ? limit : 5_000
        return Double(remaining) < Double(allowance) * RateLimit.floorFraction
    }

    /// `x-ratelimit-*`, absent unless the response came from the REST API.
    public static func from(_ response: HTTPResponse) -> RESTRateLimit? {
        guard let remaining = response.header("x-ratelimit-remaining").flatMap(Int.init) else {
            return nil
        }
        let limit = response.header("x-ratelimit-limit").flatMap(Int.init) ?? 0
        let reset = response.header("x-ratelimit-reset")
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
        return RESTRateLimit(limit: limit, remaining: remaining, resetAt: reset)
    }
}

/// How many GraphQL points one poll may spend before deferring the rest of its work.
///
/// The point of the budget is that a poll never becomes unbounded: a repository with 400
/// open pull requests would otherwise page eight times on every tick. Exceeding it defers
/// the remaining pagination to the next poll, which is safe because the cursor comes back
/// with the result (IMPLEMENTATION_PLAN §3).
public struct PointBudget: Equatable, Sendable {
    /// Roughly one full page of the search plus the tag queries.
    public static let defaultPoints = 100

    public let limit: Int
    public private(set) var spent: Int

    public init(points: Int = PointBudget.defaultPoints) {
        // A non-positive budget would stop the loop before its first page and leave the
        // panel permanently empty, which is a worse failure than ignoring the setting.
        self.limit = max(1, points)
        self.spent = 0
    }

    public var remaining: Int { max(0, limit - spent) }
    public var isExhausted: Bool { spent >= limit }

    public mutating func record(_ cost: Int) {
        spent += max(0, cost)
    }
}
