import Foundation

/// A pull request's identity: the repository it lives in, plus its number.
///
/// The repository is part of the identity everywhere it matters. Branch names like
/// `main`, `develop` or `release` recur across repositories, so an index keyed on the
/// branch alone joins unrelated pull requests into a phantom stack — see
/// ``StackLayout`` and the `stack-parent-foreign-repo` fixture.
public struct PRID: Hashable, Sendable, CustomStringConvertible {
    /// `owner/name`, as GitHub's `nameWithOwner`.
    public let repo: String
    public let number: Int

    public init(repo: String, number: Int) {
        // The two initialisers have to agree. `rawValue` is what `LocalState` writes to
        // disk, and decoding rejects any key `init?(rawValue:)` will not parse — by
        // throwing, which fails the *whole* state file rather than dropping one entry. So
        // a `PRID` that cannot survive its own `rawValue` is a stored-state hazard.
        //
        // An assert rather than a failable init: callers pass GitHub's own `nameWithOwner`
        // and pull request number, so a violation is a bug here, not untrusted input, and
        // making this fail would push a `!` into `PullRequest.id`, which cannot fail.
        assert(
            PRID.isWellFormed(repo: repo, number: number),
            "PRID(repo: \"\(repo)\", number: \(number)) serialises to a rawValue that cannot be parsed back"
        )
        self.repo = repo
        self.number = number
    }

    /// `owner/name` and a positive number — the contract both initialisers share.
    static func isWellFormed(repo: String, number: Int) -> Bool {
        let components = repo.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2
            && components.allSatisfy({ !$0.isEmpty })
            && !repo.contains(where: { $0 == "#" })
            && number > 0
    }

    /// `owner/name#123` — the spelling used on disk, in golden files, and as a
    /// dictionary key wherever `PRID` has to become a JSON object key.
    public var rawValue: String { "\(repo)#\(number)" }

    /// Parses the spelling above, and nothing else.
    ///
    /// This is the validator `LocalState` decoding runs every persisted key through, so
    /// it has to be the exact inverse of ``rawValue``: anything it accepts but spells
    /// differently would be silently rewritten the next time the state is written back.
    /// That rules out more than the obviously malformed — `Int` also accepts `+7` and
    /// `007`, which parse fine and then round-trip as `7`.
    public init?(rawValue: String) {
        guard let separator = rawValue.lastIndex(of: "#") else { return nil }
        let repo = String(rawValue[..<separator])

        // Only the canonical spelling of a number counts: `Int` also accepts `+7` and
        // `007`, which parse and then round-trip as `7`.
        let digits = String(rawValue[rawValue.index(after: separator)...])
        guard let number = Int(digits), String(number) == digits else { return nil }

        // The same predicate the memberwise initialiser asserts, so the two cannot drift.
        guard PRID.isWellFormed(repo: repo, number: number) else { return nil }

        self.init(repo: repo, number: number)
    }

    public var description: String { rawValue }

    /// The one ordering rule used for every list of rows in the panel: higher pull
    /// request number first, repository name as the tie-break. Deterministic, and
    /// never influenced by API response order or by urgency (PRD §5.1).
    public static func panelOrder(_ lhs: PRID, _ rhs: PRID) -> Bool {
        if lhs.number != rhs.number { return lhs.number > rhs.number }
        return lhs.repo < rhs.repo
    }
}

extension PRID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = PRID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a pull request id of the form 'owner/name#123', got '\(raw)'"
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
