import Foundation
import XCTest
@testable import PRStackCore

/// One derivation fixture: the three inputs to `derive`, plus a convenience for
/// expressing "the user has already seen this pull request as it stands".
struct DerivationCase {
    var now: Date
    var snapshot: RawSnapshot
    var local: LocalState
    /// Pull requests whose read digest should be recorded *as of this snapshot*, which
    /// is what "the panel was open and everything looked like this" means. Writing the
    /// digest strings into the fixture by hand would pin the digest format rather than
    /// the unread rule.
    var readAsOfSnapshot: [PRID]

    /// `local` with the `readAsOfSnapshot` digests filled in.
    func resolvedLocal() -> LocalState {
        var resolved = local
        resolved.markRead(readAsOfSnapshot, in: snapshot)
        return resolved
    }

    func derive() -> PanelModel {
        Derivation.derive(snapshot: snapshot, local: resolvedLocal(), now: now)
    }
}

extension DerivationCase: Decodable {
    private enum CodingKeys: String, CodingKey {
        case now
        case snapshot
        case local
        case readAsOfSnapshot
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        now = try container.decode(Date.self, forKey: .now)
        snapshot = try container.decode(RawSnapshot.self, forKey: .snapshot)
        local = try container.decodeIfPresent(LocalState.self, forKey: .local) ?? .empty
        readAsOfSnapshot = try container.decodeIfPresent([PRID].self, forKey: .readAsOfSnapshot) ?? []
    }
}

enum Fixtures {
    /// Fixtures and goldens are read from the source tree rather than from a bundle
    /// resource so that `PRSTACK_RECORD_GOLDENS=1 swift test` can rewrite them in place.
    private static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    static var fixturesDirectory: URL { directory.appendingPathComponent("Fixtures") }
    static var goldensDirectory: URL { directory.appendingPathComponent("Goldens") }

    static var allNames: [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: fixturesDirectory.path)) ?? []
        return contents
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    static func load(_ name: String) throws -> DerivationCase {
        let url = fixturesDirectory.appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DerivationCase.self, from: data)
    }

    static func derive(_ name: String) throws -> PanelModel {
        try load(name).derive()
    }
}

enum Goldens {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["PRSTACK_RECORD_GOLDENS"] == "1"
    }

    static func assert(
        _ name: String,
        model: PanelModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rendered = PanelModelReport.render(model)
        let url = Fixtures.goldensDirectory.appendingPathComponent("\(name).txt")

        if isRecording {
            try FileManager.default.createDirectory(
                at: Fixtures.goldensDirectory,
                withIntermediateDirectories: true
            )
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        guard let data = FileManager.default.contents(atPath: url.path),
              let expected = String(data: data, encoding: .utf8) else {
            XCTFail(
                "No golden for '\(name)'. Re-run with PRSTACK_RECORD_GOLDENS=1 to record it, "
                    + "then read the diff before committing.\n\n\(rendered)",
                file: file,
                line: line
            )
            return
        }

        XCTAssertEqual(rendered, expected, "Golden mismatch for '\(name)'", file: file, line: line)
    }
}
