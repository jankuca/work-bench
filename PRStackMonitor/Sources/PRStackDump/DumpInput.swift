import Foundation
import PRStackCore

/// The three inputs to `derive`, as they appear on disk.
///
/// Exactly the fixture shape, which is what lets `--emit-snapshot` write a file that this
/// tool — and, once anonymised, the golden tests — can read straight back.
struct DumpInput: Codable {
    var now: Date?
    var snapshot: RawSnapshot
    var local: LocalState?
    var readAsOfSnapshot: [PRID]?

    init(now: Date? = nil, snapshot: RawSnapshot, local: LocalState? = nil, readAsOfSnapshot: [PRID]? = nil) {
        self.now = now
        self.snapshot = snapshot
        self.local = local
        self.readAsOfSnapshot = readAsOfSnapshot
    }

    static func read(path: String) throws -> DumpInput {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw DumpFailure("cannot read '\(path)'")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(DumpInput.self, from: data)
        } catch {
            throw DumpFailure("cannot decode '\(path)': \(error)")
        }
    }

    /// Sorted keys and ISO 8601 dates, so two dumps of the same data diff cleanly.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func write(to path: String) throws {
        var data = try encoded()
        data.append(0x0A)
        if path == "-" {
            FileHandle.standardOutput.write(data)
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw DumpFailure("cannot write '\(path)': \(error)")
        }
    }

    /// The model this input derives to.
    func derive(now overridden: Date?) -> PanelModel {
        var local = self.local ?? .empty
        // Fixtures express "the user has already seen these" this way rather than by
        // writing digest strings by hand, so honour it here too and the dump matches the
        // golden.
        local.markRead(readAsOfSnapshot ?? [], in: snapshot)
        return Derivation.derive(
            snapshot: snapshot,
            local: local,
            now: overridden ?? now ?? Date()
        )
    }
}
