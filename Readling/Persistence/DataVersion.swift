import Foundation

/// Which app version the data on this device belongs to (see docs/data-versioning.md).
///
/// The whole data directory has one version: the app version it was last migrated to. Migrations run only between
/// neighbouring versions of `chain`, one step per pair, so an upgrade across several releases runs every step between.
enum DataVersion {
    /// Every released version in order, then `next` while the release after them is in development. A version's
    /// entry, snapshot and migration step are frozen once it is released. `next` gets its number only when
    /// `Tools/app_release.py prepare` names the release; `post-release` opens it again after tagging.
    static let chain = ["0.1.0", "0.2.0", "0.2.1"]

    /// The entry of `chain` for the version in development, whose number isn't decided yet.
    static let next = "next"

    /// The version this build writes. A development build writes `<last release>+next`, so its data is never taken
    /// for the release's.
    static var current: String { label(at: chain.count - 1, in: chain) }

    /// One step per neighbouring pair of `chain`, in order.
    static let migrations: [Migration] = [
        Migration_0_1_0_to_0_2_0.migration,
        Migration_0_2_0_to_0_2_1.migration,
    ]

    /// The version before data-version.json existed: v0.1.0 wrote only library.json.
    static let first = "0.1.0"

    /// Settings keys of the current snapshot, checked against `SettingsKeys.all` in tests.
    static let currentSettingsKeys = V0_2_1.settingsKeys

    /// The version written for `chain[index]`.
    static func label(at index: Int, in chain: [String]) -> String {
        chain[index] == next && index > 0 ? "\(chain[index - 1])+next" : chain[index]
    }

    /// Where data at `version` stands on `chain`. Data of a development build, `X+next`, ran the step out of `X`
    /// as it was then, so it stands at the version after `X`: still `next` while that is in development, or the
    /// release it became.
    static func index(of version: String, in chain: [String] = chain) -> Int? {
        if version != next, let index = chain.firstIndex(of: version) { return index }
        guard version.hasSuffix("+next"), let base = chain.firstIndex(of: String(version.dropLast(5))),
              base + 1 < chain.count else { return nil }
        return base + 1
    }

    /// SemVer order; `X+next` comes right after `X` and before any later release.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func key(_ value: String) -> (Int, Int, Int, Int, Int) {
            let development = value.hasSuffix("+next")
            let halves = (development ? String(value.dropLast(5)) : value).split(separator: "-rc", maxSplits: 1)
            let numbers = halves[0].split(separator: ".").map { Int($0) ?? 0 }
            let major = numbers.count > 0 ? numbers[0] : 0
            let minor = numbers.count > 1 ? numbers[1] : 0
            let patch = numbers.count > 2 ? numbers[2] : 0
            let rc = halves.count > 1 ? (Int(halves[1]) ?? 0) : Int.max
            return (major, minor, patch, rc, development ? 1 : 0)
        }
        let (x, y) = (key(a), key(b))
        if x == y { return .orderedSame }
        return x < y ? .orderedAscending : .orderedDescending
    }

    /// The steps that take data at `version` to `current`, or nil when `version` isn't on the chain.
    static func steps(from version: String) -> [Migration]? {
        guard let start = index(of: version) else { return nil }
        return Array(migrations[start...])
    }
}

/// `data-version.json`: the version of everything in the data directory.
struct DataVersionFile: Codable, Equatable {
    var appVersion: String

    static let name = "data-version.json"
}

/// One step of the chain: data written by `from` becomes data `to` reads.
///
/// A step works only with the frozen structures in `Persistence/Snapshots`, never with the app's live models, so
/// later changes to the models can't change what an old step does.
struct Migration: Sendable {
    let from: String
    let to: String
    let run: @Sendable (inout MigrationContext) throws -> Void
}

/// What a migration step reads and changes. Nothing is written until every step has run (see `Migrator`).
struct MigrationContext {
    /// Files of the data directory, by path relative to it, as they are after the steps so far.
    private(set) var changedFiles: [String: Data] = [:]
    /// The app's UserDefaults as they are after the steps so far.
    var settings: [String: Any]
    /// Derived data the steps ask to be rebuilt once the migration is in place.
    private(set) var rebuilds: Set<RebuildKind> = []
    private let directory: URL

    init(directory: URL, settings: [String: Any]) {
        self.directory = directory
        self.settings = settings
    }

    /// A file as the previous steps left it; nil when there is no such file.
    func read(_ path: String) throws -> Data? {
        if let changed = changedFiles[path] { return changed }
        let url = directory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    mutating func write(_ path: String, _ data: Data) {
        changedFiles[path] = data
    }

    /// Asks for derived data to be rebuilt from the source data after the migration (see `LibraryStore` rebuilding).
    mutating func requestRebuild(_ kind: RebuildKind) {
        rebuilds.insert(kind)
    }
}

/// Derived data a migration can ask to be rebuilt.
enum RebuildKind: String, Codable, Sendable, CaseIterable {
    /// Every book's reading text (`content-*.json`), built again from the stored original.
    case content
}
