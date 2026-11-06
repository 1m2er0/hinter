import Testing
import Foundation
import CryptoKit
@testable import HinterCore

private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

@Test func roundTripAndNoPlaintext() throws {
    let root = tmp(), key = SymmetricKey(size: .bits256)
    let s = SessionStore(root: root, key: key)
    let id = try s.begin()
    for l in ["Интервьюер: секрет один", "Кандидат: два", "Подсказка: три"] { try s.append(l, to: id) }
    let raw = try String(contentsOf: s.url(id), encoding: .utf8)
    #expect(!raw.contains("секрет"))
    let out = tmp()
    try s.export(id, to: out)
    #expect(try String(contentsOf: out, encoding: .utf8) == "Интервьюер: секрет один\nКандидат: два\nПодсказка: три\n")
}

@Test func wrongKeyFails() throws {
    let root = tmp()
    let id = try SessionStore(root: root, key: SymmetricKey(size: .bits256)).begin()
    try SessionStore(root: root, key: SymmetricKey(size: .bits256)).append("x", to: id)
    #expect(throws: (any Error).self) { try SessionStore(root: root, key: SymmetricKey(size: .bits256)).export(id, to: tmp()) }
}

@Test func tamperedLineIsSkippedNotFatal() throws {
    let root = tmp(), key = SymmetricKey(size: .bits256)
    let s = SessionStore(root: root, key: key)
    let id = try s.begin()
    try s.append("hello", to: id)
    try s.append("world", to: id)
    var raw = try String(contentsOf: s.url(id), encoding: .utf8)
    raw = String(raw.prefix(10)) + (raw.dropFirst(10).first == "A" ? "B" : "A") + raw.dropFirst(11)
    try raw.write(to: s.url(id), atomically: true, encoding: .utf8)
    let out = tmp()
    try s.export(id, to: out)
    #expect(try String(contentsOf: out, encoding: .utf8) == "[повреждённая строка]\nworld\n")
}

@Test func truncatedLastLineKeepsEarlierLines() throws {
    let s = SessionStore(root: tmp(), key: SymmetricKey(size: .bits256))
    let id = try s.begin()
    try s.append("kept", to: id)
    let h = try FileHandle(forWritingTo: s.url(id)); try h.seekToEnd(); try h.write(contentsOf: Data("AAAA".utf8)); try h.close()
    let out = tmp()
    try s.export(id, to: out)
    #expect(try String(contentsOf: out, encoding: .utf8) == "kept\n[повреждённая строка]\n")
}

@Test func loadOrCreateKeyIsStable() throws {
    let account = "test-\(UUID().uuidString)"
    let a = try SessionStore.loadOrCreateKey(account: account)
    let b = try SessionStore.loadOrCreateKey(account: account)
    #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
    try Keychain.delete(account: account)
}

@Test func sameSecondSessionsDoNotCollide() throws {
    let s = SessionStore(root: tmp(), key: SymmetricKey(size: .bits256))
    let a = try s.begin(); try s.append("first", to: a)
    let b = try s.begin()
    #expect(a != b)
    let out = tmp(); try s.export(a, to: out)
    #expect(try String(contentsOf: out, encoding: .utf8) == "first\n")
}
