import Foundation

/// The data v0.1.0 wrote, frozen: do not change these types (see docs/data-versioning.md).
///
/// `library.json` (`version` 2): the books, reading positions, saved words and file fingerprints. Each book's files
/// are under `books/<id>/`: `content.json` (reading text, derived), `book.json`, `docs/`, `res/`, `cover.jpg`.
enum V0_1_0 {
    struct Library: Codable {
        var version: Int // Always 2.
        var books: [Book]
        var favorites: [Passage]
        var fingerprints: [String: UUID]
    }

    struct Book: Codable {
        var id: UUID
        var title: String
        var author: String
        var chapters: [ChapterInfo]
        var position: Position
        var isSample: Bool
        var coverAspectRatio: Double?
        var hasPackage: Bool?
    }

    struct ChapterInfo: Codable {
        var title: String
        var length: Int
    }

    struct Position: Codable {
        var chapter: Int
        var offset: Int
        var fraction: Double?
    }

    struct Passage: Codable {
        var id: UUID
        var bookID: UUID
        var bookTitle: String
        var chapterTitle: String
        var chapterIndex: Int
        var offset: Int
        var selection: String
        var sentence: String
        var mastered: Bool
        var headword: String?
        var phonetic: String?
        var definition: String?
        var createdAt: Date?
        var reviewStage: Int?
        var dueAt: Date?
        var definitionSource: String?
    }

    /// UserDefaults keys v0.1.0 used, with the type of their values.
    static let settingsKeys: [String: String] = [
        "readerFont": "Double", "readerTypeface": "String", "readerLineSpacing": "Double", "readerParagraphSpacing": "Double",
        "readerMargin": "Double", "readerAppearance": "String", "readerDayTheme": "String", "readerNightTheme": "String",
        "readerBackdrop": "String", "readerBackdropVersion": "Int", "readerPageTurn": "String", "readerEyeCare": "Bool",
        "readerAutoSpeed": "Int", "readerKeepAwake": "Bool", "readerTipSeen": "Bool", "lastReadBookID": "String",
        "dictionaryExpandByDefault": "Bool", "dictionaryAccent": "String", "dictionaryManifestURL": "String",
        "translationEngine": "String", "translationAutomatic": "Bool", "translationDeepLAddress": "String",
        "translationPromptTranslate": "String", "translationPromptExplain": "String", "aiEndpoints": "Data (JSON [AIEndpoint])",
    ]
}
