import Foundation

/// What an imported book keeps besides its reading text, so it can be exported whole.
///
/// An EPUB's chapter documents are stored as parsed trees (`docs/`) and every
/// other file of the container byte for byte (`res/`). `entries` records where
/// each file went, in the order the container had them. A text import keeps the
/// original file as its only entry.
struct BookPackage: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case epub, text }

    struct Entry: Codable, Equatable, Sendable {
        /// Path inside the original container.
        var path: String
        /// File name under `docs/` (a parsed document) or `res/` (raw bytes).
        var file: String
        var isDocument: Bool
    }

    var kind: Kind
    var entries: [Entry]
}

/// Where one book's files live.
///
///     content*.json  chapter text and styles, what the reader opens (derived; the library names the current one)
///     book.json      the BookPackage
///     cover.jpg      shelf thumbnail
///     docs/<n>.json  one parsed chapter document each
///     res/<n>        every other file of the original, unchanged
struct BookDirectory: Sendable {
    let url: URL

    /// The reading text a book is imported with; text rebuilt later goes to `content-<n>.json`.
    static let firstContentFile = "content.json"

    func content(_ file: String) -> URL { url.appendingPathComponent(file) }

    /// Reading-text files present, current or not.
    func contentFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasPrefix("content") && $0.hasSuffix(".json") }
    }

    /// A name no reading-text file has yet.
    func nextContentFile() -> String {
        let numbers = contentFiles().compactMap { Int($0.dropFirst("content-".count).dropLast(".json".count)) }
        return "content-\((numbers.max() ?? 0) + 1).json"
    }
    var package: URL { url.appendingPathComponent("book.json") }
    var cover: URL { url.appendingPathComponent("cover.jpg") }
    var documents: URL { url.appendingPathComponent("docs", isDirectory: true) }
    var resources: URL { url.appendingPathComponent("res", isDirectory: true) }

    func document(_ file: String) -> URL { documents.appendingPathComponent(file) }
    func resource(_ file: String) -> URL { resources.appendingPathComponent(file) }
}
