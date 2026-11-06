import Testing
import Foundation
@testable import HinterCore

private let t0 = Date(timeIntervalSince1970: 0)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

@Test func firesOnceAfterSilence() {
    let d = TurnDetector()
    d.ingest(Utterance(speaker: .interviewer, text: "What is a mutex?", at: at(0)), isFinal: true)
    #expect(d.tick(now: at(0.5)) == nil)
    #expect(d.tick(now: at(1.3)) == "What is a mutex?")
    #expect(d.tick(now: at(2.0)) == nil)
}

@Test func newSpeechResetsTimer() {
    let d = TurnDetector()
    d.ingest(Utterance(speaker: .interviewer, text: "What is", at: at(0)), isFinal: true)
    d.ingest(Utterance(speaker: .interviewer, text: "a mutex", at: at(0.6)), isFinal: false)
    #expect(d.tick(now: at(1.3)) == nil)
    d.ingest(Utterance(speaker: .interviewer, text: "a mutex?", at: at(1.0)), isFinal: true)
    #expect(d.tick(now: at(2.3)) == "What is a mutex?")
}

@Test func candidateNeverTriggers() {
    let d = TurnDetector()
    d.ingest(Utterance(speaker: .candidate, text: "What do you think?", at: at(0)), isFinal: true)
    #expect(d.tick(now: at(5)) == nil)
}

@Test func pendingPartialDoesNotFire() {
    let d = TurnDetector()
    d.ingest(Utterance(speaker: .interviewer, text: "So what", at: at(0)), isFinal: false)
    #expect(d.tick(now: at(5)) == nil)
}

@Test func voiceActivityHoldsTheTurnOpen() {
    // Whisper gives only finals; ongoing speech is signalled separately.
    let d = TurnDetector(silence: 0.6)
    d.ingest(Utterance(speaker: .interviewer, text: "Расскажите про ваш опыт", at: at(0)), isFinal: true)
    d.speechActivity(.interviewer, at: at(0.5))
    #expect(d.tick(now: at(1.0)) == nil) // still talking, next segment not transcribed yet
    d.ingest(Utterance(speaker: .interviewer, text: "с Kubernetes?", at: at(1.5)), isFinal: true)
    #expect(d.tick(now: at(2.2)) == "Расскажите про ваш опыт с Kubernetes?")
}

@Test func candidateActivityIgnored() {
    let d = TurnDetector(silence: 0.6)
    d.ingest(Utterance(speaker: .interviewer, text: "Что такое Pod?", at: at(0)), isFinal: true)
    d.speechActivity(.candidate, at: at(0.5))
    #expect(d.tick(now: at(0.7)) == "Что такое Pod?")
}
