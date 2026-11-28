import Foundation
import Testing
import UIKit
@testable import Readling

@Suite("Offline library storage") @MainActor
struct LibraryTests {
    @Test func firstLaunchSeedsSampleButRemovedSampleStaysRemoved() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        #expect(store.readFailure == nil)
        let sample = try #require(store.books.first)
        #expect(store.books.count == 1 && sample.isSample)
        #expect(sample.chapters.count == 3)
        let content = try await store.content(for: sample)
        #expect(content.chapters[0].text.hasPrefix("Alice was beginning"))
        #expect(!content.chapters[0].text.contains("\n\n"))
        #expect(content.chapters[0].styles.contains { $0.style == .italic })
        #expect(sample.chapters[0].length == content.chapters[0].text.utf16.count)
        store.addSample()
        #expect(store.books.count == 1)
        store.removeBook(id: sample.id)
        let reopened = LibraryStore(fileURL: file)
        #expect(reopened.books.isEmpty)
        #expect(reopened.readFailure == nil)
    }

    @Test func bookTextLivesOutsideTheLibraryFile() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let source = folder.appendingPathComponent("A little book.txt")
        try Data("\u{FEFF}Hello <world> & friends.\r\nSecond line 🌿.".utf8).write(to: source)
        let store = LibraryStore(fileURL: file)
        let id = try await store.importBook(url: source)
        #expect(store.books.first?.id == id)
        #expect(store.books.first?.title == "A little book")
        let library = try String(contentsOf: file, encoding: .utf8)
        #expect(!library.contains("Second line"))
        let reopened = LibraryStore(fileURL: file)
        let book = try #require(reopened.books.first { $0.id == id })
        let content = try await reopened.content(for: book)
        #expect(content.chapters.first?.text == "Hello <world> & friends.\nSecond line 🌿.")
        let renamed = folder.appendingPathComponent("renamed.txt")
        try FileManager.default.copyItem(at: source, to: renamed)
        do {
            _ = try await reopened.importBook(url: renamed)
            Issue.record("Identical bytes with a new filename must be a duplicate")
        } catch LibraryError.duplicate(let existingID) {
            #expect(existingID == id)
        }
        let files = reopened.directory(for: id)
        #expect(FileManager.default.fileExists(atPath: files.content(BookDirectory.firstContentFile).path))
        reopened.removeBook(id: id)
        #expect(!FileManager.default.fileExists(atPath: files.url.path))
    }

    @Test func positionsWordsAndRemovalRoundTrip() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let source = folder.appendingPathComponent("book.txt")
        let text = "She peeped into a lovely 🌿 garden. Another sentence."
        try Data(text.utf8).write(to: source)
        let store = LibraryStore(fileURL: file)
        let id = try await store.importBook(url: source)
        store.savePosition(bookID: id, chapter: 0, offset: Int.max)
        #expect(store.books.first?.position.offset == text.utf16.count)
        // The last page starts before the end of the text; having seen all of it still finishes the book.
        store.savePosition(bookID: id, chapter: 0, offset: 10, fraction: 0.5)
        #expect(store.books.first?.isFinished == false)
        store.savePosition(bookID: id, chapter: 0, offset: 10, fraction: 1)
        #expect(store.books.first?.isFinished == true)
        #expect(store.books.first?.percentRead == 100)
        store.savePosition(bookID: id, chapter: 0, offset: Int.max)
        store.persist()
        let reopened = LibraryStore(fileURL: file)
        #expect(reopened.books.first?.position.offset == text.utf16.count)
        #expect(reopened.savePassage(bookID: id, chapter: 0, offset: 4, selection: "peeped", sentence: "She peeped into a lovely 🌿 garden.") == .saved)
        // Another form of the same word is the same card.
        #expect(reopened.savePassage(bookID: id, chapter: 0, offset: 0, selection: "peep", sentence: "x") == .alreadySaved)
        #expect(reopened.favorites.count == 1)
        let passage = try #require(reopened.favorites.first)
        #expect(passage.headword == "peep")
        #expect(passage.definition?.contains("窥视") == true)
        reopened.setMastered(id: passage.id, true)
        reopened.removeBook(id: id)
        let afterRemoval = LibraryStore(fileURL: file)
        #expect(afterRemoval.books.allSatisfy { $0.id != id })
        #expect(afterRemoval.favorites.first?.mastered == true)
        #expect(afterRemoval.favorites.first?.bookTitle == "book")
        afterRemoval.deleteFavorite(id: passage.id)
        #expect(LibraryStore(fileURL: file).favorites.isEmpty)
        afterRemoval.restoreFavorite(passage)
        #expect(LibraryStore(fileURL: file).favorites.count == 1)
    }

    @Test func savedExpressionKeepsItsTranslationButWordsKeepTheDictionary() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let sample = try #require(store.books.first)
        let sentence = "Alice was beginning to get very tired of sitting by her sister."
        #expect(store.savePassage(bookID: sample.id, chapter: 0, offset: 0, selection: sentence, sentence: sentence,
                                  translation: ("爱丽丝开始觉得很累。", "机器翻译 · 测试引擎")) == .saved)
        let saved = try #require(store.favorite(matching: sentence))
        #expect(saved.definition == "爱丽丝开始觉得很累。" && saved.definitionSource == "机器翻译 · 测试引擎")
        #expect(saved.isExpression && saved.displayWord == sentence)
        store.savePassage(bookID: sample.id, chapter: 0, offset: 0, selection: "tired", sentence: sentence,
                          translation: ("累", "机器翻译 · 测试引擎"))
        let word = try #require(store.favorite(matching: "tired"))
        #expect(word.definition != "累" && word.definitionSource == nil && !word.isExpression)
    }

    @Test func reviewSchedulesLongerGapsUntilMastered() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let sample = try #require(store.books.first)
        store.savePassage(bookID: sample.id, chapter: 0, offset: 0, selection: "tired", sentence: "Alice was beginning to get very tired.")
        let id = try #require(store.favorites.first?.id)
        #expect(store.favorites[0].isDue(at: .now))
        store.review(id: id, remembered: true)
        #expect(!store.favorites[0].isDue(at: .now))
        #expect(store.favorites[0].isDue(at: .now.addingTimeInterval(86_400 * 1.1)))
        store.review(id: id, remembered: false)
        #expect(store.favorites[0].reviewStage == 0)
        #expect(!store.favorites[0].isDue(at: .now))
        for _ in LibraryStore.reviewIntervals { store.review(id: id, remembered: true) }
        #expect(store.favorites[0].mastered)
    }

    @Test func unreadableLibraryIsNeverOverwrittenAndCanBeSetAside() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let original = Data("not a library {".utf8)
        try original.write(to: file)
        let store = LibraryStore(fileURL: file)
        #expect(store.readFailure != nil)
        #expect(store.books.isEmpty)
        store.addSample()
        store.persist()
        #expect(store.books.isEmpty)
        #expect(try Data(contentsOf: file) == original)
        store.retryLoading()
        #expect(store.readFailure != nil)
        store.setAsideUnreadableLibrary()
        #expect(store.readFailure == nil)
        #expect(store.books.first?.isSample == true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("library-unreadable-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(backups[0])) == original)
    }

    @Test func writeFailureDoesNotPublishWordOrRemoval() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: file)
        let sample = try #require(store.books.first)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(store.savePassage(bookID: sample.id, chapter: 0, offset: 0, selection: "Alice", sentence: "Alice was tired.") == .failed)
        #expect(store.errorMessage != nil)
        #expect(store.favorites.isEmpty)
        store.removeBook(id: sample.id)
        #expect(store.books.map(\.id) == [sample.id])
    }

    @Test func cancelledImportDoesNotPublishBook() async throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("cancelled.txt")
        try Data("Do not import me.".utf8).write(to: source)
        let store = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        let task = Task { try await store.importBook(url: source) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled import must throw")
        } catch is CancellationError { }
        #expect(store.books.count == 1)
        #expect(store.books.first?.isSample == true)
    }
}

@Suite("Offline dictionary") @MainActor
struct DictionaryTests {
    /// The bundled core alone, whatever packs the simulator has downloaded.
    let coreOnly = WordDictionary(directory: nil)

    @Test func lookupsResolveInflectionsAndContractions() throws {
        let dictionary = coreOnly
        #expect(dictionary.isAvailable)
        let peeped = try #require(dictionary.lookup("peeped"))
        #expect(peeped.headword == "peep" && peeped.inflectedFrom == "peeped")
        #expect(dictionary.lookup("went")?.headword == "go")
        #expect(dictionary.lookup("Daisies")?.headword == "daisy")
        #expect(dictionary.lookup("they’ll") != nil)
        #expect(dictionary.lookup("Hatter’s")?.headword == "hatter")
        #expect(dictionary.lookup("Rabbit's")?.headword == "rabbit")
        #expect(dictionary.lookup("Alice") == nil) // Not the acronym ALICE.
        #expect(dictionary.lookup("marmalade")?.definition.contains("果酱") == true)
        #expect(dictionary.headword(for: "peeped") == "peep")
    }

    @Test func coreCarriesPhrasesAndTheirInflections() throws {
        let dictionary = coreOnly
        #expect(dictionary.lookup("give up")?.definition.contains("放弃") == true)
        let gaveUp = try #require(dictionary.lookup("Gave  up"))
        #expect(gaveUp.headword == "give up" && gaveUp.inflectedFrom == "gave up")
        #expect(dictionary.headword(for: "gave up") == "give up")
        #expect(dictionary.lookup("a fly in the ointment") != nil)
        let phrases = dictionary.phrases(startingWith: "take").map(\.headword)
        #expect(phrases.contains("take after"))
        #expect(phrases.allSatisfy { $0.hasPrefix("take ") })
    }

    @Test func entriesCarryTheExpandedFields() throws {
        let dictionary = coreOnly
        let go = try #require(dictionary.lookup("go"))
        #expect(go.forms.contains { $0.kind == "p" && $0.word == "went" })
        #expect(go.collins == 5 && go.isOxford3000 && go.tags.contains("gk"))
        #expect(go.source == "核心词典")
        #expect(dictionary.lookup("marmalade")?.englishDefinition.contains("citrus") == true)
        // The short definition keeps at most four lines and leaves web senses to the expanded card.
        let off = try #require(dictionary.lookup("off"))
        #expect(off.definition.split(separator: "\n").count == 4 && !off.moreTranslation.isEmpty)
        let be = try #require(dictionary.lookup("be"))
        #expect(!be.definition.contains("[计]") && be.moreTranslation.contains("[计]"))
        #expect(dictionary.lookup("into")?.englishDefinition.contains("variety of applications") == true)
        let aboutTurn = try #require(dictionary.lookup("about turn"))
        #expect(!aboutTurn.definition.contains("[网络]") && aboutTurn.moreTranslation.hasPrefix("[网络]"))
    }

    @Test func formsWithMeaningsOfTheirOwnKeepThem() throws {
        let dictionary = coreOnly
        let found = try #require(dictionary.lookup("found"))
        #expect(found.headword == "find" && found.inflectedFrom == "found")
        #expect(found.ownSense?.contains("建立") == true && found.ownSense?.contains("find") == false)
        #expect(dictionary.lookup("peeped")?.ownSense == nil)
        #expect(dictionary.lookup("went")?.ownSense == nil)
        #expect(WordDictionary.withoutInflectionNotes("v. 窥视( peep的过去式和过去分词 ); 偷看\nfind的过去式和过去分词")
                == "v. 窥视; 偷看")
    }

    @Test func packsCombineAsAUnionAndKeysIgnoreWhichAreInstalled() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let core = folder.appendingPathComponent("core.sqlite")
        let downloads = folder.appendingPathComponent("packs", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try makePack(at: core, id: "core", order: 0, entries: [("abdicates", "abdicate的第三人称单数")], forms: [("abdicates", "abdicate")])
        try makePack(at: downloads.appendingPathComponent("old.sqlite"), id: "old", order: 5, entries: [("abdicate", "旧")], schema: 1)

        let coreOnly = WordDictionary(core: core, directory: downloads)
        #expect(coreOnly.packs.map(\.id) == ["core"]) // The wrong schema is ignored.
        let fallback = try #require(coreOnly.lookup("abdicates"))
        #expect(fallback.headword == "abdicate" && fallback.inflectedFrom == "abdicates" && fallback.source == "core")

        try makePack(at: downloads.appendingPathComponent("extended.sqlite"), id: "extended", order: 10,
                     entries: [("abdicate", "vt. 退位"), ("abdicate the throne", "让位")])
        let union = WordDictionary(core: core, directory: downloads)
        #expect(union.packs.map(\.id) == ["core", "extended"])
        let full = try #require(union.lookup("abdicates"))
        #expect(full.headword == "abdicate" && full.definition == "vt. 退位" && full.source == "extended")
        #expect(union.headword(for: "abdicates") == coreOnly.headword(for: "abdicates"))
        #expect(union.phrases(startingWith: "abdicate").map(\.headword) == ["abdicate the throne"])
    }

}

@Suite("Bounded EPUB and TXT importer")
struct BookImporterTests {
    @Test func spineOrderNavigationMetadataAndSafeEmphasis() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("fixture.epub")
        try epubFixture().write(to: source)
        let result = try BookImporter.load(url: source)
        #expect(result.fingerprint.count == 64)
        #expect(result.book.title == "Fixture & Book")
        #expect(result.book.author == "A. Writer")
        #expect(result.content.chapters.map(\.id) == ["OPS/two.xhtml", "OPS/one.xhtml"])
        #expect(result.book.chapters.map(\.title) == ["Second from navigation", "First from navigation"])
        let chapter = try #require(result.content.chapters.first)
        let text = chapter.text as NSString
        #expect(chapter.text.hasPrefix("Second heading\nSecond & readable italic words."))
        #expect(chapter.styles.contains { $0.style == .italic && text.substring(with: $0.range) == "italic words" })
        #expect(chapter.styles.contains { $0.style == .heading && text.substring(with: $0.range) == "Second heading" })
        for unsafe in ["alert(", "hidden styling", "Fallback title", "https://"] {
            #expect(!chapter.text.contains(unsafe))
        }
        #expect(chapter.text.contains("A safe label"))
    }

    @Test func epub2NCXTitlesAndHarmlessExternalDoctype() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("epub2.epub")
        try epubFixture(ncx: true, externalDoctype: true).write(to: source)
        let result = try BookImporter.load(url: source)
        #expect(result.book.chapters.first?.title == "Second from NCX")
        #expect(result.content.chapters.first?.text.contains("Second & readable") == true)
    }

    @Test func tablesAndDefinitionListsRetainWordBoundaries() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body><table style="color:red"><thead><tr><th>Hello</th><th>world</th></tr></thead><tbody><tr><td>One</td><td><em>two</em></td></tr></tbody></table><dl><dt>Term</dt><dd>Definition</dd><dt>Next</dt><dd>Meaning</dd></dl></body></html>
        """
        let source = folder.appendingPathComponent("tables.epub")
        try storedZIP(replacingSecondChapter(with: chapter)).write(to: source)
        let result = try #require(BookImporter.load(url: source).content.chapters.first)
        #expect(result.text == "Hello\tworld\nOne\ttwo\nTerm\nDefinition\nNext\nMeaning")
    }

    @Test func completeOfflineXHTMLEntitiesDoNotExpandCDATAOrEscapesTwice() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chapter = """
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "https://never-fetch.invalid/xhtml.dtd"><html xmlns="http://www.w3.org/1999/xhtml"><body><p title="caf&eacute;">caf&eacute; &reg; &bull; &Alpha; &euro; &rarr; &sum; &spades; &apos;</p><p>&lt;tag&gt; &quot;yes&quot; &amp; &apos;</p><p>&amp;eacute;</p><p><![CDATA[Literal &eacute;]]></p><p>&#233; &#x00E9;</p></body></html>
        """
        let source = folder.appendingPathComponent("entities.epub")
        try storedZIP(replacingSecondChapter(with: chapter)).write(to: source)
        let result = try #require(BookImporter.load(url: source).content.chapters.first)
        #expect(result.text == "café ® • Α € → ∑ ♠ '\n<tag> \"yes\" & '\n&eacute;\nLiteral &eacute;\né é")
        // Tag soup a strict parser rejects still imports through the lenient path.
        let soup = "<html><body><p>Unclosed &notAStandardEntity; <i>tag<p>Next &nbsp;para<br>line</body>"
        let lenient = folder.appendingPathComponent("soup.epub")
        try storedZIP(replacingSecondChapter(with: soup)).write(to: lenient)
        let soupChapter = try #require(BookImporter.load(url: lenient).content.chapters.first)
        #expect(soupChapter.text == "Unclosed &notAStandardEntity; tag\nNext \u{00A0}para\u{2028}line")
    }

    @Test func fontObfuscationIsNotDRMButEncryptedTextIs() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        func encryption(_ algorithm: String, _ uri: String) -> Data {
            Data("""
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="\(algorithm)"/><enc:CipherData><enc:CipherReference URI="\(uri)"/></enc:CipherData></enc:EncryptedData></encryption>
            """.utf8)
        }
        let fonts = folder.appendingPathComponent("fonts.epub")
        try epubFixture(extras: [("META-INF/encryption.xml", encryption("http://www.idpf.org/2008/embedding", "OPS/font.otf"), nil)]).write(to: fonts)
        #expect(try BookImporter.load(url: fonts).content.chapters.count == 2)
        let drm = folder.appendingPathComponent("drm.epub")
        try epubFixture(extras: [("META-INF/encryption.xml", encryption("http://www.w3.org/2001/04/xmlenc#aes128-cbc", "OPS/two.xhtml"), nil)]).write(to: drm)
        #expect(throws: BookImporter.ImportError.self) { _ = try BookImporter.load(url: drm) }
    }

    @Test func rejectsUnsafePathsFixedLayoutAndInternalEntities() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [(String, Data)] = [
            ("unsafe", epubFixture(extras: [("../escape.txt", Data("escape".utf8), nil)])),
            ("fixed", epubFixture(fixedLayout: true)),
            ("entities", epubFixture(internalEntity: true))
        ]
        for (name, data) in cases {
            let file = folder.appendingPathComponent("\(name).epub")
            try data.write(to: file)
            #expect(throws: (any Error).self) { _ = try BookImporter.load(url: file) }
        }
        // An unsafe navigation link is ignored; it only ever supplied a title.
        let nav = folder.appendingPathComponent("bad-nav.epub")
        try epubFixture(unsafeNavigation: true).write(to: nav)
        #expect(try BookImporter.load(url: nav).book.chapters.first?.title == "Second heading")
    }

    @Test func rejectsCorruptUnsupportedAndEmpty() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [(String, Data)] = [("broken.epub", Data("not a zip".utf8)), ("book.pdf", Data("%PDF".utf8)),
                                      ("empty.txt", Data(" \r\n\t".utf8)), ("binary.txt", Data([0x00, 0x01, 0xFA, 0x00]))]
        for (name, data) in cases {
            let file = folder.appendingPathComponent(name)
            try data.write(to: file)
            #expect(throws: (any Error).self) { _ = try BookImporter.load(url: file) }
        }
    }

    @Test func archiveSizeAndExpandedBudgetAreEnforcedBeforeExtraction() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let huge = folder.appendingPathComponent("huge.epub")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        // Sparse, so the test doesn't write a gigabyte.
        try handle.truncate(atOffset: UInt64(1 << 30) + 1)
        try handle.close()
        do {
            _ = try BookImporter.load(url: huge)
            Issue.record("A file over the size limit must be rejected before it is read")
        } catch BookImporter.ImportError.tooLarge { }
        // Five declared 500 MiB entries fit the per-entry ceiling but exceed the 2 GiB sum.
        let extras: [(String, Data, UInt32?)] = (0..<5).map { ("images/\($0).bin", Data(), UInt32(500 * 1_024 * 1_024)) }
        let bomb = folder.appendingPathComponent("expanded.epub")
        try epubFixture(extras: extras).write(to: bomb)
        do {
            _ = try BookImporter.load(url: bomb)
            Issue.record("Expanded-size budget must reject this archive")
        } catch BookImporter.ImportError.tooLarge { }
    }

    @Test func missingChapterIsSkippedButCRCFailureIsRejected() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("missing.epub")
        try storedZIP(fixtureEntries().filter { $0.0 != "OPS/two.xhtml" }).write(to: source)
        #expect(try BookImporter.load(url: source).content.chapters.map(\.id) == ["OPS/one.xhtml"])
        var broken = epubFixture()
        // Mutate the first local file payload, leaving its central-directory CRC unchanged.
        broken[30 + "mimetype".utf8.count] ^= 0x01
        let corrupt = folder.appendingPathComponent("bad-crc.epub")
        try broken.write(to: corrupt)
        #expect(throws: (any Error).self) { _ = try BookImporter.load(url: corrupt) }
    }

    @Test func gutenbergTextGetsChaptersParagraphsAndVerse() throws {
        let folder = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = """
        The Project Gutenberg eBook of Test
        *** START OF THE PROJECT GUTENBERG EBOOK TEST ***

        Contents

         CHAPTER I.     Down the Rabbit-Hole
         CHAPTER II.    The Pool of Tears
         CHAPTER III.   A Caucus-Race and a Long Tale

        CHAPTER I.
        Down the Rabbit-Hole


        Alice was beginning to get very tired of sitting by her sister on the
        bank, and of having nothing to do: once or twice she had peeped into
        the book her sister was reading.

        So she was considering in her own mind (as well as she could, for the
        hot day made her feel very sleepy and stupid).

        CHAPTER II.
        The Pool of Tears

        “Curiouser and curiouser!” cried Alice.

           “How doth the little crocodile
            Improve his shining tail,
           And pour the waters of the Nile
            On every golden scale!”

        *** END OF THE PROJECT GUTENBERG EBOOK TEST ***
        License text that must not appear.
        """
        let source = folder.appendingPathComponent("alice.txt")
        try Data(text.utf8).write(to: source)
        let content = try BookImporter.load(url: source).content
        #expect(content.chapters.map(\.title) == ["CHAPTER I. · Down the Rabbit-Hole", "CHAPTER II. · The Pool of Tears"])
        let first = content.chapters[0].text
        #expect(first.contains("on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading.\nSo she"))
        let second = content.chapters[1].text
        #expect(second.contains("crocodile\u{2028}Improve his shining tail"))
        #expect(!second.contains("License text"))
        // Windows-1252 text still imports.
        let latin = folder.appendingPathComponent("latin.txt")
        try Data([0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x6F, 0x6B, 0x94]).write(to: latin)
        #expect(try BookImporter.load(url: latin).content.chapters.first?.text == "Café “ok”")
    }

    @Test func longTextIsSplitIntoBoundedChapters() throws {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        var builder = ChapterTextBuilder()
        for index in 0..<200 {
            if index == 150 { builder.push(.italic); builder.anchor("deep") }
            builder.append(paragraph)
            if index == 150 { builder.pop(.italic) }
            builder.paragraphBreak()
        }
        let result = builder.finish()
        let pieces = ChapterLayout.split(ReaderChapter(id: "c", title: "Long", text: result.text, styles: result.styles,
                                                       source: "a.xhtml", anchors: result.anchors), maximumLength: 30_000)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.text.utf16.count <= 30_000 })
        #expect(pieces.map(\.text).joined(separator: "\n") == result.text)
        let styled = pieces.flatMap { piece in piece.styles.map { (piece.text as NSString).substring(with: $0.range) } }
        #expect(styled == [paragraph.trimmingCharacters(in: .whitespaces)])
        // The anchor moves with its paragraph into the piece that holds it.
        let holder = try #require(pieces.first { $0.anchors["deep"] != nil })
        #expect(holder.styles.first?.location == holder.anchors["deep"])
        #expect(pieces.allSatisfy { $0.source == "a.xhtml" })
        let place = try #require(BookContent(chapters: pieces).location(ofPath: "a.xhtml", fragment: "deep"))
        #expect(pieces[place.chapter].id == holder.id)
        #expect(BookContent(chapters: pieces).location(ofPath: "a.xhtml", fragment: "missing").map { [$0.chapter, $0.offset] } == [0, 0])
    }
}

@Suite("Canonical reader text coordinates") @MainActor
struct ReadingSurfaceContractTests {
    @Test func englishTokensUseUTF16AndKeepApostrophesAndHyphens() {
        let string = "😀 Don't re-enter; mother-in-law can’t."
        let ranges = ReadingSurface.englishWordRanges(in: string)
        #expect(ranges == [NSRange(location: 3, length: 5), NSRange(location: 9, length: 8),
                           NSRange(location: 19, length: 13), NSRange(location: 33, length: 5)])
    }

    @Test func renderedStringIsExactlyTheChapterText() {
        let chapter = ReaderChapter(id: "c", title: "T", text: "Title\nPlain 😀 italic text.",
                                    styles: [TextStyleRun(location: 0, length: 5, style: .heading),
                                             TextStyleRun(location: 15, length: 6, style: .italic)])
        let rendered = ReadingSurface.attributedText(for: chapter, size: 20)
        #expect(rendered.string == chapter.text)
        let font = rendered.attribute(.font, at: 16, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        let heading = rendered.attribute(.font, at: 1, effectiveRange: nil) as? UIFont
        #expect((heading?.pointSize ?? 0) > 20)
    }

    @Test func readerLayoutKeepsTextAndAppliesSpacing() {
        let chapter = ReaderChapter(id: "c", title: "T", text: "Title\nPlain italic text.",
                                    styles: [TextStyleRun(location: 0, length: 5, style: .heading),
                                             TextStyleRun(location: 12, length: 6, style: .italic)])
        let layout = ReaderLayout(fontSize: 20, typeface: .georgia, lineSpacing: 1.8, paragraphSpacing: 1.2, margin: 30)
        let rendered = ReadingSurface.attributedText(for: chapter, size: 20, layout: layout)
        #expect(rendered.string == chapter.text)
        let paragraph = rendered.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
        #expect(paragraph?.lineHeightMultiple == 1.8)
        #expect(paragraph?.paragraphSpacing == 24)
        let italic = rendered.attribute(.font, at: 13, effectiveRange: nil) as? UIFont
        #expect(italic?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
    }

    @Test func bookSearchFindsMatchesAcrossChaptersInOrder() {
        let chapters = [ReaderChapter(id: "a", title: "A", text: "Alice was beginning to get very tired.\nALICE again."),
                        ReaderChapter(id: "b", title: "B", text: "No match here."),
                        ReaderChapter(id: "c", title: "C", text: "Said 😀 alice.")]
        let result = BookSearch.search("alice", in: chapters)
        #expect(result.hits.map(\.chapter) == [0, 0, 2])
        #expect(result.hits.map(\.offset) == [0, 39, 8])
        #expect(!result.truncated)
        #expect(String(result.hits[2].snippet.characters).contains("😀 alice"))
        #expect(BookSearch.search("alice", in: chapters, limit: 2).truncated)
        #expect(BookSearch.search("  ", in: chapters).hits.isEmpty)
    }

    @Test func offsetsMapAcrossWhitespaceChanges() {
        let old = "One.\n\nTwo  words."
        let new = "One.\nTwo words."
        #expect(Alignment(old: old, new: new).map((old as NSString).range(of: "words").location) == (new as NSString).range(of: "words").location)
    }
}

func replacingSecondChapter(with chapter: String) -> [(String, Data, UInt32?)] {
    fixtureEntries().map { $0.0 == "OPS/two.xhtml" ? ($0.0, Data(chapter.utf8), $0.2) : $0 }
}

func scratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReadlingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func epubFixture(ncx: Bool = false, externalDoctype: Bool = false, fixedLayout: Bool = false,
                         internalEntity: Bool = false, unsafeNavigation: Bool = false,
                         extras: [(String, Data, UInt32?)] = []) -> Data {
    storedZIP(fixtureEntries(ncx: ncx, externalDoctype: externalDoctype, fixedLayout: fixedLayout,
                             internalEntity: internalEntity, unsafeNavigation: unsafeNavigation) + extras)
}

private func fixtureEntries(ncx: Bool = false, externalDoctype: Bool = false, fixedLayout: Bool = false,
                            internalEntity: Bool = false, unsafeNavigation: Bool = false) -> [(String, Data, UInt32?)] {
    let container = """
    <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
    let navigationItem = ncx ? "<item id=\"toc\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>" : "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
    let opf = """
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture &amp; Book</dc:title><dc:creator>A. Writer</dc:creator>\(fixedLayout ? "<meta property=\"rendition:layout\">pre-paginated</meta>" : "")</metadata><manifest><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>\(navigationItem)</manifest><spine\(ncx ? " toc=\"toc\"" : "")><itemref idref="two"/><itemref idref="one"/></spine></package>
    """
    let doctype = internalEntity ? "<!DOCTYPE html [<!ENTITY unsafe 'entity expansion'>]>" : externalDoctype ? "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">" : ""
    let second = """
    \(doctype)<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fallback title</title><style>hidden styling</style></head><body><h1>Second heading</h1><p onclick="alert(1)">Second &amp; readable <em>italic words</em>.</p><script>alert('unsafe')</script><iframe src="https://example.invalid"/><img src="https://example.invalid/a.png"/><a href="javascript:alert(1)">A safe label</a></body></html>
    """
    let nav = """
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="\(unsafeNavigation ? "../../../escape.xhtml" : "two.xhtml#start")">Second from navigation</a></li><li><a href="one.xhtml">First from navigation</a></li></ol></nav></body></html>
    """
    let ncxText = """
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint id="n1"><navLabel><text>Second from NCX</text></navLabel><content src="two.xhtml#start"/></navPoint><navPoint id="n2"><navLabel><text>First from NCX</text></navLabel><content src="one.xhtml"/></navPoint></navMap></ncx>
    """
    let content: [(String, String)] = [
        ("mimetype", "application/epub+zip"), ("META-INF/container.xml", container), ("OPS/book.opf", opf),
        ("OPS/one.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><h1>First heading</h1><p>First chapter.</p></body></html>"),
        ("OPS/two.xhtml", second), (ncx ? "OPS/toc.ncx" : "OPS/nav.xhtml", ncx ? ncxText : nav)
    ]
    return content.map { ($0.0, Data($0.1.utf8), nil) }
}

/// Minimal standards-compliant stored ZIP fixture writer. No test dependency on ZIPFoundation.
func storedZIP(_ entries: [(String, Data, UInt32?)]) -> Data {
    var result = Data()
    var directory = Data()
    for (path, payload, declaredSize) in entries {
        let name = Data(path.utf8)
        let offset = UInt32(result.count)
        let crc = fixtureCRC32(payload)
        let size = declaredSize ?? UInt32(payload.count)
        result.appendLE(UInt32(0x04034B50))
        for value in [UInt16(20), 0, 0, 0, 0] { result.appendLE(value) }
        result.appendLE(crc); result.appendLE(UInt32(payload.count)); result.appendLE(size)
        result.appendLE(UInt16(name.count)); result.appendLE(UInt16(0))
        result.append(name); result.append(payload)
        directory.appendLE(UInt32(0x02014B50))
        for value in [UInt16(20), 20, 0, 0, 0, 0] { directory.appendLE(value) }
        directory.appendLE(crc); directory.appendLE(UInt32(payload.count)); directory.appendLE(size)
        directory.appendLE(UInt16(name.count))
        for value in [UInt16(0), 0, 0, 0] { directory.appendLE(value) }
        directory.appendLE(UInt32(0)); directory.appendLE(offset); directory.append(name)
    }
    let directoryOffset = UInt32(result.count)
    result.append(directory)
    result.appendLE(UInt32(0x06054B50))
    result.appendLE(UInt16(0)); result.appendLE(UInt16(0))
    result.appendLE(UInt16(entries.count)); result.appendLE(UInt16(entries.count))
    result.appendLE(UInt32(directory.count)); result.appendLE(directoryOffset); result.appendLE(UInt16(0))
    return result
}

func fixtureCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0) }
    }
    return crc ^ 0xFFFF_FFFF
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
