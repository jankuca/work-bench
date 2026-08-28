import Foundation

/// Where a row sits in a stack run, which is what the sleeve around the chips is drawn
/// from: a member continues the sleeve toward each neighbour it has, and caps it where it
/// does not.
public enum SpinePosition: String, Sendable {
    /// Not part of a run of two or more — no sleeve.
    case none
    /// Top-most member: the sleeve caps above it and continues below.
    case top
    /// Continues both ways.
    case middle
    /// Bottom member, the one targeting trunk: continues above, caps below.
    case base
}

/// One contiguous run of stacked pull requests, top-most first and base last.
public struct StackRun: Equatable, Sendable {
    public var members: [PRID]

    public init(members: [PRID]) {
        self.members = members
    }

    public var base: PRID? { members.last }
    /// A run of one is a positioning fact, not a stack: nothing is drawn around it.
    public var drawsSpine: Bool { members.count >= 2 }
}

/// Every run descended from one root, kept together so the runs render adjacently.
public struct StackGroup: Equatable, Sendable {
    /// The bottom-most pull request of the whole group — the one targeting trunk. It
    /// anchors both the group's ordering and its project section.
    public var root: PRID
    /// Primary run first (the longest chain), then sibling branches.
    public var runs: [StackRun]

    public init(root: PRID, runs: [StackRun]) {
        self.root = root
        self.runs = runs
    }

    public var members: [PRID] { runs.flatMap(\.members) }
}

/// Where a single row sits in the stack structure.
public struct StackPlacement: Equatable, Sendable {
    public var spine: SpinePosition
    /// The base of the row's run, when that run is drawn as a stack.
    public var runBase: PRID?
    /// The root of the row's stack group, when it has one. Rows inherit their section
    /// from this pull request's project so a group can never straddle two headings.
    public var groupRoot: PRID?

    public init(spine: SpinePosition, runBase: PRID?, groupRoot: PRID?) {
        self.spine = spine
        self.runBase = runBase
        self.groupRoot = groupRoot
    }

    public static let loose = StackPlacement(spine: .none, runBase: nil, groupRoot: nil)
}

/// The parent/child structure derived from head and base branches.
public struct StackLayout: Equatable, Sendable {
    /// Structural parent for each pull request that has one — the member whose head branch
    /// this one is based on, merged or not. Members of a cycle are removed entirely, so
    /// they are neither blocked nor drawn with a spine.
    public var parentOf: [PRID: PRID]
    /// The parent a pull request is actually *waiting on*: its structural parent, but only
    /// while that parent is still open.
    ///
    /// The two differ for the layer sitting directly on a merge. Its branch is already in
    /// trunk, so nothing is holding the child back and `blocked` would be a lie — but the
    /// merge is still on screen until a release contains it, and the run has to keep
    /// drawing through it. ``parentOf`` is the shape; this is the verdict.
    public var blockingParentOf: [PRID: PRID]
    public var groups: [StackGroup]
    public var placement: [PRID: StackPlacement]

    public init(
        parentOf: [PRID: PRID],
        blockingParentOf: [PRID: PRID],
        groups: [StackGroup],
        placement: [PRID: StackPlacement]
    ) {
        self.parentOf = parentOf
        self.blockingParentOf = blockingParentOf
        self.groups = groups
        self.placement = placement
    }

    public func placement(for id: PRID) -> StackPlacement {
        placement[id] ?? .loose
    }

    /// Builds the layout from the pull requests in one snapshot.
    ///
    /// Only the viewer's own pull requests enter the branch index, and only while they are
    /// still in flight — open, or merged and not yet contained in a release. Two of the §2
    /// edge cases fall out of that filter for free: a parent authored by someone else never
    /// matches, and a parent in another repository never matches because the repository is
    /// part of the index key.
    ///
    /// A merge stays in the index rather than dropping out of it, which is the one place
    /// this departs from the plan's original "merged parent drops out". GitHub keeps showing
    /// the stack after the base merges — the child's base branch is still the merged pull
    /// request's head branch until the branch is deleted and the child re-targeted — and a
    /// panel that reflowed the sleeve the instant the base merged disagreed with it, hiding
    /// the merge at the bottom of the section as a loose row while its own children were
    /// still drawn as a stack above. The merge leaves the run when it leaves the panel: once
    /// a release contains it the row moves to Done, and the sleeve reflows then.
    ///
    /// `releaseStages` is the stage per pull request, as ``Derivation`` resolved it. An
    /// absent entry reads as "no binding yet", which is what a merge with no release
    /// recorded against it means.
    public static func build(
        pullRequests: [PullRequest],
        viewerLogin: String,
        releaseStages: [PRID: ReleaseStage] = [:]
    ) -> StackLayout {
        struct BranchKey: Hashable {
            let repo: String
            let ref: String
        }

        let stackable = pullRequests
            .filter { $0.authorLogin == viewerLogin && isInFlight($0, releaseStages: releaseStages) }
            .sorted { $0.number < $1.number }

        var index: [BranchKey: PullRequest] = [:]
        for pullRequest in stackable {
            let key = BranchKey(repo: pullRequest.repo, ref: pullRequest.headRef)
            guard let claimed = index[key] else {
                index[key] = pullRequest
                continue
            }
            // Two *open* pull requests from one head branch is not a real GitHub state, but
            // one merge plus one open pull request is entirely ordinary once merges stay in
            // the index: a branch merged, then reused or reopened under the same name. The
            // open one is the live parent. Between two of the same kind the lower number
            // wins — `stackable` is sorted, so that is the one already claimed — and the
            // layout stays deterministic either way.
            if claimed.state != .open, pullRequest.state == .open {
                index[key] = pullRequest
            }
        }

        var parentOf: [PRID: PRID] = [:]
        for pullRequest in stackable {
            let key = BranchKey(repo: pullRequest.repo, ref: pullRequest.baseRef)
            if let parent = index[key], parent.id != pullRequest.id {
                parentOf[pullRequest.id] = parent.id
            }
        }

        parentOf = breakCycles(in: parentOf, nodes: stackable.map(\.id))

        // Only an open parent blocks. Derived here rather than in the resolver because this
        // is where a cycle has already had its parents taken away, and a row that leads into
        // one must not come out blocked on a pull request the layout gave up on.
        let openIDs = Set(stackable.filter { $0.state == .open }.map(\.id))
        let blockingParentOf = parentOf.filter { openIDs.contains($0.value) }

        var children: [PRID: [PRID]] = [:]
        for (child, parent) in parentOf {
            children[parent, default: []].append(child)
        }
        children = children.mapValues { $0.sorted(by: PRID.panelOrder) }

        // Longest downward chain from each node, memoised. Cycles are gone by now, so
        // this terminates.
        var chainLengths: [PRID: Int] = [:]
        func chainLength(_ id: PRID) -> Int {
            if let cached = chainLengths[id] { return cached }
            let length = 1 + ((children[id] ?? []).map(chainLength).max() ?? 0)
            chainLengths[id] = length
            return length
        }

        /// Longest chain starting at `start`, base first, restricted to `remaining`.
        func longestChain(from start: PRID, within remaining: Set<PRID>) -> [PRID] {
            var chain = [start]
            var current = start
            while true {
                let candidates = (children[current] ?? []).filter { remaining.contains($0) }
                guard let next = bestStart(among: candidates, chainLength: chainLength) else { break }
                chain.append(next)
                current = next
            }
            return chain
        }

        let roots = stackable
            .map(\.id)
            .filter { parentOf[$0] == nil && !(children[$0] ?? []).isEmpty }
            .sorted(by: PRID.panelOrder)

        var groups: [StackGroup] = []
        for root in roots {
            var remaining = subtree(of: root, children: children)
            var runs: [StackRun] = []
            while !remaining.isEmpty {
                // A run can only start at a node whose parent has already been taken —
                // on the first pass that is the root, afterwards the untaken siblings.
                let starts = remaining.filter { id in
                    guard let parent = parentOf[id] else { return true }
                    return !remaining.contains(parent)
                }
                guard let start = bestStart(among: Array(starts), chainLength: chainLength) else { break }
                let chain = longestChain(from: start, within: remaining)
                // Members render top-most first, base last.
                runs.append(StackRun(members: Array(chain.reversed())))
                remaining.subtract(chain)
            }
            groups.append(StackGroup(root: root, runs: runs))
        }

        var placement: [PRID: StackPlacement] = [:]
        for group in groups {
            for run in group.runs {
                for (offset, member) in run.members.enumerated() {
                    let spine: SpinePosition
                    if !run.drawsSpine {
                        spine = .none
                    } else if offset == 0 {
                        spine = .top
                    } else if offset == run.members.count - 1 {
                        spine = .base
                    } else {
                        spine = .middle
                    }
                    placement[member] = StackPlacement(
                        spine: spine,
                        runBase: run.drawsSpine ? run.base : nil,
                        groupRoot: group.root
                    )
                }
            }
        }

        return StackLayout(
            parentOf: parentOf,
            blockingParentOf: blockingParentOf,
            groups: groups,
            placement: placement
        )
    }

    /// Whether a pull request is still part of the stack it was opened into.
    ///
    /// Open always is. A merge is until its release stage becomes terminal — at which point
    /// the row is Done, and a group straddling the Done heading is one the panel cannot
    /// draw. Closed without merging never is: nothing was contributed to the branch below
    /// it.
    ///
    /// "Terminal" is asked of the row status rather than listed here, so this cannot fall
    /// out of step with ``RowStatus/belongsInDone``. A merge into a chain that was
    /// abandoned, or onto a branch whose releases cannot be followed, is as finished as a
    /// released one and leaves the run for the same reason.
    private static func isInFlight(
        _ pullRequest: PullRequest,
        releaseStages: [PRID: ReleaseStage]
    ) -> Bool {
        switch pullRequest.state {
        case .open:
            return true
        case .closed:
            return false
        case .merged:
            guard let stage = releaseStages[pullRequest.id] else { return true }
            return !RowStatusResolver.resolve(
                pullRequest: pullRequest,
                releaseStage: stage,
                parent: nil
            ).belongsInDone
        }
    }

    /// Longest chain wins the spine; the higher pull request number breaks ties so the
    /// choice never depends on dictionary or API ordering.
    private static func bestStart(among candidates: [PRID], chainLength: (PRID) -> Int) -> PRID? {
        candidates.max { lhs, rhs in
            let left = chainLength(lhs)
            let right = chainLength(rhs)
            if left != right { return left < right }
            return PRID.panelOrder(rhs, lhs)
        }
    }

    private static func subtree(of root: PRID, children: [PRID: [PRID]]) -> Set<PRID> {
        var result: Set<PRID> = [root]
        var queue = [root]
        while let current = queue.popLast() {
            for child in children[current] ?? [] {
                if result.insert(child).inserted {
                    queue.append(child)
                }
            }
        }
        return result
    }

    /// Impossible in git, but cheap to guard. Any node that sits on — or leads into — a
    /// cycle loses its parent, so the members render as loose pull requests with no spine
    /// and no `blocked` status.
    private static func breakCycles(in parentOf: [PRID: PRID], nodes: [PRID]) -> [PRID: PRID] {
        var acyclic: Set<PRID> = []
        var cyclic: Set<PRID> = []

        for node in nodes {
            var path: [PRID] = []
            var seen: Set<PRID> = []
            var current: PRID? = node
            while let id = current {
                if cyclic.contains(id) {
                    cyclic.formUnion(path)
                    break
                }
                if acyclic.contains(id) {
                    acyclic.formUnion(path)
                    break
                }
                if seen.contains(id) {
                    cyclic.formUnion(path)
                    cyclic.insert(id)
                    break
                }
                seen.insert(id)
                path.append(id)
                current = parentOf[id]
                if current == nil { acyclic.formUnion(path) }
            }
        }

        guard !cyclic.isEmpty else { return parentOf }
        var result = parentOf
        for id in cyclic { result[id] = nil }
        return result
    }
}
