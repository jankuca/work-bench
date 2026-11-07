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

        // A fresh store, as the next launch would be: a running one reads the file once and
        // answers from memory after that.
        try Data("half a file".utf8).write(to: url)
        XCTAssertEqual(
            FileLinearProjectCacheStore(url: url).load(),
            .empty,
            "a cache that cannot be read is an empty one, never a crash"
        )
    }

    /// The leak this store was rewritten for: the app reads its cache on every poll, and
    /// each read of the file stranded a buffer. After the first load the file is not read
    /// again — proved here by removing it and getting the same cache back.
    func testTheFileStoreReadsTheFileOnceAndAnswersFromMemoryAfterThat() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linear-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("linear-cache.json")

        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        FileLinearProjectCacheStore(url: url).save(cache)

        let store = FileLinearProjectCacheStore(url: url)
        XCTAssertEqual(store.load(), cache, "the first load reads what the file holds")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(store.load(), cache, "later loads answer from memory, not the file")

        // An unchanged save writes nothing — the file stays gone.
        store.save(cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // A changed one writes the file, and a fresh store reads it back.
        cache.recordUnknown("UTF-8", at: now)
        store.save(cache)
        XCTAssertEqual(store.load(), cache)
        XCTAssertEqual(FileLinearProjectCacheStore(url: url).load(), cache)
    }

    /// Skipping an unchanged save must not skip one whose last attempt failed: the file is
    /// compared with what was actually written, not with what memory holds.
    func testAFailedWriteIsRetriedByTheNextSaveOfTheSameCache() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linear-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A plain file where the cache's directory should be, so neither creating the
        // directory nor writing into it can succeed.
        let blocker = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        let url = blocker.appendingPathComponent("linear-cache.json")

        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        let store = FileLinearProjectCacheStore(url: url)
        store.save(cache)
        XCTAssertEqual(store.load(), cache, "memory holds the cache even though the write failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // The obstacle goes away; the same cache saved again has to reach the file.
        try FileManager.default.removeItem(at: blocker)
        store.save(cache)
        XCTAssertEqual(FileLinearProjectCacheStore(url: url).load(), cache)
    }

    /// A poll whose identifiers are all fresh in memory never saves, so a pending write has
    /// to be retried by the load that poll makes instead.
    func testAFailedWriteIsRetriedByTheNextLoad() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linear-cache-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: blocker)
        let url = blocker.appendingPathComponent("linear-cache.json")

        var cache = LinearProjectCache.empty
        cache.record(billing, for: "BIL-312", at: now)
        let store = FileLinearProjectCacheStore(url: url)
        store.save(cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: blocker)
        XCTAssertEqual(store.load(), cache)
        XCTAssertEqual(FileLinearProjectCacheStore(url: url).load(), cache, "the load wrote the pending cache")
    }
}
