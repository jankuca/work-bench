import Foundation

/// A flat, fully deterministic rendering of a ``PanelPresentation``.
///
/// The sibling of ``PanelModelReport``, and it exists for the same reason one level up:
/// the panel is built on a Mac and the rules that decide what it says are not. This
/// renders every string and every semantic role the row view consumes, so the wording,
/// the meta line's composition and the release track can be pinned by a golden in a Linux
/// container — leaving the AppKit layer holding only geometry and colour, which a golden
/// could not check anyway.
public enum PanelPresentationReport {
    public static func render(_ panel: PanelPresentation) -> String {
        var lines: [String] = []
        lines.append(
            "header title=\(quoted(panel.header.title))"
                + " summary=\(quoted(panel.header.summary))"
                + " refreshing=\(panel.header.isRefreshing)"
                + " attention=\(panel.attentionCount)"
        )
        if let banner = panel.banner {
            lines.append("banner message=\(quoted(banner.message)) action=\(quoted(banner.actionTitle))")
        }

        switch panel.body {
        case .sections(let sections):
            for section in sections {
                lines.append(render(section))
                for row in section.rows {
                    lines.append("  " + render(row))
                    lines.append("    meta " + row.meta.map(render).joined(separator: " "))
                }
            }
        case .allClear(let message):
            lines.append("allClear title=\(quoted(message.title)) detail=\(quoted(message.detail))")
        case .connect(let prompt):
            // The two actions are rendered even when absent, as `-`: which accounts the
            // prompt offers to connect is exactly the decision this state exists to make,
            // and a golden that only pinned the wording would not notice it changing.
            lines.append(
                "connect title=\(quoted(prompt.title))"
                    + " detail=\(quoted(prompt.detail))"
                    + " github=\(prompt.githubActionTitle.map(quoted) ?? "-")"
                    + " linear=\(prompt.linearActionTitle.map(quoted) ?? "-")"
            )
        case .syncing(let progress):
            // The dump never reaches this state — it renders finished fixtures, which have
            // rows — so no golden pins it. The branch exists so the switch stays exhaustive,
            // and renders the checklist the same flat way for the unit test that drives it
            // directly.
            lines.append("syncing title=\(quoted(progress.title))")
            for step in progress.steps {
                lines.append(
                    "  step stage=\(step.stage.rawValue)"
                        + " state=\(render(step.state))"
                        + " detail=\(step.detail.map(quoted) ?? "-")"
                )
            }
        }

        // `linear=`, `syncing=` and `error=` are emitted only when there is something to
        // emit. A healthy source polling on its interval is the overwhelmingly common
        // case, and spending three tokens on saying so in every golden would make each
        // diff that adds one look like every fixture changed when none of them did.
        var footer = ["footer", "tone=\(panel.footer.syncTone.rawValue)"]
        footer.append("text=\(quoted(panel.footer.syncText))")
        if panel.footer.isSyncing { footer.append("syncing=true") }
        if let error = panel.footer.errorMessage { footer.append("error=\(quoted(error))") }
        if let linear = panel.footer.linearNote { footer.append("linear=\(quoted(linear))") }
        footer.append("markAllRead=\(panel.footer.showsMarkAllRead)")
        lines.append(footer.joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func render(_ state: SyncStepPresentation.State) -> String {
        switch state {
        case .pending: return "pending"
        case .active: return "active"
        case .done: return "done"
        }
    }

    private static func render(_ section: SectionPresentation) -> String {
        "section heading=\(quoted(section.heading))"
            + " count=\(section.count)"
            + " muted=\(section.isMuted)"
            + " clearAll=\(section.clearAllTitle.map(quoted) ?? "-")"
    }

    private static func render(_ row: RowPresentation) -> String {
        let reviewers = row.reviewers
            .map { "\($0.initials):\($0.tone.rawValue)" }
            .joined(separator: ",")
        return "row id=\(row.id.rawValue)"
            + " title=\(quoted(row.title))"
            + " emphasis=\(row.emphasis.rawValue)"
            + " chip=\(row.chipTone.rawValue)/\(row.chipGlyph.rawValue)"
            + " tint=\(row.isTinted)"
            + " unread=\(row.isUnread)"
            + " spine=\(spine(row.spine))"
            + " track=\(row.segments.map(\.rawValue).joined(separator: "|"))"
            + " reviewers=[\(reviewers)]+\(row.overflowReviewers)"
            + " dismissible=\(row.isDismissible)"
    }

    private static func render(_ token: MetaToken) -> String {
        switch token {
        case .issue: return "issue(\(token.text))"
        case .additionalIssues: return "more(\(token.text))"
        case .repository: return "repo(\(token.text))"
        case .number: return "num(\(token.text))"
        case .phrase(let phrase, let tone): return "phrase(\(phrase)|\(tone.rawValue))"
        case .age: return "age(\(token.text))"
        case .snooze: return "snooze(\(token.text))"
        }
    }

    private static func spine(_ draw: SpineDraw) -> String {
        switch (draw.drawsUp, draw.drawsDown) {
        case (false, false): return "none"
        case (false, true): return "down"
        case (true, false): return "up"
        case (true, true): return "both"
        }
    }

    /// Quoted because these carry spaces and `·`, and an unquoted golden line would make
    /// a trailing-space regression invisible in review — which is the class of bug this
    /// whole rendering exists to catch.
    ///
    /// The escaping covers newlines as well as quotes, because this report is read a line
    /// at a time: a value containing one would end the record early and the rest of it
    /// would be parsed as another. Every value here used to come from GitHub's own fields —
    /// a title, a login — where that is unlikely; `error=` carries a failure message, which
    /// can be a server's response body and is exactly where a stray newline comes from. The
    /// backslash goes first, or the escapes this adds would themselves be ambiguous.
    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }
}
