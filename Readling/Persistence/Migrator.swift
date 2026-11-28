import Foundation

/// The app's UserDefaults as one dictionary, so a migration can read and change settings like files.
struct SettingsDomain {
    let defaults: UserDefaults
    /// The persistent domain: the bundle identifier for `.standard`, the suite name for a suite.
    let name: String

    static var standard: SettingsDomain { SettingsDomain(defaults: .standard, name: Bundle.main.bundleIdentifier ?? "com.inp146.readling") }

    func read() -> [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }

    /// Makes the domain hold exactly `values`: changed keys are set and missing ones removed.
    func replace(with values: [String: Any]) {
        let old = read()
        for key in old.keys where values[key] == nil { defaults.removeObject(forKey: key) }
        for (key, value) in values where !isEqual(old[key], value) { defaults.set(value, forKey: key) }
    }

    private func isEqual(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        return (a as? NSObject)?.isEqual(b) ?? false
    }
}

/// Brings the data directory to `DataVersion.current` before anything reads it (see docs/data-versioning.md 3.4).
///
/// Every step runs in memory first. The result is then put in place through a journal: new files are written beside
/// the old ones, the journal names them, and only then are the old files set aside and the new ones moved in. A crash
/// before the journal is written changes nothing; after it, the next launch finishes the switch.
struct Migrator {
    enum Outcome: Equatable {
        /// Nothing was saved before: a new install.
        case fresh
        case upToDate
        case migrated(from: String)
        /// The data belongs to a newer app; nothing may be read or written (no downgrades with data, as on iOS).
        case tooNew(String)
        /// The data could not be brought up to date; the files are as they were.
        case failed(from: String, reason: String)
    }

    let directory: URL
    let settings: SettingsDomain
    var now: () -> Date = { .now }
    /// Tests only: stop right after the journal is written, as a crash there would.
    var stopsAfterJournal = false

    static let journalName = "migration-journal.json"
    static let historyName = "migration-history.json"

    private var fileManager: FileManager { .default }
    private func url(_ path: String) -> URL { directory.appendingPathComponent(path) }

    /// The version the data is at now, or nil for a directory that never held any.
    func storedVersion() throws -> String? {
        if let data = try? Data(contentsOf: url(DataVersionFile.name)) {
            return try JSONDecoder().decode(DataVersionFile.self, from: data).appVersion
        }
        return fileManager.fileExists(atPath: url("library.json").path) ? DataVersion.first : nil
    }

    func run() -> Outcome {
        do { try recover() } catch {
            return .failed(from: (try? storedVersion()) ?? "?", reason: "上次升级没有完成，也无法继续完成：\(error.localizedDescription)")
        }
        let version: String
        do {
            guard let stored = try storedVersion() else {
                try write(DataVersionFile(appVersion: DataVersion.current), to: DataVersionFile.name)
                return .fresh
            }
            version = stored
        } catch {
            return .failed(from: "?", reason: "无法读取数据版本：\(error.localizedDescription)")
        }
        switch DataVersion.compare(version, DataVersion.current) {
        case .orderedSame: return .upToDate
        case .orderedDescending: return .tooNew(version)
        case .orderedAscending: break
        }
        guard let steps = DataVersion.steps(from: version) else {
            return .failed(from: version, reason: "不认识的数据版本 \(version)")
        }
        do {
            var context = MigrationContext(directory: directory, settings: settings.read())
            for step in steps { try step.run(&context) }
            try commit(context, from: version)
            return .migrated(from: version)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            appendHistory(MigrationRecord(from: version, to: DataVersion.current, date: now(), failure: reason, backups: []))
            return .failed(from: version, reason: reason)
        }
    }

    // MARK: Committing

    private struct Journal: Codable {
        var from: String
        var to: String
        var files: [String]
        /// The settings after the migration, as a property list.
        var settings: Data
        var rebuilds: [RebuildKind]
        var date: Date
    }

    private func commit(_ context: MigrationContext, from version: String) throws {
        let files = context.changedFiles.keys.sorted()
        for path in files {
            try context.changedFiles[path]!.write(to: url(path + ".migrating"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let settings = try PropertyListSerialization.data(fromPropertyList: context.settings, format: .binary, options: 0)
        try write(Journal(from: version, to: DataVersion.current, files: files, settings: settings,
                          rebuilds: context.rebuilds.sorted { $0.rawValue < $1.rawValue }, date: now()), to: Self.journalName)
        if stopsAfterJournal { return }
        try finish()
    }

    /// Finishes a journalled migration, or clears what an unjournalled one left; a no-op when there is neither.
    func recover() throws {
        guard fileManager.fileExists(atPath: url(Self.journalName).path) else {
            removeStrayFiles()
            return
        }
        try finish()
    }

    /// Puts a journalled migration in place. Every part can run again after a crash.
    private func finish() throws {
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url(Self.journalName)))
        var backups: [String] = []
        for path in journal.files {
            let staged = url(path + ".migrating"), target = url(path)
            let backup = "\(path).\(journal.from).bak"
            if fileManager.fileExists(atPath: staged.path) {
                if fileManager.fileExists(atPath: target.path) {
                    if fileManager.fileExists(atPath: url(backup).path) { try fileManager.removeItem(at: target) }
                    else { try fileManager.moveItem(at: target, to: url(backup)) }
                }
                try fileManager.moveItem(at: staged, to: target)
            }
            if fileManager.fileExists(atPath: url(backup).path) { backups.append(backup) }
        }
        let values = try PropertyListSerialization.propertyList(from: journal.settings, format: nil) as? [String: Any] ?? [:]
        settings.replace(with: values)
        if !journal.rebuilds.isEmpty {
            var queue = RebuildQueue.load(from: directory)
            queue.requested.formUnion(journal.rebuilds)
            try queue.save(to: directory)
        }
        try write(DataVersionFile(appVersion: journal.to), to: DataVersionFile.name)
        // Backups of earlier migrations go once this one is in place.
        let earlier = history().flatMap(\.backups).filter { !backups.contains($0) }
        for path in earlier { try? fileManager.removeItem(at: url(path)) }
        appendHistory(MigrationRecord(from: journal.from, to: journal.to, date: journal.date, failure: nil, backups: backups,
                                      rebuilds: journal.rebuilds))
        try fileManager.removeItem(at: url(Self.journalName))
    }

    /// Staged files of a migration that stopped before its journal was written.
    private func removeStrayFiles() {
        guard let items = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items where item.pathExtension == "migrating" { try? fileManager.removeItem(at: item) }
    }

    private func write(_ value: some Encodable, to path: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url(path), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: History

    func history() -> [MigrationRecord] {
        (try? JSONDecoder().decode([MigrationRecord].self, from: Data(contentsOf: url(Self.historyName)))) ?? []
    }

    private func appendHistory(_ record: MigrationRecord) {
        try? write(history() + [record], to: Self.historyName)
    }

    /// The files set aside by the last migration, which "从备份重新迁移" puts back.
    func latestBackups() -> (from: String, files: [String])? {
        guard let last = history().last(where: { $0.failure == nil && !$0.backups.isEmpty }) else { return nil }
        let present = last.backups.filter { fileManager.fileExists(atPath: url($0).path) }
        return present.isEmpty ? nil : (last.from, present)
    }

    /// Puts back the files the last migration set aside and the version they had, so the migration runs again
    /// on the next `run()`. Settings are not put back. For development builds, while the step is still changing.
    func restoreLatestBackups() throws {
        guard let (from, files) = latestBackups() else { return }
        for backup in files {
            let original = String(backup.dropLast(".\(from).bak".count))
            if fileManager.fileExists(atPath: url(original).path) { try fileManager.removeItem(at: url(original)) }
            try fileManager.moveItem(at: url(backup), to: url(original))
        }
        try write(DataVersionFile(appVersion: from), to: DataVersionFile.name)
    }

    /// Deletes the backups of the last migration.
    func removeBackups() {
        for path in history().flatMap(\.backups) { try? fileManager.removeItem(at: url(path)) }
    }

    func backupSize() -> Int64 {
        history().flatMap(\.backups).reduce(0) { total, path in
            total + ((try? fileManager.attributesOfItem(atPath: url(path).path)[.size] as? Int64) ?? 0)
        }
    }
}

/// One migration, as the 数据 page lists it.
struct MigrationRecord: Codable, Equatable, Sendable {
    var from: String
    var to: String
    var date: Date
    /// Why it failed; nil when it succeeded.
    var failure: String?
    /// Files set aside before being replaced, relative to the data directory.
    var backups: [String]
    var rebuilds: [RebuildKind] = []
}

enum MigrationError: LocalizedError {
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .unexpected(let detail): "数据格式和预期不符（\(detail)）。"
        }
    }
}
