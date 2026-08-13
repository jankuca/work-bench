import Foundation
import NetKit

/// Recorded response shapes, read from the source tree rather than a bundle resource so
/// they stay editable and diffable — the same arrangement `PRStackCoreTests` uses.
///
/// These are synthetic: invented repositories, logins, titles and Linear identifiers. A
/// recorded GitHub response would describe private repositories, so anything ever taken
/// from the wire has to be fully anonymised before it is committed, not just stripped of
/// credentials (IMPLEMENTATION_PLAN §6).
enum Fixtures {
    private static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    static func text(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func data(_ name: String) throws -> Data {
        try Data(text(name).utf8)
    }
}

/// Builds the priority refresh's responses: one aliased `prN` per id asked for, in the
/// order they were asked.
///
/// A `nil` entry is the alias answering `null`, which is what a repository the token cannot
/// see and a pull request that has been deleted both look like — the case the refresh has
/// to survive rather than fail on.
enum KnownPage {
    static func json(
        repo: String = "acme/billing",
        numbers: [Int?],
        cost: Int = 8,
        remaining: Int = 4_900,
        limit: Int = 5_000,
        viewer: String = "avery",
        state: String = "OPEN",
        isDraft: Bool = false,
        updatedAt: String = "2026-01-09T08:00:00Z",
        mergedAt: String? = nil
    ) -> String {
        var fields = [
            """
            "rateLimit": {
              "limit": \(limit), "cost": \(cost), "remaining": \(remaining),
              "resetAt": "2026-01-10T13:00:00Z"
            }
            """,
            "\"viewer\": { \"login\": \"\(viewer)\" }"
        ]

        for (index, number) in numbers.enumerated() {
            guard let number else {
                fields.append("\"pr\(index)\": null")
                continue
            }
            let merged = mergedAt.map { "\n      \"mergedAt\": \"\($0)\"," } ?? ""
            fields.append(
                """
                "pr\(index)": {
                  "pullRequest": {
                    "number": \(number),
                    "title": "Pull request \(number)",
                    "url": "https://github.com/\(repo)/pull/\(number)",
                    "headRefName": "avery/branch-\(number)",
                    "baseRefName": "main",
                    "isDraft": \(isDraft),
                    "state": "\(state)",\(merged)
                    "createdAt": "2026-01-05T08:00:00Z",
                    "updatedAt": "\(updatedAt)",
                    "repository": {
                      "nameWithOwner": "\(repo)",
                      "defaultBranchRef": { "name": "main" }
                    }
                  }
                }
                """
            )
        }

        return """
        {
          "data": {
            \(fields.joined(separator: ",\n"))
          }
        }
        """
    }
}

/// Builds search responses for the pagination tests.
///
/// Hand-writing four pages of JSON would bury the thing under test — which is the loop's
/// bookkeeping, not the node shape. The full node shape has exactly one fixture,
/// `search-page-full.json`, and the mapping test owns it.
enum SearchPage {
    static func json(
        repo: String = "acme/billing",
        numbers: [Int],
        hasNextPage: Bool,
        endCursor: String?,
        cost: Int = 10,
        remaining: Int = 4_900,
        limit: Int = 5_000,
        viewer: String = "avery",
        /// `OPEN`, `MERGED` or `CLOSED`. The merged half of a poll (M6) needs the second,
        /// and a merged node is only useful with the two fields below.
        state: String = "OPEN",
        mergedAt: String? = nil,
        mergeCommit: String? = nil,
        /// A GraphQL `errors` array to send alongside the data, as GitHub does when one
        /// repository in a search is inaccessible.
        errors: String? = nil
    ) -> String {
        let nodes = numbers.map { number in
            let merged = mergedAt.map { "\n  \"mergedAt\": \"\($0)\"," } ?? ""
            let commit = mergeCommit.map { "\n  \"mergeCommit\": { \"oid\": \"\($0)-\(number)\" }," } ?? ""
            return """
            {
              "__typename": "PullRequest",
              "number": \(number),
              "title": "Pull request \(number)",
              "url": "https://github.com/\(repo)/pull/\(number)",
              "headRefName": "avery/branch-\(number)",
              "baseRefName": "main",
              "isDraft": false,
              "state": "\(state)",\(merged)\(commit)
              "createdAt": "2026-01-05T08:00:00Z",
              "updatedAt": "2026-01-09T08:00:00Z",
              "repository": { "nameWithOwner": "\(repo)", "defaultBranchRef": { "name": "main" } }
            }
            """
        }
        let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
        let errorsField = errors.map { "\n  \"errors\": \($0)," } ?? ""
        return """
        {\(errorsField)
          "data": {
            "rateLimit": {
              "limit": \(limit), "cost": \(cost), "remaining": \(remaining),
              "resetAt": "2026-01-10T13:00:00Z"
            },
            "viewer": { "login": "\(viewer)" },
            "search": {
              "issueCount": \(numbers.count),
              "pageInfo": { "hasNextPage": \(hasNextPage), "endCursor": \(cursor) },
              "nodes": [\(nodes.joined(separator: ","))]
            }
          }
        }
        """
    }
}
