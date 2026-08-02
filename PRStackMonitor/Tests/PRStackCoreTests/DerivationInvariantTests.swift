import Foundation
import XCTest
@testable import PRStackCore

final class DerivationInvariantTests: XCTestCase {
    /// Every row that needs attention is one of the three danger statuses, and no
    /// suppressed row ever does.
    func testAttentionRowsAreExactlyUnsuppressedDangerStatuses() throws {
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            for row in model.rows {
                XCTAssertEqual(
                    row.isAttention,
                    row.status.isAttentionCandidate && !row.isSuppressed,
                    "\(name): \(row.id) has an attention flag that does not follow from its status"
                )
                if row.isSuppressed {
                    XCTAssertFalse(row.isAttention, "\(name): \(row.id) is snoozed and still demanding attention")
                }
            }
            XCTAssertEqual(model.attentionCount, model.rows.filter(\.isAttention).count, name)
        }
    }

    /// Closed and shipped rows live in Done; nothing else does. A merged pull request
    /// waiting for a tag is still in flight and stays in its project section.
    func testDoneSectionHoldsExactlyTheTerminalRows() throws {
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            for section in model.sections {
                for row in section.rows {
                    let inDone = section.kind == .done
                    XCTAssertEqual(
                        inDone,
                        row.status.belongsInDone,
                        "\(name): \(row.id) (\(row.status.token)) is on the wrong side of the Done boundary"
                    )
                }
            }
        }
    }

    /// A stack group renders as adjacent rows and cannot straddle two section headings.
    func testStackGroupsAreContiguousWithinOneSection() throws {
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            for section in model.sections {
                var seen: [PRID] = []
                var closed: Set<PRID> = []
                for row in section.rows {
                    guard let root = row.stackRoot else { continue }
                    XCTAssertFalse(closed.contains(root), "\(name): group \(root) is interrupted by another row")
                    if seen.last != root {
                        if let previous = seen.last { closed.insert(previous) }
                        seen.append(root)
                    }
                }
            }

            // No group may appear in more than one section.
            var sectionOfRoot: [PRID: Int] = [:]
            for (index, section) in model.sections.enumerated() {
                for row in section.rows {
                    guard let root = row.stackRoot else { continue }
                    if let existing = sectionOfRoot[root] {
                        XCTAssertEqual(existing, index, "\(name): group \(root) spans two sections")
                    } else {
                        sectionOfRoot[root] = index
                    }
                }
            }
        }
    }

    /// Every row in a run of two or more carries a spine position, and exactly one member
    /// is the top and one is the base.
    func testSpinePositionsAreWellFormed() throws {
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            var runs: [PRID: [SpinePosition]] = [:]
            for row in model.rows {
                if let runBase = row.runBase {
                    XCTAssertNotEqual(row.spine, SpinePosition.none, "\(name): \(row.id) is in a run without a spine")
                    runs[runBase, default: []].append(row.spine)
                } else {
                    XCTAssertEqual(row.spine, SpinePosition.none, "\(name): \(row.id) draws a spine outside a run")
                }
            }
            for (base, positions) in runs {
                let tops = positions.filter { $0 == .top }.count
                let bases = positions.filter { $0 == .base }.count
                XCTAssertGreaterThanOrEqual(positions.count, 2, "\(name): run \(base) has fewer than two members")
                XCTAssertEqual(tops, 1, "\(name): run \(base) has \(tops) top members")
                XCTAssertEqual(bases, 1, "\(name): run \(base) has \(bases) base members")
            }
        }
    }

    /// Opening the panel writes the digests back; the very next derivation must show
    /// nothing unread. Unread is never set by our own writes.
    func testRecordingDigestsClearsUnread() throws {
        for name in Fixtures.allNames {
            let fixture = try Fixtures.load(name)
            let first = fixture.derive()

            var local = fixture.resolvedLocal()
            for row in first.rows {
                local.readDigests[row.id] = ReadDigest.make(
                    for: row.pullRequest,
                    releaseStage: row.releaseStage
                )
            }

            let second = Derivation.derive(snapshot: fixture.snapshot, local: local, now: fixture.now)
            XCTAssertEqual(second.unreadCount, 0, "\(name): rows stayed unread after their digests were recorded")
            XCTAssertTrue(second.rows.allSatisfy { !$0.isUnread }, name)
        }
    }

    /// A dismissed pull request is gone from the model entirely and cannot be brought
    /// back by a later change to it.
    func testDismissalSurvivesAChangeToThePullRequest() throws {
        let fixture = try Fixtures.load("panel-2a")
        let target = PRID(repo: "acme/billing", number: 4001)

        var local = fixture.resolvedLocal()
        local.dismissed.insert(target)

        var snapshot = fixture.snapshot
        snapshot.pullRequests = snapshot.pullRequests.map { pullRequest in
            guard pullRequest.id == target else { return pullRequest }
            var touched = pullRequest
            touched.commentCount += 5
            touched.mergeable = .conflicting
            return touched
        }

        let model = Derivation.derive(snapshot: snapshot, local: local, now: fixture.now)
        XCTAssertNil(model.row(target))
    }

    /// The summary counts what the header claims: open pull requests, and merged ones
    /// still waiting for a release tag.
    func testSummaryCountsMatchTheRows() throws {
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            XCTAssertEqual(
                model.summary.openCount,
                model.rows.filter { $0.pullRequest.state == .open }.count,
                name
            )
            XCTAssertEqual(
                model.summary.shippingCount,
                model.rows.filter { $0.status == .merged }.count,
                name
            )
        }
    }
}
