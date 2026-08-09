import Foundation

/// A shell-style glob, matched locally against tag names.
///
/// This exists because `refs(query:)` is a **substring name filter, not a glob matcher**.
/// It can only be used as a coarse server-side prefilter, built from ``literalPrefix``, and
/// the configured pattern then has to be applied in full to every ref that comes back.
/// Without the local pass, `*-prod` would admit every tag in the repository and bind a pull
/// request to a staging tag (IMPLEMENTATION_PLAN §3).
///
/// Hand-rolled rather than a call to the platform's `fnmatch`, because these patterns are
/// user-visible configuration and the answer must not depend on which libc the build linked
/// against. What is implemented is the part of `fnmatch` a tag pattern uses: `*`, `?`,
/// bracket expressions with ranges and negation, and `\` escaping. `FNM_PATHNAME` is
/// deliberately absent — a tag name is not a path, and `release/*` has to match
/// `release/1.4.0`.
public struct Glob: Equatable, Sendable {
    /// The pattern as the user typed it.
    public let pattern: String
    private let units: [Unit]

    public init(_ pattern: String) {
        self.pattern = pattern
        self.units = Glob.parse(pattern)
    }

    /// Whether `candidate` matches. An empty pattern matches only the empty string, which
    /// is why callers fall back to ``TagPatterns/defaultPattern`` rather than to `""`.
    public func matches(_ candidate: String) -> Bool {
        let text = Array(candidate)
        var textIndex = 0
        var unitIndex = 0
        // Where the last `*` was, and how much text it had swallowed when we passed it.
        // Backtracking to it is what makes this linear rather than exponential.
        var starIndex: Int?
        var starTextIndex = 0

        while textIndex < text.count {
            if unitIndex < units.count, case .star = units[unitIndex] {
                starIndex = unitIndex
                starTextIndex = textIndex
                unitIndex += 1
            } else if unitIndex < units.count, units[unitIndex].matches(text[textIndex]) {
                unitIndex += 1
                textIndex += 1
            } else if let starIndex {
                unitIndex = starIndex + 1
                starTextIndex += 1
                textIndex = starTextIndex
            } else {
                return false
            }
        }

        // Trailing stars are allowed to match nothing.
        while unitIndex < units.count, case .star = units[unitIndex] {
            unitIndex += 1
        }
        return unitIndex == units.count
    }

    /// The literal text the pattern opens with, for the server-side prefilter: `v*` → `v`,
    /// `release-*` → `release-`, `*-prod` → `""`.
    ///
    /// Empty means the prefilter has to be **omitted entirely**. Sending an empty `query`
    /// would not be wrong, but sending a *guess* would: any prefix that is not genuinely a
    /// prefix of every matching name would hide tags the local matcher would have accepted.
    public var literalPrefix: String {
        var prefix = ""
        for unit in units {
            guard case .literal(let character) = unit else { break }
            prefix.append(character)
        }
        return prefix
    }

    // MARK: - Units

    private enum Unit: Equatable {
        case literal(Character)
        case anyOne
        case star
        case set(members: [Member], negated: Bool)

        func matches(_ character: Character) -> Bool {
            switch self {
            case .literal(let expected):
                return character == expected
            case .anyOne:
                return true
            case .star:
                // Handled by the caller, which has to look ahead; a star never consumes
                // exactly one character.
                return false
            case .set(let members, let negated):
                let hit = members.contains { $0.contains(character) }
                return negated ? !hit : hit
            }
        }
    }

    private enum Member: Equatable {
        case single(Character)
        case range(Character, Character)

        func contains(_ character: Character) -> Bool {
            switch self {
            case .single(let value): return character == value
            case .range(let lower, let upper): return character >= lower && character <= upper
            }
        }
    }

    private static func parse(_ pattern: String) -> [Unit] {
        let characters = Array(pattern)
        var units: [Unit] = []
        var index = 0

        while index < characters.count {
            switch characters[index] {
            case "*":
                // Runs of stars are the same as one star, and collapsing them keeps the
                // backtracking bounded.
                if units.last != .star { units.append(.star) }
                index += 1
            case "?":
                units.append(.anyOne)
                index += 1
            case "\\":
                // A trailing backslash escapes nothing, so it is itself.
                if index + 1 < characters.count {
                    units.append(.literal(characters[index + 1]))
                    index += 2
                } else {
                    units.append(.literal("\\"))
                    index += 1
                }
            case "[":
                if let (unit, next) = parseSet(characters, from: index) {
                    units.append(unit)
                    index = next
                } else {
                    // An unterminated bracket is a literal bracket, which is what every
                    // `fnmatch` does and the only reading that cannot lose a tag.
                    units.append(.literal("["))
                    index += 1
                }
            default:
                units.append(.literal(characters[index]))
                index += 1
            }
        }
        return units
    }

    /// Parses `[abc]`, `[a-z0-9]`, `[!abc]` and `[^abc]`, returning the unit and the index
    /// just past the closing bracket. `nil` when there is no closing bracket.
    private static func parseSet(_ characters: [Character], from start: Int) -> (Unit, Int)? {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }

        var members: [Member] = []
        // A `]` in the first position is a literal `]`, not the terminator.
        if index < characters.count, characters[index] == "]" {
            members.append(.single("]"))
            index += 1
        }

        while index < characters.count, characters[index] != "]" {
            let lower = characters[index]
            // `a-z`, but only when the `-` is not the last character before the close.
            if index + 2 < characters.count, characters[index + 1] == "-", characters[index + 2] != "]" {
                members.append(.range(lower, characters[index + 2]))
                index += 3
            } else {
                members.append(.single(lower))
                index += 1
            }
        }

        guard index < characters.count else { return nil }
        return (.set(members: members, negated: negated), index + 1)
    }
}

extension Glob: CustomStringConvertible {
    public var description: String { pattern }
}
