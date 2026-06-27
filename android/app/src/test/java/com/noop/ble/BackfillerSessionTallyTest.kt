package com.noop.ble

import com.noop.data.InsertCounts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the success-side observability the log forensics flagged as the blind spot (#150): NOOP logged
 * FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't tell a banking strap from a
 * broken one. Covers the pure tally + summary helpers driving the new
 * "Backfill: session persisted N rows (M with motion) across K night(s)" line. Mirrors the Swift
 * BackfillerSessionTallyTests.
 */
class BackfillerSessionTallyTest {

    // rows = biometric streams only (HR, R-R, SpO2, skin-temp, resp, gravity); events/battery/steps are
    // housekeeping and must NOT inflate the count (matches the Swift tuple, which has no steps). motion = gravity.
    @Test fun chunkTallySumsBiometricRowsAndGravityOnly() {
        val counts = InsertCounts(hr = 10, rr = 4, events = 99, battery = 7, spo2 = 3, skinTemp = 2, steps = 50, resp = 1, gravity = 5)
        val (rows, motion, nights) = Backfiller.chunkTally(counts, emptyList())
        assertEquals(10 + 4 + 3 + 2 + 1 + 5, rows) // 25 — events(99)/battery(7)/steps(50) excluded
        assertEquals(5, motion)
        assertTrue(nights.isEmpty())
    }

    // nights collapse timestamps to distinct day-keys (ts / 86400): a chunk crossing a day boundary
    // counts two nights; same-day samples count once.
    @Test fun chunkTallyNightsAreDistinctDayKeys() {
        val day0 = 1_700_000_000L
        val sameDay = day0 + 3_600L
        val nextDay = day0 + 86_400L
        val (_, _, nights) = Backfiller.chunkTally(InsertCounts(), listOf(day0, sameDay, nextDay))
        assertEquals(setOf(day0 / 86_400L, nextDay / 86_400L), nights)
        assertEquals(2, nights.size)
    }

    // Silent when nothing persisted, so a console-only / caught-up session doesn't claim a false success.
    @Test fun sessionSummaryNullWhenNoRows() {
        assertNull(Backfiller.sessionSummaryLine(0, 0, 0, 0))
    }

    @Test fun sessionSummaryFormat() {
        assertEquals(
            "Backfill: session persisted 240 rows (180 with motion, 12 skin-temp) across 3 night(s).",
            Backfiller.sessionSummaryLine(240, 180, 12, 3),
        )
    }

    // #727: a strap banking HR/RR-only records (no DSP sleep block) persists rows but ZERO skin-temp,
    // so the line surfaces that 0 and "skin temp never appears" reports are self-diagnosing from the log.
    @Test fun sessionSummaryShowsZeroSkinTemp() {
        assertEquals(
            "Backfill: session persisted 872 rows (172 with motion, 0 skin-temp) across 1 night(s).",
            Backfiller.sessionSummaryLine(872, 172, 0, 1),
        )
    }

    // #783: trim=0xFFFFFFFF on a fresh run that banked NOTHING means "no banked history": the genuine
    // clock/charge guidance with the "fully charge it" hint.
    @Test fun noCursorLineNoRowsGivesNoHistoryGuidance() {
        val line = Backfiller.noCursorLine(0)
        assertTrue(line.contains("no banked history to offload"))
        assertTrue(line.contains("fully charge"))
    }

    // #783: trim=0xFFFFFFFF AFTER the auto-continuation has already persisted rows means "caught up",
    // NOT "no history". It must NOT emit the scary fully-charge guidance.
    @Test fun noCursorLineAfterRowsGivesCaughtUpLine() {
        val line = Backfiller.noCursorLine(240)
        assertTrue(line.contains("reached the end of available history"))
        assertTrue(line.contains("240 row(s)"))
        assertFalse(line.contains("no banked history"))
        assertFalse(line.contains("fully charge"))
    }

    // No em-dash leaks into either branch (project hard rule).
    @Test fun noCursorLineHasNoEmDash() {
        assertFalse(Backfiller.noCursorLine(0).contains("\u2014"))
        assertFalse(Backfiller.noCursorLine(5).contains("\u2014"))
    }

    // ---- #773 corrupt future-RTC detection ----

    // A genuine offload is PAST-dated; a past timestamp is never flagged.
    @Test fun futureRtcNotFlaggedForPastDate() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isCorruptFutureRtc(now - 86_400L, now))
        assertFalse(Backfiller.isCorruptFutureRtc(now, now))
    }

    // Ordinary forward skew under the 1-day tolerance is NOT a corrupt clock (no false alarm).
    @Test fun futureRtcToleratesSmallSkew() {
        val now = 1_700_000_000L
        assertFalse(Backfiller.isCorruptFutureRtc(now + 3_600L, now))
        // Exactly at the tolerance boundary is still OK (strictly greater trips it).
        assertFalse(Backfiller.isCorruptFutureRtc(now + Backfiller.FUTURE_RTC_TOLERANCE_SECONDS, now))
    }

    // A date days into the future can only be a corrupt strap RTC, so it's flagged.
    @Test fun futureRtcFlaggedForFarFutureDate() {
        val now = 1_700_000_000L
        assertTrue(Backfiller.isCorruptFutureRtc(now + 10L * 86_400L, now))
    }

    // The recovery hint names the cause + fix, reports days-ahead, and has no em-dash. Byte-identical to Swift.
    @Test fun futureRtcLineWording() {
        val now = 1_700_000_000L
        val line = Backfiller.futureRtcLine(now + 10L * 86_400L, now)
        assertTrue(line.contains("10 day(s) in the FUTURE"))
        assertTrue(line.contains("clock (RTC) is corrupt"))
        assertTrue(line.contains("Fully charge"))
        assertFalse(line.contains("\u2014"))
    }
}
