import Foundation

/// The data vNext writes. Frozen once vNext is released (see docs/data-versioning.md).
///
/// Changes from v0.2.1: none yet.
///
/// To change a stored structure, replace its typealias with a copy of the struct from `V0_2_1` and change the
/// copy (list the change above). Never use the app's live models here: snapshots of released versions must not change.
enum VNext {
    typealias Library = V0_2_1.Library
    typealias Book = V0_2_1.Book
    typealias ChapterInfo = V0_2_1.ChapterInfo
    typealias Position = V0_2_1.Position
    typealias Passage = V0_2_1.Passage
    static let settingsKeys = V0_2_1.settingsKeys
}
