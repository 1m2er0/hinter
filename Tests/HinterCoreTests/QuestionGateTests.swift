import Testing
import Foundation
@testable import HinterCore

private let t0 = Date(timeIntervalSince1970: 0)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private func iv(_ text: String, _ s: TimeInterval) -> Utterance { Utterance(speaker: .interviewer, text: text, at: at(s)) }

@Test func statementDoesNotTrigger() {
    let d = TurnDetector()
    d.ingest(iv("Хорошо, понятно. Спасибо.", 0), isFinal: true)
    #expect(d.tick(now: at(5)) == nil)
}

@Test func questionTriggersWithWholeTurn() {
    let d = TurnDetector()
    d.ingest(iv("Окей.", 0), isFinal: true)
    d.ingest(iv("Расскажите, как работает сборщик мусора в Java", 0.5), isFinal: true)
    #expect(d.tick(now: at(1.0)) == nil) // still within pause
    #expect(d.tick(now: at(2.0)) == "Окей. Расскажите, как работает сборщик мусора в Java")
    #expect(d.tick(now: at(3.0)) == nil)
}

@Test func englishQuestionMarkTriggers() {
    let d = TurnDetector()
    d.ingest(iv("Have you used Kafka in production?", 0), isFinal: true)
    #expect(d.tick(now: at(2)) == "Have you used Kafka in production?")
}

@Test func nonQuestionTurnIsDropped() {
    let d = TurnDetector()
    d.ingest(iv("Отлично, идём дальше.", 0), isFinal: true)
    #expect(d.tick(now: at(2)) == nil)
    d.ingest(iv("Почему вы выбрали Postgres?", 3), isFinal: true)
    #expect(d.tick(now: at(5)) == "Почему вы выбрали Postgres?") // earlier statement not glued on
}

@Test func looksLikeQuestionHeuristic() {
    #expect(looksLikeQuestion("What is a mutex"))
    #expect(looksLikeQuestion("Объясните разницу между процессом и потоком"))
    #expect(looksLikeQuestion("can you walk me through your last project"))
    #expect(looksLikeQuestion("Сколько будет стоить такой запрос"))
    #expect(!looksLikeQuestion("Понятно, спасибо"))
    #expect(!looksLikeQuestion("Хорошо"))
    #expect(!looksLikeQuestion("This is great, thanks"))
    #expect(looksLikeQuestion("Is it thread safe"))
}

private func me(_ text: String, _ s: TimeInterval) -> Utterance { Utterance(speaker: .candidate, text: text, at: at(s)) }

@Test func micEchoOfInterviewerIsDetected() {
    let q = [iv("Расскажите, как работает сборщик мусора в Java", 10)]
    #expect(isEcho(me("как работает сборщик мусора", 10.4), interviewer: q))        // verbatim slice
    #expect(isEcho(me("расскажите как работаешь сборщик мусор в жабе", 10.8), interviewer: q)) // noisy re-recognition
    #expect(!isEcho(me("Сборщик мусора в Java работает по поколениям", 14), interviewer: q))    // later answer reusing words
    #expect(!isEcho(me("Я бы начал с поколений и stop the world пауз", 10.5), interviewer: q)) // talking over, own words
    #expect(!isEcho(me("да", 10.2), interviewer: q))                                         // too short to judge
}

@Test func tooShortIsNotAQuestion() {
    #expect(!looksLikeQuestion("Алло? Алло?"))
    #expect(looksLikeQuestion("Что такое Pod?"))
}

@Test func echoArrivingBeforeOriginalIsFound() {
    // Same-room or fast-mic: the mic copy lands first, the interviewer copy arrives seconds later as one long segment.
    let mic = [me("Вот представим ситуацию. Значит, Pod в Kubernetes в статусе CrashLoopBackOff.", 10)]
    let original = iv("Представим ситуацию. Под в кубернетисе в статусе CrashLoopBackOff. Опишите порядок диагностики по шагам.", 14)
    #expect(echoesOf(original, in: mic) == [0])
    #expect(echoesOf(iv("Совсем другой вопрос про сети и DNS", 14), in: mic).isEmpty)
}

@Test func whisperEndHallucination() {
    #expect(cleanWhisperText("КОНЕЦ") == nil)
}
