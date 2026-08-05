import Foundation
import XCTest
@testable import PRStackCore

/// Every fixture, presented and compared against a checked-in golden.
///
/// The sibling of ``GoldenPanelModelTests``, one layer up. Those goldens pin what the
/// panel *contains*; these pin what it *says* — the phrase per row, the meta line's
/// composition, the release track and the section headings. That is the half of M3 a
/// Linux container can check, and it is the half that regresses silently: a reordered
/// meta line or a re-worded phrase reads as an ordinary diff in the source and as a
/// different product on screen.
///
/// Re-record with `PRSTACK_RECORD_GOLDENS=1 swift test` and read the diff.
final class GoldenPresentationTests: XCTestCase {
    /// Fixed so the goldens do not move: connected, synced 34 seconds before the
    /// fixture's own `now`, which is the footer design 2a shows. `prstack-dump
    /// --presentation` uses the same pair, so its output for a fixture reproduces that
    /// fixture's golden byte for byte — the property the model-level dump already has.
    private static let syncedAgo: TimeInterval = 34

    private func present(_ fixture: DerivationCase) -> PanelPresentation {
        PanelPresentation.make(
            model: fixture.derive(),
            status: PanelStatus(
                github: .connected,
                lastSyncedAt: fixture.now.addingTimeInterval(-GoldenPresentationTests.syncedAgo)
            ),
            now: fixture.now
        )
    }

    func testEveryFixtureMatchesItsPresentationGolden() throws {
        let names = Fixtures.allNames
        XCTAssertFalse(names.isEmpty, "No fixtures found in \(Fixtures.fixturesDirectory.path)")

        for name in names {
            let rendered = PanelPresentationReport.render(present(try Fixtures.load(name)))
            try Goldens.assert(name, rendered: rendered, in: Fixtures.presentationGoldensDirectory)
        }
    }

    /// Presentation is a pure function of the model, the status and the clock. Anything
    /// else in it would make the panel redraw differently on an identical poll.
    func testPresentationIsRepeatable() throws {
        for name in Fixtures.allNames {
            let fixture = try Fixtures.load(name)
            XCTAssertEqual(present(fixture), present(fixture), "Fixture '\(name)' is not repeatable")
        }
    }

    /// Every row reaches the view with exactly one status phrase — no row silently loses
    /// its meta line, and none grows a second phrase.
    func testEveryRowCarriesOneNumberAndOnePhrase() throws {
        for name in Fixtures.allNames {
            let presented = present(try Fixtures.load(name))
            guard case .sections(let sections) = presented.body else { continue }
            for row in sections.flatMap(\.rows) {
                let numbers = row.meta.filter { if case .number = $0 { return true } else { return false } }
                let phrases = row.meta.filter { if case .phrase = $0 { return true } else { return false } }
                XCTAssertEqual(numbers.count, 1, "\(name): \(row.id) has \(numbers.count) numbers")
                XCTAssertEqual(phrases.count, 1, "\(name): \(row.id) has \(phrases.count) phrases")
            }
        }
    }
}
