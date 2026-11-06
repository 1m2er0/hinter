import AppKit

public enum KeyImportError: Error, Equatable { case unreadable, notFound }

/// First non-empty token-like line of a key file (RTF or plain text).
public func extractAPIKey(fromRTF data: Data) throws -> String {
    // RTF (TextEdit's default) or a plain-text file with the key.
    guard let text = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil).string) ?? String(data: data, encoding: .utf8)
    else { throw KeyImportError.unreadable }
    for line in text.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !t.contains(" ") { return t }
    }
    throw KeyImportError.notFound
}
