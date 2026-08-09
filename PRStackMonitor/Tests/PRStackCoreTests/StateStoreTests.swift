import Foundation
import XCTest
@testable import PRStackCore

/// M6's other half: "the binding, and everything else in `LocalState`, survives a relaunch."
///
/// A relaunch is a new `FileStateStore` over the same path, which is what every test here
/// does — nothing is carried in memory between the save and the load.
final class StateStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prstack-state-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    private func populatedState() -> LocalState {
        let shipped = PRID(repo: "acme/billing", number: 4012)
        let waiting = PRID(repo: "acme/billing", number: 4013)
        let snoozed = PRID(repo: "acme/web", number: 77)
        return LocalState(
            dismissed: [PRID(repo: "acme/web", number: 12)],
            snoozedUntil: [snoozed: Date(timeIntervalSince1970: 1_767_960_000)],
            readDigests: [snoozed: ReadDigest(value: "rd=-;ck=passing;mg=mergeable;cc=0;lc=-;rs=unmerged")],
            releaseBindings: [shipped: "v1.4.0"],
            unboundMerges: [
                waiting: UnboundMerge(
                    mergeCommit: "9f1c2ab",
                    mergedAt: Date(timeIntervalSince1970: 1_767_900_000),
                    comparedTags: ["v1.3.9", "v1.4.0"]
                )
            ]
        )
    }

    func testAMissingFileIsAnEmptyStateAndNotAFailure() {
        let load = FileStateStore(url: stateURL).load()
        XCTAssertEqual(load, .empty)
        XCTAssertNil(load.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testEverythingSurvivesARelaunch() throws {
        let state = populatedState()
        try FileStateStore(url: stateURL).save(state)

        // A different store object over the same path — the relaunch.
        let load = FileStateStore(url: stateURL).load()
        XCTAssertNil(load.failure)
        XCTAssertEqual(load.state, state)
        XCTAssertEqual(load.state.unboundMerges.values.first?.comparedTags, ["v1.3.9", "v1.4.0"])
    }

    /// The file is meant to be readable and diffable by hand, which it only is if two writes
    /// of the same state produce the same bytes. `Dictionary` iterates in a per-process
    /// order, so this is the assertion that keeps `.sortedKeys` from being dropped.
    func testTwoWritesOfTheSameStateProduceTheSameBytes() throws {
        let state = populatedState()
        let store = FileStateStore(url: stateURL)

        try store.save(state)
        let first = try Data(contentsOf: stateURL)
        try store.save(state)
        let second = try Data(contentsOf: stateURL)

        XCTAssertEqual(first, second)
        let object = try JSONSerialization.jsonObject(with: first) as? [String: Any]
        XCTAssertEqual(object?["version"] as? Int, 1, "the file carries its schema version")
    }

    /// Starting from empty and then saving over the file in place would destroy state
    /// nothing else can supply — the dismissal tombstones. So the unreadable file is moved
    /// aside first, with its bytes intact.
    func testAnUnreadableFileIsMovedAsideRatherThanOverwritten() throws {
        let original = Data("{ this is not json".utf8)
        try original.write(to: stateURL)

        let store = FileStateStore(url: stateURL)
        let load = store.load()

        XCTAssertEqual(load.state, .empty)
        XCTAssertNotNil(load.failure)
        let quarantined = try XCTUnwrap(load.quarantinedTo)
        XCTAssertTrue(quarantined.lastPathComponent.hasPrefix("state.corrupt-"))
        XCTAssertEqual(try Data(contentsOf: quarantined), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))

        // And the app goes on working: the next save writes a fresh file beside the aside.
        try store.save(LocalState(dismissed: [PRID(repo: "acme/web", number: 1)]))
        XCTAssertEqual(
            FileStateStore(url: stateURL).load().state.dismissed,
            [PRID(repo: "acme/web", number: 1)]
        )
    }

    /// A version this build does not know is quarantined too. Half-reading a newer build's
    /// state is worse than starting clean: the keys it dropped would be written back missing.
    func testAnUnknownSchemaVersionIsQuarantined() throws {
        let future = #"{"version": 99, "state": {"dismissed": ["acme/web#1"]}}"#
        try Data(future.utf8).write(to: stateURL)

        let load = FileStateStore(url: stateURL).load()
        XCTAssertEqual(load.state, .empty)
        XCTAssertNotNil(load.quarantinedTo)
        XCTAssertEqual(load.failure?.contains("version 99"), true)
    }

    /// A relaunch loop over the same bad file must not overwrite the first quarantine's
    /// evidence with the second's.
    func testQuarantineNamesDoNotCollideWithinASecond() throws {
        let now = Date(timeIntervalSince1970: 1_767_960_000)
        let first = FileStateStore.quarantineURL(for: stateURL, at: now)
        try Data("first".utf8).write(to: first)
        let second = FileStateStore.quarantineURL(for: stateURL, at: now)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "state.corrupt-20260109T120000Z.json")
        XCTAssertEqual(second.lastPathComponent, "state.corrupt-20260109T120000Z-2.json")
    }

    func testTheInMemoryStoreRoundTripsTheSameValue() throws {
        let store = InMemoryStateStore()
        try store.save(populatedState())
        XCTAssertEqual(store.load().state, populatedState())
    }
}
