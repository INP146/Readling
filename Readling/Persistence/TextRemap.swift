import Foundation

/// Carries offsets from a book's old reading text to its rebuilt text (see docs/data-versioning.md 3.5).
///
/// Chapters are matched by the document they came from: the pieces of one source document are joined, old and
/// new, and aligned word by word (see `Alignment.match`), so a document split into a different number of chapters,
/// or one whose formulas became attachment characters, still maps. A text import is one document.
struct TextRemap: Sendable {
    private struct Document: Sendable {
        /// Where each chapter (by index in its book) starts in the joined text.
        var starts: [(chapter: Int, start: Int, length: Int)]
        var length: Int
    }

    private let old: [String: Document]
    private let new: [String: Document]
    private let oldKeys: [String]
    private let alignments: [String: Alignment]
    private let newChapterCount: Int

    init(old oldChapters: [ReaderChapter], new newChapters: [ReaderChapter]) {
        func documents(_ chapters: [ReaderChapter]) -> (documents: [String: Document], texts: [String: String]) {
            var documents: [String: Document] = [:]
            var texts: [String: String] = [:]
            for (index, chapter) in chapters.enumerated() {
                let key = chapter.source ?? ""
                var document = documents[key] ?? Document(starts: [], length: 0)
                var text = texts[key] ?? ""
                if !document.starts.isEmpty { text += "\n"; document.length += 1 }
                let length = chapter.text.utf16.count
                document.starts.append((index, document.length, length))
                document.length += length
                text += chapter.text
                documents[key] = document
                texts[key] = text
            }
            return (documents, texts)
        }
        let (oldDocuments, oldTexts) = documents(oldChapters)
        let (newDocuments, newTexts) = documents(newChapters)
        old = oldDocuments
        new = newDocuments
        oldKeys = oldChapters.map { $0.source ?? "" }
        newChapterCount = newChapters.count
        var alignments: [String: Alignment] = [:]
        for (key, text) in oldTexts {
            guard let rebuilt = newTexts[key] else { continue }
            alignments[key] = Alignment(old: text, new: rebuilt)
        }
        self.alignments = alignments
    }

    /// Where a position in the old text is in the new one.
    func map(chapter: Int, offset: Int) -> (chapter: Int, offset: Int) {
        guard newChapterCount > 0 else { return (0, 0) }
        guard oldKeys.indices.contains(chapter) else { return (min(max(0, chapter), newChapterCount - 1), 0) }
        let key = oldKeys[chapter]
        guard let source = old[key], let target = new[key], let alignment = alignments[key],
              let piece = source.starts.first(where: { $0.chapter == chapter }) else {
            // The document is gone: the chapter at the same place in the book.
            return (min(chapter, newChapterCount - 1), 0)
        }
        let mapped = alignment.map(piece.start + min(max(0, offset), piece.length))
        let landing = target.starts.last { $0.start <= mapped } ?? target.starts[0]
        return (landing.chapter, min(max(0, mapped - landing.start), landing.length))
    }
}

/// Word-level alignment of two texts. Tokens are runs of letters and digits, and every other visible character on
/// its own (punctuation, the attachment character of a picture or formula); whitespace only separates them.
struct Alignment: Sendable {
    private struct Token: Sendable { var start: Int; var end: Int }

    private let oldTokens: [Token]
    private let newTokens: [Token]
    /// For each old token, the new token it matches, or -1.
    private let matches: [Int]
    private let matchesAny: Bool
    private let oldLength: Int
    private let newLength: Int
    /// Stretches between anchors with no token unique to both sides are diffed exactly (Myers) only up to this many
    /// tokens on both sides together; longer ones stay unmatched and map to their neighbours.
    static let maximumExactGap = 2_000

    init(old: String, new: String) {
        let (oldTokens, oldWords) = Self.tokens(old)
        let (newTokens, newWords) = Self.tokens(new)
        self.oldTokens = oldTokens
        self.newTokens = newTokens
        oldLength = old.utf16.count
        newLength = new.utf16.count
        var ids: [String: Int32] = [:]
        func intern(_ words: [String]) -> [Int32] {
            words.map { word in
                if let id = ids[word] { return id }
                let id = Int32(ids.count)
                ids[word] = id
                return id
            }
        }
        let matches = Self.match(intern(oldWords), intern(newWords))
        self.matches = matches
        matchesAny = matches.contains { $0 >= 0 }
    }

    /// A common subsequence of two token lists, the way patience diff finds it: the shared start and end are matched
    /// as they are; in between, tokens that occur exactly once on each side are anchors, and the longest run of them
    /// in the same order on both sides is matched; the same is then done between each pair of anchors. Only a short
    /// stretch without such anchors is diffed exactly. Close to linear even when the texts differ a lot, where a
    /// plain Myers diff over a whole book takes time and memory that grow with the square of the difference.
    static func match(_ a: [Int32], _ b: [Int32]) -> [Int] {
        var matches = [Int](repeating: -1, count: a.count)
        var stretches = [(a: 0..<a.count, b: 0..<b.count)]
        while let (rangeA, rangeB) = stretches.popLast() {
            var lowA = rangeA.lowerBound, highA = rangeA.upperBound
            var lowB = rangeB.lowerBound, highB = rangeB.upperBound
            while lowA < highA, lowB < highB, a[lowA] == b[lowB] {
                matches[lowA] = lowB
                lowA += 1; lowB += 1
            }
            while lowA < highA, lowB < highB, a[highA - 1] == b[highB - 1] {
                highA -= 1; highB -= 1
                matches[highA] = highB
            }
            guard lowA < highA, lowB < highB else { continue }

            // Where each token occurs once, on each side; -1 when it occurs more often.
            var onceA: [Int32: Int] = [:]
            for i in lowA..<highA { onceA[a[i]] = onceA[a[i]] == nil ? i : -1 }
            var onceB: [Int32: Int] = [:]
            for j in lowB..<highB where (onceA[b[j]] ?? -1) >= 0 { onceB[b[j]] = onceB[b[j]] == nil ? j : -1 }
            var pairs: [(a: Int, b: Int)] = []
            for i in lowA..<highA where onceA[a[i]] == i {
                if let j = onceB[a[i]], j >= 0 { pairs.append((i, j)) }
            }
            let anchors = longestIncreasingRun(pairs)
            guard !anchors.isEmpty else {
                if (highA - lowA) + (highB - lowB) <= maximumExactGap { exactMatch(a, b, lowA..<highA, lowB..<highB, into: &matches) }
                continue
            }
            var startA = lowA, startB = lowB
            for anchor in anchors {
                matches[anchor.a] = anchor.b
                if startA < anchor.a, startB < anchor.b { stretches.append((startA..<anchor.a, startB..<anchor.b)) }
                startA = anchor.a + 1; startB = anchor.b + 1
            }
            if startA < highA, startB < highB { stretches.append((startA..<highA, startB..<highB)) }
        }
        return matches
    }

    /// The longest subsequence of pairs (in order of `a`) whose `b` also increases, by patience sorting.
    private static func longestIncreasingRun(_ pairs: [(a: Int, b: Int)]) -> [(a: Int, b: Int)] {
        var tops: [Int] = []          // index into pairs of the smallest last element of each run length
        var previous = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var low = 0, high = tops.count
            while low < high {
                let mid = (low + high) / 2
                if pairs[tops[mid]].b < pair.b { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[index] = tops[low - 1] }
            if low == tops.count { tops.append(index) } else { tops[low] = index }
        }
        var run: [(a: Int, b: Int)] = []
        var index = tops.last ?? -1
        while index >= 0 {
            run.append(pairs[index])
            index = previous[index]
        }
        return run.reversed()
    }

    private static func exactMatch(_ a: [Int32], _ b: [Int32], _ rangeA: Range<Int>, _ rangeB: Range<Int>, into matches: inout [Int]) {
        let difference = Array(b[rangeB]).difference(from: Array(a[rangeA]))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var j = 0
        for i in 0..<rangeA.count where !removed.contains(i) {
            while inserted.contains(j) { j += 1 }
            guard j < rangeB.count else { break }
            matches[rangeA.lowerBound + i] = rangeB.lowerBound + j
            j += 1
        }
    }

    func map(_ offset: Int) -> Int {
        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return min(offset, newLength) }
        if !matchesAny {
            return oldLength == 0 ? 0 : min(newLength, Int((Double(offset) / Double(oldLength) * Double(newLength)).rounded()))
        }
        // The token the offset is in, or the next one when it is in the space between.
        var low = 0, high = oldTokens.count
        while low < high {
            let mid = (low + high) / 2
            if oldTokens[mid].end <= offset { low = mid + 1 } else { high = mid }
        }
        if low == oldTokens.count {
            guard let last = oldTokens.indices.last(where: { matches[$0] >= 0 }) else { return newLength }
            return min(newLength, newTokens[matches[last]].end + (offset - oldTokens[last].end))
        }
        if matches[low] >= 0 {
            let match = newTokens[matches[low]]
            let inside = max(0, offset - oldTokens[low].start)
            return min(match.start + inside, match.end)
        }
        // A word that is no longer there: just after the last word before it that still is, else before the next.
        if let before = (0..<low).reversed().first(where: { matches[$0] >= 0 }) { return newTokens[matches[before]].end }
        if let after = (low..<oldTokens.count).first(where: { matches[$0] >= 0 }) { return newTokens[matches[after]].start }
        return 0
    }

    private static func tokens(_ text: String) -> ([Token], [String]) {
        var tokens: [Token] = []
        var words: [String] = []
        var word = ""
        var wordStart = 0
        var position = 0
        func flush() {
            guard !word.isEmpty else { return }
            tokens.append(Token(start: wordStart, end: position))
            words.append(word)
            word = ""
        }
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if CharacterSet.alphanumerics.contains(scalar) {
                if word.isEmpty { wordStart = position }
                word.unicodeScalars.append(scalar)
            } else {
                flush()
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar) {
                    tokens.append(Token(start: position, end: position + width))
                    words.append(String(scalar))
                }
            }
            position += width
        }
        flush()
        return (tokens, words)
    }
}

/// Derived data waiting to be rebuilt, kept across launches: `rebuild-queue.json`.
struct RebuildQueue: Codable, Equatable {
    /// What migrations asked for and has not been turned into a list of books yet.
    var requested: Set<RebuildKind> = []
    /// Books whose reading text is still to be rebuilt, in order.
    var books: [UUID] = []
    /// Why a book's last attempt failed. It stays in `books`, so it is tried again at the next launch.
    var failures: [UUID: String] = [:]
    /// How many books the current round started with, for showing progress.
    var total = 0

    static let name = "rebuild-queue.json"

    static func load(from directory: URL) -> RebuildQueue {
        (try? JSONDecoder().decode(RebuildQueue.self, from: Data(contentsOf: directory.appendingPathComponent(name)))) ?? RebuildQueue()
    }

    func save(to directory: URL) throws {
        let url = directory.appendingPathComponent(Self.name)
        if self == RebuildQueue() {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
