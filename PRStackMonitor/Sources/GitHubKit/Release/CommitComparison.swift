import Foundation
import NetKit

/// Whether a tag contains a commit, answered by `GET /repos/{o}/{r}/compare/{tag}...{sha}`.
///
/// `identical` or `behind` means the tag contains the commit: the head of the comparison —
/// the merge commit — is either the tag itself or an ancestor of it. `ahead` and `diverged`
/// mean it does not (IMPLEMENTATION_PLAN §3).
public enum CommitContainment: String, Equatable, Sendable {
    case identical
    case behind
    case ahead
    case diverged
    /// A status GitHub has not documented. Treated as "not contained" — a tag that binds a
    /// pull request permanently is not something to guess at.
    case unknown

    public var contains: Bool { self == .identical || self == .behind }

    init(rawStatus: String?) {
        self = rawStatus.flatMap(CommitContainment.init(rawValue:)) ?? .unknown
    }
}

/// One `compare` call, and the REST allowance as of it.
public struct ComparisonResult: Equatable, Sendable {
    public var containment: CommitContainment
    /// True when GitHub answered `304`, so this pair was compared earlier in this process.
    ///
    /// That can only happen after a negative: a positive binds the pull request, and a
    /// bound pull request is never compared again. So an unchanged answer is a negative,
    /// and recording it as one is what keeps the pair from being asked a third time.
    public var wasNotModified: Bool
    public var rateLimit: RESTRateLimit?

    public init(
        containment: CommitContainment,
        wasNotModified: Bool = false,
        rateLimit: RESTRateLimit? = nil
    ) {
        self.containment = containment
        self.wasNotModified = wasNotModified
        self.rateLimit = rateLimit
    }
}

extension RESTClient {
    /// Compares `tag` against `commit` in `repository`.
    ///
    /// The tag name goes into the path unencoded on purpose: `RESTClient` percent-encodes
    /// the path component it is handed, and a tag with a slash in it — `release/1.4.0` — is
    /// a path GitHub accepts as written. Encoding it here first would leave the `%2F`
    /// double-encoded by the time the URL is built.
    public func compare(
        repository: String,
        tag: String,
        containsCommit commit: String
    ) async throws -> ComparisonResult {
        let result = try await get(path: "repos/\(repository)/compare/\(tag)...\(commit)")

        guard let data = result.payload.data else {
            return ComparisonResult(
                containment: .unknown,
                wasNotModified: true,
                rateLimit: result.rateLimit
            )
        }

        let status = (try? JSONDecoder().decode(CompareResponse.self, from: data))?.status
        return ComparisonResult(
            containment: CommitContainment(rawStatus: status),
            rateLimit: result.rateLimit
        )
    }

    /// The one field of the comparison this needs. The payload also carries every commit
    /// and file in the range, which is why nothing else here decodes it.
    private struct CompareResponse: Decodable {
        var status: String?
    }
}
