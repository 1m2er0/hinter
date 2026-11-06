import Foundation

public protocol Provider: Sendable {
    var name: String { get }
    func stream(_ req: PromptRequest) -> AsyncThrowingStream<String, Error>
}

public enum ProviderKind: String, CaseIterable, Sendable { case claude, codex, nim }

public func makeProvider(_ kind: ProviderKind) -> Provider {
    switch kind {
    case .claude: ClaudeCLIProvider()
    case .codex: CodexCLIProvider()
    case .nim: NIMProvider()
    }
}

/// Apps launched from Finder get a minimal PATH, so look in the usual install dirs too.
func findBinary(_ name: String) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
    return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.withLock { data.append(d) } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Runs a CLI and maps its JSONL stdout through `parse`. Cancelling the stream kills the process.
func runCLI(_ name: String, args: [String], timeout: Duration = .seconds(120),
            parse: @escaping @Sendable (String) throws -> StreamEvent?) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { cont in
        guard let bin = findBinary(name) else { cont.finish(throwing: ProviderError.notInstalled(name)); return }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.temporaryDirectory // keep project CLAUDE.md/AGENTS.md out
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/bin", "/bin"] + [env["PATH"] ?? ""]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe(), stderrText = LockedData()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        // Drain stderr concurrently: a full stderr pipe blocks the child before it writes stdout.
        err.fileHandleForReading.readabilityHandler = { stderrText.append($0.availableData) }
        let task = Task {
            defer { err.fileHandleForReading.readabilityHandler = nil }
            do {
                try p.run()
                // Cancelled before run() → onTermination saw no process; kill it now.
                if Task.isCancelled { p.terminate(); return }
                let watchdog = Task { try await Task.sleep(for: timeout); p.terminate() }
                defer { watchdog.cancel() }
                for try await line in out.fileHandleForReading.bytes.lines {
                    switch try parse(line) {
                    case .text(let t)?: cont.yield(t)
                    case .done?: cont.finish(); return
                    case nil: continue
                    }
                }
                p.waitUntilExit()
                if p.terminationReason == .uncaughtSignal { throw ProviderError.failed("\(name): превышено время ожидания или процесс прерван") }
                if p.terminationStatus != 0 {
                    let msg = stderrText.string
                    throw ProviderError.failed(msg.isEmpty ? "\(name) exited \(p.terminationStatus)" : msg)
                }
                cont.finish()
            } catch { cont.finish(throwing: error) }
        }
        cont.onTermination = { _ in task.cancel(); if p.isRunning { p.terminate() } }
    }
}

public struct ClaudeCLIProvider: Provider {
    public let name = "Claude"
    public func stream(_ req: PromptRequest) -> AsyncThrowingStream<String, Error> {
        var user = req.user
        if let img = req.imagePath { user += "\n\nСкриншот экрана: \(img.path) — прочитай его." }
        return runCLI("claude", args: ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                       "--allowedTools", "Read", "--system-prompt", req.system, user],
                      parse: parseClaudeStreamJSONLine)
    }
}

public struct CodexCLIProvider: Provider {
    public let name = "Codex"
    public func stream(_ req: PromptRequest) -> AsyncThrowingStream<String, Error> {
        var args = ["exec", "--json", "--skip-git-repo-check"]
        if let img = req.imagePath { args += ["-i", img.path] }
        args.append("\(req.system)\n\n---\n\n\(req.user)")
        return runCLI("codex", args: args, parse: parseCodexJSONLine)
    }
}
