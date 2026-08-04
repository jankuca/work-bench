import Foundation

/// Where a row sits in a stack run, which is what the spine hairline is drawn from.
public enum SpinePosition: String, Sendable {
    /// Not part of a run of two or more — no spine.
    case none
    /// Top-most member: draws downward only.
    case top
    /// Draws both ways.
    case middle
    /// Bottom member, the one targeting trunk: draws upward only.
    case base
}

/// One contiguous run of stacked pull requests, top-most first and base last.
public struct StackRun: Equatable, Sendable {
    public var members: [PRID]

    public init(members: [PRID]) {
        self.members = members
    }

    public var base: PRID? { members.last }
    /// A run of one is a positioning fact, not a stack: no spine is drawn for it.
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
    /// The base of the row's run, when that run draws a spine.
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
    /// Open parent for each pull request that has one. Members of a cycle are removed
    /// entirely, so they are neither blocked nor drawn with a spine.
    public var parentOf: [PRID: PRID]
    public var groups: [StackGroup]
    public var placement: [PRID: StackPlacement]

    public init(parentOf: [PRID: PRID], groups: [StackGroup], placement: [PRID: StackPlacement]) {
        self.parentOf = parentOf
        self.groups = groups
        self.placement = placement
    }

    public func placement(for id: PRID) -> StackPlacement {
        placement[id] ?? .loose
    }

    /// Builds the layout from the pull requests in one snapshot.
    ///
    /// Only the viewer's own **open** pull requests enter the branch index. That single
    /// filter is what makes three of the §2 edge cases fall out for free: a merged parent
    /// drops out and its children re-target trunk, a parent authored by someone else never
    /// matches, and a parent in another repository never matches because the repository is
    /// part of the index key.
    public static func build(pullRequests: [PullRequest], viewerLogin: String) -> StackLayout {
        struct BranchKey: Hashable {
            let repo: String
            let ref: String
        }

        let stackable = pullRequests
            .filter { $0.state == .open && $0.authorLogin == viewerLogin }
            .sorted { $0.number < $1.number }

        var index: [BranchKey: PRID] = [:]
        for pullRequest in stackable {
            let key = BranchKey(repo: pullRequest.repo, ref: pullRequest.headRef)
            // Two open pull requests from the same head branch is not a real GitHub state,
            // but if it ever happens the lower number wins so the layout stays deterministic.
            if index[key] == nil { index[key] = pullRequest.id }
        }

        var parentOf: [PRID: PRID] = [:]
        for pullRequest in stackable {
            let key = BranchKey(repo: pullRequest.repo, ref: pullRequest.baseRef)
            if let parent = index[key], parent != pullRequest.id {
                parentOf[pullRequest.id] = parent
            }
        }

        parentOf = breakCycles(in: parentOf, nodes: stackable.map(\.id))

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

        return StackLayout(parentOf: parentOf, groups: groups, placement: placement)
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
