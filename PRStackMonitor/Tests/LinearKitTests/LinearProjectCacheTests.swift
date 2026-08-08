import Foundation
import PRStackCore
import XCTest
@testable import LinearKit

final class LinearProjectCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_000_000)

    private var billing: IssueRef {
        IssueRef(identifier: "BIL-312", projectID: "proj-billing", projectName: "Billing")
    }

    func testFreshnessIsTheRefreshIntervalAndNothingElse() {
        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now.addingTimeInterval(-LinearProjectCache.refreshInterval + 1))
        XCTAssertTrue(cache.isFresh("BIL-312", now: now))

        cache.record(billing, for: "BIL-312", at: now.addingTimeInterval(-LinearProjectCache.refreshInterval - 1))
        XCTAssertFalse(cache.isFresh("BIL-312", now: now))
        // Still an answer, though — which is what keeps headings up during an outage.
        XCTAssertEqual(cache.issue(for: "BIL-312")?.projectName, "Billing")
    }

    /// An entry written before a clock correction would otherwise be re-fetched on every
    /// poll until the clock caught up.
    func testAnEntryFromTheFutureCountsAsFresh() {
        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now.addingTimeInterval(3_600))
        XCTAssertTrue(cache.isFresh("BIL-312", now: now))
    }

    func testStaleOrMissingKeepsTheOrderItWasGiven() {
        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        XCTAssertEqual(
            cache.staleOrMissing(among: ["SRC-97", "BIL-312", "PAY-90"], now: now),
            ["SRC-97", "PAY-90"]
        )
    }

    func testAnUnknownIdentifierIsARecordedAnswerNotAnAbsentOne() {
        var cache = LinearProjectCache.empty
        cache.recordUnknown("UTF-8", at: now)
        XCTAssertNil(cache.issue(for: "UTF-8"))
        XCTAssertNotNil(cache.entry(for: "UTF-8"))
        XCTAssertTrue(cache.isFresh("UTF-8", now: now), "a negative answer is cached like any other")
        XCTAssertEqual(cache.staleOrMissing(among: ["UTF-8"], now: now), [])
    }

    func testRetainOnlyDropsIdentifiersNothingReferencesAnyMore() {
        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        cache.recordUnknown("UTF-8", at: now)
        cache.retainOnly(["BIL-312"])
        XCTAssertEqual(Set(cache.entries.keys), ["BIL-312"])
    }

    // MARK: - Persistence

    func testRoundTripsThroughJSONWithItsSchemaVersion() throws {
        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        cache.recordUnknown("UTF-8", at: now)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cache)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, LinearProjectCache.schemaVersion)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(LinearProjectCache.self, from: data)
        XCTAssertEqual(restored, cache)
        XCTAssertEqual(restored.issue(for: "BIL-312")?.projectID, "proj-billing")
        XCTAssertNil(restored.issue(for: "UTF-8"))
        XCTAssertNotNil(restored.entry(for: "UTF-8"))
    }

    /// A cache written by a future version is discarded, not thrown on. It holds nothing
    /// the user typed and nothing that cannot be fetched again, so the worst an unreadable
    /// one costs is a poll's worth of requests.
    func testAnUnrecognisedSchemaVersionReadsAsEmpty() throws {
        let data = Data(#"{"version": 99, "entries": {"BIL-312": {"refreshedAt": 0}}}"#.utf8)
        let restored = try JSONDecoder().decode(LinearProjectCache.self, from: data)
        XCTAssertTrue(restored.entries.isEmpty)
    }

    func testTheFileStoreSurvivesAMissingAndACorruptFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linear-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("linear-cache.json")

        let store = FileLinearProjectCacheStore(url: url)
        XCTAssertEqual(store.load(), .empty, "a cache that is not there yet is an empty one")

        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        // The directory does not exist yet either — saving has to create it.
        store.save(cache)
        XCTAssertEqual(store.load().issue(for: "BIL-312")?.projectName, "Billing")

        try Data("half a file".utf8).write(to: url)
        XCTAssertEqual(store.load(), .empty, "a cache that cannot be read is an empty one, never a crash")
    }
}
