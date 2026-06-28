import Foundation
import SwiftUI
import StrandAnalytics

/// The Report action behind every Test Centre Report button (spec section 5.2 flow). It assembles the
/// redacted, capped bundle for the active profile, presents the MANDATORY review-before-share sheet
/// (spec section 12) bound to the exact report.txt the user is about to share, and only on an explicit
/// confirm hands the bundle to TestReportFlow.run (which saves/shares it, opens the prefilled GitHub
/// issue, and toasts). No network of our own, no cloud.
///
/// This is the thin orchestrator that ties Group D's UI to the Group B/C contracts (TestBundleAssembler,
/// FileExport.exportBundle, ReportReviewGate, TestReportLink, TestReportFlow). It is an ObservableObject
/// so the screen can present the review sheet off `pendingReview`.
@MainActor
final class TestCentreReport: ObservableObject {

    /// A report pending the user's review. The screen presents a sheet bound to `gate.previewText` while
    /// this is non-nil; confirming calls `confirm()`, cancelling calls `cancel()`.
    struct Pending: Identifiable {
        let id = UUID()
        let profile: TestDomain
        let title: String
        var gate: ReportReviewGate
    }

    /// Non-nil while a report is awaiting review. Drive a `.sheet(item:)` off this.
    @Published var pending: Pending?

    /// A one-line status banner the screen can show after a share fires (the app has no global toast).
    @Published var lastStatus: String?

    /// M3 (#812): the redacted report.txt for the iOS "Copy report.txt" fallback. Set after a confirmed
    /// share on the mobile path (TestReportFlow.Plan.offersCopyFallback); the screen surfaces a button
    /// bound to it so a user who cannot attach the .zip can paste the <details> block straight into the
    /// issue. nil on macOS / when there is nothing to copy, so the button stays hidden.
    @Published var copyableReport: String?

    /// Build the redacted bundle for `mode` and stage it for review. Nothing leaves the device yet.
    func start(mode: TestMode, live: LiveState) {
        let entries = TestBundleAssembler.assemble(profile: mode.domain, live: live)
        pending = Pending(profile: mode.domain, title: mode.title,
                          gate: ReportReviewGate(entries: entries))
    }

    /// The user read the report and confirmed: clear the gate and run the shipped share + deep-link flow.
    func confirm() {
        guard var p = pending else { return }
        p.gate.confirm()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        // CAPTURE-A (#812): seed the issue's what_happens box from the tester's own questionnaire answers so
        // a report submitted without the .zip still opens with their words. The log tail is prefilled inside
        // TestReportFlow from the redacted report.txt entry.
        let seed = TestModeRegistry.mode(p.profile).flatMap {
            TestReportLink.whatHappensSeed(questionnaire: $0.questionnaire, answers: TestCentre.answers(p.profile))
        }
        TestReportFlow.run(
            profile: p.profile, title: p.title,
            version: version, platform: platform, osVersion: osVersion,
            gate: p.gate,
            entries: p.gate.entries,
            showToast: { [weak self] msg in self?.lastStatus = msg },
            // M3: prime the clipboard AND surface the report for a visible "Copy report.txt" button so the
            // documented mobile fallback is reachable, not just silently on the pasteboard.
            copyToPasteboard: { [weak self] text in PlatformPasteboard.copy(text); self?.copyableReport = text },
            whatHappensSeed: seed)
        pending = nil
    }

    /// The user cancelled the review: nothing is shared.
    func cancel() { pending = nil }
}
