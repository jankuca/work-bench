import Foundation
import XCTest
@testable import PRStackCore

/// Merges that did not land on trunk, and how far the panel can follow them without asking
/// GitHub anything.
///
/// The behaviour under test is one rule applied at every level: *whose branch did this
/// merge into, and what happened to that pull request*. Nothing here knows or cares whether
/// a merge was a merge commit, a squash or a rebase, which is exactly why the squash cases
/// need no special handling.
final class MergeChainTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private var start: Date { Date(timeIntervalSince1970: 1_767_900_000) }

    private func pullRequest(
        _ number: Int,
        repo: String = "acme/billing",
        head: String,
        base: String,
        defaultBranch: String? = "main",
        state: GitHubState = .merged,
        commit: String? = nil,
        createdDaysIn: Double = 0,
        mergedDaysIn: Double? = nil
    ) -> PullRequest {
        let created = start.addingTimeInterval(createdDaysIn * day)
        let merged = mergedDaysIn.map { start.addingTimeInterval($0 * day) }
        return PullRequest(
            repo: repo,
            number: number,
            title: "PR \(number)",
            headRef: head,
            baseRef: base,
            defaultBranch: defaultBranch,
            state: state,
            mergeCommit: state == .merged ? (commit ?? "commit\(number)") : nil,
            createdAt: created,
            updatedAt: merged ?? created,
            mergedAt: state == .merged ? (merged ?? created.addingTimeInterval(day)) : nil
        )
    }

    private func id(_ number: Int, repo: String = "acme/billing") -> PRID {
        PRID(repo: repo, number: number)
    }

    private func stage(
        _ pullRequest: PullRequest,
        among all: [PullRequest],
        local: LocalState = .empty
    ) -> ReleaseStage {
        Derivation.releaseStage(
            for: pullRequest,
            in: MergeChain.headIndex(all),
            local: local
        )
    }

    // MARK: - What counts as nested

    /// The whole feature keys off this one predicate, and it has to read an unknown default
    /// branch as trunk: a pull request decoded from a state file written before the field
    /// existed must track exactly as it did, not divert into chain resolution on the
    /// strength of a missing value.
    func testAMergeWithNoKnownDefaultBranchIsNotTreatedAsNested() {
        let unknown = pullRequest(10, head: "avery/a", base: "avery/b", defaultBranch: nil)
        XCTAssertFalse(MergeChain.isNested(unknown))

        let known = pullRequest(11, head: "avery/a", base: "avery/b")
        XCTAssertTrue(MergeChain.isNested(known))

        let trunk = pullRequest(12, head: "avery/a", base: "main")
        XCTAssertFalse(MergeChain.isNested(trunk))
    }

    // MARK: - The local walk

    /// The case the whole thing exists for: a squashed parent. The child's own merge commit
    /// is on a branch the squash rewrote away, so no tag will ever contain it — but the
    /// parent shipped, and the child shipped with it.
    func testAChildInheritsTheReleaseOfTheParentItMergedInto() {
        let parent = pullRequest(200, head: "avery/parent", base: "main", mergedDaysIn: 3)
        let child = pullRequest(201, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        var local = LocalState.empty
        local.bind(parent.id, toRelease: "v2.1.0")

        XCTAssertEqual(stage(child, among: [parent, child], local: local), .released(tag: "v2.1.0"))
    }

    /// Multi-level, and every level a different merge method as far as this is concerned —
    /// which is to say it never comes up. Only the root needs a commit on trunk.
    func testAReleasePropagatesDownAWholeChain() {
        let root = pullRequest(300, head: "avery/root", base: "main", mergedDaysIn: 5)
        let middle = pullRequest(301, head: "avery/middle", base: "avery/root", mergedDaysIn: 4)
        let leaf = pullRequest(302, head: "avery/leaf", base: "avery/middle", mergedDaysIn: 3)

        var local = LocalState.empty
        local.bind(root.id, toRelease: "v3.0.0")

        let all = [root, middle, leaf]
        XCTAssertEqual(stage(middle, among: all, local: local), .released(tag: "v3.0.0"))
        XCTAssertEqual(stage(leaf, among: all, local: local), .released(tag: "v3.0.0"))
    }

    /// Before the parent ships, the row says what it is actually waiting for. `awaiting
    /// release` was never true of it — the release it is waiting for is not its own.
    func testAnUnreleasedParentLeavesTheChildNamingIt() {
        let parent = pullRequest(400, head: "avery/parent", base: "main", mergedDaysIn: 3)
        let child = pullRequest(401, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        XCTAssertEqual(
            stage(child, among: [parent, child]),
            .mergedIntoPullRequest(parent.id)
        )
    }

    func testAnOpenParentLeavesTheChildNamingIt() {
        let parent = pullRequest(500, head: "avery/parent", base: "main", state: .open)
        let child = pullRequest(501, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        XCTAssertEqual(
            stage(child, among: [parent, child]),
            .mergedIntoPullRequest(parent.id)
        )
    }

    /// The parent was abandoned, so the child's change never reached trunk and never will.
    /// This is the case that used to sit at `merged · awaiting release` forever.
    func testAClosedParentEndsTheChain() {
        let parent = pullRequest(600, head: "avery/parent", base: "main", state: .closed)
        let child = pullRequest(601, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        XCTAssertEqual(
            stage(child, among: [parent, child]),
            .mergedIntoAbandonedPullRequest(parent.id)
        )
    }

    // MARK: - The lifetime guard

    /// A branch name reused months apart has two pull requests claiming it. Joining the
    /// child to the wrong one would bind it to the wrong release, permanently — so the
    /// child's merge has to fall inside the parent's lifetime.
    func testAReusedBranchNameResolvesToTheParentThatWasOpenAtTheTime() {
        let firstUse = pullRequest(
            700,
            head: "team/integration",
            base: "main",
            createdDaysIn: 0,
            mergedDaysIn: 2
        )
        let secondUse = pullRequest(
            720,
            head: "team/integration",
            base: "main",
            createdDaysIn: 30,
            mergedDaysIn: 32
        )
        let child = pullRequest(
            701,
            head: "avery/child",
            base: "team/integration",
            createdDaysIn: 1,
            mergedDaysIn: 1.5
        )

        var local = LocalState.empty
        local.bind(firstUse.id, toRelease: "v1.0.0")
        local.bind(secondUse.id, toRelease: "v9.9.9")

        XCTAssertEqual(
            stage(child, among: [firstUse, secondUse, child], local: local),
            .released(tag: "v1.0.0"),
            "the merge happened during the first use of the branch, not the second"
        )
    }

    /// Two candidates whose lifetimes both cover the merge is not something to guess at.
    /// The row stays where it was rather than being bound to one of them.
    func testAnAmbiguousBranchResolvesToNothing() {
        let one = pullRequest(800, head: "team/shared", base: "main", createdDaysIn: 0, mergedDaysIn: 10)
        let two = pullRequest(801, head: "team/shared", base: "main", createdDaysIn: 0, mergedDaysIn: 10)
        let child = pullRequest(
            802,
            head: "avery/child",
            base: "team/shared",
            createdDaysIn: 1,
            mergedDaysIn: 2
        )

        XCTAssertNil(MergeChain.parent(of: child, in: MergeChain.headIndex([one, two, child])))
        XCTAssertEqual(stage(child, among: [one, two, child]), .mergedAwaitingTag)
    }

    /// Nothing in a snapshot guarantees it is acyclic, and the walk reads raw branches.
    func testACycleTerminates() {
        let first = pullRequest(900, head: "avery/a", base: "avery/b", mergedDaysIn: 2)
        let second = pullRequest(901, head: "avery/b", base: "avery/a", mergedDaysIn: 2)

        // The assertion that matters is that this returns at all. The walk reaches the
        // second pull request, follows it back to the first, recognises it and stops — with
        // no anchor to fall back on, that is an ordinary merge awaiting a tag.
        XCTAssertEqual(stage(first, among: [first, second]), .mergedAwaitingTag)
    }

    // MARK: - Anchors, for the chains that leave the snapshot

    /// A pull request opened on top of somebody else's. Their pull request is never in the
    /// snapshot — both searches carry `author:@me` — so the walk runs out and the resolver's
    /// answer stands in.
    func testAForeignParentIsReadFromItsAnchor() {
        let child = pullRequest(1000, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)
        let theirs = PRID(repo: "acme/billing", number: 1001)

        var local = LocalState.empty
        local.recordAnchor(MergeAnchor(outcome: .pending(theirs), checkedAt: start), for: child.id)
        XCTAssertEqual(stage(child, among: [child], local: local), .mergedIntoPullRequest(theirs))

        local.recordAnchor(MergeAnchor(outcome: .abandoned(theirs), checkedAt: start), for: child.id)
        XCTAssertEqual(
            stage(child, among: [child], local: local),
            .mergedIntoAbandonedPullRequest(theirs)
        )
    }

    /// Once their pull request reaches trunk, the row is waiting for a tag like any other
    /// merge — and the tracker has been pointed at the commit that actually landed.
    func testALandedAnchorRetargetsTheComparisonAndReadsAsAwaitingATag() {
        let child = pullRequest(1100, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)
        let theirs = PRID(repo: "acme/billing", number: 1101)
        let landedAt = start.addingTimeInterval(4 * day)

        var local = LocalState.empty
        local.recordMerges(from: [child])
        XCTAssertEqual(local.unboundMerges[child.id]?.mergeCommit, child.mergeCommit)

        local.recordAnchor(
            MergeAnchor(outcome: .landed(root: theirs, commit: "trunk9", mergedAt: landedAt), checkedAt: start),
            for: child.id
        )

        XCTAssertEqual(stage(child, among: [child], local: local), .mergedAwaitingTag)
        XCTAssertEqual(
            local.unboundMerges[child.id]?.mergeCommit,
            "trunk9",
            "a tag has to contain what the chain put on trunk, not this row's own merge commit"
        )
        XCTAssertEqual(local.unboundMerges[child.id]?.mergedAt, landedAt)

        // The row goes on reporting its own merge commit for as long as it is in the
        // snapshot, so the next poll's `recordMerges` must not undo any of this. If it
        // did, the negatives would go with it and the tracker would re-test every
        // candidate tag on every poll, against a commit no tag can ever contain.
        local.recordComparison(child.id, against: "v1.0.0")
        local.recordMerges(from: [child])
        XCTAssertEqual(local.unboundMerges[child.id]?.mergeCommit, "trunk9")
        XCTAssertEqual(local.unboundMerges[child.id]?.mergedAt, landedAt)
        XCTAssertEqual(
            local.unboundMerges[child.id]?.comparedTags,
            ["v1.0.0"],
            "a negative recorded against the trunk commit is still about the right commit"
        )
    }

    /// Negatives recorded against the row's own merge commit were about a commit no tag was
    /// ever going to contain. Carrying them over would skip the very tag that contains the
    /// one it has been re-pointed at.
    func testRetargetingDropsComparisonsMadeAgainstTheOldCommit() {
        let child = pullRequest(1200, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [child])
        local.recordComparison(child.id, against: "v1.0.0")
        local.recordComparison(child.id, against: "v1.1.0")
        XCTAssertEqual(local.unboundMerges[child.id]?.comparedTags.count, 2)

        local.retarget(child.id, toTrunkCommit: "trunk9", mergedAt: start)
        XCTAssertEqual(local.unboundMerges[child.id]?.comparedTags, [])
    }

    /// Re-pointing at the same commit is idempotent — it must not throw away negatives that
    /// are still about the right commit, which would re-spend them on every poll.
    func testRetargetingToTheSameCommitKeepsItsComparisons() throws {
        let child = pullRequest(1300, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [child])
        local.recordComparison(child.id, against: "v1.0.0")

        let commit = try XCTUnwrap(child.mergeCommit)
        local.retarget(child.id, toTrunkCommit: commit, mergedAt: start)
        XCTAssertEqual(local.unboundMerges[child.id]?.comparedTags, ["v1.0.0"])
    }

    /// A branch no pull request owns — a long-lived integration branch merged into by hand.
    /// Nothing more will ever be learned, so the row is finished rather than left asking.
    func testAnUntrackedBranchEndsUpInDone() {
        let child = pullRequest(1400, head: "avery/child", base: "develop", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordAnchor(
            MergeAnchor(outcome: .untracked(branch: "develop"), checkedAt: start),
            for: child.id
        )

        XCTAssertEqual(stage(child, among: [child], local: local), .mergedIntoBranch("develop"))
        let status = RowStatusResolver.resolve(
            pullRequest: child,
            releaseStage: .mergedIntoBranch("develop"),
            parent: nil
        )
        XCTAssertEqual(status, .mergedUntracked)
        XCTAssertTrue(status.belongsInDone, "nothing further will be learned, so it stops taking up room")
    }

    /// An abandoned chain has nothing left to compare, and the record is what drags the
    /// closed search's lower bound backwards and holds the app at the awaiting-release
    /// cadence. Both stop.
    func testAnAbandonedChainRetiresTheUnboundRecordAndStaysRetired() {
        let child = pullRequest(1500, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)
        let theirs = PRID(repo: "acme/billing", number: 1501)

        var local = LocalState.empty
        local.recordMerges(from: [child])
        XCTAssertNotNil(local.unboundMerges[child.id])

        local.recordAnchor(MergeAnchor(outcome: .abandoned(theirs), checkedAt: start), for: child.id)
        XCTAssertNil(local.unboundMerges[child.id])

        // The next poll sees the same merged pull request again and must not put it back.
        local.recordMerges(from: [child])
        XCTAssertNil(local.unboundMerges[child.id])
    }

    // MARK: - Writing the inherited release down

    /// Derivation can work this out from the snapshot, but the snapshot is bounded by the
    /// closed search's lower bound — which shrinks as merges bind. Once the parent stops
    /// being fetched there is nothing left to derive it from a second time, so the row
    /// would flip back to `awaiting release` months after it shipped.
    func testAnInheritedReleaseIsWrittenDownAndOutlivesTheSnapshot() {
        let parent = pullRequest(2300, head: "avery/parent", base: "main", mergedDaysIn: 3)
        let child = pullRequest(2301, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [parent, child])
        local.bind(parent.id, toRelease: "v4.0.0")
        local.bindInheritedReleases(from: [parent, child])

        XCTAssertEqual(local.releaseBindings[child.id], "v4.0.0")
        XCTAssertNil(
            local.unboundMerges[child.id],
            "binding retires the record that was dragging the closed search's bound backwards"
        )

        // The parent has aged out of the snapshot. The row still reads as shipped.
        XCTAssertEqual(stage(child, among: [child], local: local), .released(tag: "v4.0.0"))
    }

    /// A leaf three levels down reads the root's binding directly, so one pass is enough
    /// however deep the stack goes.
    func testAWholeChainIsWrittenDownInOnePass() {
        let root = pullRequest(2400, head: "avery/root", base: "main", mergedDaysIn: 5)
        let middle = pullRequest(2401, head: "avery/middle", base: "avery/root", mergedDaysIn: 4)
        let leaf = pullRequest(2402, head: "avery/leaf", base: "avery/middle", mergedDaysIn: 3)

        var local = LocalState.empty
        local.bind(root.id, toRelease: "v5.0.0")
        local.bindInheritedReleases(from: [root, middle, leaf])

        XCTAssertEqual(local.releaseBindings[middle.id], "v5.0.0")
        XCTAssertEqual(local.releaseBindings[leaf.id], "v5.0.0")
    }

    /// Nothing is written for a chain that has not shipped — that would be claiming a
    /// release, permanently, on the strength of a parent that is merely merged.
    func testNothingIsInheritedFromAnUnreleasedParent() {
        let parent = pullRequest(2500, head: "avery/parent", base: "main", mergedDaysIn: 3)
        let child = pullRequest(2501, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        var local = LocalState.empty
        local.bindInheritedReleases(from: [parent, child])

        XCTAssertTrue(local.releaseBindings.isEmpty)
    }

    // MARK: - What is worth a comparison

    func testComparisonsAreNotSpentOnAMergeWaitingOnAnotherPullRequest() {
        let parent = pullRequest(1600, head: "avery/parent", base: "main", mergedDaysIn: 3)
        let child = pullRequest(1601, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [parent, child])
        XCTAssertEqual(Set(local.unboundMerges.keys), [parent.id, child.id])

        let comparable = MergeChain.comparable(
            local.unboundMerges,
            among: [parent, child],
            local: local
        )
        XCTAssertEqual(
            Set(comparable.keys),
            [parent.id],
            "the child binds by inheriting the parent's release, so testing its own commit is wasted"
        )
    }

    /// The non-regression that matters: a nested merge nobody has resolved yet is compared
    /// exactly as it was before any of this existed. Withholding it would strand the very
    /// rows that bind today — a chain merged all the way down with merge commits.
    func testAnUnresolvedNestedMergeIsStillCompared() {
        let child = pullRequest(1700, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [child])

        XCTAssertEqual(
            Set(MergeChain.comparable(local.unboundMerges, among: [child], local: local).keys),
            [child.id]
        )
    }

    func testAnUntrackedMergeStopsBeingComparedOnceItsAllowanceIsSpent() {
        let child = pullRequest(1800, head: "avery/child", base: "develop", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [child])
        local.recordAnchor(
            MergeAnchor(outcome: .untracked(branch: "develop"), checkedAt: start),
            for: child.id
        )
        XCTAssertEqual(
            Set(MergeChain.comparable(local.unboundMerges, among: [child], local: local).keys),
            [child.id],
            "an integration branch merged to trunk with a merge commit does carry the work there"
        )

        for index in 0..<MergeChain.untrackedComparisonCap {
            local.recordComparison(child.id, against: "v\(index)")
        }
        XCTAssertTrue(
            MergeChain.comparable(local.unboundMerges, among: [child], local: local).isEmpty,
            "but nothing says it ever will, so the allowance is finite"
        )
    }

    /// Stopping the comparisons is not enough. The record itself is what holds the closed
    /// search's lower bound open and keeps the app on its awaiting-release cadence, so a row
    /// that has stopped asking has to stop costing too — and must not come back on the next
    /// poll that sees the same merged pull request.
    func testAnUntrackedMergeRetiresItsRecordOnceTheAllowanceIsSpent() {
        let child = pullRequest(1850, head: "avery/child", base: "develop", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordMerges(from: [child])
        local.recordAnchor(
            MergeAnchor(outcome: .untracked(branch: "develop"), checkedAt: start),
            for: child.id
        )

        for index in 0..<(MergeChain.untrackedComparisonCap - 1) {
            local.recordComparison(child.id, against: "v\(index)")
        }
        XCTAssertNotNil(local.unboundMerges[child.id], "still inside its allowance")

        local.recordComparison(child.id, against: "v-last")
        XCTAssertNil(local.unboundMerges[child.id])
        XCTAssertNil(local.oldestUnboundMergeAt, "nothing left holding the search window open")

        local.recordMerges(from: [child])
        XCTAssertNil(local.unboundMerges[child.id], "and the next poll must not put it back")
    }

    /// A lookup that could not answer is unsettled, so it is asked again — but on the
    /// backoff, not on every poll. Without a recorded anchor these consume a lookup every
    /// single poll, forever, for a question that may never have an answer.
    func testAnUnresolvedAnchorBacksOffRatherThanBeingAskedEveryPoll() {
        let child = pullRequest(1900, head: "avery/child", base: "team/shared", mergedDaysIn: 2)
        let checkedAt = start.addingTimeInterval(10 * day)

        var local = LocalState.empty
        local.recordAnchor(
            MergeAnchor(outcome: .unresolved(branch: "team/shared"), checkedAt: checkedAt),
            for: child.id
        )

        XCTAssertFalse(MergeAnchorOutcome.unresolved(branch: "x").isSettled)
        XCTAssertTrue(
            MergeChain.unresolved(
                among: [child],
                local: local,
                now: checkedAt.addingTimeInterval(MergeChain.anchorBackoff - 1)
            ).isEmpty
        )
        XCTAssertEqual(
            MergeChain.unresolved(
                among: [child],
                local: local,
                now: checkedAt.addingTimeInterval(MergeChain.anchorBackoff)
            ).map(\.id),
            [child.id]
        )
    }

    /// It must also not read as a terminal state: the row says exactly what it said before
    /// the lookup ran.
    func testAnUnresolvedAnchorLeavesTheRowWhereItWas() {
        let child = pullRequest(1950, head: "avery/child", base: "team/shared", mergedDaysIn: 2)

        var local = LocalState.empty
        local.recordAnchor(
            MergeAnchor(outcome: .unresolved(branch: "team/shared"), checkedAt: start),
            for: child.id
        )

        XCTAssertEqual(stage(child, among: [child], local: local), .mergedAwaitingTag)
    }

    // MARK: - What is worth asking GitHub

    func testOnlyChainsTheSnapshotCannotFollowAreAskedAbout() {
        let parent = pullRequest(1900, head: "avery/parent", base: "main", mergedDaysIn: 3)
        let ownChild = pullRequest(1901, head: "avery/child", base: "avery/parent", mergedDaysIn: 2)
        let foreignChild = pullRequest(1902, head: "avery/other", base: "morgan/feature", mergedDaysIn: 2)
        let trunkMerge = pullRequest(1903, head: "avery/plain", base: "main", mergedDaysIn: 2)

        let asked = MergeChain.unresolved(
            among: [parent, ownChild, foreignChild, trunkMerge],
            local: .empty,
            now: start.addingTimeInterval(10 * day)
        )
        XCTAssertEqual(asked.map(\.id), [foreignChild.id])
    }

    /// A settled answer is a fact about a pull request that already merged. Re-asking would
    /// spend a request to learn something that cannot have changed.
    func testASettledAnchorIsNeverAskedAgain() {
        let child = pullRequest(2000, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)
        let theirs = PRID(repo: "acme/billing", number: 2001)
        let muchLater = start.addingTimeInterval(100 * day)

        var local = LocalState.empty
        local.recordAnchor(MergeAnchor(outcome: .abandoned(theirs), checkedAt: start), for: child.id)
        XCTAssertTrue(MergeChain.unresolved(among: [child], local: local, now: muchLater).isEmpty)

        local.recordAnchor(
            MergeAnchor(outcome: .untracked(branch: "morgan/feature"), checkedAt: start),
            for: child.id
        )
        XCTAssertTrue(MergeChain.unresolved(among: [child], local: local, now: muchLater).isEmpty)
    }

    /// An open parent is the one answer that can move, so it is the one that is re-asked —
    /// on a backoff, not on every poll.
    func testAPendingAnchorIsReAskedOnlyAfterTheBackoff() {
        let child = pullRequest(2100, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)
        let theirs = PRID(repo: "acme/billing", number: 2101)
        let checkedAt = start.addingTimeInterval(10 * day)

        var local = LocalState.empty
        local.recordAnchor(MergeAnchor(outcome: .pending(theirs), checkedAt: checkedAt), for: child.id)

        XCTAssertTrue(
            MergeChain.unresolved(
                among: [child],
                local: local,
                now: checkedAt.addingTimeInterval(MergeChain.anchorBackoff - 1)
            ).isEmpty
        )
        XCTAssertEqual(
            MergeChain.unresolved(
                among: [child],
                local: local,
                now: checkedAt.addingTimeInterval(MergeChain.anchorBackoff)
            ).map(\.id),
            [child.id]
        )
    }

    func testADismissedPullRequestIsNeverAskedAboutAndKeepsNoAnchor() {
        let child = pullRequest(2200, head: "avery/child", base: "morgan/feature", mergedDaysIn: 2)
        let theirs = PRID(repo: "acme/billing", number: 2201)

        var local = LocalState.empty
        local.recordAnchor(MergeAnchor(outcome: .pending(theirs), checkedAt: start), for: child.id)
        local.dismiss(child.id)

        XCTAssertNil(local.mergeAnchors[child.id])
        XCTAssertTrue(
            MergeChain.unresolved(
                among: [child],
                local: local,
                now: start.addingTimeInterval(100 * day)
            ).isEmpty
        )
    }

    // MARK: - Persistence

    func testAnchorsSurviveARoundTrip() throws {
        var state = LocalState.empty
        state.recordAnchor(
            MergeAnchor(outcome: .pending(id(10)), checkedAt: start),
            for: id(1)
        )
        state.recordAnchor(
            MergeAnchor(
                outcome: .landed(root: id(11), commit: "abc123", mergedAt: start),
                checkedAt: start
            ),
            for: id(2)
        )
        state.recordAnchor(
            MergeAnchor(outcome: .abandoned(id(12)), checkedAt: start),
            for: id(3)
        )
        state.recordAnchor(
            MergeAnchor(outcome: .untracked(branch: "develop"), checkedAt: start),
            for: id(4)
        )
        state.recordAnchor(
            MergeAnchor(outcome: .unresolved(branch: "team/shared"), checkedAt: start),
            for: id(5)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(LocalState.self, from: try encoder.encode(state))
        XCTAssertEqual(restored.mergeAnchors, state.mergeAnchors)
    }

    /// Every state file written before this existed has no `mergeAnchors` key, and must
    /// decode to a state where nothing has been resolved rather than failing.
    func testAStateFileWithoutAnchorsDecodesToNone() throws {
        let json = Data(#"{"dismissed":[],"displayed":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = try decoder.decode(LocalState.self, from: json)
        XCTAssertEqual(state.mergeAnchors, [:])
    }
}
