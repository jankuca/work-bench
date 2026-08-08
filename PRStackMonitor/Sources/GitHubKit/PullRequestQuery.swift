import Foundation
import NetKit

/// The one search query per poll (IMPLEMENTATION_PLAN §3), paginated to completion.
enum PullRequestQuery {
    /// Two selections deserve a note because they are additions to the plan's snippet:
    ///
    /// - `rateLimit` selects `limit` as well as `cost remaining resetAt`. The plan's rule
    ///   is "back off when `remaining` drops below 10% of the hourly allowance", and
    ///   without `limit` that percentage has to be computed against a hard-coded 5,000 —
    ///   which is wrong the moment the token type changes. The field is free.
    /// - `author { login }` is selected even though `author:@me` guarantees the answer.
    ///   Authorship survives as far as stack derivation, where only the viewer's own pull
    ///   requests may act as parents (`stack-parent-foreign-author`), so it is better read
    ///   than assumed.
    ///
    /// `contexts` returns the `StatusCheckRollupContext` union, so it needs inline
    /// fragments on both members — `CheckRun` and `StatusContext`. A bare selection set
    /// does not compile server-side.
    static let text = """
    query PullRequestSearch($query: String!, $pageSize: Int!, $cursor: String) {
      rateLimit { limit cost remaining resetAt }
      viewer { login }
      search(query: $query, type: ISSUE, first: $pageSize, after: $cursor) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            number title body url headRefName baseRefName isDraft state
            createdAt updatedAt mergedAt
            mergeable reviewDecision
            mergeCommit { oid }
            author { login }
            repository { nameWithOwner defaultBranchRef { name } }
            comments(last: 1) { totalCount nodes { createdAt } }
            reviews(last: 20) { nodes { author { login avatarUrl } state submittedAt } }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                    contexts(first: 20) {
                      totalCount
                      nodes {
                        __typename
                        ... on CheckRun { name conclusion status detailsUrl }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    static func variables(query: String, pageSize: Int, cursor: String?) -> [String: GraphQLValue] {
        [
            "query": .string(query),
            "pageSize": .int(pageSize),
            "cursor": cursor.map(GraphQLValue.string) ?? .null
        ]
    }
}
