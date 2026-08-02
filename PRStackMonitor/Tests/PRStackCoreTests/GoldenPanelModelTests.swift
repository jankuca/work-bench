import Foundation
import XCTest
@testable import PRStackCore

/// Every fixture is derived and compared against a checked-in golden.
///
/// The regressions worth catching in derivation are ordering regressions, and those are
/// exactly the ones a human reviewer skims past. Re-record with
/// `PRSTACK_RECORD_GOLDENS=1 swift test` and read the diff before committing.
final class GoldenPanelModelTests: XCTestCase {
    func testEveryFixtureMatchesItsGolden() throws {
        let names = Fixtures.allNames
        XCTAssertFalse(names.isEmpty, "No fixtures found in \(Fixtures.fixturesDirectory.path)")

        for name in names {
            let model = try Fixtures.derive(name)
            try Goldens.assert(name, model: model)
        }
    }

    /// Derivation must not depend on the order pull requests arrive in. GitHub's search
    /// results are not stably ordered, so any dependence would let rows swap places
    /// between polls with no underlying change (PRD §5.1).
    func testDerivationIsIndependentOfSnapshotOrder() throws {
        for name in Fixtures.allNames {
            let fixture = try Fixtures.load(name)
            let forward = fixture.derive()

            var reversed = fixture
            reversed.snapshot = RawSnapshot(
                viewerLogin: fixture.snapshot.viewerLogin,
                pullRequests: fixture.snapshot.pullRequests.reversed()
            )

            XCTAssertEqual(
                PanelModelReport.render(forward),
                PanelModelReport.render(reversed.derive()),
                "Fixture '\(name)' derives differently when the snapshot order is reversed"
            )
        }
    }

    /// Same inputs, same outputs — including across separate calls, which is what makes
    /// the model safe to diff against `previous` at M4.
    func testDerivationIsRepeatable() throws {
        for name in Fixtures.allNames {
            let fixture = try Fixtures.load(name)
            XCTAssertEqual(fixture.derive(), fixture.derive(), "Fixture '\(name)' is not repeatable")
        }
    }
}
