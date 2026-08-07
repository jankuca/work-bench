import Foundation
import XCTest
@testable import PRStackCore

/// A table test over the icon's priority order (IMPLEMENTATION_PLAN §5).
final class IconStateTests: XCTestCase {
    private struct Row {
        var github: SourceHealth
        var attention: Int
        var unread: Int
        var expected: IconState
        var why: String
    }

    func testPriorityTable() {
        let rows: [Row] = [
            Row(github: .connected, attention: 0, unread: 0, expected: .idle, why: "nothing to say"),
            Row(github: .connected, attention: 0, unread: 3, expected: .unread, why: "unread only"),
            Row(github: .connected, attention: 2, unread: 0, expected: .actionNeeded(count: 2), why: "attention only"),
            Row(
                github: .connected,
                attention: 2,
                unread: 5,
                expected: .actionNeeded(count: 2),
                why: "attention outranks unread, and the badge counts attention rows, not unread ones"
            ),
            Row(
                github: .unauthorized("token expired"),
                attention: 3,
                unread: 3,
                expected: .disconnected,
                why: "an expired token shows dashed rather than a cached badge"
            ),
            Row(
                github: .unreachable("timed out"),
                attention: 3,
                unread: 0,
                expected: .disconnected,
                why: "a cached badge asserts something the app cannot currently verify"
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
                IconState.resolve(github: row.github, attentionCount: row.attention, unreadCount: row.unread),
                row.expected,
                row.why
            )
        }
    }

    /// Opening the panel rewrites the read digests, so the next derivation has nothing
    /// unread — the icon drops out of `unread`. It must not drop out of `actionNeeded`:
    /// looking at a failing check does not fix it.
    func testOpeningClearsUnreadButNotActionNeeded() throws {
        let fixture = try Fixtures.load("panel-2a")
        let status = PanelStatus(github: .connected, lastSyncedAt: fixture.now)

        let before = Derivation.derive(snapshot: fixture.snapshot, local: .empty, now: fixture.now)
        XCTAssertGreaterThan(before.unreadCount, 0, "The 2a fixture should start with unread rows")
        XCTAssertGreaterThan(before.attentionCount, 0, "The 2a fixture should start with attention rows")
        XCTAssertEqual(
            IconState.resolve(model: before, status: status),
            .actionNeeded(count: before.attentionCount)
        )

        var opened = LocalState.empty
        opened.markAllRead(in: fixture.snapshot)
        let after = Derivation.derive(snapshot: fixture.snapshot, local: opened, now: fixture.now)

        XCTAssertEqual(after.unreadCount, 0)
        XCTAssertEqual(after.attentionCount, before.attentionCount)
        XCTAssertEqual(
            IconState.resolve(model: after, status: status),
            .actionNeeded(count: after.attentionCount),
            "Opening the panel cleared action-needed, which only the pull requests can do"
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
            if case .actionNeeded(let count) = icon {
                XCTAssertEqual(count, model.attentionCount, name)
            }
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
            .actionNeeded(count: 1),
            .actionNeeded(count: 4),
            .unread,
            .idle,
            .inFlight
        ]
        let labels = states.map(\.accessibilityLabel)

        XCTAssertEqual(Set(labels).count, labels.count, "Two icon states read identically")
        XCTAssertTrue(labels.allSatisfy { $0.hasPrefix("Pull requests") })
        XCTAssertEqual(IconState.actionNeeded(count: 1).accessibilityLabel, "Pull requests, 1 needs you")
        XCTAssertEqual(IconState.actionNeeded(count: 4).accessibilityLabel, "Pull requests, 4 need you")
    }
}
