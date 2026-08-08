import Foundation
import PRStackCore

/// Pulls Linear identifiers out of a pull request's own fields.
///
/// A pull request routinely resolves **more than one** ticket — "Fixes BIL-312, BIL-313",
/// or a branch named for one issue whose body closes two more. So this collects an
/// **ordered set**, not the first match, scanning in the order IMPLEMENTATION_PLAN §2
/// fixes and de-duplicating while preserving first-seen position:
///
/// 1. Branch name
/// 2. Pull request title, in reading order
/// 3. Body: `linear.app/…/issue/XXX-123` URLs and bare identifiers, in reading order
///
/// That order is the whole point. The primary issue — the one that decides which project
/// section the row lands in — is the first of these that has a project, so deriving the
/// order from the pull request's own fields rather than from API response order is what
/// keeps a row from migrating between sections between polls (PRD §5.1).
///
/// **False positives are expected and are not filtered here.** `UTF-8`, `SHA-256` and
/// `HTTP-2` all have the shape of a Linear identifier, and no local rule can tell them
/// from a real team key without knowing the workspace's teams. Resolution is what settles
/// it: an identifier Linear does not know resolves to nothing, is dropped from
/// `linearIssues`, and never reaches the meta line. Guessing here instead would mean
/// either a hard-coded deny list that goes stale or dropping real three-letter teams.
public enum IssueIdentifierScanner {
    /// Every identifier this pull request references, in scan order.
    public static func identifiers(in pullRequest: PullRequest) -> [String] {
        var ordered = OrderedIdentifiers()
        // Branch names are conventionally lower-case (`jk/bil-312-add-tax-rows`), so this
        // pass is case-insensitive and normalises up. The prose passes below are not: a
        // title or body is written in English, and matching `covid-19` or `top-10` there
        // would put a junk identifier ahead of the real one in an order the primary issue
        // is chosen from.
        ordered.append(scan(pullRequest.headRef, requiringUppercase: false).map(\.identifier))
        ordered.append(scan(pullRequest.title, requiringUppercase: true).map(\.identifier))
        if let body = pullRequest.body {
            ordered.append(scanBody(body))
        }
        return ordered.values
    }

    // MARK: - Body

    /// The body carries identifiers two ways, and both count in reading order: a
    /// `linear.app` issue URL — which the Linear UI produces when a branch is copied, and
    /// which is often lower-case — and a bare identifier under "Closes:".
    ///
    /// The two passes are merged by position rather than concatenated, so a body that
    /// opens with a URL and then names a second ticket yields them in the order they are
    /// written. Concatenating would put every URL first, which would silently change which
    /// ticket is primary — and so which section the row is in — for that shape of body.
    static func scanBody(_ body: String) -> [String] {
        let characters = Array(body)
        let hits = (scanIssueURLs(characters) + scan(characters, requiringUppercase: true))
            .sorted { left, right in
                if left.start != right.start { return left.start < right.start }
                // A URL hit and a bare hit can start at the same offset only when the bare
                // scan matched the identifier inside the URL's own path. Same identifier,
                // so the tie-break never changes the result — it just has to be stable.
                return left.identifier < right.identifier
            }

        var ordered = OrderedIdentifiers()
        ordered.append(hits.map(\.identifier))
        return ordered.values
    }

    /// `https://linear.app/acme/issue/BIL-312/add-tax-rows` → `BIL-312`.
    ///
    /// Matched case-insensitively: the path Linear generates is upper-case, but a
    /// hand-typed or lower-cased URL still points at the same issue.
    private static func scanIssueURLs(_ characters: [Character]) -> [Hit] {
        let host = Array("linear.app")
        var hits: [Hit] = []
        var index = 0

        while let match = find(host, in: characters, from: index) {
            guard isCompleteHost(characters, at: match, length: host.count) else {
                // `notlinear.app/acme/issue/bil-312` and
                // `example.com/linear.app/acme/issue/bil-312` both contain the string and
                // neither is a Linear URL. Advance by one rather than to the end of the
                // URL, so a real linear.app later in the same token is still found.
                index = match + 1
                continue
            }
            // Bounded to the URL the host belongs to. Without this, a body mentioning
            // linear.app in one paragraph and an unrelated `/issue/` path in the next
            // would join them into an identifier neither of them names.
            let end = urlEnd(in: characters, from: match)
            if let marker = find(Array("/issue/"), in: characters, from: match, before: end) {
                let start = marker + "/issue/".count
                let segment = pathSegment(in: characters, from: start, before: end)
                if let identifier = normalised(String(characters[start..<segment]), requiringUppercase: false) {
                    hits.append(Hit(start: start, identifier: identifier))
                }
            }
            index = end
        }
        return hits
    }

    /// Whether the match at `index` is the URL's whole host rather than a fragment of a
    /// longer hostname or a path segment that happens to spell it.
    ///
    /// This is worth being strict about: a URL that merely *contains* `linear.app` resolves
    /// to a real Linear issue whose project then groups somebody else's pull request. The
    /// two rules are what a host boundary actually is —
    ///
    /// - what precedes it may not extend the hostname: a letter, a digit or a `-` means
    ///   `notlinear.app`, and a single `/` not part of `//` means it is a path segment;
    ///   a `.` is allowed, so `www.linear.app` still counts.
    /// - what follows it may not extend the hostname either: `/` starts the path, `:` a
    ///   port, and anything else that is not a hostname character ends the URL. A letter,
    ///   digit, `-` or `.` means something like `linear.apple.com`.
    private static func isCompleteHost(_ characters: [Character], at index: Int, length: Int) -> Bool {
        if index > 0 {
            let previous = characters[index - 1]
            if previous.isLetter || previous.isNumber || previous == "-" { return false }
            // A path separator, unless it is the second slash of `https://`.
            if previous == "/", index < 2 || characters[index - 2] != "/" { return false }
        }
        let after = index + length
        if after < characters.count {
            let next = characters[after]
            if next.isLetter || next.isNumber || next == "-" || next == "." { return false }
        }
        return true
    }

    /// How far the URL starting at or before `index` runs: to the first character that
    /// cannot appear in one.
    private static func urlEnd(in characters: [Character], from index: Int) -> Int {
        var end = index
        while end < characters.count, isURLCharacter(characters[end]) { end += 1 }
        return end
    }

    private static func pathSegment(in characters: [Character], from start: Int, before end: Int) -> Int {
        var index = start
        while index < end, characters[index] != "/", characters[index] != "?", characters[index] != "#" {
            index += 1
        }
        return index
    }

    private static func isURLCharacter(_ character: Character) -> Bool {
        if character.isWhitespace { return false }
        return !")>\"'`,;]}".contains(character)
    }

    private static func find(
        _ needle: [Character],
        in haystack: [Character],
        from start: Int,
        before end: Int? = nil
    ) -> Int? {
        let limit = (end ?? haystack.count) - needle.count
        guard limit >= start, !needle.isEmpty else { return nil }
        var index = start
        while index <= limit {
            var offset = 0
            while offset < needle.count,
                  haystack[index + offset].lowercased() == needle[offset].lowercased() {
                offset += 1
            }
            if offset == needle.count { return index }
            index += 1
        }
        return nil
    }

    // MARK: - Bare identifiers

    struct Hit: Equatable {
        var start: Int
        var identifier: String
    }

    static func scan(_ text: String, requiringUppercase: Bool) -> [Hit] {
        scan(Array(text), requiringUppercase: requiringUppercase)
    }

    /// Finds `KEY-123` anywhere a key and a number sit either side of a hyphen.
    ///
    /// Hand-rolled rather than a regular expression, and deliberately so. The shape wanted
    /// is not `[A-Z][A-Z0-9]+-\d+` applied naively — it has to match `BIL-312` inside
    /// `jk/bil-312-add-tax-rows`, which is the single most common way a branch names its
    /// ticket, while not matching `312-add` in the same string, not truncating `BIL-3120`
    /// to `BIL-312`, and not reading `2026-01-10` as an identifier. Splitting a run of
    /// identifier characters on `-` and testing adjacent segments says all of that
    /// directly; the equivalent expression needs both lookbehind and lookahead and reads
    /// like a puzzle.
    static func scan(_ characters: [Character], requiringUppercase: Bool) -> [Hit] {
        var hits: [Hit] = []
        var index = 0

        while index < characters.count {
            guard isRunCharacter(characters[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isRunCharacter(characters[end]) { end += 1 }

            // Segment boundaries within the run, so `bil-312-add-thing` offers the
            // adjacent pair (`bil`, `312`) and nothing else does.
            var segments: [(start: Int, end: Int)] = []
            var cursor = index
            while cursor < end {
                var segmentEnd = cursor
                while segmentEnd < end, characters[segmentEnd] != "-" { segmentEnd += 1 }
                segments.append((cursor, segmentEnd))
                cursor = segmentEnd + 1
            }

            for pair in 0..<max(0, segments.count - 1) {
                let key = Array(characters[segments[pair].start..<segments[pair].end])
                let number = Array(characters[segments[pair + 1].start..<segments[pair + 1].end])
                guard isKey(key, requiringUppercase: requiringUppercase), isNumber(number) else { continue }
                hits.append(
                    Hit(
                        start: segments[pair].start,
                        identifier: String(key).uppercased() + "-" + String(number)
                    )
                )
            }

            index = end
        }
        return hits
    }

    /// The identifier a URL path segment *opens* with, or nil.
    ///
    /// Anchored at the start rather than searched, because the segment is the identifier —
    /// but not always only the identifier: Linear writes `/issue/BIL-312/add-tax-rows`
    /// while a copied branch URL can arrive as `/issue/BIL-312-add-tax-rows`. Both name
    /// BIL-312, and neither should pick up `312` or `rows`.
    static func normalised(_ candidate: String, requiringUppercase: Bool) -> String? {
        scan(candidate, requiringUppercase: requiringUppercase)
            .first { $0.start == 0 }?
            .identifier
    }

    /// Linear team keys are letters and digits, opening with a letter, and are never one
    /// character — which is also what keeps `x-1` out of the results.
    private static func isKey(_ characters: [Character], requiringUppercase: Bool) -> Bool {
        guard characters.count >= 2 else { return false }
        guard let first = characters.first, first.isLetter else { return false }
        return characters.allSatisfy { character in
            guard character.isASCII, character.isLetter || character.isNumber else { return false }
            return requiringUppercase ? !character.isLowercase : true
        }
    }

    private static func isNumber(_ characters: [Character]) -> Bool {
        !characters.isEmpty && characters.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isRunCharacter(_ character: Character) -> Bool {
        character == "-" || (character.isASCII && (character.isLetter || character.isNumber))
    }
}

/// Append-only, first-seen order preserved.
///
/// The order is the contract — see ``IssueIdentifierScanner`` — so this exists rather than
/// a `Set` plus a sort, which would have no order to preserve, or an array plus `contains`,
/// which is quadratic on a body that mentions the same ticket twenty times.
struct OrderedIdentifiers {
    private(set) var values: [String] = []
    private var seen: Set<String> = []

    mutating func append(_ identifier: String) {
        guard seen.insert(identifier).inserted else { return }
        values.append(identifier)
    }

    mutating func append<S: Sequence>(_ identifiers: S) where S.Element == String {
        for identifier in identifiers { append(identifier) }
    }
}
