import Foundation
import Testing
@testable import WarmupCore

/// Process-level checks against a synthetic engine: /bin/sh runs a script that answers from a
/// mode file. No Node, no engine state and no network are involved.
final class FakeEngine: @unchecked Sendable {
    let root: String
    let script: String
    let binding: EngineBinding
    static let installation = "install_fake_engine_01"

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonical = try #require(realpath(base.path, nil))
        self.root = String(cString: canonical)
        free(canonical)
        self.script = self.root + "/fake-engine.sh"
        let body = """
        #!/bin/sh
        mode=$(cat "\(self.root)/mode")
        log="\(self.root)/calls"
        echo "$*" >> "$log"
        if [ "$mode" = slowstatus ]; then sleep 1; mode=status; fi
        case "$mode" in
          status) printf '%s\\n' '{"protocolVersion":1,"command":"status","outcome":"ready","reason":"status","installationId":"\(Self.installation)","observedAt":"x","schedule":{"zone":"UTC","times":["08:00"]},"scheduleEnabled":true,"scheduleRevision":3,"job":"loaded","compatibility":"ready","lastTick":null,"lastTickZone":null,"timeZoneMode":"local","slotLedger":[],"next":null,"accounts":[],"activeBatch":null,"clockHold":null,"lastSlotOutcome":null,"enrolled":0,"enabled":0,"pilots":0,"recent":[],"unresolved":[],"recovery":"none","capability":{"version":1,"features":["expected_installation_id","expected_revision","expected_local_date","schedule_inspect","schedule_weekdays","slot_explanation"]},"engine":{"nodePath":"/bin/sh","scriptPath":"\(self.script)"},"engineBuild":"sha256:test"}' ;;
          env) env | sort | tr '\\n' ' ' > "\(self.root)/env"; printf '%s\\n' '{"protocolVersion":1,"command":"status","outcome":"blocked","reason":"x","installationId":"\(Self.installation)","observedAt":"x"}'; exit 2 ;;
          flood) yes '{"padding":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' | head -c 3000000; exit 0 ;;
          stderrflood) yes 'diagnostic noise' | head -c 3000000 >&2; printf '%s\\n' '{"protocolVersion":1,"command":"status","outcome":"blocked","reason":"x","installationId":"\(Self.installation)","observedAt":"x"}'; exit 2 ;;
          slow) sleep 30 ;;
          slowmutation) sleep 1; printf '%s\\n' '{"protocolVersion":1,"command":"run","outcome":"success","reason":"run_complete","installationId":"\(Self.installation)","observedAt":"x","selected":1,"attempted":1,"results":[]}' ;;
          lostmutation) printf 'partial'; kill -9 $$ ;;
          runnofields) printf '%s\\n' '{"protocolVersion":1,"command":"run","outcome":"success","reason":"run_complete","installationId":"\(Self.installation)","observedAt":"x"}' ;;
          enrollnofields) printf '%s\\n' '{"protocolVersion":1,"command":"enroll","outcome":"ready","reason":"enrolled","installationId":"\(Self.installation)","observedAt":"x"}' ;;
          schednofields) printf '%s\\n' '{"protocolVersion":1,"command":"schedule","outcome":"ready","reason":"schedule_enabled","installationId":"\(Self.installation)","observedAt":"x"}' ;;
          schedrefused) printf '%s\\n' '{"protocolVersion":1,"command":"schedule","outcome":"blocked","reason":"schedule_revision_conflict","installationId":"\(Self.installation)","observedAt":"x"}'; exit 2 ;;
          otherinstall) printf '%s\\n' '{"protocolVersion":1,"command":"status","outcome":"ready","reason":"status","installationId":"install_replaced_00001","observedAt":"x"}' ;;
        esac
        """
        FileManager.default.createFile(atPath: self.script, contents: Data(body.utf8), attributes: [.posixPermissions: 0o644])
        self.binding = EngineBinding(nodePath: "/bin/sh", scriptPath: self.script, engineBuild: "sha256:test", installationId: Self.installation, capabilityVersion: 1)
    }

    func mode(_ value: String) { FileManager.default.createFile(atPath: self.root + "/mode", contents: Data(value.utf8)) }
    var calls: [String] { ((try? String(contentsOfFile: self.root + "/calls", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    deinit { try? FileManager.default.removeItem(atPath: self.root) }

    func client(timeout: Duration = .seconds(10)) async -> EngineClient {
        // The fake engine is a shell script, not the four engine modules; launch checks are tested separately.
        let client = EngineClient(binding: self.binding, home: self.root, readTimeout: timeout, launchCheck: { _ in nil })
        await client.setCapability(Capability(version: 1, features: ["expected_installation_id", "expected_revision", "expected_local_date", "schedule_inspect", "schedule_weekdays", "slot_explanation"]))
        return client
    }
}

@Suite(.serialized) struct EngineProcess {
    @Test func statusRoundTripAndBindingComparison() async throws {
        let engine = try FakeEngine()
        engine.mode("status")
        let reply = try await engine.client().read(.status, as: EngineStatus.self).get()
        let status = try #require(reply.payload)
        #expect(BindingVerifier.compare(engine.binding, envelope: reply.envelope, status: status) == nil)
        #expect(BindingVerifier.checkFiles(nodePath: "/bin/sh", scriptPath: engine.script) == nil)
        let moved = EngineBinding(nodePath: "/bin/sh", scriptPath: engine.script, engineBuild: "sha256:other", installationId: FakeEngine.installation, capabilityVersion: 1)
        #expect(BindingVerifier.compare(moved, envelope: reply.envelope, status: status) == .engineMismatch("engine build"))
        #expect(engine.calls == ["status"])
    }

    @Test func childGetsOnlyTheMinimalEnvironment() async throws {
        let engine = try FakeEngine()
        engine.mode("env")
        setenv("WARMUP_CANARY_SECRET", "canary-value", 1)
        defer { unsetenv("WARMUP_CANARY_SECRET") }
        _ = await engine.client().read(.status, as: EngineStatus.self)
        let env = try String(contentsOfFile: engine.root + "/env", encoding: .utf8)
        #expect(env.contains("HOME=\(engine.root)"))
        #expect(env.contains("PATH=/usr/bin:/bin"))
        #expect(!env.contains("canary-value"))
        #expect(!env.contains("TZ="))
    }

    @Test func oversizedOutputIsRejectedAndBounded() async throws {
        let engine = try FakeEngine()
        engine.mode("flood")
        let started = ContinuousClock.now
        let result = await engine.client().read(.status, as: EngineStatus.self)
        #expect(result.failureIssue == .outputTooLarge)
        #expect(ContinuousClock.now - started < .seconds(5))
        engine.mode("stderrflood")
        let noisy = await engine.client().read(.status, as: EngineStatus.self)
        #expect(noisy.failureIssue == nil, "stderr is drained and capped, never parsed")
    }

    @Test func readTimeoutTerminatesOnlyTheOwnedChild() async throws {
        let engine = try FakeEngine()
        engine.mode("slow")
        let started = ContinuousClock.now
        let result = await engine.client(timeout: .milliseconds(500)).read(.status, as: EngineStatus.self)
        #expect(result.failureIssue == .timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func cancellingADrainClosesItsDescriptorWhileTheWriterStaysOpen() throws {
        // The writer never closes (a helper holding the pipe); cancel must still end the reader and
        // close its duplicate descriptor, which the cancel handler does before leaving the group.
        let pipe = Pipe()
        let sink = BoundedSink(limit: 1024)
        let done = DispatchGroup()
        let made = PipeDrain(pipe.fileHandleForReading, into: sink, done: done, onOverflow: {})
        let drain = try #require(made)
        pipe.fileHandleForWriting.write(Data("partial".utf8))
        let deadline = Date().addingTimeInterval(2)
        while sink.snapshot.0.isEmpty, Date() < deadline { usleep(10_000) }
        #expect(done.wait(timeout: .now() + 0.2) == .timedOut)  // still reading: the writer is open
        drain.cancel()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(sink.snapshot.0 == Data("partial".utf8))
        try pipe.fileHandleForWriting.close()
    }

    @Test func aHelperHoldingThePipeCannotOutlastTheDeadline() async throws {
        // The direct child exits at once, but a background helper inherits stdout and keeps it
        // open for 8 s. The reply must still end near the deadline, as a timeout.
        let started = ContinuousClock.now
        let output = try await ProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "sleep 8 & exit 0"], environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/", timeout: .milliseconds(500), terminateOnOverflow: true)
        #expect(output.timedOut)
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    @Test func installationChangeIsRejected() async throws {
        let engine = try FakeEngine()
        engine.mode("otherinstall")
        #expect(await engine.client().read(.status, as: EngineStatus.self).failureIssue == .installationMismatch)
    }

    @Test func oneMutationAtATimeAndLostOutcomesStayUnknown() async throws {
        let engine = try FakeEngine()
        engine.mode("slowmutation")
        let client = await engine.client()
        async let first = client.mutate(.runAll(allowSlotOverlap: false))
        try await Task.sleep(for: .milliseconds(200))
        let second = await client.mutate(.runAccount(enrollmentId: "enr_01", allowSlotOverlap: false))
        #expect(second.failureIssue == .mutationInFlight)
        #expect((await first).failureIssue == nil)
        #expect(engine.calls == ["run --expected-installation-id \(FakeEngine.installation)"], "the refused mutation never spawned")
        engine.mode("lostmutation")
        #expect(await client.mutate(.runAll(allowSlotOverlap: false)).failureIssue == .mutationOutcomeUnknown)
        #expect(await client.read(.runAll(allowSlotOverlap: false), as: Envelope.self).failureIssue == .invalidCommand)
    }

    @Test func missingCapabilityDisablesCommandsWithoutSpawning() async throws {
        let engine = try FakeEngine()
        engine.mode("status")
        let client = EngineClient(binding: engine.binding, home: engine.root)
        let unverified = ClientIssue.featureUnavailable("a verified engine binding")
        #expect(await client.read(.scheduleInspect, as: ScheduleProjection.self).failureIssue == unverified)
        #expect(await client.read(.list, as: AccountList.self).failureIssue == unverified)
        #expect(await client.read(.history(account: nil, since: nil), as: HistoryReport.self).failureIssue == unverified)
        #expect(await client.mutate(.scheduleEnable(expectedRevision: 1)).failureIssue == unverified)
        await client.setCapability(Capability(version: 1, features: []))
        #expect(await client.read(.scheduleInspect, as: ScheduleProjection.self).failureIssue == .featureUnavailable("schedule_inspect"))
        #expect(engine.calls.isEmpty)
    }
}

@Suite(.serialized) struct BindingStorage {
    @Test func roundTripMissingCorruptAndUnsafe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BindingStore(directory: dir)
        #expect(throws: BindingIssue.missing) { try store.load() }
        let binding = EngineBinding(nodePath: "/bin/sh", scriptPath: "/tmp/x.mjs", engineBuild: "sha256:a", installationId: "install_store_000001", capabilityVersion: 1)
        try store.save(binding)
        #expect(try store.load() == binding)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        chmod(store.file.path, 0o644)
        #expect(throws: BindingIssue.unsafeFile("binding file")) { try store.load() }
        chmod(store.file.path, 0o600)
        try Data("{".utf8).write(to: store.file)
        chmod(store.file.path, 0o600)
        #expect(throws: BindingIssue.corrupt) { try store.load() }
        #expect(BindingVerifier.checkFiles(nodePath: "/bin/sh", scriptPath: "/tmp/../tmp/x.mjs") != nil)
        try store.save(binding)
        let real = dir.appendingPathComponent("real.json")
        try FileManager.default.moveItem(at: store.file, to: real)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: real)
        #expect(throws: BindingIssue.unsafeFile("binding file")) { try store.load() }
        try FileManager.default.removeItem(at: store.file)
        try store.save(binding)
        chmod(dir.path, 0o755)
        #expect(throws: BindingIssue.unsafeFile("binding directory")) { try store.load() }
    }
}

extension Result {
    var failureIssue: Failure? { if case let .failure(issue) = self { issue } else { nil } }
}

@Suite(.serialized) struct ProvisioningProbe {
    @Test func notReadyEngineIsReportedAsSuch() async throws {
        let engine = try FakeEngine()
        engine.mode("env")
        let result = await EngineClient.provisionalStatus(nodePath: "/bin/sh", scriptPath: engine.script, home: engine.root)
        #expect(result.failureIssue == .engineNotReady("x"))
        engine.mode("status")
        let ready = try await EngineClient.provisionalStatus(nodePath: "/bin/sh", scriptPath: engine.script, home: engine.root).get()
        #expect(ready.0.installationId == FakeEngine.installation)
        #expect(ready.1.engineBuild == "sha256:test")
    }
}

/// The pre-mutation check: bound files are re-verified and the engine modules must still hash to
/// the bound build. The expected digest below was computed independently (Python hashlib) with
/// the engine's framing: name NUL byte-count NUL bytes, for each module in order.
@Suite struct LaunchCheck {
    static let vector = "sha256:3cfb231d25ecfa5a1dfc289b12d5594812e7dbd46b0691ffc834362c86bc5def"

    func engineDirectory() throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("warmup-modules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let canonical = try #require(realpath(base.path, nil))
        defer { free(canonical) }
        let root = String(cString: canonical)
        for (name, body) in [("chatgpt-probe.mjs", "probe"), ("router-reader.mjs", "reader"), ("runtime.mjs", "runtime"), ("warmup.mjs", "warmup")] {
            FileManager.default.createFile(atPath: root + "/" + name, contents: Data(body.utf8), attributes: [.posixPermissions: 0o644])
        }
        return root
    }

    @Test func digestMatchesTheEngineFraming() throws {
        let root = try self.engineDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(BindingVerifier.engineBuild(scriptDirectory: root) == Self.vector)
        let binding = EngineBinding(
            nodePath: "/bin/sh", scriptPath: root + "/warmup.mjs", engineBuild: Self.vector, installationId: "install_x", capabilityVersion: 1)
        #expect(BindingVerifier.verifyLaunch(binding) == nil)
        // One replaced module byte, or a missing module, fails the check.
        FileManager.default.createFile(atPath: root + "/runtime.mjs", contents: Data("runtimE".utf8), attributes: [.posixPermissions: 0o644])
        #expect(BindingVerifier.verifyLaunch(binding) == .engineMismatch("engine build"))
        try FileManager.default.removeItem(atPath: root + "/runtime.mjs")
        #expect(BindingVerifier.engineBuild(scriptDirectory: root) == nil)
    }

    @Test func theEntryScriptAndEveryModuleMustBeTheFilesThatWereHashed() throws {
        let root = try self.engineDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let files = FileManager.default
        // A different entry script beside the digested modules is not covered by the digest.
        files.createFile(atPath: root + "/other.mjs", contents: Data("x".utf8))
        #expect(BindingVerifier.verifyLaunch(self.binding(root, "other.mjs")) == .engineMismatch("engine entry script"))
        // A module replaced by a link (same bytes) or made group-writable is refused.
        let binding = self.binding(root, "warmup.mjs")
        let module = root + "/runtime.mjs"
        files.createFile(atPath: root + "/real.mjs", contents: Data("runtime".utf8))
        try files.removeItem(atPath: module)
        try files.createSymbolicLink(atPath: module, withDestinationPath: root + "/real.mjs")
        #expect(BindingVerifier.verifyLaunch(binding) == .unsafeFile("engine module runtime.mjs"))
        try files.removeItem(atPath: module)
        files.createFile(atPath: module, contents: Data("runtime".utf8))
        chmod(module, 0o664)
        #expect(BindingVerifier.verifyLaunch(binding) == .unsafeFile("engine module runtime.mjs"))
        chmod(module, 0o644)
        #expect(BindingVerifier.verifyLaunch(binding) == nil)
    }

    func binding(_ root: String, _ script: String) -> EngineBinding {
        EngineBinding(
            nodePath: "/bin/sh", scriptPath: root + "/" + script, engineBuild: Self.vector, installationId: "install_x",
            capabilityVersion: 1)
    }

    @Test func aChangedEngineRefusesTheMutationWithoutStartingAProcess() async throws {
        let engine = try FakeEngine()
        engine.mode("slowmutation")
        let client = EngineClient(
            binding: engine.binding, home: engine.root, readTimeout: .seconds(10),
            launchCheck: { _ in .engineMismatch("engine build") })
        await client.setCapability(Capability(version: 1, features: ["expected_installation_id"]))
        let result = await client.mutate(.runAll(allowSlotOverlap: false))
        #expect(result.failureIssue == .bindingChanged(BindingIssue.engineMismatch("engine build").description))
        #expect(engine.calls.isEmpty)
    }
}
