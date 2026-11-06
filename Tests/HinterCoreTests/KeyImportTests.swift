import Testing
import AppKit
@testable import HinterCore

private func rtf(_ s: String) -> Data {
    let a = NSAttributedString(string: s)
    return a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:])!
}

@Test func extractsKeyFromRTF() throws {
    #expect(try extractAPIKey(fromRTF: rtf("nvapi-TESTKEY123\n")) == "nvapi-TESTKEY123")
}

@Test func extractsKeyAfterBlankLines() throws {
    #expect(try extractAPIKey(fromRTF: rtf("\n  \n  nvapi-ABC  \n")) == "nvapi-ABC")
}

@Test func throwsWhenNoKey() {
    #expect(throws: KeyImportError.notFound) { try extractAPIKey(fromRTF: rtf("\n \n")) }
}

@Test func extractsKeyFromPlainText() throws {
    #expect(try extractAPIKey(fromRTF: Data("  nvapi-PLAIN42 \n".utf8)) == "nvapi-PLAIN42")
}
