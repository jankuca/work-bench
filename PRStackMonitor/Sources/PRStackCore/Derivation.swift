import Foundation

/// The one place a snapshot becomes a panel.
///
/// Pure: no networking, no persistence, no clock reads. `now` is injected, so snooze
/// expiry and every other time-dependent decision is deterministic and testable without
/// a Mac in the loop.
///
/// Derivation also returns the **transitions** it observed, not just the new state — see
/// ``derive(snapshot:local:previous:now:)``. Those are diffed against the previous model,
/// so they are a pure by-product of this function and equally testable.
public enum Derivation {
    /// The panel, plus the events that separate it from `previous`.
    ///
    /// `previous` is the model from the last derivation, held in memory by whoever is
    /// polling and **never persisted**. `previous == nil` is the cold-start baseline: the
    /// model is built normally and the event list is empty, so a relaunch never replays
    /// history as fresh activity. Unread dots on relaunch come from the persisted read
    /// digests, which is a separate mechanism (IMPLEMENTATION_PLAN §1).
    public static func derive(
        snapshot: RawSnapshot,
        local: LocalState,
        previous: PanelModel?,
        now: Date
    ) -> (model: PanelModel, events: [DomainEvent]) {
        let model = derive(snapshot: snapshot, local: local, now: now)
        return (model, EventDiff.events(previous: previous, current: model))
    }

    /// The panel alone, for callers with no previous model to diff against — the goldens,
    /// the debug dump, and any one-shot rendering. Identical to passing `previous: nil`
    /// above, which emits no events by construction.
    public static func derive(snapshot: RawSnapshot, local: LocalState, now: Date) -> PanelModel {
        // Dismissal is a permanent tombstone: the pull request leaves the model entirely
        // and can never be resurrected by a later event (PRD §5.3). Dismissal is only
        // offered on Done rows, and a Done row is never a stack member, so dropping these
        // here can never break a run.
        let visible = snapshot.pullRequests.filter { !local.dismissed.contains($0.id) }
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The layout needs the stages before it can be built: a merge stays in its stack
        // until a release contains it (``StackLayout/build``). Keyed the same way as `byID`,
        // first occurrence winning, so the two cannot disagree about a repeated id.
        let stages = Dictionary(
            visible.map { ($0.id, releaseStage(for: $0, local: local)) },
            uniquingKeysWith: { first, _ in first }
        )
        let layout = StackLayout.build(
            pullRequests: visible,
            viewerLogin: snapshot.viewerLogin,
            releaseStages: stages
        )

        var rows: [PanelRow] = []
        rows.reserveCapacity(visible.count)
        for pullRequest in visible {
            let placement = layout.placement(for: pullRequest.id)
            let stage = releaseStage(for: pullRequest, local: local)
            let status = RowStatusResolver.resolve(
                pullRequest: pullRequest,
                releaseStage: stage,
                parent: layout.blockingParentOf[pullRequest.id]
            )
            let deadline = local.snoozedUntil[pullRequest.id]
            let isSuppressed = deadline.map { now < $0 } ?? false
            let digest = ReadDigest.make(for: pullRequest, releaseStage: stage)

            rows.append(
                PanelRow(
                    pullRequest: pullRequest,
                    status: status,
                    releaseStage: stage,
                    // Snooze silences "this needs you", never "this finished".
                    isAttention: status.isAttentionCandidate && !isSuppressed,
                    isSuppressed: isSuppressed,
                    snoozedUntil: isSuppressed ? deadline : nil,
                    // A pull request we have never recorded a digest for is new to the
                    // user, and new is unread.
                    isUnread: local.readDigests[pullRequest.id] != digest,
                    spine: placement.spine,
                    runBase: placement.runBase,
                    stackRoot: placement.groupRoot
                )
            )
        }

        let sections = assembleSections(rows: rows, layout: layout, byID: byID)

        return PanelModel(
            sections: sections,
            showsRepoNames: Set(visible.map(\.repo)).count > 1,
            readyCount: rows.filter(\.isReady).count,
            attentionCount: rows.filter(\.isAttention).count,
            unreadCount: rows.filter(\.isUnread).count,
            summary: PanelSummary(
                // `status != .draft` rather than `!pullRequest.isDraft`: the status is the
                // one derived truth about a row, and it already accounts for a draft that
                // was closed — which is a Done row and belongs in neither count.
                openCount: rows.filter { $0.pullRequest.state == .open && $0.status != .draft }.count,
                draftCount: rows.filter { $0.status == .draft }.count,
                shippingCount: rows.filter { $0.status == .merged }.count
            )
        )
    }

    // MARK: - Release stage

    /// v1 binds releases by tag containment (M6). Until a binding exists a merged pull
    /// request sits at `merged · awaiting release`, which per PRD §10 is quiet by design
    /// and not an error state.
    static func releaseStage(for pullRequest: PullRequest, local: LocalState) -> ReleaseStage {
        guard pullRequest.state == .merged else { return .unmerged }
        if let tag = local.releaseBindings[pullRequest.id] { return .released(tag: tag) }
        return .mergedAwaitingTag
    }

    // MARK: - Sections

    private static func assembleSections(
        rows: [PanelRow],
        layout: StackLayout,
        byID: [PRID: PullRequest]
    ) -> [PanelSection] {
        var buckets: [PanelSection.Kind: [PanelRow]] = [:]
        for row in rows {
            buckets[sectionKind(for: row, byID: byID), default: []].append(row)
        }

        var sections = buckets.map { bucket in
            PanelSection(kind: bucket.key, rows: order(rows: bucket.value, layout: layout))
        }

        sections.sort(by: sectionPrecedes)
        return sections.filter { !$0.rows.isEmpty }
    }

    /// A row's section. Members of a stack group take the project of the group's root —
    /// the base pull request, the member least likely to change — because a run is drawn
    /// as adjacent rows and cannot straddle two section headings.
    private static func sectionKind(for row: PanelRow, byID: [PRID: PullRequest]) -> PanelSection.Kind {
        if row.status.belongsInDone { return .done }
        let source = row.stackRoot.flatMap { byID[$0] } ?? row.pullRequest
        guard let issue = source.primaryIssue, let projectID = issue.projectID else { return .other }
        return .project(id: projectID, name: issue.projectName ?? projectID)
    }

    /// Within a section: stack groups first, ordered by their root pull request number
    /// descending, then loose pull requests by number descending. Never API order, and
    /// never re-sorted by urgency (PRD §5.1).
    private static func order(rows: [PanelRow], layout: StackLayout) -> [PanelRow] {
        var byID: [PRID: PanelRow] = [:]
        for row in rows { byID[row.id] = row }

        var ordered: [PanelRow] = []
        var placed: Set<PRID> = []

        for group in layout.groups.sorted(by: { PRID.panelOrder($0.root, $1.root) }) {
            // A group's members all share the root's section by construction, so a group
            // is either wholly in this section or wholly absent.
            guard byID[group.root] != nil else { continue }
            for run in group.runs {
                for member in run.members {
                    guard let row = byID[member] else { continue }
                    ordered.append(row)
                    placed.insert(member)
                }
            }
        }

        let loose = rows
            .filter { !placed.contains($0.id) }
            .sorted { PRID.panelOrder($0.id, $1.id) }

        return ordered + loose
    }

    /// Projects by most recent activity among their rows, then `Other`, then `Done`.
    private static func sectionPrecedes(_ lhs: PanelSection, _ rhs: PanelSection) -> Bool {
        let left = sectionRank(lhs.kind)
        let right = sectionRank(rhs.kind)
        if left != right { return left < right }
        guard case .project(let leftID, let leftName) = lhs.kind,
              case .project(let rightID, let rightName) = rhs.kind else {
            return false
        }
        let leftActivity = lhs.rows.map(\.pullRequest.updatedAt).max() ?? .distantPast
        let rightActivity = rhs.rows.map(\.pullRequest.updatedAt).max() ?? .distantPast
        if leftActivity != rightActivity { return leftActivity > rightActivity }
        if leftName != rightName { return leftName < rightName }
        return leftID < rightID
    }

    private static func sectionRank(_ kind: PanelSection.Kind) -> Int {
        switch kind {
        case .project: return 0
        case .other: return 1
        case .done: return 2
        }
    }
}
