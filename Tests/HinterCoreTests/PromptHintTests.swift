import Testing
@testable import HinterCore

@Test func promptWarnsAboutMangledTerms() {
    let p = buildPrompt(mode: .question, context: CandidateContext(resume: "", job: ""), transcript: [], now: .now, imagePath: nil)
    #expect(p.system.contains("искажены"))
}
