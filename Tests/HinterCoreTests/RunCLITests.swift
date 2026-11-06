import Testing
@testable import HinterCore

@Test(.timeLimit(.minutes(1))) func stderrFloodDoesNotDeadlock() async throws {
    // >64KB on stderr used to block the child before it wrote stdout.
    let s = runCLI("sh", args: ["-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo done"],
                   parse: { $0 == "done" ? .text("ok") : nil })
    #expect(try await s.reduce("", +) == "ok")
}
