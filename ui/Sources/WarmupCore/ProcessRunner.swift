import Foundation

/// Raw result of one engine child process. Captures are already cut to their limits.
public struct ProcessOutput: Sendable, Equatable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32
    public var stdoutOverflow: Bool
    public var stderrOverflow: Bool
    public var timedOut: Bool
    public var terminatedBySignal: Bool
}

public enum ProcessLaunchError: Error, Equatable, Sendable {
    case notAbsolute
    case launchFailed
}

/// Accumulates at most `limit` bytes and records whether more arrived. Draining continues past
/// the limit so a chatty child can never block on a full pipe.
final class BoundedSink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var overflowed = false
    let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Returns false once the limit has been exceeded.
    func append(_ chunk: Data) -> Bool {
        self.lock.withLock {
            let room = self.limit - self.data.count
            if chunk.count > room {
                if room > 0 { self.data.append(chunk.prefix(room)) }
                self.overflowed = true
            } else {
                self.data.append(chunk)
            }
            return !self.overflowed
        }
    }

    var snapshot: (Data, Bool) { self.lock.withLock { (self.data, self.overflowed) } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { self.lock.withLock { self.value = true } }
    var isSet: Bool { self.lock.withLock { self.value } }
}

/// Process objects are not Sendable; this box confines every use to the runner below.
private final class ChildBox: @unchecked Sendable {
    let process = Process()
}

/// Runs one engine command as a direct child: absolute executable, structured arguments,
/// no shell, explicit environment. Read-only calls pass a timeout and an overflow kill switch;
/// mutations pass neither, so the app never shortens or interrupts an engine mutation.
public struct ProcessRunner: Sendable {
    /// The engine allows a 1 MiB JSON body plus its trailing newline.
    public static let stdoutLimit = (1 << 20) + 1
    public static let stderrLimit = 64 << 10

    static let killGrace: Duration = .seconds(2)
    /// After the deadline and kill grace, how long the pipes may still drain. A helper process
    /// that inherited a pipe and outlives the engine cannot hold the reply open past this.
    static let drainGrace: Duration = .seconds(1)

    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        timeout: Duration?,
        terminateOnOverflow: Bool
    ) async throws -> ProcessOutput {
        guard executable.hasPrefix("/"), workingDirectory.hasPrefix("/") else { throw ProcessLaunchError.notAbsolute }
        let box = ChildBox()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let out = BoundedSink(limit: Self.stdoutLimit), err = BoundedSink(limit: Self.stderrLimit)
        let timedOut = Flag()
        let drainDeadline = timeout.map { DispatchTime.now() + Self.seconds($0 + Self.killGrace + Self.drainGrace) }
        let stdoutDone = DispatchGroup(), stderrDone = DispatchGroup()
        let overflowKill: @Sendable () -> Void = {
            if terminateOnOverflow, box.process.isRunning { box.process.terminate() }
        }
        // Both readers are set up before launch: if a descriptor cannot be prepared, nothing starts.
        guard
            let stdoutDrain = PipeDrain(
                stdoutPipe.fileHandleForReading, into: out, done: stdoutDone, onOverflow: overflowKill)
        else { throw ProcessLaunchError.launchFailed }
        // Excess diagnostics are drained and discarded; stderr is never parsed, so it never kills.
        guard let stderrDrain = PipeDrain(stderrPipe.fileHandleForReading, into: err, done: stderrDone, onOverflow: {})
        else {
            await Self.stop([stdoutDrain], groups: [stdoutDone])
            throw ProcessLaunchError.launchFailed
        }

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ProcessLaunchError.launchFailed)
                    return
                }
                // The parent must not hold the write ends, or the readers never see EOF.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                if let timeout {
                    Task.detached {
                        try? await Task.sleep(for: timeout)
                        guard box.process.isRunning else { return }
                        timedOut.set()
                        box.process.terminate()  // SIGTERM to this exact owned child only
                        try? await Task.sleep(for: Self.killGrace)
                        if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                    }
                }
            }
        } catch {
            // Launch failed: the readers never see EOF (the parent still holds the write ends).
            await Self.stop([stdoutDrain, stderrDrain], groups: [stdoutDone, stderrDone])
            throw error
        }
        let stdoutDrained = await Self.wait(stdoutDone, until: drainDeadline)
        let stderrDrained = await Self.wait(stderrDone, until: drainDeadline)
        if !stdoutDrained || !stderrDrained {
            // A helper still holds a pipe open: stop reading and close our descriptors now, so no
            // reader or descriptor outlives this call.
            timedOut.set()
            await Self.stop([stdoutDrain, stderrDrain], groups: [stdoutDone, stderrDone])
        }
        let (stdout, stdoutOverflow) = out.snapshot
        let (stderr, stderrOverflow) = err.snapshot
        return ProcessOutput(
            stdout: stdout, stderr: stderr, exitCode: status,
            stdoutOverflow: stdoutOverflow, stderrOverflow: stderrOverflow,
            timedOut: timedOut.isSet, terminatedBySignal: process.terminationReason == .uncaughtSignal)
    }

    /// Cancels the readers and waits until each has closed its descriptor. A cancelled source always
    /// runs its cancel handler (close and leave), so this wait is bounded and returns.
    private static func stop(_ drains: [PipeDrain], groups: [DispatchGroup]) async {
        drains.forEach { $0.cancel() }
        for group in groups { _ = await Self.wait(group, until: nil) }
    }

    /// True when the group finished, false when `deadline` passed first. No deadline waits forever.
    private static func wait(_ group: DispatchGroup, until deadline: DispatchTime?) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            guard let deadline else {
                group.notify(queue: .global()) { continuation.resume(returning: true) }
                return
            }
            DispatchQueue.global().async { continuation.resume(returning: group.wait(timeout: deadline) == .success) }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// The child gets only what Node needs to start. No credentials, proxies or TZ are passed;
/// the engine resolves the Mac's zone itself.
public enum EngineEnvironment {
    public static func minimal(home: String) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin", "LANG": "C"]
    }

    public static func currentUserHome() -> String? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.hasPrefix("/") ? home : nil
    }
}

/// Reads one pipe without blocking a thread: a dispatch read source on a duplicate of the read
/// descriptor. Cancelling it (at EOF, on a read error, or at the drain deadline) closes that
/// duplicate and leaves the group exactly once.
final class PipeDrain: @unchecked Sendable {
    private let source: DispatchSourceRead

    /// Nil when the descriptor cannot be duplicated or made non-blocking; the caller must not launch.
    init?(_ handle: FileHandle, into sink: BoundedSink, done: DispatchGroup, onOverflow: @escaping @Sendable () -> Void)
    {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { return nil }
        let flags = fcntl(descriptor, F_GETFL)
        // Close-on-exec: the engine (or anything it starts) must never inherit our read end.
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
        else {
            close(descriptor)
            return nil
        }
        done.enter()
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: DispatchQueue(label: "local.warmup.pipe-drain"))
        source.setEventHandler { [source] in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if !sink.append(Data(buffer[0..<count])) { onOverflow() }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(descriptor)
            done.leave()
        }
        self.source = source
        source.resume()
    }

    func cancel() { self.source.cancel() }
}
