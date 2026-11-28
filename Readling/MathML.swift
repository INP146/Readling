import Foundation
import SwiftMath

/// Formulas in books. EPUB 3 writes them as MathML; the reader draws them with SwiftMath, which typesets LaTeX
/// with OpenType math fonts (the same approach as iosMath and TeX). So a `math` element becomes LaTeX once, at
/// import, and the chapter keeps that LaTeX: when the book also carries the formula's TeX source (a `semantics`
/// annotation) that is used as written; otherwise the presentation MathML is translated element by element.
enum MathML {
    struct Formula: Equatable {
        /// What SwiftMath draws; nil when neither the TeX source nor the translation could be typeset.
        var latex: String?
        /// The formula as plain text, for reading aloud, copying, and as what is shown when it can't be drawn.
        var text: String
    }

    static func formula(_ math: XMLTree.Node) -> Formula {
        let text = math.attribute("alttext").map(PlainTextLayout.cleanLabel).flatMap { $0.isEmpty ? nil : $0 } ?? spokenText(math)
        if let tex = annotationTeX(math), typesets(tex) { return Formula(latex: tex, text: text) }
        let converted = Converter().children(math).trimmingCharacters(in: .whitespaces)
        return Formula(latex: !converted.isEmpty && typesets(converted) ? converted : nil, text: text)
    }

    /// Whether SwiftMath can read this LaTeX. It stops at commands it doesn't know rather than guessing.
    static func typesets(_ latex: String) -> Bool {
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil else { return false }
        return !list.atoms.isEmpty
    }

    /// The formula's characters with the invisible operators taken out.
    static func spokenText(_ node: XMLTree.Node) -> String {
        var parts: [String] = []
        func walk(_ node: XMLTree.Node) {
            let name = localName(node)
            if name == "annotation" || name == "annotation-xml" { return }
            if name == "semantics", let first = node.children.first { walk(first); return }
            for part in node.content {
                switch part {
                case .text(let value): parts.append(value)
                case .node(let child): walk(child); if ["mi", "mn", "mo", "mtext"].contains(localName(child)) { parts.append(" ") }
                case .comment, .instruction: break
                }
            }
        }
        walk(node)
        let joined = parts.joined().unicodeScalars.filter { !(0x2061...0x2064).contains($0.value) }
        return PlainTextLayout.cleanLabel(String(String.UnicodeScalarView(joined)))
    }

    private static func annotationTeX(_ math: XMLTree.Node) -> String? {
        guard let annotation = math.first(where: {
            localName($0) == "annotation" && ($0.attribute("encoding")?.lowercased().contains("tex") ?? false)
        }) else { return nil }
        var tex = annotation.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        where tex.hasPrefix(open) && tex.hasSuffix(close) && tex.count >= open.count + close.count {
            tex = String(tex.dropFirst(open.count).dropLast(close.count))
            break
        }
        return tex.isEmpty ? nil : tex
    }

    fileprivate static func localName(_ node: XMLTree.Node) -> String {
        (node.name.split(separator: ":").last.map(String.init) ?? node.name).lowercased()
    }
}

/// Presentation MathML to LaTeX, limited to what SwiftMath understands.
private struct Converter {
    func convert(_ node: XMLTree.Node) -> String {
        let parts = node.children
        func part(_ index: Int) -> String { index < parts.count ? convert(parts[index]) : "" }
        switch MathML.localName(node) {
        case "annotation", "annotation-xml", "mprescripts", "none", "mphantom": return ""
        case "semantics", "maction": return part(0)
        case "mi": return identifier(node)
        case "mn": return Self.characters(node.plainText.trimmingCharacters(in: .whitespacesAndNewlines))
        case "mo": return Self.characters(node.plainText.trimmingCharacters(in: .whitespacesAndNewlines))
        case "mtext": return Self.text(node.plainText)
        case "ms": return Self.text("\"\(node.plainText)\"")
        case "mspace": return space(node.attribute("width"))
        case "mfrac":
            let thickness = node.attribute("linethickness")?.trimmingCharacters(in: .whitespaces)
            if thickness == "0" || thickness == "0px" || thickness == "0em" { return "{{\(part(0))} \\atop {\(part(1))}}" }
            return "\\frac{\(part(0))}{\(part(1))}"
        case "msqrt": return "\\sqrt{\(children(node))}"
        case "mroot": return "\\sqrt[\(part(1))]{\(part(0))}"
        case "msup": return "{\(part(0))}^{\(part(1))}"
        case "msub": return "{\(part(0))}_{\(part(1))}"
        case "msubsup": return "{\(part(0))}_{\(part(1))}^{\(part(2))}"
        case "munder":
            if parts.count > 1, Self.isLine(parts[1].plainText) { return "\\underline{\(part(0))}" }
            return "{\(part(0))}_{\(part(1))}"
        case "mover":
            if parts.count > 1, let accent = Self.accent(parts[1].plainText.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         wide: parts[0].plainText.count > 1) {
                return "\\\(accent){\(part(0))}"
            }
            return "{\(part(0))}^{\(part(1))}"
        case "munderover": return "{\(part(0))}_{\(part(1))}^{\(part(2))}"
        case "mmultiscripts":
            // Only the first pair of scripts after the base; prescripts are rare and have no LaTeX of their own here.
            var result = "{\(part(0))}"
            if parts.count > 1, MathML.localName(parts[1]) != "mprescripts", MathML.localName(parts[1]) != "none" { result += "_{\(part(1))}" }
            if parts.count > 2, MathML.localName(parts[2]) != "mprescripts", MathML.localName(parts[2]) != "none" { result += "^{\(part(2))}" }
            return result
        case "mtable":
            let rows = parts.filter { ["mtr", "mlabeledtr"].contains(MathML.localName($0)) }.map { row in
                // A labelled row starts with its equation number, which has no place in a matrix.
                let cells = MathML.localName(row) == "mlabeledtr" ? Array(row.children.dropFirst()) : row.children
                return cells.map(convert).joined(separator: " & ")
            }
            return "\\begin{matrix}\(rows.joined(separator: " \\\\ "))\\end{matrix}"
        case "mfenced":
            let open = node.attribute("open") ?? "(", close = node.attribute("close") ?? ")"
            let separators = Array((node.attribute("separators") ?? ",").filter { !$0.isWhitespace })
            var inner = ""
            for (index, child) in parts.enumerated() {
                if index > 0, !separators.isEmpty { inner += Self.characters(String(separators[min(index - 1, separators.count - 1)])) + " " }
                inner += convert(child)
            }
            return "\\left\(Self.delimiter(open)) \(inner) \\right\(Self.delimiter(close))"
        case "menclose":
            let notation = node.attribute("notation") ?? "longdiv"
            if notation.contains("radical") { return "\\sqrt{\(children(node))}" }
            if notation.contains("top") { return "\\overline{\(children(node))}" }
            if notation.contains("bottom") { return "\\underline{\(children(node))}" }
            return children(node)
        default: return children(node)
        }
    }

    /// An mrow and its relatives: fences at both ends grow with what they hold.
    func children(_ node: XMLTree.Node) -> String {
        let parts = node.children
        if parts.count >= 2, let first = parts.first, let last = parts.last,
           MathML.localName(first) == "mo", MathML.localName(last) == "mo",
           first.attribute("stretchy") != "false", last.attribute("stretchy") != "false",
           Self.opening.contains(first.plainText.trimmingCharacters(in: .whitespaces)),
           Self.closing.contains(last.plainText.trimmingCharacters(in: .whitespaces)) {
            let inner = parts.dropFirst().dropLast().map(convert).joined(separator: " ")
            return "\\left\(Self.delimiter(first.plainText)) \(inner) \\right\(Self.delimiter(last.plainText))"
        }
        return parts.map(convert).joined(separator: " ")
    }

    private func identifier(_ node: XMLTree.Node) -> String {
        let name = node.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        // Function names such as sin and log are operators LaTeX knows by name.
        if name.count > 1, name.allSatisfy(\.isLetter), MTMathAtomFactory.textToLatexSymbolName[name] == name { return "\\\(name) " }
        let variant = node.attribute("mathvariant") ?? (name.count == 1 ? "italic" : "normal")
        let body = Self.characters(name)
        switch variant {
        case "normal": return name.count == 1 && !name.first!.isASCII ? body : "\\mathrm{\(body)}"
        case "bold", "bold-italic": return "\\mathbf{\(body)}"
        case "double-struck": return "\\mathbb{\(body)}"
        case "script", "bold-script": return "\\mathcal{\(body)}"
        case "fraktur", "bold-fraktur": return "\\mathfrak{\(body)}"
        case "sans-serif", "bold-sans-serif", "sans-serif-italic", "sans-serif-bold-italic": return "\\mathsf{\(body)}"
        case "monospace": return "\\mathtt{\(body)}"
        default: return body
        }
    }

    private func space(_ width: String?) -> String {
        guard let width = width?.trimmingCharacters(in: .whitespaces), width.hasSuffix("em"),
              let ems = Double(width.dropLast(2)) else { return "\\ " }
        return ems >= 1.5 ? "\\qquad " : ems >= 0.8 ? "\\quad " : ems >= 0.27 ? "\\; " : ems > 0 ? "\\, " : ""
    }

    // MARK: Characters

    private static let opening: Set<String> = ["(", "[", "{", "|", "‖", "⟨", "〈", "⌈", "⌊"]
    private static let closing: Set<String> = [")", "]", "}", "|", "‖", "⟩", "〉", "⌉", "⌋"]

    private static func delimiter(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "": "."
        case "{": "\\{"
        case "}": "\\}"
        case "‖": "\\|"
        case "⟨", "〈": "\\langle"
        case "⟩", "〉": "\\rangle"
        case "⌈": "\\lceil"
        case "⌉": "\\rceil"
        case "⌊": "\\lfloor"
        case "⌋": "\\rfloor"
        case let other where ["(", ")", "[", "]", "|", "/"].contains(other): other
        default: "."
        }
    }

    private static func isLine(_ raw: String) -> Bool {
        ["_", "‾", "¯", "\u{0332}", "−", "-"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func accent(_ mark: String, wide: Bool) -> String? {
        switch mark {
        case "^", "ˆ", "\u{0302}": wide ? "widehat" : "hat"
        case "~", "˜", "\u{0303}": wide ? "widetilde" : "tilde"
        case "¯", "‾", "-", "−", "\u{0304}", "\u{0305}": wide ? "overline" : "bar"
        case "→", "\u{20D7}": "vec"
        case "˙", ".", "\u{0307}": "dot"
        case "¨", "..", "\u{0308}": "ddot"
        case "ˇ", "\u{030C}": "check"
        case "˘", "\u{0306}": "breve"
        case "´", "\u{0301}": "acute"
        case "`", "\u{0300}": "grave"
        default: nil
        }
    }

    /// Characters SwiftMath reads differently from their Unicode, or not at all.
    private static let named: [Character: String] = [
        "−": "-", "–": "-", "∗": "*", "∂": "partial", "′": "prime", "'": "prime", "″": "prime\\prime", "~": "sim",
        "…": "ldots", "⋯": "cdots", "·": "cdot", "⋅": "cdot", "∣": "mid", "ϕ": "phi", "φ": "varphi", "ϵ": "epsilon", "ε": "varepsilon",
        "{": "{", "}": "}", "#": "#", "$": "$", "%": "%", "&": "&", "_": "_", "\\": "backslash", "^": "wedge",
        "\u{00A0}": " ", "∘": "circ", "ℓ": "ell", "⟨": "langle", "⟩": "rangle", "〈": "langle", "〉": "rangle",
    ]

    /// Token text as LaTeX: ASCII as is, symbols by their command names, mathematical letters as letters in a font.
    static func characters(_ raw: String) -> String {
        var result = ""
        for character in raw {
            guard let scalar = character.unicodeScalars.first else { continue }
            if (0x2061...0x2064).contains(scalar.value) || character.isWhitespace { continue } // Invisible operators.
            if let name = named[character] {
                result += name.count == 1 ? "\\\(name)" : (name.hasPrefix("prime") ? "{}^{\\\(name)}" : "\\\(name) ")
            } else if character.isASCII {
                result.append(character)
            } else if let letter = mathematicalLetter(scalar) {
                result += letter
            } else if let name = MTMathAtomFactory.textToLatexSymbolName[String(character)] {
                result += "\\\(name) "
            } else if MTMathAtomFactory.atom(forCharacter: character) != nil {
                result.append(character) // Accented Latin and Cyrillic letters.
            }
            // Anything else has no glyph SwiftMath can reach and is left out.
        }
        return result
    }

    /// Text inside a formula. SwiftMath's \text keeps spaces but, like TeX, takes only plain characters.
    static func text(_ raw: String) -> String {
        var result = ""
        for character in raw {
            switch character {
            case "{", "}", "$", "#", "%", "&", "_": result += "\\\(character)"
            case "\\", "^", "~": continue
            case "’", "‘": result += "'"
            case "“", "”": result += "\""
            case "–", "—", "−": result += "-"
            case _ where character.isWhitespace: result += " "
            case _ where character.isASCII || MTMathAtomFactory.atom(forCharacter: character) != nil: result.append(character)
            default: continue
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (result.isEmpty ? "" : "\\ ") : "\\text{\(result)}"
    }

    // The Mathematical Alphanumeric Symbols block: 13 styles of A–Z a–z, with the letters Unicode had already
    // encoded elsewhere (ℝ, ℎ, ℒ …) left as holes.
    private static let alphabets: [(base: UInt32, command: String?)] = [
        (0x1D400, "mathbf"), (0x1D434, nil), (0x1D468, "mathbf"), (0x1D49C, "mathcal"), (0x1D4D0, "mathcal"),
        (0x1D504, "mathfrak"), (0x1D538, "mathbb"), (0x1D56C, "mathfrak"), (0x1D5A0, "mathsf"), (0x1D5D4, "mathsf"),
        (0x1D608, "mathsf"), (0x1D63C, "mathsf"), (0x1D670, "mathtt"),
    ]
    private static let letterlike: [Character: (Character, String?)] = [
        "ℂ": ("C", "mathbb"), "ℍ": ("H", "mathbb"), "ℕ": ("N", "mathbb"), "ℙ": ("P", "mathbb"), "ℚ": ("Q", "mathbb"),
        "ℝ": ("R", "mathbb"), "ℤ": ("Z", "mathbb"), "ℎ": ("h", nil), "ℬ": ("B", "mathcal"), "ℰ": ("E", "mathcal"),
        "ℱ": ("F", "mathcal"), "ℋ": ("H", "mathcal"), "ℐ": ("I", "mathcal"), "ℒ": ("L", "mathcal"), "ℳ": ("M", "mathcal"),
        "ℛ": ("R", "mathcal"), "ℭ": ("C", "mathfrak"), "ℌ": ("H", "mathfrak"), "ℑ": ("I", "mathfrak"), "ℜ": ("R", "mathfrak"),
        "ℨ": ("Z", "mathfrak"),
    ]

    private static func mathematicalLetter(_ scalar: Unicode.Scalar) -> String? {
        func styled(_ letter: Character, _ command: String?) -> String { command.map { "\\\($0){\(letter)}" } ?? String(letter) }
        if let (letter, command) = letterlike[Character(scalar)] { return styled(letter, command) }
        if (0x1D7CE...0x1D7FF).contains(scalar.value) { // Bold, double-struck, sans and monospace digits.
            let index = scalar.value - 0x1D7CE
            let digit = Character(String(index % 10))
            return styled(digit, ["mathbf", "mathbb", "mathsf", "mathsf", "mathtt"][Int(index / 10)])
        }
        for alphabet in alphabets where (alphabet.base..<alphabet.base + 52).contains(scalar.value) {
            let index = scalar.value - alphabet.base
            guard let letter = Unicode.Scalar(index < 26 ? 0x41 + index : 0x61 + index - 26) else { return nil }
            return styled(Character(letter), alphabet.command)
        }
        return nil
    }
}
