import Foundation

/// A flat, fully deterministic rendering of a ``PanelModel``.
///
/// This is what the golden tests compare, and what M2's debug dump prints. It exists
/// because the regressions worth catching here are ordering regressions, and those are
/// exactly the ones a human reviewer skims past in a diff of structured objects.
public enum PanelModelReport {
    public static func render(_ model: PanelModel) -> String {
        var lines: [String] = []
        lines.append(
            "panel repoNames=\(model.showsRepoNames)"
                + " attention=\(model.attentionCount)"
                + " unread=\(model.unreadCount)"
                + " open=\(model.summary.openCount)"
                + " shipping=\(model.summary.shippingCount)"
        )
        for section in model.sections {
            lines.append(render(section.kind))
            for row in section.rows {
                lines.append("  " + render(row))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ kind: PanelSection.Kind) -> String {
        switch kind {
        case .project(let id, let name): return "section kind=project id=\(id) name=\(name)"
        case .other: return "section kind=other"
        case .done: return "section kind=done"
        }
    }

    private static func render(_ row: PanelRow) -> String {
        "row id=\(row.id.rawValue)"
            + " status=\(row.status.token)"
            + " attention=\(row.isAttention)"
            + " suppressed=\(row.isSuppressed)"
            + " unread=\(row.isUnread)"
            + " spine=\(row.spine.rawValue)"
            + " run=\(row.runBase?.rawValue ?? "-")"
            + " group=\(row.stackRoot?.rawValue ?? "-")"
            + " issue=\(row.primaryIssue?.identifier ?? "-")"
            + " extra=\(row.additionalIssueCount)"
    }
}
