import Foundation

/// The data v0.2.0 writes. Frozen once v0.2.0 is released (see docs/data-versioning.md).
///
/// Changes from v0.1.0:
/// - `library.json` `version` 3: each book names its reading-text file (`contentFile`), since text rebuilt from the
///   stored original goes to a new file (`content-<n>.json`) before the library switches to it.
/// - `data-version.json` records the version of the whole data directory.
enum V0_2_0 {
    struct Library: Codable {
        var version: Int // Always 3.
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
        /// File name of the reading text under `books/<id>/`; nil for the sample, whose text is built in.
        var contentFile: String?
    }

    typealias ChapterInfo = V0_1_0.ChapterInfo
    typealias Position = V0_1_0.Position
    typealias Passage = V0_1_0.Passage
    static let settingsKeys = V0_1_0.settingsKeys
}
