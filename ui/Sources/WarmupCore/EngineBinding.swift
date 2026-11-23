import CryptoKit
import Foundation

/// The reviewed link between this app and one engine installation. Written only by the explicit
/// provisioning step, never inferred at launch. Holds no credentials, accounts or schedule state.
public struct EngineBinding: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let supportedCapability = 1

    public let schemaVersion: Int
    public let nodePath: String
    public let scriptPath: String
    public let engineBuild: String
    public let installationId: String
    public let capabilityVersion: Int

    public init(nodePath: String, scriptPath: String, engineBuild: String, installationId: String, capabilityVersion: Int) {
        self.schemaVersion = Self.schemaVersion
        self.nodePath = nodePath
        self.scriptPath = scriptPath
        self.engineBuild = engineBuild
        self.installationId = installationId
        self.capabilityVersion = capabilityVersion
    }

    public var scriptDirectory: String { (self.scriptPath as NSString).deletingLastPathComponent }
}

public enum BindingIssue: Error, Equatable, Sendable, CustomStringConvertible {
    case missing
    case corrupt
    case unsafeFile(String)
    case pathNotCanonical(String)
    case engineMismatch(String)

    public var description: String {
        switch self {
        case .missing: "Setup required: no reviewed engine binding"
        case .corrupt: "Setup required: the engine binding could not be read"
        case let .unsafeFile(what): "Engine binding refused: unsafe \(what)"
        case let .pathNotCanonical(what): "Engine binding refused: \(what) is not a canonical path"
        case let .engineMismatch(what): "Engine does not match its binding: \(what)"
        }
    }
}

/// Private, atomic storage for the binding: a 0700 directory and a 0600 file owned by this user.
public struct BindingStore: Sendable {
    public let directory: URL
    public var file: URL { self.directory.appendingPathComponent("engine-binding.json") }

    public init(directory: URL) { self.directory = directory }

    public static func defaultStore() -> BindingStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return BindingStore(directory: support.appendingPathComponent("local.warmup.menu", isDirectory: true))
    }

    public func load() throws(BindingIssue) -> EngineBinding {
        var directory = stat()
        guard lstat(self.directory.path, &directory) == 0 else { throw .missing }
        guard (directory.st_mode & S_IFMT) == S_IFDIR, directory.st_uid == getuid(), (directory.st_mode & 0o077) == 0 else {
            throw .unsafeFile("binding directory")
        }
        // Open without following links, then check and read the same descriptor (no TOCTOU).
        let fd = open(self.file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? .missing : .unsafeFile("binding file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o077) == 0, info.st_size < 16384 else {
            throw .unsafeFile("binding file")
        }
        guard let data = try? handle.readToEnd(),
              let binding = try? JSONDecoder().decode(EngineBinding.self, from: data),
              binding.schemaVersion == EngineBinding.schemaVersion else { throw .corrupt }
        return binding
    }

    public func save(_ binding: EngineBinding) throws {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(self.directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw BindingIssue.unsafeFile("binding directory")
        }
        chmod(self.directory.path, 0o700)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(binding)
        let temp = self.directory.appendingPathComponent(".engine-binding.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              let written = FileHandle(forWritingAtPath: temp.path) else {
            throw BindingIssue.unsafeFile("binding write")
        }
        try written.synchronize()
        try written.close()
        guard rename(temp.path, self.file.path) == 0 else {
            unlink(temp.path)
            throw BindingIssue.unsafeFile("binding write")
        }
    }
}

public enum BindingVerifier {
    /// The script must be canonical. The Node path is the exact path the engine itself reports
    /// (the LaunchAgent uses the same one); it may be a package-manager link, but its target
    /// must be a regular executable that only root or this user can change.
    public static func checkFiles(nodePath: String, scriptPath: String) -> BindingIssue? {
        guard nodePath.hasPrefix("/"), scriptPath.hasPrefix("/") else { return .pathNotCanonical("engine path") }
        guard let script = realpath(scriptPath, nil) else { return .unsafeFile("engine script") }
        defer { free(script) }
        guard String(cString: script) == scriptPath else { return .pathNotCanonical("engine script") }
        if let issue = Self.checkOwnedRegular(scriptPath, what: "engine script") { return issue }
        guard let node = realpath(nodePath, nil) else { return .unsafeFile("Node executable") }
        defer { free(node) }
        let target = String(cString: node)
        if let issue = Self.checkOwnedRegular(target, what: "Node executable") { return issue }
        guard access(target, X_OK) == 0 else { return .unsafeFile("Node executable") }
        return nil
    }

    /// The engine's module files, in the order its build digest covers them (warmup.mjs).
    public static let engineModules = ["chatgpt-probe.mjs", "router-reader.mjs", "runtime.mjs", "warmup.mjs"]
    /// The module Node runs; the others are its imports, resolved beside it.
    public static let entryModule = "warmup.mjs"

    /// The engine build digest recomputed from the files beside the script: SHA-256 over each
    /// module's name, byte count and bytes, exactly as the engine reports it. Nil if unreadable.
    public static func engineBuild(scriptDirectory: String) -> String? {
        var hasher = SHA256()
        for name in self.engineModules {
            guard let bytes = FileManager.default.contents(atPath: scriptDirectory + "/" + name) else { return nil }
            hasher.update(data: Data("\(name)\0\(bytes.count)\0".utf8))
            hasher.update(data: bytes)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Run before every mutation: the bound files are still safe, and the engine modules still
    /// hash to the build that was verified when the binding was made.
    /// The bound script must be the digested entry point (`warmup.mjs`), and every module must be a
    /// regular file (not a link) that only root or this user can change, so the bytes hashed here
    /// are the bytes Node loads. A same-user change between this check and the launch is outside
    /// what the app can prevent (README, Limits).
    public static func verifyLaunch(_ binding: EngineBinding) -> BindingIssue? {
        if let issue = self.checkFiles(nodePath: binding.nodePath, scriptPath: binding.scriptPath) { return issue }
        guard (binding.scriptPath as NSString).lastPathComponent == self.entryModule else {
            return .engineMismatch("engine entry script")
        }
        for name in self.engineModules {
            if let issue = Self.checkOwnedRegular(binding.scriptDirectory + "/" + name, what: "engine module \(name)") {
                return issue
            }
        }
        guard self.engineBuild(scriptDirectory: binding.scriptDirectory) == binding.engineBuild else {
            return .engineMismatch("engine build")
        }
        return nil
    }

    private static func checkOwnedRegular(_ path: String, what: String) -> BindingIssue? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .unsafeFile(what) }
        guard info.st_uid == 0 || info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { return .unsafeFile(what) }
        return nil
    }

    /// Compares one status observation with the binding. Any difference keeps controls off.
    public static func compare(_ binding: EngineBinding, envelope: Envelope, status: EngineStatus) -> BindingIssue? {
        guard envelope.installationId == binding.installationId else { return .engineMismatch("installation") }
        guard let capability = status.capability, capability.version == binding.capabilityVersion,
              capability.version == EngineBinding.supportedCapability else { return .engineMismatch("capability") }
        guard status.engineBuild == binding.engineBuild else { return .engineMismatch("engine build") }
        guard status.engine?.nodePath == binding.nodePath, status.engine?.scriptPath == binding.scriptPath else {
            return .engineMismatch("engine paths")
        }
        return nil
    }
}
