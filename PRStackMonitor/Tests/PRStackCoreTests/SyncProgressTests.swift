import XCTest
@testable import PRStackCore

/// The sync steps the footer's label opens: the reducer that folds events into
/// ``SyncProgress`` and the presentation that turns one into the footer's checklist. Both are
/// pure, so this is the whole of what a golden could pin about the feature — the AppKit
/// popover over it is geometry and colour.
final class SyncProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func emptyModel() -> PanelModel {
        PanelModel(
            sections: [],
            showsRepoNames: false,
            attentionCount: 0,
            unreadCount: 0,
            summary: PanelSummary(openCount: 0, shippingCount: 0)
        )
    }

    /// A status mid-sync: connected, refreshing, one sync already landed — which is the
    /// steady state the popover is most often opened in.
    private func syncingStatus() -> PanelStatus {
        PanelStatus(
            github: .connected,
            linear: .connected,
            lastSyncedAt: now.addingTimeInterval(-3),
            isRefreshing: true
        )
    }

    private func steps(_ progress: SyncProgress, status: PanelStatus? = nil) -> [SyncStepPresentation] {
        PanelPresentation.make(
            model: emptyModel(),
            status: status ?? syncingStatus(),
            now: now,
            syncProgress: progress
        ).footer.progressSteps
    }

    // MARK: - Reducer

    func testBeganMovesAStepToActive() {
        var progress = SyncProgress.initial
        XCTAssertEqual(progress.step(.openPullRequests).lifecycle, .pending)
        progress.apply(.began(.openPullRequests))
        XCTAssertEqual(progress.step(.openPullRequests).lifecycle, .active)
    }

    func testAdvancedCarriesFoundAndTotal() {
        var progress = SyncProgress.initial
        progress.apply(.advanced(.openPullRequests, found: 12, total: 47))
        let step = progress.step(.openPullRequests)
        XCTAssertEqual(step.lifecycle, .active)
        XCTAssertEqual(step.found, 12)
        XCTAssertEqual(step.total, 47)
    }

    /// A page that reports no count must not erase a total an earlier page reported.
    func testAdvancedKeepsAKnownTotalWhenNextPageReportsNone() {
        var progress = SyncProgress.initial
        progress.apply(.advanced(.openPullRequests, found: 12, total: 47))
        progress.apply(.advanced(.openPullRequests, found: 24, total: nil))
        let step = progress.step(.openPullRequests)
        XCTAssertEqual(step.found, 24)
        XCTAssertEqual(step.total, 47)
    }

    func testFinishedTicksAStep() {
        var progress = SyncProgress.initial
        progress.apply(.began(.mergedPullRequests))
        progress.apply(.finished(.mergedPullRequests))
        XCTAssertEqual(progress.step(.mergedPullRequests).lifecycle, .done)
    }

    /// Events can arrive out of order across the actor hop; a stray `began` after `finished`
    /// must not un-tick the step.
    func testBeganAfterFinishedDoesNotReopen() {
        var progress = SyncProgress.initial
        progress.apply(.finished(.openPullRequests))
        progress.apply(.began(.openPullRequests))
        XCTAssertEqual(progress.step(.openPullRequests).lifecycle, .done)
    }

    func testSkippedDoesNotOverrideDone() {
        var progress = SyncProgress.initial
        progress.apply(.finished(.releaseTags))
        progress.apply(.skipped(.releaseTags))
        XCTAssertEqual(progress.step(.releaseTags).lifecycle, .done)
    }

    // MARK: - Footer steps

    func testProgressFeedsTheFooterSteps() {
        let progress = SyncProgress.initial.applying(.began(.openPullRequests))
        let shown = steps(progress)
        // The two searches always show; the open one is active, merged is still pending.
        XCTAssertEqual(shown.map(\.stage), [.openPullRequests, .mergedPullRequests])
        XCTAssertEqual(shown[0].state, .active)
        XCTAssertEqual(shown[1].state, .pending)
    }

    /// No progress at all — every launch before its first poll — leaves the footer with an
    /// empty step list, so the label is just a label.
    func testNoProgressMeansNoSteps() {
        let footer = PanelPresentation.make(model: emptyModel(), status: syncingStatus(), now: now).footer
        XCTAssertTrue(footer.progressSteps.isEmpty)
    }

    /// The steps never touch the body: the empty-state screen is left exactly as it was,
    /// whatever a sync is doing.
    func testProgressDoesNotChangeTheBody() {
        let progress = SyncProgress.initial.applying(.began(.openPullRequests))
        // Never synced, no credential → the connect prompt, progress or not.
        let status = PanelStatus(github: .unconfigured, hasGitHubCredential: false)
        let panel = PanelPresentation.make(model: emptyModel(), status: status, now: now, syncProgress: progress)
        guard case .connect = panel.body else {
            return XCTFail("expected the connect prompt, got \(panel.body)")
        }
        // …and the label still carries the steps to open.
        XCTAssertFalse(panel.footer.progressSteps.isEmpty)
    }

    func testSearchStepShowsOfTotal() {
        let progress = SyncProgress.initial
            .applying(.advanced(.openPullRequests, found: 12, total: 47))
        XCTAssertEqual(steps(progress).first { $0.stage == .openPullRequests }?.detail, "12 of 47")
    }

    /// A conditional step that is still pending is not shown — it might be about to be
    /// skipped, and revealing it only to take it away is the flicker the rule avoids.
    func testPendingConditionalStepsAreHidden() {
        let progress = SyncProgress.initial.applying(.began(.openPullRequests))
        let shown = steps(progress)
        XCTAssertFalse(shown.contains { $0.stage == .releaseTags })
        XCTAssertFalse(shown.contains { $0.stage == .linearProjects })
    }

    /// A skipped step never appears, even the always-run searches.
    func testSkippedStepsAreDropped() {
        var progress = SyncProgress.initial
        progress.apply(.began(.openPullRequests))
        progress.apply(.finished(.openPullRequests))
        progress.apply(.skipped(.mergedPullRequests))
        let shown = steps(progress)
        XCTAssertEqual(shown.map(\.stage), [.openPullRequests])
        XCTAssertEqual(shown[0].state, .done)
    }

    /// A begun conditional step shows, with its own unit rather than a bare number.
    func testReleaseTagStepShowsMergeCount() {
        var progress = SyncProgress.initial
        progress.apply(.finished(.openPullRequests))
        progress.apply(.finished(.mergedPullRequests))
        progress.apply(.began(.releaseTags))
        progress.apply(.advanced(.releaseTags, found: 1, total: 1))
        XCTAssertEqual(steps(progress).first { $0.stage == .releaseTags }?.detail, "1 merge")
    }

    /// The last sync's steps survive between polls — the footer keeps them so the popover has
    /// something to show when nothing is in flight.
    func testCompletedStepsRemainForTheSummary() {
        var progress = SyncProgress.initial
        for stage in [SyncStage.openPullRequests, .mergedPullRequests] {
            progress.apply(.began(stage))
            progress.apply(.advanced(stage, found: 5, total: 5))
            progress.apply(.finished(stage))
        }
        var idle = syncingStatus()
        idle.isRefreshing = false
        let shown = steps(progress, status: idle)
        XCTAssertEqual(shown.map(\.state), [.done, .done])
        XCTAssertEqual(shown.map(\.detail), ["5 of 5", "5 of 5"])
    }
}
