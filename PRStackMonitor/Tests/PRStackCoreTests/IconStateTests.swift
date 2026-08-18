import Foundation
import XCTest
@testable import PRStackCore

/// A table test over the icon's priority order (IMPLEMENTATION_PLAN §5).
final class IconStateTests: XCTestCase {
    private struct Row {
        var github: SourceHealth
        var ready: Int = 0
        var attention: Int
        var unread: Int
        var expected: IconState
        var why: String
    }

    func testPriorityTable() {
        let rows: [Row] = [
            Row(github: .connected, attention: 0, unread: 0, expected: .idle, why: "nothing to say"),
            Row(github: .connected, attention: 0, unread: 3, expected: .unread, why: "unread only"),
            Row(
                github: .connected,
                attention: 2,
                unread: 0,
                expected: .counts(ready: 0, attention: 2),
                why: "the red badge alone"
            ),
            Row(
                github: .connected,
                ready: 3,
                attention: 0,
                unread: 0,
                expected: .counts(ready: 3, attention: 0),
                why: "the green badge alone"
            ),
            Row(
                github: .connected,
                ready: 3,
                attention: 2,
                unread: 0,
                expected: .counts(ready: 3, attention: 2),
                why: "both badges: neither number hides the other"
            ),
            Row(
                github: .connected,
                ready: 1,
                attention: 2,
                unread: 5,
                expected: .counts(ready: 1, attention: 2),
                why: "counts outrank unread, and they count their own rows, not unread ones"
            ),
            Row(
                github: .connected,
                ready: 1,
                attention: 0,
                unread: 5,
                expected: .counts(ready: 1, attention: 0),
                why: "green outranks the unread dot exactly as red does"
            ),
            Row(
                github: .unauthorized("token expired"),
                ready: 2,
                attention: 3,
                unread: 3,
                expected: .disconnected,
                why: "an expired token shows dashed rather than cached badges"
            ),
            Row(
                github: .unreachable("timed out"),
                ready: 2,
                attention: 3,
                unread: 0,
                expected: .disconnected,
                why: "cached badges assert something the app cannot currently verify"
            ),
            Row(
                github: .unconfigured,
                attention: 0,
                unread: 0,
                expected: .disconnected,
                why: "first run has nothing to be idle about"
            )
        ]

        for row in rows {
            XCTAssertEqual(
                IconState.resolve(
                    github: row.github,
                    readyCount: row.ready,
                    attentionCount: row.attention,
                    unreadCount: row.unread
                ),
                row.expected,
                row.why
            )
        }
    }

    /// Only the red half is a demand. A mergeable pull request is an invitation, and the
    /// PRD §5.2 invariant the flag backs is about attention rows.
    func testOnlyTheRedBadgeIsDemanding() {
        XCTAssertTrue(IconState.counts(ready: 0, attention: 1).isDemanding)
        XCTAssertTrue(IconState.counts(ready: 4, attention: 1).isDemanding)
        XCTAssertFalse(IconState.counts(ready: 4, attention: 0).isDemanding)
        XCTAssertFalse(IconState.unread.isDemanding)
        XCTAssertFalse(IconState.idle.isDemanding)
        XCTAssertFalse(IconState.disconnected.isDemanding)
    }

    /// Opening the panel rewrites the read digests, so the next derivation has nothing
    /// unread — the icon drops out of `unread`. It must not drop either count: looking at
    /// a failing check does not fix it, and looking at a mergeable one does not merge it.
    func testOpeningClearsUnreadButNotTheCounts() throws {
        let fixture = try Fixtures.load("panel-2a")
        let status = PanelStatus(github: .connected, lastSyncedAt: fixture.now)

        let before = Derivation.derive(snapshot: fixture.snapshot, local: .empty, now: fixture.now)
        XCTAssertGreaterThan(before.unreadCount, 0, "The 2a fixture should start with unread rows")
        XCTAssertGreaterThan(before.attentionCount, 0, "The 2a fixture should start with attention rows")
        XCTAssertGreaterThan(before.readyCount, 0, "The 2a fixture should start with a ready row")
        XCTAssertEqual(
            IconState.resolve(model: before, status: status),
            .counts(ready: before.readyCount, attention: before.attentionCount)
        )

        var opened = LocalState.empty
        opened.markAllRead(in: fixture.snapshot)
        let after = Derivation.derive(snapshot: fixture.snapshot, local: opened, now: fixture.now)

        XCTAssertEqual(after.unreadCount, 0)
        XCTAssertEqual(after.attentionCount, before.attentionCount)
        XCTAssertEqual(after.readyCount, before.readyCount)
        XCTAssertEqual(
            IconState.resolve(model: after, status: status),
            .counts(ready: after.readyCount, attention: after.attentionCount),
            "Opening the panel cleared a count, which only the pull requests can do"
        )
    }

    /// The invariant from PRD §5.2, read from the icon's side: a panel with an attention
    /// row never shows a plain or merely-unread glyph. Checked over every fixture rather
    /// than asserted as a convention.
    func testAttentionAlwaysReachesTheIcon() throws {
        let connected = PanelStatus(github: .connected)
        // `allNames` turns a directory-enumeration failure into an empty array, so without
        // this the loop below passes by never running.
        XCTAssertFalse(Fixtures.allNames.isEmpty, "No fixtures found in \(Fixtures.fixturesDirectory.path)")
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            let icon = IconState.resolve(model: model, status: connected)
            XCTAssertEqual(
                icon.isDemanding,
                model.attentionCount > 0,
                "\(name): \(icon.token) does not match \(model.attentionCount) attention row(s)"
            )
            XCTAssertEqual(icon.attentionCount, model.attentionCount, name)
        }
    }

    /// The green badge's own version of the same check: every fixture's ready rows reach
    /// the icon, and a fixture with none of them never shows a green badge.
    func testReadyRowsReachTheIcon() throws {
        let connected = PanelStatus(github: .connected)
        XCTAssertFalse(Fixtures.allNames.isEmpty, "No fixtures found in \(Fixtures.fixturesDirectory.path)")
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            let icon = IconState.resolve(model: model, status: connected)
            XCTAssertEqual(icon.readyCount, model.readyCount, name)
            XCTAssertEqual(
                model.readyCount,
                model.rows.filter { $0.status == .readyToMerge && !$0.isSuppressed }.count,
                "\(name): readyCount does not follow from the rows"
            )
        }
    }

    /// Tags-only release tracking has no input that produces the amber state, so nothing
    /// may resolve to it. The case stays in the enum for a future deployment tracker.
    func testInFlightIsNeverResolved() throws {
        let healths: [SourceHealth] = [.connected, .unconfigured, .unauthorized("x"), .unreachable("y")]
        XCTAssertFalse(Fixtures.allNames.isEmpty, "No fixtures found in \(Fixtures.fixturesDirectory.path)")
        for name in Fixtures.allNames {
            let model = try Fixtures.derive(name)
            for health in healths {
                let icon = IconState.resolve(model: model, status: PanelStatus(github: health))
                XCTAssertNotEqual(icon, .inFlight, name)
            }
        }
    }

    /// Every state reads as something, and no two read the same. The status item is one
    /// control with one label, so this string is the whole of what VoiceOver gets.
    func testAccessibilityLabelsAreDistinct() {
        let states: [IconState] = [
            .disconnected,
            .counts(ready: 0, attention: 1),
            .counts(ready: 0, attention: 4),
            .counts(ready: 2, attention: 0),
            .counts(ready: 2, attention: 4),
            .unread,
            .idle,
            .inFlight
        ]
        let labels = states.map(\.accessibilityLabel)

        XCTAssertEqual(Set(labels).count, labels.count, "Two icon states read identically")
        XCTAssertTrue(labels.allSatisfy { $0.hasPrefix("Pull requests") })
        XCTAssertEqual(
            IconState.counts(ready: 0, attention: 1).accessibilityLabel,
            "Pull requests, 1 needs you"
        )
        XCTAssertEqual(
            IconState.counts(ready: 0, attention: 4).accessibilityLabel,
            "Pull requests, 4 need you"
        )
        XCTAssertEqual(
            IconState.counts(ready: 1, attention: 0).accessibilityLabel,
            "Pull requests, 1 ready to merge"
        )
        // Both badges, in the order they are drawn.
        XCTAssertEqual(
            IconState.counts(ready: 2, attention: 4).accessibilityLabel,
            "Pull requests, 2 ready to merge, 4 need you"
        )
    }
}
