import Foundation
import Testing
import UIKit
@testable import Readling

/// Renders an XHTML body the way EPUB import does.
private func chapter(_ body: String) throws -> ReaderChapter {
    let document = try XMLTree.parse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\(body)</body></html>".utf8))
    var renderer = ChapterRenderer()
    try BookImporter.render(try #require(document.descendants("body").first), into: &renderer)
    let result = renderer.finish()
    return ReaderChapter(id: "c", title: "T", text: result.text, styles: result.styles, anchors: result.anchors)
}

private func runs(_ chapter: ReaderChapter, _ style: TextStyleRun.Style) -> [TextStyleRun] {
    chapter.styles.filter { $0.style == style }
}

private func substring(_ chapter: ReaderChapter, _ run: TextStyleRun) -> String {
    (chapter.text as NSString).substring(with: run.range)
}

@Suite("Tables")
struct TableTests {
    static let prices = """
    <p>Before</p>
    <table>
      <caption>Prices</caption>
      <tr><th>Item</th><th>Cost</th></tr>
      <tr><td>Tea</td> <td>3</td></tr>
      <tr><td></td><td>5</td></tr>
      <tr><td colspan="2">Total <b>8</b></td></tr>
      <tr><td></td><td> </td></tr>
    </table>
    <p>After</p>
    """

    @Test func rowsAreParagraphsAndCellsAreTabs() throws {
        let chapter = try chapter(Self.prices)
        // An empty first cell keeps its tab so the next cell stays in its column; an empty row leaves nothing.
        #expect(chapter.text == "Before\nPrices\nItem\tCost\nTea\t3\n\t5\nTotal 8\nAfter")
        let table = try #require(runs(chapter, .table).first)
        #expect(substring(chapter, table) == "Item\tCost\nTea\t3\n\t5\nTotal 8\n")
        #expect(TableShape(table.value) == TableShape(rows: [[1, 1], [1, 1], [1, 1], [2]]))
        #expect(runs(chapter, .bold).map { substring(chapter, $0) } == ["Item", "Cost", "8"]) // The tab between cells isn't bold.
        #expect(runs(chapter, .center).map { substring(chapter, $0) } == ["Prices"])
    }

    @Test func blocksInsideCellsBreakLinesNotRows() throws {
        let chapter = try chapter("""
        <table><tr><td><p>One</p><p>Two</p></td><td><ul><li>a</li><li>b</li></ul></td>\
        <td><table><tr><td>x</td><td>y</td></tr><tr><td>z</td></tr></table></td></tr></table>
        """)
        #expect(chapter.text == "One\u{2028}Two\t•\u{00A0}a\u{2028}•\u{00A0}b\tx y\u{2028}z")
        #expect(runs(chapter, .list).isEmpty)
        #expect(TableShape(runs(chapter, .table).first?.value) == TableShape(rows: [[1, 1, 1]]))
    }

    @Test func tagSoupTablesReadTheSame() throws {
        let strict = try chapter(Self.prices)
        let lenient = try LenientHTML.extract("<html><body>\(Self.prices.replacingOccurrences(of: "</td>", with: ""))</body></html>")
        #expect(lenient.text == strict.text)
        #expect(lenient.styles.first { $0.style == .table }?.value == strict.styles.first { $0.style == .table }?.value)
    }

    @Test @MainActor func wideEnoughTablesAreGrids() throws {
        let chapter = try chapter(Self.prices)
        let rendered = ReadingSurface.attributedText(for: chapter, size: 17, width: 320)
        #expect(rendered.string == chapter.text)
        let text = chapter.text as NSString
        let row = text.range(of: "Tea\t3")
        let style = try #require(rendered.attribute(.paragraphStyle, at: row.location, effectiveRange: nil) as? NSParagraphStyle)
        // The numeric column aligns right at its edge.
        #expect(style.tabStops.count == 1)
        #expect(style.tabStops.first?.alignment == .right)
        // Both cells sit on one line.
        let layout = LaidOut(rendered, width: 320)
        #expect(layout.line(of: row.location) == layout.line(of: row.location + 4))
    }

    @Test @MainActor func narrowTablesStackTheirCells() throws {
        let chapter = try chapter("""
        <table><tr><td>Remarkably</td><td>Considerable</td><td>Extraordinarily</td></tr></table>
        """)
        let rendered = ReadingSurface.attributedText(for: chapter, size: 17, width: 200)
        #expect(rendered.string == chapter.text)
        let layout = LaidOut(rendered, width: 200)
        let lines = [0, 11, 24].map(layout.line(of:))
        #expect(Set(lines).count == 3)
        // Later cells hang under the first, each one line below the last: no empty line between them.
        #expect(layout.x(of: 11) > layout.x(of: 0))
        #expect(layout.x(of: 24) == layout.x(of: 11))
        #expect(abs((lines[2] - lines[1]) - (lines[1] - lines[0])) < 0.5)
        #expect(lines[1] - lines[0] < 17 * 2)
        // Wide enough, the same table is a grid.
        let wide = ReadingSurface.attributedText(for: chapter, size: 17, width: 700)
        #expect(Set([0, 11, 24].map(LaidOut(wide, width: 700).line(of:))).count == 1)
    }

    @Test @MainActor func aLongLastCellWrapsUnderItsColumn() throws {
        let chapter = try chapter("""
        <table><tr><td>I.</td><td><a href="#c1">Down the Rabbit-Hole, in which Alice follows a rabbit and falls a very long way</a></td></tr>\
        <tr><td>II.</td><td>The Pool of Tears</td></tr></table>
        """)
        let rendered = ReadingSurface.attributedText(for: chapter, size: 17, width: 300)
        let layout = LaidOut(rendered, width: 300)
        let title = 3, later = (chapter.text as NSString).range(of: "long way").location
        #expect(layout.line(of: later) != layout.line(of: title))
        #expect(abs(layout.x(of: later) - layout.x(of: title)) < 40)
    }

    @Test func splittingAChapterKeepsEachPieceOfATableInShape() throws {
        let rows = (1...40).map { "<tr><td>Row \($0) with some words in it</td><td colspan=\"\($0 % 2 + 1)\">\($0)</td></tr>" }.joined()
        let whole = try chapter("<table>\(rows)</table>")
        let pieces = ChapterLayout.split(whole, maximumLength: 600)
        #expect(pieces.count > 1)
        for piece in pieces {
            let table = try #require(piece.styles.first { $0.style == .table })
            let shape = TableShape(table.value)
            let first = (piece.text as NSString).substring(with: table.range).split(separator: "\n").first.map(String.init) ?? ""
            let number = Int(first.split(separator: "\t").last ?? "") ?? 0
            #expect(shape.span(row: 0, cell: 1) == number % 2 + 1, "\(first)")
        }
    }
}

@Suite("Formulas")
struct MathTests {
    private func latex(_ mathML: String) throws -> MathML.Formula {
        let tree = try XMLTree.parse(Data("<math xmlns=\"http://www.w3.org/1998/Math/MathML\">\(mathML)</math>".utf8))
        return MathML.formula(try #require(tree.children.first))
    }

    @Test func presentationMathMLBecomesLaTeX() throws {
        let cases: [(String, String)] = [
            ("<mfrac><mn>1</mn><mi>x</mi></mfrac>", "\\frac{1}{x}"),
            ("<msup><mi>x</mi><mn>2</mn></msup>", "{x}^{2}"),
            ("<msubsup><mi>a</mi><mi>i</mi><mn>2</mn></msubsup>", "{a}_{i}^{2}"),
            ("<msqrt><mi>b</mi></msqrt>", "\\sqrt{b}"),
            ("<mroot><mi>b</mi><mn>3</mn></mroot>", "\\sqrt[3]{b}"),
            ("<mi>α</mi><mo>≤</mo><mi>β</mi>", "\\alpha"),
            ("<mi>ℝ</mi>", "\\mathbb{R}"),
            ("<mi>sin</mi><mo>&#x2061;</mo><mi>θ</mi>", "\\sin"),
            ("<mrow><mo>(</mo><mi>a</mi><mo>+</mo><mi>b</mi><mo>)</mo></mrow>", "\\left( a + b \\right)"),
            ("<munderover><mo>∑</mo><mrow><mi>i</mi><mo>=</mo><mn>1</mn></mrow><mi>n</mi></munderover><mi>i</mi>", "\\sum"),
            ("<mover><mi>v</mi><mo>→</mo></mover>", "\\vec{v}"),
            ("<mtable><mtr><mtd><mn>1</mn></mtd><mtd><mn>0</mn></mtd></mtr><mtr><mtd><mn>0</mn></mtd><mtd><mn>1</mn></mtd></mtr></mtable>",
             "\\begin{matrix}1 & 0 \\\\ 0 & 1\\end{matrix}"),
            ("<mi>f</mi><mo>′</mo><mo>(</mo><mi>x</mi><mo>)</mo>", "\\prime"),
            ("<mtext>if x &gt; 0</mtext>", "\\text{if x > 0}"),
            ("<mi mathvariant=\"bold\">v</mi>", "\\mathbf{v}"),
            ("<mfenced><mi>a</mi><mi>b</mi></mfenced>", "\\left( a, b \\right)"),
        ]
        for (mathML, expected) in cases {
            let formula = try latex(mathML)
            let latex = try #require(formula.latex, "\(mathML)")
            #expect(latex.contains(expected), "\(mathML) → \(latex)")
            #expect(MathML.typesets(latex))
        }
    }

    @Test func theBooksOwnTeXIsPreferredWhenItTypesets() throws {
        let annotated = try latex("""
        <semantics><mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow>\
        <annotation encoding="application/x-tex">E = mc^2</annotation></semantics>
        """)
        #expect(annotated.latex == "E = mc^2")
        #expect(annotated.text == "E = m c 2")
        // TeX that SwiftMath can't read falls back to the MathML.
        let unknown = try latex("""
        <semantics><mrow><mi>f</mi><mo>(</mo><mi>x</mi><mo>)</mo></mrow>\
        <annotation encoding="application/x-tex">\\operatorname{f}(x)</annotation></semantics>
        """)
        #expect(unknown.latex == "f ( x )")
    }

    @Test func formulasBecomeAttachmentsInline_orAsBlocks() throws {
        let chapter = try chapter("""
        <p>Since <math><msup><mi>x</mi><mn>2</mn></msup></math> grows, we have</p>\
        <math display="block" alttext="sum of i"><munderover><mo>∑</mo><mi>i</mi><mi>n</mi></munderover><mi>i</mi></math>\
        <p>and so on.</p>
        """)
        #expect(chapter.text == "Since \u{FFFC} grows, we have\n\u{FFFC}\nand so on.")
        let math = runs(chapter, .math)
        #expect(math.map(\.location) == [6, 23])
        #expect(math.map(\.value) == ["{x}^{2}", "{\\sum }_{i}^{n} i"])
        #expect(math.map(\.alt) == ["x 2", "sum of i"])
    }

    @Test func texBetweenDelimitersIsTypeset() throws {
        let chapter = try chapter(#"""
        <p>Let <span class="math inline">\(Y=f(X)\)</span> be a model, so</p><p>\[\hat{Y} = \sum_{i} x_i\]</p>\#
        <p>costs $5 and $6, $$ $$ stays, \(\notacommand x\) too, and <code>\(a\)</code> is code.</p>
        """#)
        #expect(chapter.text == #"Let \#u{FFFC} be a model, so\#n\#u{FFFC}\#ncosts $5 and $6, $$ $$ stays, \(\notacommand x\) too, and \(a\) is code."#)
        let math = runs(chapter, .math)
        #expect(math.map(\.value) == ["Y=f(X)", #"\hat{Y} = \sum_{i} x_i"#])
        #expect(math.map(\.alt) == ["Y=f(X)", #"\hat{Y} = \sum_{i} x_i"#])
        // The same through the tag-soup reader, with $$ for display.
        let lenient = try LenientHTML.extract("<body><p>so $$x^2$$ and \\(y\\)<br></body>")
        #expect(lenient.text == "so\n\u{FFFC}\nand \u{FFFC}")
    }

    @Test func tagSoupFormulasAreReadWhole() throws {
        let result = try LenientHTML.extract("<html><body><p>Area <m:math><m:mi>π</m:mi><m:msup><m:mi>r</m:mi><m:mn>2</m:mn></m:msup></m:math> here<br></body></html>")
        #expect(result.text == "Area \u{FFFC} here")
        #expect(result.styles.first { $0.style == .math }?.value == "\\pi  {r}^{2}")
    }

    @Test @MainActor func formulasSitOnTheBaselineAndBlocksAreCentered() throws {
        let chapter = try chapter("""
        <p>Half is <math><mfrac><mn>1</mn><mn>2</mn></mfrac></math>.</p><math display="block"><mfrac><mn>1</mn><mn>2</mn></mfrac></math>
        """)
        let rendered = ReadingSurface.attributedText(for: chapter, size: 20)
        #expect(rendered.string == chapter.text)
        let inline = try #require(rendered.attribute(.attachment, at: 8, effectiveRange: nil) as? ReaderMathAttachment)
        let block = try #require(rendered.attribute(.attachment, at: 11, effectiveRange: nil) as? ReaderMathAttachment)
        let line = CGRect(x: 0, y: 0, width: 300, height: 24)
        let small = inline.attachmentBounds(for: nil, proposedLineFragment: line, glyphPosition: .zero, characterIndex: 8)
        let large = block.attachmentBounds(for: nil, proposedLineFragment: line, glyphPosition: .zero, characterIndex: 11)
        // The denominator hangs below the baseline; display style is the larger.
        #expect(small.minY < 0 && small.height > 0)
        #expect(large.height > small.height)
        #expect((rendered.attribute(.paragraphStyle, at: 11, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
        #expect((rendered.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle)?.alignment != .center)
        // Too wide for the line, it shrinks to fit.
        let narrow = block.attachmentBounds(for: nil, proposedLineFragment: CGRect(x: 0, y: 0, width: 5, height: 24), glyphPosition: .zero, characterIndex: 11)
        #expect(narrow.width <= 5)
        let image = block.image(forBounds: large, textContainer: nil, characterIndex: 11)
        #expect(image?.size == large.size)
    }
}

@Suite("More HTML")
struct MoreElementTests {
    @Test func listsNumberTheWayTheBookSays() throws {
        let chapter = try chapter("""
        <ol type="a"><li>x</li><li>y</li></ol><ol style="list-style-type: upper-roman" start="3"><li>z</li></ol>\
        <ul style="list-style: none"><li>plain</li></ul>
        """)
        #expect(chapter.text == "a.\u{00A0}x\nb.\u{00A0}y\nIII.\u{00A0}z\nplain")
    }

    @Test func rulesQuotationsAndDefinitionTerms() throws {
        let chapter = try chapter("""
        <p>End.</p><hr/><p>She said <q>go <q>now</q></q>.</p><dl><dt>Term</dt><dd>Meaning</dd></dl><p>x<ruby>漢<rt>kan</rt></ruby></p>
        """)
        #expect(chapter.text == "End.\n\u{FFFC}\nShe said “go ‘now’”.\nTerm\nMeaning\nx漢")
        #expect(runs(chapter, .rule).map(\.location) == [5])
        #expect(runs(chapter, .bold).map { substring(chapter, $0) } == ["Term"])
    }
}

/// A chapter's text laid out in one tall container, as the scrolling reader does.
@MainActor
private struct LaidOut {
    let manager = NSLayoutManager()
    private let storage: NSTextStorage

    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
    }

    func line(of character: Int) -> CGFloat {
        manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
    }

    func x(of character: Int) -> CGFloat {
        manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: character)).x
    }
}
