import Foundation
import PRStackCore

// A debug dump for the derivation: read a snapshot, derive it, print the panel.
//
// M2's done-criteria is "real PRs appear in a debug dump", so this is the tool that
// later gets pointed at live GitHub data. Until then it reads the same JSON shape the
// fixtures use, which means its output for a fixture is byte-identical to that
// fixture's golden.

private struct DumpInput: Decodable {
    var now: Date?
    var snapshot: RawSnapshot
    var local: LocalState?
    var readAsOfSnapshot: [PRID]?
}

private let usage = """
usage: prstack-dump <snapshot.json> [--now 2026-01-10T12:00:00Z]

  <snapshot.json>  { "now": …, "snapshot": { … }, "local": { … } }
                   The fixtures under Tests/PRStackCoreTests/Fixtures are exactly this
                   shape, so any of them can be dumped directly.

  --now            Override the snapshot's own timestamp. Snooze expiry and everything
                   else time-dependent is a pure function of this, so moving it is how
                   you watch a snoozed row wake up.
"""

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private let timestamps = ISO8601DateFormatter()

var path: String?
var overriddenNow: Date?

var arguments = Array(CommandLine.arguments.dropFirst())
var index = arguments.startIndex

while index < arguments.endIndex {
    switch arguments[index] {
    case "--now":
        index += 1
        guard index < arguments.endIndex else { fail("--now needs a timestamp\n\n" + usage) }
        guard let parsed = timestamps.date(from: arguments[index]) else {
            fail("--now needs an ISO 8601 timestamp such as 2026-01-10T12:00:00Z")
        }
        overriddenNow = parsed
    case "-h", "--help":
        print(usage)
        exit(0)
    case let argument where argument.hasPrefix("-"):
        fail("unknown option '\(argument)'\n\n" + usage)
    case let argument:
        guard path == nil else { fail("expected a single snapshot path\n\n" + usage) }
        path = argument
    }
    index += 1
}

guard let path else { fail(usage) }

guard let data = FileManager.default.contents(atPath: path) else {
    fail("cannot read '\(path)'")
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601

let input: DumpInput
do {
    input = try decoder.decode(DumpInput.self, from: data)
} catch {
    fail("cannot decode '\(path)': \(error)")
}

var local = input.local ?? .empty
// The fixtures express "the user has already seen these" this way rather than by writing
// digest strings by hand, so honour it here too and the dump matches the golden.
local.markRead(input.readAsOfSnapshot ?? [], in: input.snapshot)

let model = Derivation.derive(
    snapshot: input.snapshot,
    local: local,
    now: overriddenNow ?? input.now ?? Date()
)

print(PanelModelReport.render(model), terminator: "")
