import Foundation
import XCTest
@testable import PRStackCore

/// Adjacent snoozed layers of one stack run fold into a single row. The fixture
/// `snooze-collapses-stacked-layers` pins what the row says; these pin where folding stops
/// and how far the row's actions reach.
final class CollapsedRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func pullRequest(_ number: Int, on base: String = "main", updatedAgo hours: Double = 3) -> PullRequest {
        PullRequest(
            repo: "acme/web",
            number: number,
            title: "Layer \(number)",
            headRef: "jk/n\(number)",
            baseRef: base,
            authorLogin: "viewer",
            updatedAt: now.addingTimeInterval(-hours * 60 * 60)
        )
    }

    private func id(_ number: Int) -> PRID {
        PRID(repo: "acme/web", number: number)
    }

    private func rows(_ pullRequests: [PullRequest], snoozes: [PRID: Snooze]) throws -> [RowPresentation] {
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: pullRequests)
        let model = Derivation.derive(snapshot: snapshot, local: LocalState(snoozes: snoozes), now: now)
        let panel = PanelPresentation.make(model: model, status: .fixture(now: now), now: now)
        guard case .sections(let sections) = panel.body else {
            XCTFail("Expected rows")
            return []
        }
        return sections.flatMap(\.rows)
    }

    /// A forked stack draws each branch as its own run. Two fully snoozed branches fold
    /// into one row each, never into one row for both: the sleeve breaks between them.
    func testSiblingRunsFoldSeparately() throws {
        let pullRequests = [
            pullRequest(1),
            pullRequest(2, on: "jk/n1"),
            pullRequest(3, on: "jk/n2"),
            pullRequest(5, on: "jk/n1"),
            pullRequest(6, on: "jk/n5"),
        ]
        let later = Snooze.until(now.addingTimeInterval(86_400))
        let snoozes: [PRID: Snooze] = [
            id(1): later,
            id(2): .merged(id(1)),
            id(3): .merged(id(2)),
            id(5): .merged(id(1)),
            id(6): .merged(id(5)),
        ]

        let presented = try rows(pullRequests, snoozes: snoozes)

        XCTAssertEqual(presented.map(\.memberIDs.count), [3, 2])
        XCTAssertTrue(presented.allSatisfy(\.isCollapsed))
    }

    /// One snoozed layer is not a fold: it keeps its number, its own phrase and its track.
    func testASingleSnoozedLayerStaysAnOrdinaryRow() throws {
        let presented = try rows(
            [pullRequest(1), pullRequest(2, on: "jk/n1")],
            snoozes: [id(2): .merged(id(1))]
        )

        XCTAssertEqual(presented.map(\.isCollapsed), [false, false])
        XCTAssertEqual(presented[0].meta.first, .number(2))
        XCTAssertEqual(presented[0].memberIDs, [id(2)])
        XCTAssertEqual(presented[0].wakeTitle, "Wake now")
    }

    /// The row is the bottom-most layer's, and it acts on every layer folded into it.
    func testTheRowIsTheBottomMostLayersAndActsOnEveryLayer() throws {
        let presented = try rows(
            [
                pullRequest(1),
                pullRequest(2, on: "jk/n1", updatedAgo: 5),
                pullRequest(3, on: "jk/n2", updatedAgo: 1),
                pullRequest(9),
            ],
            snoozes: [id(2): .merged(id(1)), id(3): .merged(id(2))]
        )
        let collapsed = try XCTUnwrap(presented.first(where: \.isCollapsed))

        XCTAssertEqual(collapsed.id, id(2))
        XCTAssertEqual(collapsed.title, "Layer 2")
        XCTAssertEqual(collapsed.url, pullRequest(2).url)
        XCTAssertEqual(collapsed.memberIDs, [id(3), id(2)])
        XCTAssertEqual(collapsed.wakeTitle, "Wake all")
        // No number: the count stands in for it. The age is the newest member's.
        XCTAssertEqual(collapsed.meta.map(\.text), ["2 snoozed", "until #1 is merged", "1h"])
        XCTAssertTrue(collapsed.supports(.snooze))
        // Snoozing the row snoozes every member, so none of them is offered as a target.
        XCTAssertEqual(collapsed.snoozeTargets.map(\.id), [id(1), id(9)])
        XCTAssertEqual(collapsed.collapsedMembers.map(\.menuTitle), ["#3 Layer 3", "#2 Layer 2"])
    }

    /// An awake layer between snoozed ones splits them: the rows are the stack's order, and
    /// folding across it would draw it in the wrong place.
    func testAnAwakeLayerSplitsTheFold() throws {
        let presented = try rows(
            [
                pullRequest(1),
                pullRequest(2, on: "jk/n1"),
                pullRequest(3, on: "jk/n2"),
                pullRequest(4, on: "jk/n3"),
            ],
            snoozes: [id(2): .merged(id(1)), id(4): .merged(id(3))]
        )

        XCTAssertEqual(presented.map(\.id), [id(4), id(3), id(2), id(1)])
        XCTAssertFalse(presented.contains(where: \.isCollapsed))
    }
}
