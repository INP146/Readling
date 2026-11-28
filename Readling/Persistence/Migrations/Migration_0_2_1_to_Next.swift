import Foundation

/// v0.2.1 → vNext.
/// - Library: unchanged.
/// - Settings: unchanged.
/// - Reading text: not rebuilt.
///
/// This version's data changes go here (docs/data-versioning.md 3.3): convert source data from `V0_2_1` to
/// `VNext` through `context`, and ask for `.content` to be rebuilt when import builds text differently. Keep the
/// list above up to date; it is what the release notes and the next reader go by.
enum Migration_0_2_1_to_Next {
    static let migration = Migration(from: "0.2.1", to: "next") { _ in }
}
