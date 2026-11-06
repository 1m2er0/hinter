import Testing
import Foundation
@testable import HinterCore

private let sr = 16_000.0
private func tone(_ sec: Double) -> [Float] { (0..<Int(sec * sr)).map { Float(sin(Double($0) * 0.3)) * 0.2 } }
private func silence(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * sr)) }

@Test func emitsSegmentAfterPause() {
    let s = SpeechSegmenter()
    #expect(s.push(silence(0.3) + tone(1.0)).isEmpty)
    let out = s.push(silence(0.6))
    #expect(out.count == 1)
    #expect(abs(Double(out[0].count) / sr - 1.0) < 0.4) // speech plus a little padding, leading silence mostly trimmed
}

@Test func shortBlipIsDropped() {
    let s = SpeechSegmenter()
    #expect(s.push(tone(0.1) + silence(0.8)).isEmpty)
}

@Test func longSpeechIsCutAtMax() {
    let s = SpeechSegmenter()
    let out = s.push(tone(11))
    #expect(out.count == 1)
    #expect(Double(out[0].count) / sr <= 10.1)
}

@Test func chunkedPushEqualsWhole() {
    let s = SpeechSegmenter()
    var out: [[Float]] = []
    let all = tone(1.0) + silence(0.6) + tone(0.8) + silence(0.6)
    for i in stride(from: 0, to: all.count, by: 1000) { out += s.push(Array(all[i..<min(i + 1000, all.count)])) }
    #expect(out.count == 2)
}

@Test func wavHeaderAndSize() {
    let d = wavData([0, 0.5, -0.5, 1], sampleRate: 16_000)
    #expect(d.count == 44 + 8)
    #expect(String(decoding: d.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: d[8..<12], as: UTF8.self) == "WAVE")
}

@Test func whisperHallucinationsFiltered() {
    #expect(cleanWhisperText(" Продолжение следует... ") == nil)
    #expect(cleanWhisperText("Субтитры сделал DimaTorzok") == nil)
    #expect(cleanWhisperText("[музыка]") == nil)
    #expect(cleanWhisperText("Thank you.") == nil)
    #expect(cleanWhisperText(" Под получил статус OOMKilled. ") == "Под получил статус OOMKilled.")
}

@Test func whisperPromptHasContextTermsAndIsShort() {
    let p = whisperPrompt(CandidateContext(resume: "Go, ClickHouse, gRPC. Руководил командой.", job: "SRE: Kubernetes, ArgoCD"))
    for t in ["ClickHouse", "gRPC", "ArgoCD", "OOMKilled", "CrashLoopBackOff"] { #expect(p.contains(t), "missing \(t)") }
    #expect(!p.contains("Руководил"))
    #expect(p.count <= 600) // whisper initial prompt is ~224 tokens
    let huge = whisperPrompt(CandidateContext(resume: (0..<500).map { "Term\($0)" }.joined(separator: " "), job: ""))
    #expect(huge.count <= 600)
}
