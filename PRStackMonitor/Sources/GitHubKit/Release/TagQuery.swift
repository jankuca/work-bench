import Foundation
import NetKit

/// The paginated tag query (IMPLEMENTATION_PLAN §3).
enum TagRefsQuery {
    /// Three schema details are easy to get wrong here, and each one fails quietly:
    ///
    /// - `orderBy` takes a `RefOrder` where **both** `field` and `direction` are required.
    /// - `committedDate` lives on `Commit`, **not** on `Tag`, so an annotated tag needs
    ///   `tagger { date }` or its target commit's date.
    /// - an annotated tag's `target.oid` is the *tag object's* id, not the commit's — the
    ///   commit oid is one level further in.
    ///
    /// Containment is tested by tag **name**, so the last one only matters for dating and
    /// ordering; but comparing a tag-object oid against a merge commit would never match,
    /// and nothing would say why.
    static let text = """
    query TagRefs($owner: String!, $name: String!, $prefilter: String, $pageSize: Int!, $cursor: String) {
      rateLimit { limit cost remaining resetAt }
      repository(owner: $owner, name: $name) {
        refs(
          refPrefix: "refs/tags/"
          query: $prefilter
          first: $pageSize
          after: $cursor
          orderBy: { field: TAG_COMMIT_DATE, direction: ASC }
        ) {
          pageInfo { hasNextPage endCursor }
          nodes {
            name
            target {
              __typename
              oid
              ... on Commit { committedDate }
              ... on Tag {
                tagger { date }
                target {
                  __typename
                  oid
                  ... on Commit { committedDate }
                }
              }
            }
          }
        }
      }
    }
    """

    /// `prefilter` is the literal prefix of the configured glob, or `null` when the pattern
    /// opens with a wildcard. It is a *substring* filter on GitHub's side — a prefilter, not
    /// the match — so the glob is applied again locally to everything it returns.
    static func variables(
        owner: String,
        name: String,
        prefilter: String?,
        pageSize: Int,
        cursor: String?
    ) -> [String: GraphQLValue] {
        [
            "owner": .string(owner),
            "name": .string(name),
            "prefilter": prefilter.map(GraphQLValue.string) ?? .null,
            "pageSize": .int(pageSize),
            "cursor": cursor.map(GraphQLValue.string) ?? .null
        ]
    }
}

// MARK: - Wire shape

struct TagRefsPayload: Decodable, Equatable {
    var rateLimit: RateLimitDTO? = nil
    /// Null when the repository is gone or the token cannot see it, with the reason in
    /// `errors`. That is a warning about one repository, not a failed poll.
    var repository: TagRepositoryDTO? = nil
}

struct TagRepositoryDTO: Decodable, Equatable {
    var refs: RefConnectionDTO? = nil
}

struct RefConnectionDTO: Decodable, Equatable {
    var pageInfo: PageInfoDTO? = nil
    var nodes: [TagRefDTO?]? = nil
}

struct TagRefDTO: Decodable, Equatable {
    /// Just the tag name — `refPrefix` is stripped by GitHub, so this is `v1.4.0`, not
    /// `refs/tags/v1.4.0`.
    var name: String? = nil
    var target: TagTargetDTO? = nil
}

/// The ref's target: a `Commit` for a lightweight tag, a `Tag` object for an annotated one.
struct TagTargetDTO: Decodable, Equatable {
    var typeName: String? = nil
    /// The tag object's oid for an annotated tag, the commit's for a lightweight one.
    var oid: String? = nil
    /// `Commit` only.
    var committedDate: Date? = nil
    /// `Tag` only.
    var tagger: TaggerDTO? = nil
    /// `Tag` only — the commit the annotated tag points at.
    var target: TaggedCommitDTO? = nil

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case oid
        case committedDate
        case tagger
        case target
    }
}

struct TaggerDTO: Decodable, Equatable {
    var date: Date? = nil
}

struct TaggedCommitDTO: Decodable, Equatable {
    var typeName: String? = nil
    var oid: String? = nil
    var committedDate: Date? = nil

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case oid
        case committedDate
    }
}
