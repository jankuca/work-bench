import XCTest
@testable import PRStackCore

/// The first-sync stepper: the reducer that folds events into ``SyncProgress`` and the
/// presentation that turns one into the checklist the panel draws. Both are pure, so this is
/// the whole of what a golden could pin about the feature — the AppKit view over it is
/// geometry and colour.
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

    /// The status the initial sync runs under: refreshing, nothing ever synced, a credential
    /// in hand — which is what the stepper gate asks for.
    private func syncingStatus() -> PanelStatus {
        PanelStatus(
            github: .unconfigured,
            linear: .unconfigured,
            lastSyncedAt: nil,
            isRefreshing: true,
            hasGitHubCredential: true,
            hasLinearCredential: false
        )
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

    // MARK: - Presentation gate

    func testInitialSyncRendersTheStepper() {
        let progress = SyncProgress.initial.applying(.began(.openPullRequests))
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: syncingStatus(),
            now: now,
            syncProgress: progress
        )
        guard case .syncing(let shown) = panel.body else {
            return XCTFail("expected the syncing body, got \(panel.body)")
        }
        // The two searches always show; the open one is active, merged is still pending.
        XCTAssertEqual(shown.steps.map(\.stage), [.openPullRequests, .mergedPullRequests])
        XCTAssertEqual(shown.steps[0].state, .active)
        XCTAssertEqual(shown.steps[1].state, .pending)
    }

    /// A completed sync — `lastSyncedAt` set — never shows the stepper, whatever progress it
    /// is handed: the panel has rows or an all-clear by then.
    func testSyncedPanelNeverShowsTheStepper() {
        var status = syncingStatus()
        status.lastSyncedAt = now.addingTimeInterval(-3)
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: status,
            now: now,
            syncProgress: SyncProgress.initial.applying(.began(.openPullRequests))
        )
        if case .syncing = panel.body { XCTFail("a synced panel must not show the stepper") }
    }

    /// No credential to sync with keeps the connect prompt, not a stepper for a request that
    /// never goes out.
    func testNoCredentialStaysOnConnectPrompt() {
        var status = syncingStatus()
        status.hasGitHubCredential = false
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: status,
            now: now,
            syncProgress: SyncProgress.initial.applying(.began(.openPullRequests))
        )
        guard case .connect = panel.body else {
            return XCTFail("expected the connect prompt, got \(panel.body)")
        }
    }

    /// With no progress passed at all — every steady-state poll — the body is exactly what it
    /// was before the feature existed.
    func testNoProgressLeavesTheBodyUnchanged() {
        let panel = PanelPresentation.make(model: emptyModel(), status: syncingStatus(), now: now)
        if case .syncing = panel.body { XCTFail("no progress should mean no stepper") }
    }

    // MARK: - Step building

    func testSearchStepShowsOfTotal() {
        let progress = SyncProgress.initial
            .applying(.advanced(.openPullRequests, found: 12, total: 47))
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: syncingStatus(),
            now: now,
            syncProgress: progress
        )
        guard case .syncing(let shown) = panel.body else { return XCTFail("expected syncing") }
        XCTAssertEqual(shown.steps.first { $0.stage == .openPullRequests }?.detail, "12 of 47")
    }

    /// A conditional step that is still pending is not shown — it might be about to be
    /// skipped, and revealing it only to take it away is the flicker the rule avoids.
    func testPendingConditionalStepsAreHidden() {
        let progress = SyncProgress.initial.applying(.began(.openPullRequests))
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: syncingStatus(),
            now: now,
            syncProgress: progress
        )
        guard case .syncing(let shown) = panel.body else { return XCTFail("expected syncing") }
        XCTAssertFalse(shown.steps.contains { $0.stage == .releaseTags })
        XCTAssertFalse(shown.steps.contains { $0.stage == .linearProjects })
    }

    /// A skipped step never appears, even the always-run searches.
    func testSkippedStepsAreDropped() {
        var progress = SyncProgress.initial
        progress.apply(.began(.openPullRequests))
        progress.apply(.finished(.openPullRequests))
        progress.apply(.skipped(.mergedPullRequests))
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: syncingStatus(),
            now: now,
            syncProgress: progress
        )
        guard case .syncing(let shown) = panel.body else { return XCTFail("expected syncing") }
        XCTAssertEqual(shown.steps.map(\.stage), [.openPullRequests])
        XCTAssertEqual(shown.steps[0].state, .done)
    }

    /// A begun conditional step shows, with its own unit rather than a bare number.
    func testReleaseTagStepShowsMergeCount() {
        var progress = SyncProgress.initial
        progress.apply(.finished(.openPullRequests))
        progress.apply(.finished(.mergedPullRequests))
        progress.apply(.began(.releaseTags))
        progress.apply(.advanced(.releaseTags, found: 1, total: 1))
        let panel = PanelPresentation.make(
            model: emptyModel(),
            status: syncingStatus(),
            now: now,
            syncProgress: progress
        )
        guard case .syncing(let shown) = panel.body else { return XCTFail("expected syncing") }
        XCTAssertEqual(shown.steps.first { $0.stage == .releaseTags }?.detail, "1 merge")
    }
}
