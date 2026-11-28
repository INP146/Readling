import Foundation

/// The data vNext writes. Frozen once vNext is released (see docs/data-versioning.md).
enum VNext {
    typealias Library = V0_2_0.Library
    typealias Book = V0_2_0.Book
    typealias ChapterInfo = V0_2_0.ChapterInfo
    typealias Position = V0_2_0.Position
    typealias Passage = V0_2_0.Passage
    static let settingsKeys = V0_2_0.settingsKeys
}
