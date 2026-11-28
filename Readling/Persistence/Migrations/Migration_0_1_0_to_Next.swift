import Foundation

/// v0.1.0 → vNext.
/// - Library `version` 2 → 3: every book with files names its reading text, which v0.1.0 kept in `content.json`.
/// - Settings: unchanged.
/// - Rebuild every book's reading text: vNext draws tables, formulas (MathML and TeX), rules and list styles that
///   v0.1.0 left out or flattened.
enum Migration_0_1_0_to_Next {
    static let migration = Migration(from: "0.1.0", to: "next") { context in
        guard let data = try context.read("library.json") else { return } // Nothing saved yet.
        let old = try JSONDecoder().decode(V0_1_0.Library.self, from: data)
        guard old.version == 2 else { throw MigrationError.unexpected("library.json version \(old.version)") }
        let library = VNext.Library(
            version: 3,
            books: old.books.map { book in
                VNext.Book(id: book.id, title: book.title, author: book.author, chapters: book.chapters, position: book.position,
                            isSample: book.isSample, coverAspectRatio: book.coverAspectRatio, hasPackage: book.hasPackage,
                            contentFile: book.isSample ? nil : "content.json")
            },
            favorites: old.favorites,
            fingerprints: old.fingerprints)
        context.write("library.json", try JSONEncoder().encode(library))
        context.requestRebuild(.content)
    }
}
