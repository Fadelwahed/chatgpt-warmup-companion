import Foundation
import Testing

@testable import WarmupCore

/// App 0.6 F10: the read-only CLI's parser, output builders and exit codes. The live engine is never
/// read here; the builders run over the engine-generated fixtures.
@Suite struct StatusCommandLine {
    static let at0800 = 1_794_463_200_000
    /// 05:45 in Asia/Gaza, 2 h 15 min before the fixture's next time.
    static let now = Date(timeIntervalSince1970: Double(1_794_463_200_000 - 135 * 60_000) / 1000)
    /// A valid observation time for rendered snapshots: `now`, 12 Nov in Asia/Gaza.
    static let observedNow = 1_794_463_200_000 - 135 * 60_000

    func status(_ name: String = "status-enabled", edit: ((inout [String: Any]) -> Void)? = nil) throws -> EngineStatus
    {
        try #require(ReplyValidator.payload(EngineStatus.self, from: try Fixture.output(name, edit: edit)))
    }

    func projection() throws -> ScheduleProjection {
        try #require(ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
    }

    /// status-enabled with usage on the first account.
    func withUsage() throws -> EngineStatus {
        try self.status { object in
            guard var accounts = object["accounts"] as? [[String: Any]] else { return }
            accounts[0]["usage"] = [
                "primary": ["usedPercent": 4, "windowMinutes": 300, "resetsAt": Self.at0800 - 3_600_000 + 18_120_000],
                "observedAt": Self.at0800 - 86_400_000,
            ]
            object["accounts"] = accounts
        }
    }

    @Test func parser() {
        #expect(StatusCLI.parse([]) == .app)
        #expect(StatusCLI.parse(["--status"]) == .status)
        #expect(StatusCLI.parse(["--json"]) == .json)
        #expect(StatusCLI.parse(["--provision-binding", "--node", "/n"]) == .provision(["--node", "/n"]))
        #expect(StatusCLI.parse(["--status", "--json"]) == .usage(StatusCLI.usageText))
        #expect(StatusCLI.parse(["--json", "extra"]) == .usage(StatusCLI.usageText))
        #expect(StatusCLI.parse(["-psn_0_123"]) == .app)
        #expect(StatusCLI.parse(["-NSDocumentRevisionsDebugMode", "YES"]) == .app)
        #expect(StatusCLI.parse(["status"]) == .app)
    }

    @Test func textCarriesTheFacts() throws {
        let status = try self.withUsage()
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12", macZone: "Asia/Gaza")
        let text = StatusCLI.text(status: status, glance: glance, projection: try self.projection(), now: Self.now)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "All good · next 08:00")
        #expect(lines.contains("Next: 08:00, in 2 h 15 min"))
        #expect(lines.contains("Today: ○ 08:00 ○ 13:00 ○ 18:00"))
        #expect(lines.contains("  ✓ Background job: running"))
        #expect(lines.contains { $0.hasPrefix("Account 1: Ready · ") && $0.hasSuffix("seen Wed 08:00") })
        #expect(lines.contains("Account 2: Ready · No usage seen yet"))
    }

    /// App 0.6.8 (review round 1): a time moved to 13:10 prints as 13:10 in both outputs.
    @Test func movedTimePrintsWhenItRuns() throws {
        let status = try self.withUsage()
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12", macZone: "Asia/Gaza")
        let projection = try #require(
            ReplyValidator.payload(
                ScheduleProjection.self,
                from: try Fixture.output("projection-default") { object in
                    guard var days = object["days"] as? [[String: Any]],
                        var admissions = days[0]["admissions"] as? [[String: Any]]
                    else { return }
                    for index in admissions.indices where admissions[index]["logicalTime"] as? String == "13:00" {
                        admissions[index]["admission"] = "13:10"
                    }
                    days[0]["admissions"] = admissions
                    object["days"] = days
                }))
        let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: Self.now)
        #expect(text.split(separator: "\n").contains("Today: ○ 08:00 ○ 13:10 ○ 18:00"))
        let data = StatusCLI.json(status: status, glance: glance, projection: projection, now: Self.now)
        let decoded = try JSONDecoder().decode(StatusCLI.Report.self, from: data)
        #expect(decoded.today.map(\.time) == ["08:00", "13:10", "18:00"])
    }

    @Test func outputsCarryNoIdentifiersOrPaths() throws {
        let status = try self.withUsage()
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        let projection = try self.projection()
        let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: Self.now)
        let json = String(
            decoding: StatusCLI.json(status: status, glance: glance, projection: projection, now: Self.now),
            as: UTF8.self)
        for output in [text, json] {
            #expect(!output.contains("enr_"))
            #expect(!output.contains("install_ui_fixture_01"))
            #expect(!output.contains("/Users/"))
            #expect(!output.contains("/opt/"))
            #expect(!output.contains("warmup.mjs"))
        }
    }

    @Test func jsonDecodesBack() throws {
        let status = try self.withUsage()
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        let projection = try self.projection()
        let data = StatusCLI.json(status: status, glance: glance, projection: projection, now: Self.now)
        let decoded = try JSONDecoder().decode(StatusCLI.Report.self, from: data)
        #expect(decoded == StatusCLI.report(status: status, glance: glance, projection: projection, now: Self.now))
        #expect(decoded.state == "scheduled")
        #expect(decoded.today.map(\.mark) == ["upcoming", "upcoming", "upcoming"])
        #expect(decoded.accounts.map(\.label) == ["Account 1", "Account 2"])
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        #expect(keys == ["accounts", "checkedAt", "health", "next", "state", "today", "verdict"])
    }

    @Test func exitCodes() throws {
        let fine = [HealthRow(title: "Background job", value: "running", level: .ok)]
        let scheduled = GlanceBuilder.make(status: try self.status(), today: "2026-11-12")
        #expect(StatusCLI.exitCode(glance: scheduled, health: fine) == 0)
        let warning = fine + [HealthRow(title: "Router", value: "needs a review", level: .warning)]
        #expect(StatusCLI.exitCode(glance: scheduled, health: warning) == 1)
        let paused = GlanceBuilder.make(status: try self.status("status-paused"), today: "2026-11-12")
        #expect(StatusCLI.exitCode(glance: paused, health: fine) == 1)
        #expect(StatusCLI.exitCode(glance: nil, health: fine) == 2)
        let unreadable = StatusCLI.render(nil, json: false, now: Self.now)
        #expect(unreadable.code == 2)
        #expect(unreadable.stdout.isEmpty)
        #expect(unreadable.stderr == "Warm-up: no engine connection. Open the app's Settings to reconnect.")
        let snapshot = StatusCLI.Snapshot(
            status: try self.status(), observedAt: Self.observedNow, projection: try self.projection())
        let rendered = StatusCLI.render(snapshot, json: true, now: Self.now)
        #expect(rendered.stderr == nil)
        #expect(try JSONDecoder().decode(StatusCLI.Report.self, from: rendered.stdout).verdict.hasPrefix("All good"))
    }

    /// 0.6.3: once the app has opened the problem slot, the CLI no longer says "Needs a look" for it.
    @Test func acknowledgedProblemMatchesTheApp() throws {
        let ledger: [String: Any] = [
            "slot": "2026-11-11T18:00", "admission": "18:00", "verdict": "not_admitted", "cause": "no_tick_between",
            "zone": "Asia/Gaza", "at": Self.observedNow - 3_600_000,
        ]
        let missed = try self.status { $0["slotLedger"] = [ledger] }
        let snapshot = StatusCLI.Snapshot(
            status: missed, observedAt: Self.observedNow, projection: try self.projection())
        let unseen = StatusCLI.render(snapshot, json: true, now: Self.now)
        #expect(unseen.code == 1)
        #expect(try JSONDecoder().decode(StatusCLI.Report.self, from: unseen.stdout).verdict.hasPrefix("Needs a look"))
        let seen = StatusCLI.render(snapshot, json: true, now: Self.now, acknowledgedSlot: "2026-11-11T18:00")
        #expect(seen.code == 0)
        #expect(try JSONDecoder().decode(StatusCLI.Report.self, from: seen.stdout).verdict.hasPrefix("All good"))
        let older = StatusCLI.render(snapshot, json: false, now: Self.now, acknowledgedSlot: "2026-11-11T13:00")
        #expect(older.code == 1)
        let malformed = StatusCLI.render(snapshot, json: false, now: Self.now, acknowledgedSlot: "2026-11-11T18:00 ")
        #expect(malformed.code == 1)
        // The app writes this key; the CLI reads the same one.
        #expect(GlanceBuilder.acknowledgedSlotKey == "acknowledgedProblemSlot")
    }

    /// 0.7.0: an opened miss today is "Next 08:00 · 1 missed today", never "unknown", and still exits 0.
    @Test func openedMissTodayHasItsOwnVerdict() throws {
        let ledger: [String: Any] = [
            "slot": "2026-11-12T01:00", "admission": "01:00", "verdict": "not_admitted", "cause": "no_tick_between",
            "zone": "Asia/Gaza", "at": Self.observedNow - 3_600_000,
        ]
        let missed = try self.status { $0["slotLedger"] = [ledger] }
        let snapshot = StatusCLI.Snapshot(
            status: missed, observedAt: Self.observedNow, projection: try self.projection())
        let text = StatusCLI.render(snapshot, json: false, now: Self.now, acknowledgedSlot: "2026-11-12T01:00")
        #expect(text.code == 0)
        // `render` names the zone only when it is not this Mac's own, so these checks hold in any zone.
        let output = String(decoding: text.stdout, as: UTF8.self)
        let first = try #require(output.split(separator: "\n").first)
        #expect(first.hasPrefix("Next 08:00") && first.hasSuffix(" · 1 missed today"))
        #expect(!output.contains("Last 7 days"), "the CLI reads no history")
        let json = StatusCLI.render(snapshot, json: true, now: Self.now, acknowledgedSlot: "2026-11-12T01:00")
        #expect(json.code == 0)
        let report = try JSONDecoder().decode(StatusCLI.Report.self, from: json.stdout)
        #expect(report.verdict.hasPrefix("Next 08:00") && report.verdict.hasSuffix(" · 1 missed today"))
        #expect(report.state == "scheduled")
        func verdict(macZone: String) throws -> String {
            let glance = GlanceBuilder.make(
                status: missed, today: "2026-11-12", observedAt: Self.observedNow, macZone: macZone,
                acknowledgedSlot: "2026-11-12T01:00")
            return StatusCLI.report(
                status: missed, glance: glance, projection: try self.projection(), now: Self.now,
                observedAt: Self.observedNow
            ).verdict
        }
        #expect(try verdict(macZone: "Asia/Gaza") == "Next 08:00 · 1 missed today")
        #expect(try verdict(macZone: "UTC") == "Next 08:00 (Asia/Gaza) · 1 missed today")
        let keys = try #require(try JSONSerialization.jsonObject(with: json.stdout) as? [String: Any]).keys.sorted()
        #expect(keys == ["accounts", "checkedAt", "health", "next", "state", "today", "verdict"])

        let unresolved: [[String: Any]] = [["enrollmentId": "enr_01", "slot": "2026-11-12T01:00", "at": 1]]
        let both = try self.status {
            $0["slotLedger"] = [ledger]
            $0["unresolved"] = unresolved
        }
        let attention = StatusCLI.render(
            StatusCLI.Snapshot(status: both, observedAt: Self.observedNow, projection: try self.projection()),
            json: false, now: Self.now, acknowledgedSlot: "2026-11-12T01:00")
        #expect(attention.code == 1)
        #expect(
            String(decoding: attention.stdout, as: UTF8.self).hasPrefix("Needs attention: 1 send without a result\n"))
    }

    /// 060-FIX1 item 7: without a ready schedule the CLI prints nothing and exits 2.
    @Test func unreadableScheduleExitsTwo() throws {
        let snapshot = StatusCLI.Snapshot(status: try self.status(), observedAt: nil, projection: nil)
        for json in [false, true] {
            let rendered = StatusCLI.render(snapshot, json: json, now: Self.now)
            #expect(rendered.code == 2)
            #expect(rendered.stdout.isEmpty)
            #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
        }
    }

    /// 060-FIX1 item 2: block reasons render only through plain codes; malformed times print "unknown".
    @Test func engineStringsAreNotEchoed() throws {
        let raws = ["someone@example.com", "/Users/someone/secret", "enr_01HXYZ", "acct-1234-abcd"]
        for raw in raws {
            let status = try self.status { object in
                guard var accounts = object["accounts"] as? [[String: Any]] else { return }
                accounts[0]["block"] = raw
                object["accounts"] = accounts
            }
            let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
            let projection = try self.projection()
            let report = StatusCLI.report(status: status, glance: glance, projection: projection, now: Self.now)
            #expect(report.accounts[0].state == "Blocked")
            let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: Self.now)
            let json = String(
                decoding: StatusCLI.json(status: status, glance: glance, projection: projection, now: Self.now),
                as: UTF8.self)
            for output in [text, json] { #expect(!output.contains(raw)) }
        }
        let known = try self.status { object in
            guard var accounts = object["accounts"] as? [[String: Any]] else { return }
            accounts[0]["block"] = "daily_cap_reached"
            object["accounts"] = accounts
        }
        let knownGlance = GlanceBuilder.make(status: known, today: "2026-11-12")
        let knownReport = StatusCLI.report(
            status: known, glance: knownGlance, projection: try self.projection(), now: Self.now)
        #expect(knownReport.accounts[0].state == "Daily limit reached")
        let rawTime = "8am@host"
        let malformed = try self.status {
            $0["next"] = ["slot": "2026-11-12T08:00", "admission": rawTime, "date": "12/11/2026", "at": Self.at0800]
        }
        let glance = GlanceBuilder.make(status: malformed, today: "2026-11-12")
        let projection = try self.projection()
        let report = StatusCLI.report(status: malformed, glance: glance, projection: projection, now: Self.now)
        #expect(report.next == "unknown")
        let text = StatusCLI.text(status: malformed, glance: glance, projection: projection, now: Self.now)
        let json = String(
            decoding: StatusCLI.json(status: malformed, glance: glance, projection: projection, now: Self.now),
            as: UTF8.self)
        for output in [text, json] {
            #expect(!output.contains(rawTime))
            #expect(!output.contains("12/11/2026"))
        }
        #expect(StatusCLI.safeTime("8:00") == "unknown")
        #expect(StatusCLI.safeTime("08:00 ") == "unknown")
    }

    /// 060-FIX2 item 2: an unknown lowercase block code prints the fixed "Blocked".
    @Test func unknownBlockCodeIsBlocked() throws {
        let status = try self.status { object in
            guard var accounts = object["accounts"] as? [[String: Any]] else { return }
            accounts[0]["block"] = "secret_family_name"
            object["accounts"] = accounts
        }
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        let projection = try self.projection()
        let report = StatusCLI.report(status: status, glance: glance, projection: projection, now: Self.now)
        #expect(report.accounts[0].state == "Blocked")
        let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: Self.now)
        #expect(!text.contains("secret"))
    }

    /// 060-FIX2 item 2: a zone the CLI cannot check prints nothing and exits 2.
    @Test func uncheckedZoneExitsTwo() throws {
        for zone in ["Mars/Olympus", "../../etc/passwd", "Asia/Gaza x", "someone@example.com", ""] {
            let status = try self.status { object in
                guard var schedule = object["schedule"] as? [String: Any] else { return }
                schedule["zone"] = zone
                object["schedule"] = schedule
            }
            let snapshot = StatusCLI.Snapshot(status: status, observedAt: nil, projection: try self.projection())
            for json in [false, true] {
                let rendered = StatusCLI.render(snapshot, json: json, now: Self.now)
                #expect(rendered.code == 2)
                #expect(rendered.stdout.isEmpty)
                #expect(rendered.stderr == "Warm-up: the engine reply could not be checked.")
            }
        }
        #expect(StatusCLI.isZone("Asia/Gaza"))
        #expect(StatusCLI.isZone("America/Argentina/Buenos_Aires"))
        #expect(StatusCLI.isZone("UTC"))
    }

    /// 060-FIX2 item 2: a malformed slot label in the verdict prints "unknown".
    @Test func badSlotLabelIsUnknown() throws {
        let raw = "enr_secret_slot"
        let status = try self.status {
            $0["activeBatch"] = ["slot": raw, "enrollmentIds": ["enr_a"], "zone": "Asia/Gaza", "state": "running"]
        }
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        let projection = try self.projection()
        let report = StatusCLI.report(status: status, glance: glance, projection: projection, now: Self.now)
        #expect(report.verdict == "Warming up: unknown")
        let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: Self.now)
        #expect(!text.contains("_slot"))
        #expect(StatusCLI.isSlot("2026-11-12T08:00"))
        #expect(!StatusCLI.isSlot("2026-11-12T08:00 "))
    }

    /// 060-FIX3 item 2: fields are checked before the verdict is composed, so a malformed admission
    /// that is a substring of a malformed date cannot shield the date from redaction.
    @Test func overlappingMalformedFieldsAreNotEchoed() throws {
        let date = "enr_secret_8am"
        let admission = "8am"
        let status = try self.status {
            $0["next"] = ["slot": "2026-11-12T08:00", "admission": admission, "date": date, "at": Self.at0800]
        }
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12", macZone: "Asia/Gaza")
        let projection = try self.projection()
        let report = StatusCLI.report(status: status, glance: glance, projection: projection, now: Self.now)
        #expect(report.verdict == "All good · next unknown")
        #expect(report.next == "unknown")
        let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: Self.now)
        let json = String(
            decoding: StatusCLI.json(status: status, glance: glance, projection: projection, now: Self.now),
            as: UTF8.self)
        for output in [text, json] {
            #expect(!output.contains("enr_"))
            #expect(!output.contains("secret"))
            #expect(!output.contains(admission))
        }
    }

    /// 0.7.0 (order 133): while Router is blocked, the headline says since when; the CLI rebuilds it
    /// from the status, never prints "unknown", and keeps its exit code.
    @Test func blockedHeadlineSaysSinceWhen() throws {
        let today = Self.at0800 - 3 * 3_600_000  // 05:00 on 12 Nov in Asia/Gaza
        let earlier = Self.at0800 - (9 * 60 + 50) * 60_000  // 22:10 on 11 Nov
        func blocked(since: Int?) throws -> EngineStatus {
            try self.status {
                $0["compatibility"] = "blocked"
                $0["compatibilityBlockedSince"] = since.map { $0 as Any } ?? NSNull()
            }
        }
        let note = "codex-router changed. Scheduled warm-ups are skipped until it is reviewed."
        let cases: [(Int?, String)] = [
            (today, "Blocked since 05:00: Router needs a review"),
            (earlier, "Blocked since 22:10 yesterday: Router needs a review"),
            (nil, "Blocked: Router needs a review"),
        ]
        var codes: Set<Int32> = []
        for (since, headline) in cases {
            let status = try blocked(since: since)
            let glance = GlanceBuilder.make(
                status: status, today: "2026-11-12", observedAt: Self.observedNow, macZone: "Asia/Gaza")
            #expect(glance.state == .blocked)
            #expect(glance.headline == headline)
            #expect(glance.notes.first == note)
            let report = StatusCLI.report(
                status: status, glance: glance, projection: try self.projection(), now: Self.now,
                observedAt: Self.observedNow)
            #expect(report.verdict == headline)
            let snapshot = StatusCLI.Snapshot(
                status: status, observedAt: Self.observedNow, projection: try self.projection())
            let rendered = StatusCLI.render(snapshot, json: false, now: Self.now, acknowledgedSlot: nil)
            let first = String(decoding: rendered.stdout, as: UTF8.self).split(separator: "\n").first
            #expect(first.map(String.init) == headline)
            codes.insert(rendered.code)
        }
        #expect(codes.count == 1, "the blocked exit code does not depend on the time")
        // Without today's date the headline stays fixed.
        let unknownDay = GlanceBuilder.make(status: try blocked(since: today), today: nil, macZone: "Asia/Gaza")
        #expect(unknownDay.headline == "Blocked: Router needs a review")
    }
}

/// 060-FIX4 item 2: `StatusCLI.read` pairs a status with a projection of the same schedule. A fake
/// engine (/bin/sh) answers each `status` and `schedule inspect` call from numbered reply files.
@Suite struct StatusCommandLinePairing {
    static let installation = "install_cli_pairing_01"

    final class Engine: @unchecked Sendable {
        let root: String
        let script: String
        let binding: EngineBinding

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "warmup-cli-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let canonical = try #require(realpath(base.path, nil))
            self.root = String(cString: canonical)
            free(canonical)
            self.script = self.root + "/fake-engine.sh"
            let body = """
                #!/bin/sh
                case "$*" in
                  *"schedule inspect"*) kind=inspect ;;
                  *status*) kind=status ;;
                  *) kind=other ;;
                esac
                n=$(cat "\(self.root)/count-$kind" 2>/dev/null || echo 0)
                n=$((n + 1))
                echo "$n" > "\(self.root)/count-$kind"
                cat "\(self.root)/$kind-$n.json"
                printf '\\n'
                """
            FileManager.default.createFile(atPath: self.script, contents: Data(body.utf8))
            self.binding = EngineBinding(
                nodePath: "/bin/sh", scriptPath: self.script, engineBuild: "sha256:test",
                installationId: StatusCommandLinePairing.installation, capabilityVersion: 1)
        }

        deinit { try? FileManager.default.removeItem(atPath: self.root) }

        /// Writes the `n`th reply for `kind` from a fixture, edited to this engine's identity.
        func reply(_ kind: String, _ n: Int, fixture: String, revision: Int) throws {
            var object = try #require(try JSONSerialization.jsonObject(with: Fixture.data(fixture)) as? [String: Any])
            object["installationId"] = StatusCommandLinePairing.installation
            object["scheduleRevision"] = revision
            if kind == "status" {
                object["engine"] = ["nodePath": "/bin/sh", "scriptPath": self.script]
                object["engineBuild"] = "sha256:test"
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            FileManager.default.createFile(atPath: "\(self.root)/\(kind)-\(n).json", contents: data)
        }

        func count(_ kind: String) -> Int {
            let text = (try? String(contentsOfFile: "\(self.root)/count-\(kind)", encoding: .utf8)) ?? "0"
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        func client() -> EngineClient {
            EngineClient(binding: self.binding, home: self.root, readTimeout: .seconds(10), launchCheck: { _ in nil })
        }
    }

    @Test func mismatchTwiceExitsTwoWithNoOutput() async throws {
        let engine = try Engine()
        for n in [1, 2] {
            try engine.reply("status", n, fixture: "status-enabled", revision: 1)
            try engine.reply("inspect", n, fixture: "projection-default", revision: 2)
        }
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot != nil)
        #expect(snapshot?.projection == nil)
        let rendered = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(rendered.code == 2)
        #expect(rendered.stdout.isEmpty)
        #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }

    @Test func mismatchThenMatchExitsZero() async throws {
        let engine = try Engine()
        // The first pair straddles an edit: status at revision 1, inspect already at 2.
        try engine.reply("status", 1, fixture: "status-enabled", revision: 1)
        try engine.reply("inspect", 1, fixture: "projection-default", revision: 2)
        try engine.reply("status", 2, fixture: "status-enabled", revision: 2)
        try engine.reply("inspect", 2, fixture: "projection-default", revision: 2)
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot?.status.scheduleRevision == 2)
        #expect(snapshot?.projection?.scheduleRevision == 2)
        let rendered = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(rendered.code == 0)
        #expect(rendered.stderr == nil)
        #expect(!rendered.stdout.isEmpty)
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }
}

/// 060-FIX5 items 3 and 5: the pair must agree on the local date, and unresolved sends are never
/// "All good".
extension StatusCommandLinePairing {
    /// 23:59:59 on 12 Nov in Asia/Gaza (UTC+2), then 00:00:30 on 13 Nov.
    static let beforeMidnight = "2026-11-12T21:59:59.000Z"
    static let afterMidnight = "2026-11-12T22:00:30.000Z"

    /// The default projection as read on 13 Nov: 12 Nov is gone.
    static func nextDay(_ object: inout [String: Any]) {
        object["localDate"] = "2026-11-13"
        object["days"] = (object["days"] as? [[String: Any]] ?? []).filter { $0["date"] as? String != "2026-11-12" }
    }

    @Test func pairAcrossMidnightIsRetried() async throws {
        let engine = try Engine()
        try engine.reply("status", 1, fixture: "status-enabled", revision: 1) { $0["observedAt"] = Self.beforeMidnight }
        try engine.reply("inspect", 1, fixture: "projection-default", revision: 1, edit: Self.nextDay)
        try engine.reply("status", 2, fixture: "status-enabled", revision: 1) { $0["observedAt"] = Self.afterMidnight }
        try engine.reply("inspect", 2, fixture: "projection-default", revision: 1, edit: Self.nextDay)
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot?.projection?.localDate == "2026-11-13")
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }

    @Test func pairAcrossMidnightTwiceExitsTwo() async throws {
        let engine = try Engine()
        for n in [1, 2] {
            try engine.reply("status", n, fixture: "status-enabled", revision: 1) {
                $0["observedAt"] = Self.beforeMidnight
            }
            try engine.reply("inspect", n, fixture: "projection-default", revision: 1, edit: Self.nextDay)
        }
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot != nil)
        #expect(snapshot?.projection == nil)
        let rendered = StatusCLI.render(snapshot, json: true, now: StatusCommandLine.now)
        #expect(rendered.code == 2)
        #expect(rendered.stdout.isEmpty)
        #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
    }

    @Test func projectionWithoutTodayIsNotRendered() throws {
        let status = try #require(
            ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        let projection = try #require(
            ReplyValidator.payload(
                ScheduleProjection.self, from: try Fixture.output("projection-default", edit: Self.nextDay)))
        let snapshot = StatusCLI.Snapshot(status: status, observedAt: nil, projection: projection)
        for json in [false, true] {
            let rendered = StatusCLI.render(snapshot, json: json, now: StatusCommandLine.now)
            #expect(rendered.code == 2)
            #expect(rendered.stdout.isEmpty)
            #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
        }
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        let text = StatusCLI.text(status: status, glance: glance, projection: projection, now: StatusCommandLine.now)
        #expect(text.contains("Today: Schedule not available"))
        #expect(!text.contains("Today: no warm-ups"))
    }

    @Test func unresolvedSendsNeedAttention() throws {
        let rows: [[String: Any]] = [
            ["enrollmentId": "enr_01", "slot": "2026-11-12T08:00", "at": 1_794_463_200_000],
            ["enrollmentId": "enr_02", "slot": "2026-11-12T08:00", "at": 1_794_463_201_000],
        ]
        let status = try #require(
            ReplyValidator.payload(
                EngineStatus.self, from: try Fixture.output("status-enabled") { $0["unresolved"] = rows }))
        #expect(status.unresolved.count == 2)
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        let snapshot = StatusCLI.Snapshot(
            status: status, observedAt: StatusCommandLine.observedNow, projection: projection)
        let text = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(text.code == 1)
        let output = String(decoding: text.stdout, as: UTF8.self)
        #expect(output.hasPrefix("Needs attention: 2 sends without a result\n"))
        #expect(!output.contains("All good"))
        #expect(!output.contains("enr_"))
        let json = StatusCLI.render(snapshot, json: true, now: StatusCommandLine.now)
        #expect(json.code == 1)
        let report = try JSONDecoder().decode(StatusCLI.Report.self, from: json.stdout)
        #expect(report.unresolvedSends == 2)
        #expect(report.verdict == "Needs attention: 2 sends without a result")
        #expect(!String(decoding: json.stdout, as: UTF8.self).contains("enr_"))
        #expect(StatusCLI.unresolvedVerdict(1) == "Needs attention: 1 send without a result")
        #expect(StatusCLI.unresolvedVerdict(0) == nil)
        let glance = GlanceBuilder.make(status: status, today: "2026-11-12")
        let fine = [HealthRow(title: "Background job", value: "running", level: .ok)]
        #expect(StatusCLI.exitCode(glance: glance, health: fine, unresolved: 2) == 1)
        #expect(StatusCLI.exitCode(glance: glance, health: fine, unresolved: 0) == 0)
    }
}

extension StatusCommandLinePairing.Engine {
    /// `reply` with a further edit to the fixture object.
    func reply(
        _ kind: String, _ n: Int, fixture: String, revision: Int, edit: (inout [String: Any]) -> Void
    ) throws {
        try self.reply(kind, n, fixture: fixture, revision: revision)
        let path = "\(self.root)/\(kind)-\(n).json"
        let data = try #require(FileManager.default.contents(atPath: path))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        FileManager.default.createFile(atPath: path, contents: try JSONSerialization.data(withJSONObject: object))
    }
}

/// 060-FIX6 items 4 and 6: the projection's own `localDate` must be the status observation's date,
/// "today" in the output is that date, and the unresolved count is printed whatever the verdict.
extension StatusCommandLinePairing {
    /// 08:00 on 12 Nov in Asia/Gaza.
    static let observedOn12 = 1_794_463_200_000

    /// Yesterday's projection still lists today's date, but was read for 12 Nov: retried, then paired.
    @Test func staleProjectionAcrossRolloverIsRetried() async throws {
        let engine = try Engine()
        try engine.reply("status", 1, fixture: "status-enabled", revision: 1) { $0["observedAt"] = Self.afterMidnight }
        try engine.reply("inspect", 1, fixture: "projection-default", revision: 1)  // localDate 12 Nov
        try engine.reply("status", 2, fixture: "status-enabled", revision: 1) { $0["observedAt"] = Self.afterMidnight }
        try engine.reply("inspect", 2, fixture: "projection-default", revision: 1, edit: Self.nextDay)
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot?.projection?.localDate == "2026-11-13")
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }

    @Test func staleProjectionTwiceExitsTwo() async throws {
        let engine = try Engine()
        for n in [1, 2] {
            try engine.reply("status", n, fixture: "status-enabled", revision: 1) {
                $0["observedAt"] = Self.afterMidnight
            }
            try engine.reply("inspect", n, fixture: "projection-default", revision: 1)
        }
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot != nil)
        #expect(snapshot?.projection == nil)
        let rendered = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(rendered.code == 2)
        #expect(rendered.stdout.isEmpty)
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
    }

    /// Rendering after midnight still speaks for the observation's day; a projection from another
    /// day than the observation is never rendered.
    @Test func renderUsesTheObservationDate() throws {
        let status = try #require(
            ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        let nextDay = Date(timeIntervalSince1970: Double(Self.observedOn12 + 86_400_000) / 1000)
        let observed = StatusCLI.Snapshot(status: status, observedAt: Self.observedOn12, projection: projection)
        let rendered = StatusCLI.render(observed, json: false, now: nextDay)
        #expect(rendered.code != 2)
        #expect(String(decoding: rendered.stdout, as: UTF8.self).contains("Today: "))
        #expect(StatusCLI.observedDay(status: status, observedAt: Self.observedOn12, now: nextDay) == "2026-11-12")
        let later = StatusCLI.Snapshot(
            status: status, observedAt: Self.observedOn12 + 86_400_000, projection: projection)
        let stale = StatusCLI.render(later, json: true, now: nextDay)
        #expect(stale.code == 2)
        #expect(stale.stderr == "Warm-up: the schedule could not be read.")
        #expect(!StatusCLI.paired(projection: projection, status: status, today: "2026-11-13"))
        #expect(StatusCLI.paired(projection: projection, status: status, today: "2026-11-12"))
    }

    @Test func unresolvedCountPrintedWhateverTheVerdict() throws {
        let rows: [[String: Any]] = [
            ["enrollmentId": "enr_01", "slot": "2026-11-12T08:00", "at": 1_794_463_200_000],
            ["enrollmentId": "enr_02", "slot": "2026-11-12T08:00", "at": 1_794_463_201_000],
        ]
        let paused = try #require(
            ReplyValidator.payload(
                EngineStatus.self, from: try Fixture.output("status-paused") { $0["unresolved"] = rows }))
        let glance = GlanceBuilder.make(status: paused, today: "2026-11-12")
        let text = StatusCLI.text(status: paused, glance: glance, projection: nil, now: StatusCommandLine.now)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "Paused")
        #expect(lines.contains("Sends without a result: 2"))
        #expect(!text.contains("enr_"))
        let clean = try #require(
            ReplyValidator.payload(
                EngineStatus.self, from: try Fixture.output("status-paused") { $0["unresolved"] = [] }))
        let quiet = StatusCLI.text(
            status: clean, glance: GlanceBuilder.make(status: clean, today: "2026-11-12"), projection: nil,
            now: StatusCommandLine.now)
        #expect(!quiet.contains("Sends without a result"))
    }
}

/// 060-FIX7 items 3 and 5: an invalid `observedAt` is a mismatch, never the wall clock; a cut
/// unresolved list is a lower bound.
extension StatusCommandLinePairing {
    @Test func invalidObservedAtIsRetriedThenExitsTwo() async throws {
        let engine = try Engine()
        for n in [1, 2] {
            try engine.reply("status", n, fixture: "status-enabled", revision: 1) { $0["observedAt"] = "not-a-time" }
            try engine.reply("inspect", n, fixture: "projection-default", revision: 1)
        }
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot != nil)
        #expect(snapshot?.observedAt == nil)
        #expect(snapshot?.projection == nil)
        for json in [false, true] {
            let rendered = StatusCLI.render(snapshot, json: json, now: StatusCommandLine.now)
            #expect(rendered.code == 2)
            #expect(rendered.stdout.isEmpty)
            #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
        }
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }

    @Test func invalidThenValidObservedAtPairs() async throws {
        let engine = try Engine()
        try engine.reply("status", 1, fixture: "status-enabled", revision: 1) { $0["observedAt"] = "not-a-time" }
        try engine.reply("inspect", 1, fixture: "projection-default", revision: 1)
        try engine.reply("status", 2, fixture: "status-enabled", revision: 1)
        try engine.reply("inspect", 2, fixture: "projection-default", revision: 1)
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot?.observedAt != nil)
        #expect(snapshot?.projection != nil)
        #expect(engine.count("status") == 2)
    }

    /// A snapshot without an observation time is never rendered with the wall clock's date.
    @Test func renderWithoutObservationTimeExitsTwo() throws {
        let status = try #require(
            ReplyValidator.payload(EngineStatus.self, from: try Fixture.output("status-enabled")))
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        let snapshot = StatusCLI.Snapshot(status: status, observedAt: nil, projection: projection)
        let rendered = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(rendered.code == 2)
        #expect(rendered.stdout.isEmpty)
        #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
    }

    @Test func truncatedUnresolvedListIsALowerBound() throws {
        let rows: [[String: Any]] = [
            ["enrollmentId": "enr_01", "slot": "2026-11-12T08:00", "at": 1_794_463_200_000],
            ["enrollmentId": "enr_02", "slot": "2026-11-12T08:00", "at": 1_794_463_201_000],
        ]
        let cut = try #require(
            ReplyValidator.payload(
                EngineStatus.self,
                from: try Fixture.output("status-paused") {
                    $0["unresolved"] = rows
                    $0["unresolvedTruncated"] = true
                }))
        #expect(cut.unresolvedTruncated == true)
        let glance = GlanceBuilder.make(status: cut, today: "2026-11-12")
        let text = StatusCLI.text(status: cut, glance: glance, projection: nil, now: StatusCommandLine.now)
        #expect(text.split(separator: "\n").map(String.init).contains("Sends without a result: 2 or more"))
        #expect(!text.contains("enr_"))
        let data = StatusCLI.json(status: cut, glance: glance, projection: nil, now: StatusCommandLine.now)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["unresolvedTruncated"] as? Bool == true)
        #expect(object["unresolvedSends"] as? Int == 2)
        // An uncut list stays exact, and the flag is absent.
        let whole = try #require(
            ReplyValidator.payload(
                EngineStatus.self, from: try Fixture.output("status-paused") { $0["unresolved"] = rows }))
        let exact = StatusCLI.text(
            status: whole, glance: GlanceBuilder.make(status: whole, today: "2026-11-12"), projection: nil,
            now: StatusCommandLine.now)
        #expect(exact.split(separator: "\n").map(String.init).contains("Sends without a result: 2"))
        let plain = StatusCLI.json(
            status: whole, glance: GlanceBuilder.make(status: whole, today: "2026-11-12"), projection: nil,
            now: StatusCommandLine.now)
        let keys = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any]).keys
        #expect(!keys.contains("unresolvedTruncated"))
    }
}

/// 060-FIX8 items 4 and 5: a failed or not-ready inspect is retried with a fresh status read, and a cut
/// unresolved list makes the verdict a lower bound.
extension StatusCommandLinePairing {
    @Test func failedInspectIsRetriedThenPairs() async throws {
        let engine = try Engine()
        // No inspect-1 reply: the first inspect fails to parse.
        try engine.reply("status", 1, fixture: "status-enabled", revision: 1)
        try engine.reply("status", 2, fixture: "status-enabled", revision: 1)
        try engine.reply("inspect", 2, fixture: "projection-default", revision: 1)
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot?.projection != nil)
        #expect(StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now).code == 0)
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }

    @Test func notReadyInspectTwiceExitsTwo() async throws {
        let engine = try Engine()
        for n in [1, 2] {
            try engine.reply("status", n, fixture: "status-enabled", revision: 1)
            try engine.reply("inspect", n, fixture: "projection-default", revision: 1) { $0["outcome"] = "blocked" }
        }
        let snapshot = await StatusCLI.read(client: engine.client())
        #expect(snapshot != nil)
        #expect(snapshot?.projection == nil)
        let rendered = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(rendered.code == 2)
        #expect(rendered.stdout.isEmpty)
        #expect(rendered.stderr == "Warm-up: the schedule could not be read.")
        #expect(engine.count("status") == 2)
        #expect(engine.count("inspect") == 2)
        #expect(engine.count("other") == 0)
    }

    @Test func truncatedVerdictSaysOrMore() throws {
        let rows: [[String: Any]] = [
            ["enrollmentId": "enr_01", "slot": "2026-11-12T08:00", "at": 1_794_463_200_000],
            ["enrollmentId": "enr_02", "slot": "2026-11-12T08:00", "at": 1_794_463_201_000],
        ]
        let status = try #require(
            ReplyValidator.payload(
                EngineStatus.self,
                from: try Fixture.output("status-enabled") {
                    $0["unresolved"] = rows
                    $0["unresolvedTruncated"] = true
                }))
        let projection = try #require(
            ReplyValidator.payload(ScheduleProjection.self, from: try Fixture.output("projection-default")))
        let snapshot = StatusCLI.Snapshot(
            status: status, observedAt: StatusCommandLine.observedNow, projection: projection)
        let text = StatusCLI.render(snapshot, json: false, now: StatusCommandLine.now)
        #expect(text.code == 1)
        let output = String(decoding: text.stdout, as: UTF8.self)
        #expect(output.hasPrefix("Needs attention: 2 or more sends without a result\n"))
        #expect(!output.contains("enr_"))
        let json = StatusCLI.render(snapshot, json: true, now: StatusCommandLine.now)
        let report = try JSONDecoder().decode(StatusCLI.Report.self, from: json.stdout)
        #expect(report.verdict == "Needs attention: 2 or more sends without a result")
        #expect(StatusCLI.unresolvedVerdict(1, truncated: true) == "Needs attention: 1 or more sends without a result")
        #expect(StatusCLI.unresolvedVerdict(2) == "Needs attention: 2 sends without a result")
    }
}

/// App 0.7.0: the Accounts table and the CLI share one readiness rule.
@Suite struct OneReadinessRule {
    static let now = 1_794_463_200_000

    static func row(_ state: String, reason: String = "eligible", pilot: Bool = true) -> AccountRow {
        AccountRow(
            routerAccountId: "router_a", enrollmentId: "enr_a", registryReason: reason, enrollmentState: state,
            eligible: true, enabled: state == "enabled", pilot: pilot, lastOutcome: nil, lastReason: nil, lastAt: nil)
    }

    static func state(block: String? = nil, cooldownUntil: Int? = nil) -> AccountState {
        AccountState(enrollmentId: "enr_a", block: block, cooldownUntil: cooldownUntil, usage: nil)
    }

    @Test func blockAndCooldownReplaceReady() {
        let ready = Self.row("enabled")
        let blocked = Self.state(block: "daily_cap_reached")
        #expect(AccountText.readiness(ready, state: blocked, now: Self.now) == "Daily limit reached")
        #expect(AccountText.symbol(ready, state: blocked, now: Self.now) == "exclamationmark.triangle")
        #expect(AccountText.needsLook(ready, state: blocked, now: Self.now))
        let unknown = Self.state(block: "some_new_code")
        #expect(AccountText.readiness(ready, state: unknown, now: Self.now) == "Blocked")
        let cooling = Self.state(cooldownUntil: Self.now + 60_000)
        #expect(AccountText.readiness(ready, state: cooling, now: Self.now) == "Cooling down")
        #expect(AccountText.symbol(ready, state: cooling, now: Self.now) == "hourglass")
        #expect(!AccountText.needsLook(ready, state: cooling, now: Self.now))
        let cooled = Self.state(cooldownUntil: Self.now - 60_000)
        #expect(AccountText.readiness(ready, state: cooled, now: Self.now) == "Ready")
        #expect(AccountText.readiness(ready, state: Self.state(), now: Self.now) == "Ready")
        #expect(AccountText.symbol(ready, state: Self.state(), now: Self.now) == "checkmark.circle")
        #expect(AccountText.readiness(ready) == "Ready")
    }

    @Test func otherStatesAreUnchangedByStatus() {
        let cooling = Self.state(block: "cooldown", cooldownUntil: Self.now + 60_000)
        #expect(AccountText.readiness(Self.row("not_enrolled"), state: cooling, now: Self.now) == "Not added yet")
        #expect(AccountText.readiness(Self.row("disabled"), state: cooling, now: Self.now) == "Turned off")
        #expect(
            AccountText.readiness(Self.row("enrolled_unregistered"), state: cooling, now: Self.now)
                == "Missing from Router")
        #expect(
            AccountText.readiness(Self.row("enabled", pilot: false), state: cooling, now: Self.now)
                == "Needs a first manual warm-up")
    }

    @Test func cliUsesTheSameRule() {
        for state in [
            Self.state(), Self.state(block: "daily_cap_reached"), Self.state(block: "some_new_code"),
            Self.state(cooldownUntil: Self.now + 1), Self.state(cooldownUntil: Self.now - 1),
        ] {
            #expect(
                StatusCLI.accountState(state, now: Self.now)
                    == AccountText.readiness(Self.row("enabled"), state: state, now: Self.now))
        }
        #expect(StatusCLI.accountState(Self.state(cooldownUntil: Self.now + 1), now: Self.now) == "Cooling down")
        #expect(StatusCLI.accountState(Self.state(block: "some_new_code"), now: Self.now) == StatusCLI.blockedText)
    }
}
