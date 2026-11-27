import Foundation
import Testing

@testable import WarmupCore

/// App 0.6.10 (work order 125): one alert per blocking episode while compatibility blocks Warm-up.
@Suite struct CompatibilityAlertTests {
    static let since = 1_794_528_293_000
    static let installation = AlertScope.fingerprint(installation: "install_ui_fixture_01")
    static let blocked = "blocked"

    func status(edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled", edit: edit)))
    }

    // MARK: update

    @Test func readyEndsTheEpisode() {
        let record = CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true)
        let cleared = CompatibilityAlert.update(
            record, installation: Self.installation, compatibility: "ready", blockedSince: nil)
        #expect(cleared == nil)
        #expect(!CompatibilityAlert.due(cleared))
    }

    @Test func blockedWithNoRecordIsDue() {
        let record = CompatibilityAlert.update(
            nil, installation: Self.installation, compatibility: Self.blocked, blockedSince: Self.since)
        #expect(record == CompatibilityRecord(installation: Self.installation, since: Self.since, announced: false))
        #expect(CompatibilityAlert.due(record))
    }

    @Test func sameSinceIsNotDueOnceAnnounced() {
        let announced = CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true)
        let later = CompatibilityAlert.update(
            announced, installation: Self.installation, compatibility: Self.blocked, blockedSince: Self.since)
        #expect(later == announced)
        #expect(!CompatibilityAlert.due(later))
    }

    @Test func newSinceIsDueAgain() {
        let announced = CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true)
        let next = CompatibilityAlert.update(
            announced, installation: Self.installation, compatibility: Self.blocked, blockedSince: Self.since + 60_000)
        #expect(next == CompatibilityRecord(installation: Self.installation, since: Self.since + 60_000))
        #expect(CompatibilityAlert.due(next))
    }

    @Test func anotherInstallationIsDueAgain() {
        let announced = CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true)
        let other = AlertScope.fingerprint(installation: "install_ui_fixture_02")
        let record = CompatibilityAlert.update(
            announced, installation: other, compatibility: Self.blocked, blockedSince: Self.since)
        #expect(record == CompatibilityRecord(installation: other, since: Self.since))
        #expect(CompatibilityAlert.due(record))
    }

    @Test func nilSinceThenAValueIsNotReAlerted() throws {
        let first = CompatibilityAlert.update(
            nil, installation: Self.installation, compatibility: Self.blocked, blockedSince: nil)
        #expect(first == CompatibilityRecord(installation: Self.installation, since: nil))
        #expect(CompatibilityAlert.due(first))
        var announced = try #require(first)
        announced.announced = true
        let adopted = CompatibilityAlert.update(
            announced, installation: Self.installation, compatibility: Self.blocked, blockedSince: Self.since)
        #expect(adopted == CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true))
        #expect(!CompatibilityAlert.due(adopted))
    }

    @Test func valueThenNilSinceKeepsTheRecord() {
        let announced = CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true)
        let later = CompatibilityAlert.update(
            announced, installation: Self.installation, compatibility: Self.blocked, blockedSince: nil)
        #expect(later == announced)
    }

    @Test func readyThenBlockedIsDue() {
        let announced = CompatibilityRecord(installation: Self.installation, since: Self.since, announced: true)
        let ready = CompatibilityAlert.update(
            announced, installation: Self.installation, compatibility: "ready", blockedSince: nil)
        #expect(ready == nil)
        let again = CompatibilityAlert.update(
            ready, installation: Self.installation, compatibility: Self.blocked, blockedSince: Self.since)
        #expect(again == CompatibilityRecord(installation: Self.installation, since: Self.since))
        #expect(CompatibilityAlert.due(again))
    }

    // MARK: stillApplies

    @Test func stillAppliesFalseWhenUnverified() {
        let record = CompatibilityRecord(installation: Self.installation, since: Self.since)
        #expect(
            !CompatibilityAlert.stillApplies(
                record, latestVerified: false, latestCompatibility: Self.blocked, latestBlockedSince: Self.since))
    }

    @Test func stillAppliesFalseWithoutAStatus() {
        let record = CompatibilityRecord(installation: Self.installation, since: Self.since)
        #expect(
            !CompatibilityAlert.stillApplies(
                record, latestVerified: true, latestCompatibility: nil, latestBlockedSince: nil))
    }

    @Test func stillAppliesFalseWhenReady() {
        let record = CompatibilityRecord(installation: Self.installation, since: Self.since)
        #expect(
            !CompatibilityAlert.stillApplies(
                record, latestVerified: true, latestCompatibility: "ready", latestBlockedSince: nil))
    }

    @Test func stillAppliesFalseWhenSinceChanged() {
        let record = CompatibilityRecord(installation: Self.installation, since: Self.since)
        #expect(
            !CompatibilityAlert.stillApplies(
                record, latestVerified: true, latestCompatibility: Self.blocked, latestBlockedSince: Self.since + 1))
    }

    @Test func stillAppliesTrueOtherwise() {
        let record = CompatibilityRecord(installation: Self.installation, since: Self.since)
        #expect(
            CompatibilityAlert.stillApplies(
                record, latestVerified: true, latestCompatibility: Self.blocked, latestBlockedSince: Self.since))
        #expect(
            CompatibilityAlert.stillApplies(
                record, latestVerified: true, latestCompatibility: Self.blocked, latestBlockedSince: nil))
        let unknown = CompatibilityRecord(installation: Self.installation, since: nil)
        #expect(
            CompatibilityAlert.stillApplies(
                unknown, latestVerified: true, latestCompatibility: Self.blocked, latestBlockedSince: Self.since))
    }

    // MARK: content and model

    @Test func contentNamesNoPathHashOrRevision() throws {
        let text = CompatibilityAlert.content()
        #expect(text.title == "Warm-up is blocked")
        #expect(
            text.body
                == "codex-router changed, usually after Update or Restart in its menu. Upcoming warm-ups will be "
                + "skipped until you run repin-router.")
        #expect(text.body.contains("repin-router"))
        let hex = try Regex("[0-9a-fA-F]{40}")
        for part in [text.title, text.body] {
            #expect(!part.contains("/"))
            #expect(part.firstMatch(of: hex) == nil)
            #expect(!part.lowercased().contains("sha"))
        }
    }

    @Test func recordJSONHoldsNoRawInstallationID() throws {
        let data = try JSONEncoder().encode(CompatibilityRecord(installation: Self.installation, since: Self.since))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("install_ui_fixture_01"))
        #expect(try JSONDecoder().decode(CompatibilityRecord.self, from: data).since == Self.since)
    }

    @Test func statusDecodesWithAndWithoutBlockedSince() throws {
        let ready = try self.status()
        #expect(ready.compatibility == "ready")
        #expect(ready.compatibilityBlockedSince == nil)
        let blocked = try self.status {
            $0["compatibility"] = "blocked"
            $0["compatibilityBlockedSince"] = Self.since
        }
        #expect(blocked.compatibility == "blocked")
        #expect(blocked.compatibilityBlockedSince == Self.since)
        // An older engine reply without the key at all.
        let absent = try self.status {
            $0["compatibility"] = "blocked"
            $0["compatibilityBlockedSince"] = nil
        }
        #expect(absent.compatibilityBlockedSince == nil)
    }

    @Test func readyWithAStaleSinceEndsTheEpisode() {
        let record = CompatibilityRecord(installation: "fp", since: Self.since, announced: true)
        #expect(
            CompatibilityAlert.update(record, installation: "fp", compatibility: "ready", blockedSince: Self.since)
                == nil)
    }
}
