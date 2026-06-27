import XCTest
@testable import Strand

/// Pins the success-side observability the log forensics flagged as the blind spot (#150): NOOP logged
/// FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a banking strap from a
/// broken one. These cover the pure tally + summary helpers that drive the new
/// "Backfill: session persisted N rows (M with motion) across K night(s)" line.
final class BackfillerSessionTallyTests: XCTestCase {

    // rows = biometric streams only (HR, R-R, SpO2, skin-temp, resp, gravity) — battery/events are
    // housekeeping, NOT biometric history, so they must not inflate the count. motion = gravity.
    func testChunkTallySumsBiometricRowsAndGravityOnly() {
        let counts = (hr: 10, rr: 4, events: 99, battery: 7, spo2: 3, skinTemp: 2, resp: 1, gravity: 5)
        let tally = Backfiller.chunkTally(counts: counts, timestamps: [])
        XCTAssertEqual(tally.rows, 10 + 4 + 3 + 2 + 1 + 5)   // 25 — events(99)/battery(7) excluded
        XCTAssertEqual(tally.motion, 5)
        XCTAssertTrue(tally.nights.isEmpty)
    }

    // nights collapse timestamps to distinct day-keys (ts / 86400), so a chunk spanning a day boundary
    // counts two nights and same-day samples count once.
    func testChunkTallyNightsAreDistinctDayKeys() {
        let day0 = 1_700_000_000
        let sameDay = day0 + 3_600
        let nextDay = day0 + 86_400
        let tally = Backfiller.chunkTally(counts: (0, 0, 0, 0, 0, 0, 0, 0), timestamps: [day0, sameDay, nextDay])
        XCTAssertEqual(tally.nights, Set([day0 / 86_400, nextDay / 86_400]))
        XCTAssertEqual(tally.nights.count, 2)
    }

    // The summary stays SILENT when nothing persisted, so a console-only / caught-up session doesn't
    // claim a false success — the existing empty-banking diagnostics speak for that case instead.
    func testSessionSummaryNilWhenNoRows() {
        XCTAssertNil(Backfiller.sessionSummaryLine(rows: 0, motion: 0, skinTemp: 0, nights: 0))
    }

    func testSessionSummaryFormat() {
        XCTAssertEqual(
            Backfiller.sessionSummaryLine(rows: 240, motion: 180, skinTemp: 12, nights: 3),
            "Backfill: session persisted 240 rows (180 with motion, 12 skin-temp) across 3 night(s).")
    }

    // #727: a strap banking HR/RR-only records (no DSP sleep block) persists rows but ZERO skin-temp,
    // so the line surfaces that 0 and "skin temp never appears" reports are self-diagnosing from the log.
    func testSessionSummaryShowsZeroSkinTemp() {
        XCTAssertEqual(
            Backfiller.sessionSummaryLine(rows: 872, motion: 172, skinTemp: 0, nights: 1),
            "Backfill: session persisted 872 rows (172 with motion, 0 skin-temp) across 1 night(s).")
    }

    // #783: trim=0xFFFFFFFF on a fresh run that banked NOTHING means "no banked history": the genuine
    // clock/charge guidance with the "fully charge it" hint.
    func testNoCursorLineNoRowsGivesNoHistoryGuidance() {
        let line = Backfiller.noCursorLine(rowsPersisted: 0)
        XCTAssertTrue(line.contains("no banked history to offload"))
        XCTAssertTrue(line.contains("fully charge it"))
    }

    // #783: trim=0xFFFFFFFF AFTER the auto-continuation has already persisted rows means "caught up",
    // NOT "no history". It must NOT emit the scary fully-charge guidance (that falsely alarmed users
    // whose strap had just synced fine).
    func testNoCursorLineAfterRowsGivesCaughtUpLine() {
        let line = Backfiller.noCursorLine(rowsPersisted: 240)
        XCTAssertTrue(line.contains("reached the end of available history"))
        XCTAssertTrue(line.contains("240 row(s)"))
        XCTAssertFalse(line.contains("no banked history"))
        XCTAssertFalse(line.contains("fully charge"))
    }

    // No em-dash leaks into either branch (project hard rule).
    func testNoCursorLineHasNoEmDash() {
        XCTAssertFalse(Backfiller.noCursorLine(rowsPersisted: 0).contains("\u{2014}"))
        XCTAssertFalse(Backfiller.noCursorLine(rowsPersisted: 5).contains("\u{2014}"))
    }

    // MARK: - #773 corrupt future-RTC detection

    // A genuine offload is PAST-dated; a past timestamp is never flagged.
    func testFutureRtcNotFlaggedForPastDate() {
        let now = 1_700_000_000
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now - 86_400, wallNowUnix: now))
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now, wallNowUnix: now))
    }

    // Ordinary forward skew under the 1-day tolerance is NOT a corrupt clock (no false alarm).
    func testFutureRtcToleratesSmallSkew() {
        let now = 1_700_000_000
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now + 3_600, wallNowUnix: now))
        // Exactly at the tolerance boundary is still OK (strictly greater trips it).
        XCTAssertFalse(Backfiller.isCorruptFutureRtc(endUnix: now + Backfiller.futureRtcToleranceSeconds, wallNowUnix: now))
    }

    // A date days into the future can only be a corrupt strap RTC, so it's flagged.
    func testFutureRtcFlaggedForFarFutureDate() {
        let now = 1_700_000_000
        XCTAssertTrue(Backfiller.isCorruptFutureRtc(endUnix: now + 10 * 86_400, wallNowUnix: now))
    }

    // The recovery hint names the cause + the fix and reports the days-ahead, with no em-dash.
    func testFutureRtcLineWording() {
        let now = 1_700_000_000
        let line = Backfiller.futureRtcLine(endUnix: now + 10 * 86_400, wallNowUnix: now)
        XCTAssertTrue(line.contains("10 day(s) in the FUTURE"))
        XCTAssertTrue(line.contains("clock (RTC) is corrupt"))
        XCTAssertTrue(line.contains("Fully charge"))
        XCTAssertFalse(line.contains("\u{2014}"))
    }
}
