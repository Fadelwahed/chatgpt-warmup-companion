import Foundation

/// Why a reply could not be accepted. None of these is ever shown as success.
public enum ClientIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidCommand
    case featureUnavailable(String)
    case environmentUnavailable
    case launchFailed
    case timedOut
    case outputTooLarge
    case malformedOutput
    case protocolMismatch
    case commandMismatch
    case exitOutcomeMismatch
    case installationMismatch
    case mutationInFlight
    /// A mutation's outcome is unknown (child lost, malformed or oversize reply). The engine may
    /// have acted. The app must reconcile with a read before offering a fresh action.
    case mutationOutcomeUnknown
    case engineNotReady(String)
    /// A previous change ended with an unknown outcome; a successful status read must come first.
    case reconcileRequired
    /// The bound engine files changed since the binding was verified; no process was started.
    case bindingChanged(String)

    public var description: String {
        switch self {
        case .invalidCommand: "The request was refused before starting the engine"
        case let .featureUnavailable(feature): "This engine does not support \(feature)"
        case .environmentUnavailable: "The user home directory could not be resolved"
        case .launchFailed: "The engine could not be started"
        case .timedOut: "The engine did not answer within 10 seconds"
        case .outputTooLarge: "The engine reply exceeded the size limit"
        case .malformedOutput: "The engine reply was not valid"
        case .protocolMismatch: "The engine uses an unsupported protocol"
        case .commandMismatch: "The engine answered a different command"
        case .exitOutcomeMismatch: "The engine exit status disagreed with its result"
        case .installationMismatch: "The engine installation changed"
        case .mutationInFlight: "Another change is still running"
        case .mutationOutcomeUnknown: "The result of the last change is unknown; refresh before trying again"
        case .reconcileRequired: "Refresh status before making another change"
        case let .engineNotReady(reason): "The engine is not ready: \(reason.replacingOccurrences(of: "_", with: " "))"
        case let .bindingChanged(issue): "The engine files changed since they were verified: \(issue)"
        }
    }
}

public struct EngineReply<Payload: Sendable>: Sendable {
    public let envelope: Envelope
    public let payload: Payload?
    public let exitCode: Int32
    public let stderrBytes: Int
}

/// Validates engine output against the protocol contract before anything is displayed.
public enum ReplyValidator {
    public static let readTimeout: Duration = .seconds(10)

    static let exitOutcomes: [Int32: Set<String>] = [
        0: ["ready", "idle", "success"], 1: ["partial"], 2: ["blocked"], 3: ["busy"], 4: ["no_work"],
    ]

    public static func envelope(
        from output: ProcessOutput, command: EngineCommand, expectedInstallation: String?
    ) -> Result<Envelope, ClientIssue> {
        if output.stdoutOverflow { return .failure(.outputTooLarge) }
        if output.timedOut { return .failure(.timedOut) }
        var data = output.stdout
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty, !data.contains(0x0A),
              let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any],
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return .failure(.malformedOutput) }
        guard envelope.protocolVersion == 1 else { return .failure(.protocolMismatch) }
        guard envelope.command == command.engineName else { return .failure(.commandMismatch) }
        guard let allowed = Self.exitOutcomes[output.exitCode], allowed.contains(envelope.outcome) else {
            return .failure(.exitOutcomeMismatch)
        }
        if let expectedInstallation, envelope.installationId != expectedInstallation { return .failure(.installationMismatch) }
        return .success(envelope)
    }

    public static func payload<Payload: Decodable>(_ type: Payload.Type, from output: ProcessOutput) -> Payload? {
        var data = output.stdout
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// The only path from the app to the engine. Reads are bounded by a timeout; at most one
/// mutation runs at a time and is never retried, queued or killed by the app.
public actor EngineClient {
    public nonisolated let binding: EngineBinding
    private let runner: ProcessRunner
    private let home: String?
    private let readTimeout: Duration
    private var mutating = false
    private var needsReconcile = false
    /// Bumped whenever an unknown outcome is recorded; only a status read that started after the
    /// latest bump can reconcile it.
    private var unknownGeneration = 0
    private var capability: Capability?
    /// Checked immediately before every mutation starts a process.
    private let launchCheck: @Sendable (EngineBinding) -> BindingIssue?

    public init(
        binding: EngineBinding, runner: ProcessRunner = ProcessRunner(),
        home: String? = EngineEnvironment.currentUserHome(), readTimeout: Duration = ReplyValidator.readTimeout,
        launchCheck: @escaping @Sendable (EngineBinding) -> BindingIssue? = BindingVerifier.verifyLaunch
    ) {
        self.binding = binding
        self.runner = runner
        self.home = home
        self.readTimeout = readTimeout
        self.launchCheck = launchCheck
    }

    /// Capability observed in the latest valid status; gates every non-status command.
    public func setCapability(_ capability: Capability?) { self.capability = capability }

    public var isMutating: Bool { self.mutating }
    public var reconcileRequired: Bool { self.needsReconcile }

    public func read<Payload: Decodable & Sendable>(_ command: EngineCommand, as type: Payload.Type) async -> Result<EngineReply<Payload>, ClientIssue> {
        guard !command.isMutation else { return .failure(.invalidCommand) }
        let startedAt = self.unknownGeneration
        let result = await self.invoke(command, as: type)
        // Only a fresh, valid, ready status that began after the unknown outcome reconciles it.
        if command == .status, case let .success(reply) = result, reply.envelope.outcome == "ready", startedAt == self.unknownGeneration {
            self.needsReconcile = false
        }
        return result
    }

    /// Runs one guarded mutation. Never retried or queued; a second call while one is running,
    /// or before an unknown outcome has been reconciled, is refused without starting a process.
    public func mutate<Payload: MutationPayload>(_ command: EngineCommand, as type: Payload.Type) async -> Result<EngineReply<Payload>, ClientIssue> {
        guard command.isMutation else { return .failure(.invalidCommand) }
        guard !self.mutating else { return .failure(.mutationInFlight) }
        guard !self.needsReconcile else { return .failure(.reconcileRequired) }
        self.mutating = true
        defer { self.mutating = false }
        let result = await self.invoke(command, as: type)
        switch result {
        case let .success(reply) where !Self.complete(reply):
            self.recordUnknown() // an accepted envelope without its result fields proves nothing
            return .failure(.mutationOutcomeUnknown)
        case .success: return result
        case .failure(.invalidCommand), .failure(.featureUnavailable), .failure(.environmentUnavailable), .failure(.launchFailed),
            .failure(.bindingChanged):
            return result // refused before the engine could act
        case .failure:
            self.recordUnknown()
            return .failure(.mutationOutcomeUnknown)
        }
    }

    private func recordUnknown() {
        self.needsReconcile = true
        self.unknownGeneration += 1
    }

    private static func complete<Payload: MutationPayload>(_ reply: EngineReply<Payload>) -> Bool {
        guard let payload = reply.payload else { return false }
        // A refusal carries only the envelope; an accepted change must carry its result fields.
        return !["ready", "idle", "success"].contains(reply.envelope.outcome) || payload.isComplete
    }

    public func mutate(_ command: EngineCommand) async -> Result<EngineReply<Envelope>, ClientIssue> {
        await self.mutate(command, as: Envelope.self)
    }

    /// Read-only status through explicit paths, used only by the operator's provisioning step
    /// before any installation ID is known. It never writes a binding by itself.
    public static func provisionalStatus(
        nodePath: String, scriptPath: String, runner: ProcessRunner = ProcessRunner(),
        home: String? = EngineEnvironment.currentUserHome()
    ) async -> Result<(Envelope, EngineStatus), ClientIssue> {
        guard let home else { return .failure(.environmentUnavailable) }
        let output: ProcessOutput
        do {
            output = try await runner.run(
                executable: nodePath, arguments: [scriptPath, "status"], environment: EngineEnvironment.minimal(home: home),
                workingDirectory: (scriptPath as NSString).deletingLastPathComponent,
                timeout: ReplyValidator.readTimeout, terminateOnOverflow: true)
        } catch { return .failure(.launchFailed) }
        switch ReplyValidator.envelope(from: output, command: .status, expectedInstallation: nil) {
        case let .failure(issue): return .failure(issue)
        case let .success(envelope):
            guard envelope.outcome == "ready" else { return .failure(.engineNotReady(envelope.reason)) }
            guard envelope.installationId != nil, let status = ReplyValidator.payload(EngineStatus.self, from: output) else {
                return .failure(.malformedOutput)
            }
            return .success((envelope, status))
        }
    }

    private func invoke<Payload: Decodable & Sendable>(_ command: EngineCommand, as type: Payload.Type) async -> Result<EngineReply<Payload>, ClientIssue> {
        if command != .status {
            // Every command other than status needs a verified binding and its capability.
            guard let capability = self.capability else { return .failure(.featureUnavailable("a verified engine binding")) }
            let features = Set(capability.features)
            if let missing = command.requiredFeatures.first(where: { !features.contains($0) }) { return .failure(.featureUnavailable(missing)) }
        }
        // An earlier verified reply is no authority for what runs now: before a mutation starts a
        // process, the files are checked again and the modules must still hash to the bound build.
        if command.isMutation, let issue = self.launchCheck(self.binding) { return .failure(.bindingChanged(issue.description)) }
        guard let args = try? command.arguments(installationId: command.isMutation ? self.binding.installationId : nil) else {
            return .failure(.invalidCommand)
        }
        guard let home = self.home else { return .failure(.environmentUnavailable) }
        let output: ProcessOutput
        do {
            output = try await self.runner.run(
                executable: self.binding.nodePath,
                arguments: [self.binding.scriptPath] + args,
                environment: EngineEnvironment.minimal(home: home),
                workingDirectory: self.binding.scriptDirectory,
                timeout: command.isMutation ? nil : self.readTimeout,
                terminateOnOverflow: !command.isMutation)
        } catch {
            return .failure(.launchFailed)
        }
        switch ReplyValidator.envelope(from: output, command: command, expectedInstallation: self.binding.installationId) {
        case let .failure(issue): return .failure(issue)
        case let .success(envelope):
            let payload = ReplyValidator.payload(type, from: output)
            if envelope.outcome == "ready" || envelope.outcome == "idle", payload == nil, Payload.self != Envelope.self {
                return .failure(.malformedOutput)
            }
            return .success(EngineReply(envelope: envelope, payload: payload, exitCode: output.exitCode, stderrBytes: output.stderr.count))
        }
    }
}
