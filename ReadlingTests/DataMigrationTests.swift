import Foundation
import Testing
@testable import Readling

private final class FixtureMarker: NSObject {}

/// A released version's data directory (`ReadlingTests/Fixtures/AppData/<version>.bundle`), copied somewhere it
/// can be changed, with its settings in a UserDefaults suite of its own.
private struct InstalledFixture {
    let directory: URL
    let settings: SettingsDomain
    let originalSettings: [String: Any]
    var library: URL { directory.appendingPathComponent("library.json") }

    static func url(of version: String) -> URL? {
        let bundle = Bundle(for: FixtureMarker.self)
        return bundle.url(forResource: version, withExtension: "bundle")
            ?? bundle.url(forResource: version, withExtension: "bundle", subdirectory: "AppData")
    }

    init(_ version: String) throws {
        let fixture = try #require(Self.url(of: version))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadlingTests-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root.appendingPathComponent("Readling", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("Readling"), to: directory)
        let suite = "ReadlingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let plist = try Data(contentsOf: fixture.appendingPathComponent("settings.plist"))
        originalSettings = try #require(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        defaults.setPersistentDomain(originalSettings, forName: suite)
        settings = SettingsDomain(defaults: defaults, name: suite)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        settings.defaults.removePersistentDomain(forName: settings.name)
    }

    func json(_ path: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(path))) as? [String: Any])
    }
}

@MainActor
private func rebuildEverything(_ store: LibraryStore) async {
    for id in store.rebuild.pending { await store.rebuildNow(id) }
}

@Suite("Data versions and migrations") @MainActor
struct DataMigrationTests {
    @Test func theChainHasOneStepPerNeighbouringVersion() {
        let chain = DataVersion.chain
        #expect(DataVersion.migrations.count == chain.count - 1)
        for (index, step) in DataVersion.migrations.enumerated() {
            #expect(step.from == chain[index] && step.to == chain[index + 1], "\(step.from) → \(step.to)")
        }
        #expect(!chain.dropLast().contains(DataVersion.next), "only the last entry can be in development")
        #expect(DataVersion.current == (chain.last == DataVersion.next ? "\(chain[chain.count - 2])+next" : chain.last))
        #expect(DataVersion.index(of: DataVersion.current) == chain.count - 1)
        #expect(DataVersion.chain.first == DataVersion.first)
        #expect(DataVersion.compare("0.10.0", "0.9.1") == .orderedDescending)
        #expect(DataVersion.compare("0.2.0-rc1", "0.2.0-rc2") == .orderedAscending)
        #expect(DataVersion.compare("0.2.0-rc2", "0.2.0") == .orderedAscending)
        #expect(DataVersion.compare("0.1.0", "0.1.0+next") == .orderedAscending)
        #expect(DataVersion.compare("0.1.0+next", "0.1.1-rc1") == .orderedAscending)
        #expect(DataVersion.compare("0.1.0+next", "0.1.0+next") == .orderedSame)
    }

    /// Data of a development build stands at the version after the release it started from, whether that is still
    /// in development or has since been released under its number.
    @Test func developmentDataStandsAtTheVersionAfterItsBase() {
        let developing = ["0.1.0", "next"]
        #expect(DataVersion.label(at: 1, in: developing) == "0.1.0+next")
        #expect(DataVersion.index(of: "0.1.0+next", in: developing) == 1)
        #expect(DataVersion.index(of: "next", in: developing) == nil)
        let released = ["0.1.0", "0.2.0", "next"]
        #expect(DataVersion.index(of: "0.1.0+next", in: released) == 1)
        #expect(DataVersion.index(of: "0.2.0+next", in: released) == 2)
        #expect(DataVersion.index(of: "0.2.0+next", in: ["0.1.0", "0.2.0"]) == nil)
        #expect(DataVersion.index(of: "0.3.0+next", in: released) == nil)
        #expect(SettingsKeys.all == Set(DataVersion.currentSettingsKeys.keys))
    }

    /// Every released version's data reaches the current version, and after the text is rebuilt, positions and
    /// saved words still point at the words they pointed at.
    @Test(arguments: Array(DataVersion.chain.dropLast()))
    func releasedDataMigratesAndRebuilds(version: String) async throws {
        let fixture = try InstalledFixture(version)
        defer { fixture.remove() }
        // Before: the word at each saved place, read from the text the old version wrote.
        let before = LibraryWords(directory: fixture.directory)
        #expect(!before.positions.isEmpty && !before.favorites.isEmpty)

        let store = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        #expect(store.migrationOutcome == .migrated(from: version))
        #expect(store.readFailure == nil)
        #expect(try fixture.json(DataVersionFile.name)["appVersion"] as? String == DataVersion.current)
        #expect(try fixture.json("library.json")["version"] as? Int == LibraryStore.libraryVersion)
        #expect(store.migrator.history().last?.failure == nil)
        // Settings are carried over untouched unless a migration deliberately changed them.
        let settings = fixture.settings.read()
        for (key, value) in fixture.originalSettings { #expect((settings[key] as? NSObject)?.isEqual(value) == true, "\(key)") }

        let rebuiltText = !store.rebuild.pending.isEmpty
        await rebuildEverything(store)
        #expect(store.rebuild.isFinished && store.rebuild.failures.isEmpty, "\(store.rebuild.failures)")
        for book in store.books where !book.isSample {
            let content = try await store.content(for: book)
            if rebuiltText {
                #expect(book.contentFile != before.contentFiles[book.id], "\(book.title) was rebuilt into a new file")
            }
            #expect(book.chapters == content.chapterInfo)
            if let word = before.positions[book.id] {
                #expect(content.chapters.indices.contains(book.position.chapter))
                #expect(LibraryWords.word(at: book.position.offset, in: content.chapters[book.position.chapter].text) == word, "\(book.title)")
            }
        }
        for item in store.favorites {
            guard let book = store.books.first(where: { $0.id == item.bookID }), let expected = before.favorites[item.id] else { continue }
            let content = try await store.content(for: book)
            let text = content.chapters[item.chapterIndex].text as NSString
            let found = text.substring(with: NSRange(location: item.offset, length: min((item.selection as NSString).length, text.length - item.offset)))
            #expect(found.lowercased() == expected.lowercased(), "\(item.selection) in \(book.title)")
            #expect(item.chapterTitle == content.chapters[item.chapterIndex].title)
        }

        // The old text stays while the backup that points to it does, and goes with it.
        let formulas = try #require(store.books.first { $0.title == "Formulas and Tables" })
        let files = store.directory(for: formulas.id)
        if rebuiltText, !store.migrator.history().flatMap(\.backups).isEmpty {
            #expect(Set(files.contentFiles()) == [before.contentFiles[formulas.id]!, formulas.contentFile!])
        }
        let rebuilt = try await store.content(for: formulas)
        #expect(rebuilt.chapters[0].styles.contains { $0.style == .math })
        #expect(rebuilt.chapters[1].styles.contains { $0.style == .table })
        store.removeMigrationBackups()
        #expect(files.contentFiles() == [formulas.contentFile!])
        #expect(store.migrator.backupSize() == 0)

        // Opening again changes nothing.
        let reopened = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        #expect(reopened.migrationOutcome == .upToDate)
        #expect(reopened.rebuild.isFinished)
        #expect(reopened.books == store.books && reopened.favorites == store.favorites)
    }

    /// Changing what import builds needs the step in development to ask for the text to be rebuilt, or books
    /// already imported would keep reading the old way.
    @Test func changedTextIsRebuiltByTheStepInDevelopment() throws {
        // Once DataVersion.current has been released and its fixture saved, any later text change must first open
        // `next` in DataVersion.chain (app_release.py post-release).
        let currentReleased = InstalledFixture.url(of: DataVersion.current) != nil
        let baseline = currentReleased ? DataVersion.current : DataVersion.chain[DataVersion.chain.count - 2]
        let fixture = try InstalledFixture(baseline)
        defer { fixture.remove() }
        let library = try JSONDecoder().decode(StoredBooks.self, from: Data(contentsOf: fixture.library))
        var changed: [String] = []
        for book in library.books where book.hasPackage == true && !book.isSample {
            let files = BookDirectory(url: fixture.directory.appendingPathComponent("books/\(book.id.uuidString)", isDirectory: true))
            let package = try JSONDecoder().decode(BookPackage.self, from: Data(contentsOf: files.package))
            let stored = try JSONDecoder().decode(BookContent.self, from: Data(contentsOf: files.content(book.contentFile ?? BookDirectory.firstContentFile)))
            if try BookBuilder.build(from: files, package: package).content.chapters != stored.chapters { changed.append(book.title) }
        }
        guard !changed.isEmpty else { return }
        #expect(!currentReleased, "Text built differently from released \(baseline) for \(changed); run app_release.py post-release to open `next` in DataVersion.chain, then request .content")
        var context = MigrationContext(directory: fixture.directory, settings: fixture.settings.read())
        try #require(DataVersion.migrations.last).run(&context)
        #expect(context.rebuilds.contains(.content), "Text built differently from \(baseline) for \(changed); the step to \(DataVersion.current) must request .content")
    }

    @Test func aMigrationStoppedAfterItsJournalIsFinishedAtTheNextLaunch() throws {
        let fixture = try InstalledFixture(DataVersion.first)
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.library)
        var migrator = Migrator(directory: fixture.directory, settings: fixture.settings)
        migrator.stopsAfterJournal = true
        _ = migrator.run()
        // Stopped: the old files are still in place, the new one waits beside them.
        #expect(try Data(contentsOf: fixture.library) == original)
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(Migrator.journalName).path))
        let store = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        #expect(store.migrationOutcome == .upToDate)
        #expect(store.readFailure == nil)
        #expect(try fixture.json("library.json")["version"] as? Int == LibraryStore.libraryVersion)
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("library.json.\(DataVersion.first).bak")) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(Migrator.journalName).path))
        #expect(!store.rebuild.pending.isEmpty, "The rebuild the journal asked for is queued")
    }

    @Test func filesStagedWithoutAJournalAreDiscarded() throws {
        let fixture = try InstalledFixture(DataVersion.first)
        defer { fixture.remove() }
        try Data("half written".utf8).write(to: fixture.directory.appendingPathComponent("library.json.migrating"))
        let store = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        #expect(store.migrationOutcome == .migrated(from: DataVersion.first))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("library.json.migrating").path))
    }

    @Test func aFailedMigrationLeavesTheDataAsItWas() throws {
        let fixture = try InstalledFixture(DataVersion.first)
        defer { fixture.remove() }
        let broken = Data(#"{"version": 2, "books": "not a list"}"#.utf8)
        try broken.write(to: fixture.library)
        let store = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        guard case .failed(let from, _) = store.migrationOutcome else { Issue.record("\(store.migrationOutcome)"); return }
        #expect(from == DataVersion.first)
        #expect(store.readFailure != nil)
        #expect(try Data(contentsOf: fixture.library) == broken)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(DataVersionFile.name).path))
        #expect(store.migrator.history().last?.failure != nil)
        #expect(store.savePassage(bookID: UUID(), chapter: 0, offset: 0, selection: "x", sentence: "") == .failed)
    }

    @Test func dataFromANewerVersionIsNeitherReadNorWritten() async throws {
        let fixture = try InstalledFixture(DataVersion.first)
        defer { fixture.remove() }
        try JSONEncoder().encode(DataVersionFile(appVersion: "99.0.0")).write(to: fixture.directory.appendingPathComponent(DataVersionFile.name))
        let original = try Data(contentsOf: fixture.library)
        let store = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        #expect(store.newerDataVersion == "99.0.0")
        #expect(store.books.isEmpty)
        store.persist()
        store.addSample()
        #expect(try Data(contentsOf: fixture.library) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("library.json.\(DataVersion.first).bak").path))
        // The way out keeps the data, renamed, and starts afresh.
        store.setAsideNewerData()
        #expect(store.newerDataVersion == nil)
        #expect(store.migrationOutcome == .fresh)
        let parent = fixture.directory.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0.hasPrefix("Readling-99.0.0-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: parent.appendingPathComponent(aside[0]).appendingPathComponent("library.json")) == original)
    }

    @Test func aNewLibraryStartsAtTheCurrentVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReadlingTests-fresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"),
                                 settings: SettingsDomain(defaults: UserDefaults(suiteName: "ReadlingTests-fresh")!, name: "ReadlingTests-fresh"))
        #expect(store.migrationOutcome == .fresh)
        let version = try JSONDecoder().decode(DataVersionFile.self, from: Data(contentsOf: folder.appendingPathComponent(DataVersionFile.name)))
        #expect(version.appVersion == DataVersion.current)
        #expect(store.books.first?.isSample == true)
        #expect(LibraryStore(fileURL: folder.appendingPathComponent("library.json")).migrationOutcome == .upToDate)
    }

    @Test func rebuildingFromBackupsRunsTheMigrationAgain() async throws {
        let fixture = try InstalledFixture(DataVersion.first)
        defer { fixture.remove() }
        let store = LibraryStore(fileURL: fixture.library, settings: fixture.settings)
        await rebuildEverything(store)
        let rebuiltBooks = store.books
        store.remigrateFromBackups()
        #expect(store.migrationOutcome == .migrated(from: DataVersion.first))
        #expect(!store.rebuild.pending.isEmpty)
        await rebuildEverything(store)
        #expect(store.rebuild.failures.isEmpty)
        #expect(store.books.map(\.position) == rebuiltBooks.map(\.position))
        #expect(store.books.map(\.chapters) == rebuiltBooks.map(\.chapters))
    }

    @Test func aNewlyImportedBookIsWhatBuildingItAgainGives() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReadlingTests-build-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let bundle = Bundle(for: FixtureMarker.self)
        for (name, ext) in [("formulas", "epub"), ("verse", "txt"), ("alice", "epub")] {
            let url = try #require(bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
            let id = try await store.importBook(url: url)
            let book = try #require(store.books.first { $0.id == id })
            let files = store.directory(for: id)
            let package = try JSONDecoder().decode(BookPackage.self, from: Data(contentsOf: files.package))
            let loaded = try await store.content(for: book)
            #expect(try BookBuilder.build(from: files, package: package).content.chapters == loaded.chapters, "\(name)")
        }
    }
}

@Suite("Text remapping")
struct TextRemapTests {
    @Test func wordsAfterAFormulaKeepTheirPlace() {
        let old = "Model \\(Y=f(X)\\) fits. She looked at the curious formula."
        let new = "Model \u{FFFC} fits. She looked at the curious formula."
        let alignment = Alignment(old: old, new: new)
        for word in ["fits", "curious", "formula"] {
            #expect(alignment.map((old as NSString).range(of: word).location) == (new as NSString).range(of: word).location, "\(word)")
        }
        // Inside what was replaced: just after the last word that is still there.
        #expect(alignment.map((old as NSString).range(of: "f(X)").location) == (new as NSString).range(of: "Model").upperBound)
    }

    /// A whole book as one document (a text import) whose text changed a lot: a plain Myers diff of it took minutes.
    @Test func longDocumentWithManyChangesAlignsQuickly() {
        var seed: UInt64 = 1
        func word() -> String {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Int(seed >> 33)
            return r % 5 == 0 ? "w\(r % 20_000)" : ["the", "sea", "and", "of", "a", "whale"][r % 6]
        }
        let paragraphs = (0..<10_000).map { index in "Part\(index) " + (0..<20).map { _ in word() }.joined(separator: " ") + "." }
        let old = paragraphs.joined(separator: "\n")
        var changed = paragraphs.map { $0.replacingOccurrences(of: " the ", with: " le ") }
        changed.swapAt(10, 9_000)
        let new = "A new preface.\n" + changed.joined(separator: "\n")
        let start = Date()
        let alignment = Alignment(old: old, new: new)
        #expect(Date().timeIntervalSince(start) < 10)
        for part in ["Part5000 ", "Part11 ", "Part9001 ", "Part9999 "] {
            #expect(alignment.map((old as NSString).range(of: part).location) == (new as NSString).range(of: part).location, "\(part)")
        }
    }

    @Test func chaptersOfOneDocumentMapAcrossADifferentSplit() {
        let first = ReaderChapter(id: "a", title: "A", text: "One two three.", source: "doc.xhtml")
        let second = ReaderChapter(id: "a#2", title: "A (2)", text: "Four five six.", source: "doc.xhtml")
        let other = ReaderChapter(id: "b", title: "B", text: "Seven eight.", source: "b.xhtml")
        let joined = ReaderChapter(id: "a", title: "A", text: "One two three.\nFour 5 five six.", source: "doc.xhtml")
        let remap = TextRemap(old: [first, second, other], new: [joined, other])
        let mapped = remap.map(chapter: 1, offset: ("Four five six." as NSString).range(of: "five").location)
        #expect(mapped.chapter == 0)
        #expect(mapped.offset == (joined.text as NSString).range(of: "five").location)
        #expect(remap.map(chapter: 2, offset: 6) == (1, 6))
    }

    @Test func unknownStylesAreDroppedNotFatal() throws {
        let json = #"{"id":"c","title":"T","text":"Hello world","styles":[{"location":0,"length":5,"style":"bold"},{"location":6,"length":5,"style":"hologram"}]}"#
        let chapter = try JSONDecoder().decode(ReaderChapter.self, from: Data(json.utf8))
        #expect(chapter.styles.map(\.style) == [.bold])
    }

    @Test func savedWordsAreFoundAgainNearby() {
        let item = SavedPassage(bookID: UUID(), bookTitle: "B", chapterTitle: "C", chapterIndex: 0, offset: 0, selection: "curious",
                                sentence: "She looked at the curious formula.")
        let text = "Intro. She looked at the curious formula."
        let expected = (text as NSString).range(of: "curious").location
        #expect(LibraryStore.locate(item, in: text, near: expected) == expected)
        #expect(LibraryStore.locate(item, in: text, near: expected + 3) == expected)
        #expect(LibraryStore.locate(item, in: text, near: 0) == expected)
    }
}

/// What the saved places of a library point at, read from the files themselves.
private struct LibraryWords {
    var positions: [UUID: String] = [:]
    var favorites: [UUID: String] = [:]
    var contentFiles: [UUID: String] = [:]

    init(directory: URL) {
        guard let library = try? JSONDecoder().decode(StoredBooks.self, from: Data(contentsOf: directory.appendingPathComponent("library.json"))) else { return }
        var texts: [UUID: [String]] = [:]
        for book in library.books where !book.isSample {
            let file = book.contentFile ?? BookDirectory.firstContentFile
            contentFiles[book.id] = file
            let url = directory.appendingPathComponent("books/\(book.id.uuidString)/\(file)")
            guard let content = try? JSONDecoder().decode(BookContent.self, from: Data(contentsOf: url)) else { continue }
            texts[book.id] = content.chapters.map(\.text)
            if content.chapters.indices.contains(book.position.chapter) {
                positions[book.id] = Self.word(at: book.position.offset, in: content.chapters[book.position.chapter].text)
            }
        }
        for item in library.favorites {
            guard let chapters = texts[item.bookID], chapters.indices.contains(item.chapterIndex) else { continue }
            let text = chapters[item.chapterIndex] as NSString
            favorites[item.id] = text.substring(with: NSRange(location: item.offset, length: min((item.selection as NSString).length, text.length - item.offset)))
        }
    }

    /// The word at or right after `offset`, skipping any leading spaces or punctuation.
    static func word(at offset: Int, in text: String) -> String {
        let text = text as NSString
        var start = max(0, offset)
        while start < text.length, let scalar = Unicode.Scalar(text.character(at: start)), !CharacterSet.alphanumerics.contains(scalar) {
            start += 1
        }
        var end = start
        while end < text.length, let scalar = Unicode.Scalar(text.character(at: end)), CharacterSet.alphanumerics.contains(scalar) {
            end += 1
        }
        return text.substring(with: NSRange(location: start, length: end - start))
    }
}

/// The parts of `library.json` the tests read, in any version from v0.1.0 on.
private struct StoredBooks: Decodable {
    struct Book: Decodable {
        var id: UUID
        var title: String
        var isSample: Bool
        var hasPackage: Bool?
        var contentFile: String?
        var position: ReadingPosition
    }
    struct Favorite: Decodable {
        var id: UUID
        var bookID: UUID
        var chapterIndex: Int
        var offset: Int
        var selection: String
    }
    var books: [Book]
    var favorites: [Favorite]
}

/// Writes a data fixture for `DataVersion.current` when `$READLING_WRITE_FIXTURE` is set (invoked by
/// `python3 Tools/app_release.py post-release` after tagging a release; a no-op during ordinary test runs).
@MainActor @Test func writeCurrentDataFixtureWhenRequested() async throws {
    guard let destination = ProcessInfo.processInfo.environment["READLING_WRITE_FIXTURE"], !destination.isEmpty else { return }
    let out = URL(fileURLWithPath: destination, isDirectory: true)
    try? FileManager.default.removeItem(at: out)
    let data = out.appendingPathComponent("Readling", isDirectory: true)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let suite = "ReadlingFixture-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let domain = SettingsDomain(defaults: defaults, name: suite)
    let store = LibraryStore(fileURL: data.appendingPathComponent("library.json"), settings: domain)

    let bundle = Bundle(for: FixtureMarker.self)
    func fixture(_ name: String, _ ext: String) throws -> URL {
        try #require(bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }
    let alice = try await store.importBook(url: try fixture("alice", "epub"))
    let formulas = try await store.importBook(url: try fixture("formulas", "epub"))
    let verse = try await store.importBook(url: try fixture("verse", "txt"))

    func save(_ book: UUID, chapter: Int, _ word: String, sentence: String, translation: (String, String)? = nil) async throws -> UUID {
        let item = try #require(store.books.first { $0.id == book })
        let text = try await store.content(for: item).chapters[chapter].text as NSString
        let range = text.range(of: word)
        #expect(range.location != NSNotFound, "\(word)")
        #expect(store.savePassage(bookID: book, chapter: chapter, offset: range.location, selection: word, sentence: sentence,
                                  translation: translation) == .saved)
        return try #require(store.favorites.first).id
    }
    func offset(of word: String, in book: UUID, chapter: Int) async throws -> Int {
        let item = try #require(store.books.first { $0.id == book })
        return (try await store.content(for: item).chapters[chapter].text as NSString).range(of: word).location
    }

    let curious = try await save(formulas, chapter: 0, "curious", sentence: "She looked at the curious formula and smiled, because the meaning was suddenly plain.")
    _ = try await save(formulas, chapter: 0, "suddenly plain", sentence: "She looked at the curious formula and smiled, because the meaning was suddenly plain.",
                       translation: ("突然变得清楚", "机器翻译 · Apple 本机翻译"))
    let ledger = try await save(formulas, chapter: 1, "balanced", sentence: "At the end of the day the ledger balanced, and the shopkeeper was content.")
    _ = try await save(verse, chapter: 0, "traveller", sentence: "A traveller came along the road and paused beside the gate, wondering whether anyone was home.")
    _ = try await save(alice, chapter: 2, "rabbit", sentence: "")
    store.review(id: curious, remembered: true)
    store.setMastered(id: ledger, true)

    store.savePosition(bookID: formulas, chapter: 1, offset: try await offset(of: "Nothing else happened", in: formulas, chapter: 1), fraction: 0.9)
    store.savePosition(bookID: verse, chapter: 1, offset: try await offset(of: "They talked", in: verse, chapter: 1))
    store.savePosition(bookID: alice, chapter: 3, offset: try await offset(of: "quite forgot", in: alice, chapter: 3))
    store.persist()

    let endpoint = AIEndpoint(name: "Fixture", format: .openAI, baseURL: "https://example.com/v1", model: "fixture-model")
    let settings: [String: Any] = [
        SettingsKeys.readerFont: ReaderTypography.defaultSize + 2,
        SettingsKeys.readerTypeface: ReaderTypeface.georgia.rawValue,
        SettingsKeys.readerLineSpacing: 1.5,
        SettingsKeys.readerParagraphSpacing: 1.0,
        SettingsKeys.readerMargin: 30.0,
        SettingsKeys.readerAppearance: "dark",
        SettingsKeys.readerDayTheme: ReaderTheme.defaultDay,
        SettingsKeys.readerNightTheme: ReaderTheme.defaultNight,
        SettingsKeys.readerBackdrop: ReaderBackdrop.linen.rawValue,
        SettingsKeys.readerPageTurn: PageTurn.curl.rawValue,
        SettingsKeys.readerEyeCare: true,
        SettingsKeys.readerAutoSpeed: 4,
        SettingsKeys.readerKeepAwake: true,
        SettingsKeys.dictionaryExpandByDefault: true,
        SettingsKeys.dictionaryAccent: "en-GB",
        SettingsKeys.lastReadBookID: formulas.uuidString,
        SettingsKeys.translationEngine: TranslationProviderID.ai(endpoint.id).rawValue,
        SettingsKeys.translationAutomatic: false,
        SettingsKeys.translationDeepLAddress: "https://api-free.deepl.com",
        SettingsKeys.translationPromptTranslate: "Translate into Chinese: {text}",
        SettingsKeys.aiEndpoints: try JSONEncoder().encode([endpoint]),
    ]
    try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        .write(to: out.appendingPathComponent("settings.plist"))
}
