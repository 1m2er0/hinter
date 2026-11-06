import Testing
@testable import HinterCore

@Test func stripsCJKAndHangulButKeepsCyrillicLatinCode() {
    #expect(sanitizeHint("• Батуми —天 alphabet tower, 친구 мост") == "• Батуми — alphabet tower, мост")
    #expect(sanitizeHint("• настроено автоматическоеフェйловер") == "• настроено автоматическоейловер")
    #expect(sanitizeHint("• `kubectl get pods -o wide` → OK") == "• `kubectl get pods -o wide` → OK")
}

@Test func keepsAtMostFiveBullets() {
    let many = (1...20).map { "• пункт \($0)" }.joined(separator: "\n")
    let out = sanitizeHint(many)
    #expect(out.split(separator: "\n").count == 5)
    #expect(out.hasSuffix("• пункт 5"))
}

@Test func codeAnswersAreNotTruncated() {
    let code = "```python\n" + (1...30).map { "x\($0) = \($0)" }.joined(separator: "\n") + "\n```\n• O(n)"
    #expect(sanitizeHint(code) == code)
}
