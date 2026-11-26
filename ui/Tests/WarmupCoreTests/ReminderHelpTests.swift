import Foundation
import Testing

@testable import WarmupCore

/// App 0.6.7: the pause reminder (F12) and the Help text (F16).
@Suite struct ReminderHelp {
    static let day = PauseReminder.intervalMs
    static let start = 1_763_799_300_000  // Sat 22 Nov 2025 10:15 in Asia/Gaza
    static let installation = AlertScope.fingerprint(installation: "install_ui_fixture_01")

    // MARK: update

    @Test func enabledClearsTheRecord() {
        let record = PauseRecord(installation: Self.installation, since: Self.start)
        let cleared = PauseReminder.update(
            record, installation: Self.installation, scheduleEnabled: true, revision: 0, now: Self.start)
        #expect(cleared == nil)
    }

    @Test func firstPausedObservationStartsNow() {
        let record = PauseReminder.update(
            nil, installation: Self.installation, scheduleEnabled: false, revision: 0, now: Self.start)
        #expect(record == PauseRecord(installation: Self.installation, since: Self.start, lastReminded: nil))
    }

    @Test func laterPausedObservationsKeepSince() {
        let first = PauseRecord(installation: Self.installation, since: Self.start, lastReminded: Self.start + Self.day)
        let later = PauseReminder.update(
            first, installation: Self.installation, scheduleEnabled: false, revision: 0, now: Self.start + 3 * Self.day)
        #expect(later == first)
    }

    @Test func anotherInstallationRestarts() {
        let first = PauseRecord(installation: Self.installation, since: Self.start, lastReminded: Self.start + Self.day)
        let other = AlertScope.fingerprint(installation: "install_ui_fixture_02")
        let now = Self.start + 2 * Self.day
        let record = PauseReminder.update(first, installation: other, scheduleEnabled: false, revision: 0, now: now)
        #expect(record == PauseRecord(installation: other, since: now))
    }

    /// Resumed and paused again between two reads: the schedule revision moved, so the new pause
    /// starts its own day instead of inheriting the old pause's timing (0.6.7 review round 1).
    @Test func resumeAndRepauseRestarts() {
        let old = PauseRecord(
            installation: Self.installation, since: Self.start, revision: 12, lastReminded: Self.start + Self.day)
        let now = Self.start + 3 * Self.day
        let record = PauseReminder.update(
            old, installation: Self.installation, scheduleEnabled: false, revision: 14, now: now)
        #expect(record == PauseRecord(installation: Self.installation, since: now, revision: 14))
        #expect(!PauseReminder.due(record, now: now))
        let same = PauseReminder.update(
            old, installation: Self.installation, scheduleEnabled: false, revision: 12, now: now)
        #expect(same == old)
    }

    /// A damaged saved record with extreme times is never due and never traps (0.6.7 review round 4).
    @Test func extremeSavedTimesAreNeverDue() {
        let now = Self.start + 3 * Self.day
        #expect(!PauseReminder.due(PauseRecord(installation: Self.installation, since: Int.min), now: now))
        #expect(
            !PauseReminder.due(
                PauseRecord(installation: Self.installation, since: Self.start, lastReminded: Int.min), now: now))
        #expect(!PauseReminder.due(PauseRecord(installation: Self.installation, since: Int.max), now: now))
        #expect(!PauseReminder.due(PauseRecord(installation: Self.installation, since: Self.start), now: Int.min))
    }

    /// Checked again just before posting (0.6.7 review round 2): a newer read decides.
    @Test func newerReadDecidesBeforePosting() {
        let record = PauseRecord(installation: Self.installation, since: Self.start, revision: 12)
        #expect(PauseReminder.stillApplies(record, latestVerified: true, latestEnabled: false, latestRevision: 12))
        #expect(!PauseReminder.stillApplies(record, latestVerified: true, latestEnabled: true, latestRevision: 13))
        #expect(!PauseReminder.stillApplies(record, latestVerified: true, latestEnabled: false, latestRevision: 14))
        // A failed read, or an engine that no longer matches its binding, cannot confirm the pause
        // (0.6.7 review round 3), even if the last good status still says paused.
        #expect(!PauseReminder.stillApplies(record, latestVerified: false, latestEnabled: false, latestRevision: 12))
        #expect(!PauseReminder.stillApplies(record, latestVerified: false, latestEnabled: nil, latestRevision: nil))
    }

    // MARK: due

    @Test func notDueOneMillisecondBeforeADay() {
        let record = PauseRecord(installation: Self.installation, since: Self.start)
        #expect(!PauseReminder.due(record, now: Self.start + Self.day - 1))
        #expect(!PauseReminder.due(nil, now: Self.start + 2 * Self.day))
    }

    @Test func dueAtExactlyADay() {
        let record = PauseRecord(installation: Self.installation, since: Self.start)
        #expect(PauseReminder.due(record, now: Self.start + Self.day))
    }

    @Test func afterAReminderNotDueForAnotherDay() {
        let reminded = Self.start + Self.day + 5_000
        let record = PauseRecord(installation: Self.installation, since: Self.start, lastReminded: reminded)
        #expect(!PauseReminder.due(record, now: reminded))
        #expect(!PauseReminder.due(record, now: reminded + Self.day - 1))
        #expect(PauseReminder.due(record, now: reminded + Self.day))
    }

    @Test func clockMovedBackIsNeverDue() {
        let record = PauseRecord(installation: Self.installation, since: Self.start)
        #expect(!PauseReminder.due(record, now: Self.start - 1))
        #expect(!PauseReminder.due(record, now: Self.start - 3 * Self.day))
        let reminded = PauseRecord(
            installation: Self.installation, since: Self.start, lastReminded: Self.start + Self.day)
        #expect(!PauseReminder.due(reminded, now: Self.start + Self.day - 1))
    }

    // MARK: content

    @Test func contentNamesThePauseTimeInPOSIXDigits() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Gaza"))
        let text = PauseReminder.content(since: Self.start, zone: zone)
        #expect(text.title == "Scheduling is still paused")
        #expect(
            text.body
                == "Warm-up has been paused since Sat 22 Nov at 10:15. No automatic warm-ups run until you resume it.")
        // The formatter is built with en_US_POSIX and Gregorian, so no other locale's digits can appear.
        let ascii = text.body.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
    }

    @Test func recordJSONHoldsNoRawInstallationID() throws {
        let record = PauseRecord(
            installation: Self.installation, since: Self.start, lastReminded: Self.start + Self.day)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!json.contains("install_"))
        #expect(try JSONDecoder().decode(PauseRecord.self, from: Data(json.utf8)) == record)
    }

    // MARK: Help

    static var helpTexts: [String] { [HelpText.title] + HelpText.sections.flatMap { [$0.heading, $0.body] } }

    @Test func helpListsEveryMarkGlyph() throws {
        let marks = try #require(HelpText.sections.first { $0.heading == "What the marks mean" })
        let kinds: [TodayMark.Kind] = [.confirmed, .uncertain, .problem, .missed, .skipped, .upcoming]
        for kind in kinds { #expect(marks.body.contains("\(kind.glyph)  \(kind.words)")) }
        #expect(marks.body.split(separator: "\n").count == kinds.count)
    }

    @Test func helpUsesPlainWords() {
        #expect(Fixes051.offending(Self.helpTexts).isEmpty)
    }

    @Test func helpNamesNoIdentifiersOrPaths() {
        for text in Self.helpTexts {
            for needle in ["install_", "/Users/", ".mjs", "@"] { #expect(!text.contains(needle)) }
        }
    }

    @Test func helpSaysWhereWakesAreShownAndBooked() throws {
        let section = try #require(HelpText.sections.first { $0.heading == "When warm-ups run" })
        #expect(
            section.body.hasSuffix(
                "Schedule shows whether a wake is booked for each coming time. The schedule-wakes script in the "
                    + "Warm-up repository books them for 7 days at a time; with alerts on, Warm-up tells you the day "
                    + "before they run out."))
        #expect(!section.body.contains("Settings shows a command"))
    }

    @Test func helpHasSixSections() {
        #expect(HelpText.sections.count == 6)
    }
}
