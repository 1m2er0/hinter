import Testing
import Foundation
@testable import HinterCore

private let now = Date(timeIntervalSince1970: 10_000)
private let ctx = CandidateContext(resume: "RESUME_TEXT", job: "JOB_TEXT")
private let transcript = [
    Utterance(speaker: .interviewer, text: "old question", at: now.addingTimeInterval(-200)),
    Utterance(speaker: .candidate, text: "my answer", at: now.addingTimeInterval(-60)),
    Utterance(speaker: .interviewer, text: "What is a mutex?", at: now.addingTimeInterval(-5)),
]

@Test func questionPrompt() {
    let p = buildPrompt(mode: .question, context: ctx, transcript: transcript, now: now, imagePath: nil)
    #expect(p.system.contains("RESUME_TEXT") && p.system.contains("JOB_TEXT"))
    #expect(p.system.contains("3–5") && p.system.contains("тезис"))
    #expect(p.system.contains("языке вопроса"))
    #expect(!p.user.contains("old question"))
    #expect(p.user.contains("Кандидат: my answer") && p.user.contains("Интервьюер: What is a mutex?"))
    #expect(p.imagePath == nil)
}

@Test func liveCodePrompt() {
    let img = URL(fileURLWithPath: "/tmp/x.png")
    let p = buildPrompt(mode: .liveCode, context: ctx, transcript: transcript, now: now, imagePath: img)
    #expect(p.system.contains("код") && p.system.contains("1–2 строки"))
    #expect(p.imagePath == img)
}

@Test func autoTriggerNamesQuestionAndAllowsSkip() {
    let p = buildPrompt(mode: .question, context: ctx, transcript: transcript, now: now, imagePath: nil, question: "What is a mutex?")
    #expect(p.user.hasSuffix("Вопрос интервьюера: What is a mutex?"))
    #expect(p.system.contains("выведи один символ «—»"))
    let manual = buildPrompt(mode: .question, context: ctx, transcript: transcript, now: now, imagePath: nil)
    #expect(!manual.system.contains("«—»"))
}

@Test func skipAnswerRecognised() {
    #expect(isSkipAnswer(" — \n"))
    #expect(isSkipAnswer("-"))
    #expect(!isSkipAnswer("— Мьютекс это блокировка"))
}

@Test func nonTechnicalQuestionsAreAnsweredToo() {
    // Regression: "не технический вопрос → —" made the model skip "почему небо голубое" and behavioral questions.
    let p = buildPrompt(mode: .question, context: ctx, transcript: transcript, now: now, imagePath: nil, question: "Почему небо голубое?")
    #expect(!p.system.contains("не технический"))
    #expect(p.system.contains("любой вопрос"))
}
