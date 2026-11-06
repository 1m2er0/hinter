import Foundation
import CryptoKit

public typealias SessionID = String

/// One file per call in `root/sessions/`; each line is a base64 AES-GCM box, so appends never re-read the file.
public final class SessionStore {
    let dir: URL
    let key: SymmetricKey

    public init(root: URL, key: SymmetricKey) {
        dir = root.appendingPathComponent("sessions")
        self.key = key
    }

    public static func loadOrCreateKey(account: String = "transcript-key") throws -> SymmetricKey {
        if let d = try Keychain.get(account: account) { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        try Keychain.set(k.withUnsafeBytes { Data($0) }, account: account)
        return k
    }

    public func url(_ id: SessionID) -> URL { dir.appendingPathComponent("\(id).hh") }

    public func begin() throws -> SessionID {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = f.string(from: Date()) + "-" + UUID().uuidString.prefix(4)
        FileManager.default.createFile(atPath: url(id).path, contents: nil, attributes: [.posixPermissions: 0o600])
        return id
    }

    public func append(_ line: String, to id: SessionID) throws {
        let box = try AES.GCM.seal(Data(line.utf8), using: key).combined!.base64EncodedString() + "\n"
        let h = try FileHandle(forWritingTo: url(id))
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(box.utf8))
    }

    public func export(_ id: SessionID, to out: URL) throws {
        let lines = try String(contentsOf: url(id), encoding: .utf8).split(separator: "\n")
        // A torn/corrupt line (crash mid-write) must not cost the rest of the call.
        var ok = 0
        let text = lines.map { b64 -> String in
            guard let d = Data(base64Encoded: String(b64)), let box = try? AES.GCM.SealedBox(combined: d),
                  let plain = try? AES.GCM.open(box, using: key)
            else { return "[повреждённая строка]\n" }
            ok += 1
            return String(decoding: plain, as: UTF8.self) + "\n"
        }.joined()
        if ok == 0, !lines.isEmpty { throw CocoaError(.fileReadCorruptFile) } // wrong key, not a torn line
        try text.write(to: out, atomically: true, encoding: .utf8)
    }
}
