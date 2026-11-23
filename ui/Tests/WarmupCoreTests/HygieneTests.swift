import Foundation
import Testing

@testable import WarmupCore

/// Work order 066 (app 0.6.6): the copied slot summary passes an allowlist, and saved alert state is
/// scoped to the bound installation.
@Suite struct DiagnosticAllowlist {
    /// A slot explanation reply with the given engine strings.
    static func result(
        slot: String = "2026-11-12T13:00", zone: String = "Asia/Gaza", verdict: String = "not_admitted",
        cause: String = "no_tick_between", exclusion: String? = "weekday", admission: String? = "13:00",
        dispatch: String = "unknown", response: String = "uncertain", reason: String? = "stream_or_transport_uncertain",
        guidance: String = "outcome_unknown_no_resend", windowEffect: String = "unverified"
    ) throws -> SlotExplanationResult {
        let account: [String: Any] = [
            "enrollmentId": "enr_secret_01", "known": true, "outcome": "uncertain", "reason": reason ?? NSNull(),
            "at": 1_000, "skipped": false, "possibleSend": true, "reservationUnresolved": false,
            "dispatch": dispatch, "response": response, "windowEffect": "unverified", "guidance": guidance,
        ]
        let explanation: [String: Any] = [
            "slot": slot, "date": "2026-11-12", "logicalTime": "13:00", "verdict": verdict, "configured": true,
            "exclusion": exclusion ?? NSNull(), "admission": admission ?? NSNull(), "admissionAt": 1_000,
            "notAdmitted": ["cause": cause, "zone": zone, "at": 1_000, "guidance": "check_job_and_mac_awake"],
            "activeBatch": false, "batchOutcome": NSNull(), "accounts": [account],
            "heartbeat": ["lastTick": 900, "lastTickZone": zone, "observedAfterAdmission": false],
            "windowEffect": windowEffect, "retentionDays": 30,
        ]
        let data = try JSONSerialization.data(withJSONObject: ["zone": zone, "explanation": explanation])
        return try JSONDecoder().decode(SlotExplanationResult.self, from: data)
    }

    @Test func knownReplyPrintsAsBefore() throws {
        let text = SlotDiagnostic.text(try Self.result(), engineVersion: "1.2.3")
        #expect(
            text == """
                Warm-up slot 2026-11-12T13:00 (Asia/Gaza)
                Verdict: not_admitted — no_tick_between
                Configured now: yes, excluded (weekday)
                Admission: 13:00
                Heartbeat after admission minute: no
                Account 1: dispatch=unknown response=uncertain reason=stream_or_transport_uncertain guidance=outcome_unknown_no_resend
                Usage window effect: unverified
                Engine: 1.2.3; evidence retained 30 days
                """)
        let none = SlotDiagnostic.text(try Self.result(exclusion: nil, admission: nil, reason: nil), engineVersion: nil)
        #expect(none.contains("Configured now: yes\n"))
        #expect(none.contains("Admission: unknown"))
        #expect(none.contains("reason=none "))
        #expect(none.hasSuffix("Engine: unknown; evidence retained 30 days"))
        let offline = SlotDiagnostic.text(try Self.result(), engineVersion: "1.0.0-offline")
        #expect(offline.contains("Engine: 1.0.0-offline;"))
    }

    @Test func unknownCodesPrintOther() throws {
        let hostile = ["sk-live_abc123", "user@example.com"]
        for value in hostile {
            let text = SlotDiagnostic.text(
                try Self.result(
                    verdict: value, cause: value, exclusion: value, dispatch: value, response: value, reason: value,
                    guidance: value, windowEffect: value),
                engineVersion: "1.2.3")
            #expect(text.contains("Verdict: other — other"))
            #expect(text.contains("excluded (other)"))
            #expect(text.contains("dispatch=other response=other reason=other guidance=other"))
            #expect(text.contains("Usage window effect: other"))
            #expect(!text.contains(value))
            #expect(!text.contains("sk-"))
            #expect(!text.contains("@"))
        }
    }

    @Test func malformedFieldsPrintUnknown() throws {
        let zones = [
            "Asia/Gaza\nsk-live_abc123", "sk_live_abc123", "Acct/user_0123abcd", "user@example.com", "1Zone",
            String(repeating: "A", count: 101), "",
        ]
        for zone in zones {
            let text = SlotDiagnostic.text(try Self.result(zone: zone), engineVersion: "1.2.3")
            #expect(text.hasPrefix("Warm-up slot 2026-11-12T13:00 (unknown)\n"))
            if !zone.isEmpty { #expect(!text.contains(zone)) }
        }
        let slots = ["2026-11-12T13:00 sk-live_abc123", "2026-11-12", "user@example.com", "٢٠٢٦-11-12T13:00"]
        for slot in slots {
            let text = SlotDiagnostic.text(try Self.result(slot: slot), engineVersion: "1.2.3")
            #expect(text.hasPrefix("Warm-up slot unknown (Asia/Gaza)\n"))
            #expect(!text.contains(slot))
        }
        for admission in ["13:00:00", "1300", "sk-live_abc123", "13:00\n"] {
            let text = SlotDiagnostic.text(try Self.result(admission: admission), engineVersion: "1.2.3")
            #expect(text.contains("Admission: unknown\n"))
            #expect(!text.contains(admission))
        }
        for version in ["1.2", "1.2.3-Beta", "1.2.3 sk-live_abc123", "user@example.com", "v1.2.3", "1.2.3-offline\n"] {
            let text = SlotDiagnostic.text(try Self.result(), engineVersion: version)
            #expect(text.hasSuffix("Engine: unknown; evidence retained 30 days"))
            #expect(!text.contains(version))
        }
    }

    @Test func validPatternsPass() throws {
        let zones = ["UTC", "America/Argentina/Buenos_Aires", "Etc/GMT+3", "Etc/GMT-14"]
        for zone in zones {
            let text = SlotDiagnostic.text(try Self.result(zone: zone), engineVersion: nil)
            #expect(text.hasPrefix("Warm-up slot 2026-11-12T13:00 (\(zone))\n"))
        }
        let early = SlotDiagnostic.text(try Self.result(admission: "12:58"), engineVersion: nil)
        #expect(early.contains("Admission: 12:58\n"))
    }
}

@Suite struct AlertInstallationScope {
    static let first = AlertScope.fingerprint(installation: "install_ui_fixture_01")
    static let second = AlertScope.fingerprint(installation: "install_ui_fixture_02")

    @Test func fingerprintIsSixteenHexOfSHA256() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223...
        #expect(AlertScope.fingerprint(installation: "abc") == "ba7816bf8f01cfea")
        #expect(Self.first.count == 16)
        #expect(Self.first.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(Self.first != Self.second)
        #expect(!Self.first.contains("install"))
    }

    @Test func sameInstallationKeeps() {
        #expect(AlertScope.decide(current: Self.first, stored: Self.first, outbox: Self.first) == .keep)
        #expect(AlertScope.decide(current: Self.first, stored: Self.first, outbox: nil) == .keep)
    }

    @Test func differentInstallationResets() {
        #expect(AlertScope.decide(current: Self.second, stored: Self.first, outbox: Self.first) == .reset(Self.second))
        #expect(AlertScope.decide(current: Self.second, stored: Self.first, outbox: nil) == .reset(Self.second))
    }

    @Test func noneStoredAdopts() {
        #expect(AlertScope.decide(current: Self.first, stored: nil, outbox: nil) == .adopt(Self.first))
        #expect(AlertScope.decide(current: Self.first, stored: nil, outbox: Self.first) == .adopt(Self.first))
    }

    @Test func outboxOfAnotherInstallationIsDropped() {
        #expect(AlertScope.decide(current: Self.first, stored: Self.first, outbox: Self.second) == .reset(Self.first))
        #expect(AlertScope.decide(current: Self.first, stored: nil, outbox: Self.second) == .reset(Self.first))
    }

    @Test func unreadableBindingHolds() {
        #expect(AlertScope.decide(current: nil, stored: Self.first, outbox: Self.second) == .unbound)
        #expect(AlertScope.decide(current: nil, stored: nil, outbox: nil) == .unbound)
    }

    /// The outbox file carries the fingerprint; a 0.6.5 file without one decodes as nil.
    @Test func outboxStoresTheFingerprint() throws {
        let entry = PendingAlert(
            SlotProblem(slot: "2026-11-12T08:00", kind: .notAdmitted(cause: "no_tick_between"), at: 1_000),
            zone: "Asia/Gaza")
        let outbox = AlertOutbox(installation: Self.first).adding(entry)
        #expect(outbox.installation == Self.first)
        #expect(outbox.removing(slots: ["2026-11-12T08:00"]).installation == Self.first)
        #expect(outbox.scoped(to: Self.second).entries == outbox.entries)
        let data = try JSONEncoder().encode(outbox)
        #expect(String(decoding: data, as: UTF8.self).contains(Self.first))
        #expect(!String(decoding: data, as: UTF8.self).contains("install_ui_fixture_01"))
        #expect(try JSONDecoder().decode(AlertOutbox.self, from: data) == outbox)
        let unscoped = try JSONEncoder().encode(AlertOutbox().adding(entry))
        #expect(!String(decoding: unscoped, as: UTF8.self).contains("installation"))
        let older = try JSONDecoder().decode(AlertOutbox.self, from: unscoped)
        #expect(older.installation == nil)
        #expect(older.entries == [entry])
    }
}
