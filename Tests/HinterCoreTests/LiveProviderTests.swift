import Testing
import Foundation
@testable import HinterCore

// Opt-in: HH_LIVE=1 swift test --filter Live  (hits real providers)
private let live = ProcessInfo.processInfo.environment["HH_LIVE"] == "1"
private let req = PromptRequest(system: "Отвечай одним словом.", user: "Столица Франции?", imagePath: nil)

private func collect(_ p: Provider) async throws -> String { try await p.stream(req).reduce("", +) }

@Test(.enabled(if: live)) func liveNIM() async throws {
    let rtf = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../nim_api_key.rtf"))
    let out = try await collect(NIMProvider(key: extractAPIKey(fromRTF: rtf)))
    #expect(out.contains("Париж"), "got: \(out)")
}

@Test(.enabled(if: live)) func liveClaude() async throws {
    #expect(try await collect(ClaudeCLIProvider()).contains("Париж"))
}

@Test(.enabled(if: live)) func missingBinaryIsReported() async {
    await #expect(throws: ProviderError.notInstalled("definitely-not-a-cli")) {
        for try await _ in runCLI("definitely-not-a-cli", args: [], parse: { _ in nil }) {}
    }
}

@Test(.enabled(if: live)) func liveNIMSkipsNonQuestion() async throws {
    let rtf = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../nim_api_key.rtf"))
    let nim = NIMProvider(key: try extractAPIKey(fromRTF: rtf))
    let ctx = CandidateContext(resume: "Backend, Go, 5 лет", job: "Senior Go developer")
    func ask(_ q: String) async throws -> String {
        let t = [Utterance(speaker: .interviewer, text: q, at: Date())]
        return try await nim.stream(buildPrompt(mode: .question, context: ctx, transcript: t, now: Date(), imagePath: nil, question: q)).reduce("", +)
    }
    #expect(isSkipAnswer(try await ask("Отлично, хорошо, понятно. Идём дальше.")))
    #expect(!isSkipAnswer(try await ask("Что такое горутина и чем она отличается от потока?")))
}

// HH_LIVE=1 HH_WAVS=/path/a.wav:/path/b.wav — real whisper-server round trip.
@Test(.enabled(if: live && ProcessInfo.processInfo.environment["HH_WAVS"] != nil)) func liveWhisper() async throws {
    let model = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/HinterHind/models/ggml-large-v3-turbo-q5_0.bin")
    let server = WhisperServer(model: model, port: 18_179)
    let t0 = Date()
    try await server.start()
    print("server ready in \(Date().timeIntervalSince(t0))s")
    defer { server.stop() }
    let prompt = whisperPrompt(CandidateContext(resume: "", job: ""))
    for path in ProcessInfo.processInfo.environment["HH_WAVS"]!.split(separator: ":") {
        let t = Date()
        let text = try await server.transcribe(Data(contentsOf: URL(fileURLWithPath: String(path))), language: "ru", prompt: prompt)
        print(String(format: "%.2fs", Date().timeIntervalSince(t)), text)
        #expect(!text.isEmpty)
    }
}
