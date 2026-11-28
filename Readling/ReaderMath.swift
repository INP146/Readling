import UIKit
import SwiftMath

/// A formula drawn inline in chapter text, typeset by SwiftMath from the LaTeX kept in the chapter.
///
/// It sits on the baseline like a word: the part below the formula's own baseline hangs below the line's. A formula
/// alone in its paragraph is set in display style (larger operators and fractions) and centered. One wider than the
/// line, or taller than a page, is scaled down to fit, as pictures are.
final class ReaderMathAttachment: NSTextAttachment {
    private let formula: ReaderFormula?
    private let color: UIColor

    init(latex: String, pointSize: CGFloat, color: UIColor, typeface: ReaderTypeface, display: Bool) {
        formula = MainActor.assumeIsolated { ReaderFormula.make(latex: latex, pointSize: pointSize, typeface: typeface, display: display) }
        self.color = color
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The formula's size before any scaling; zero when it can't be typeset.
    var naturalSize: CGSize { formula.map { CGSize(width: $0.width, height: $0.ascent + $0.descent) } ?? .zero }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        guard let formula else { return .zero }
        let height = formula.ascent + formula.descent
        var scale = min(1, max(1, lineFrag.width) / formula.width)
        if let container = textContainer, container.size.height < 100_000 { scale = min(scale, max(1, container.size.height - 1) / height) }
        return CGRect(x: 0, y: -formula.descent * scale, width: ceil(formula.width * scale), height: ceil(height * scale))
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        // Drawn when shown, in the colour the text has now, so a light/dark switch needs no new layout.
        let ink = color.resolvedColor(with: UITraitCollection.current)
        let formula = formula, size = imageBounds.size
        return MainActor.assumeIsolated { formula?.image(size: size, color: ink) }
    }
}

/// One typeset formula, shared by every attachment that shows it at the same size.
@MainActor
final class ReaderFormula {
    private static let cache: NSCache<NSString, ReaderFormula> = {
        let cache = NSCache<NSString, ReaderFormula>()
        cache.countLimit = 2_000
        return cache
    }()

    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    private let display: MTMathListDisplay
    /// The formula in black at the size last asked for, and that drawing in the colour last asked for.
    private var shape: (size: CGSize, image: UIImage)?
    private var drawn: (size: CGSize, color: UIColor, image: UIImage)?

    private init(display: MTMathListDisplay) {
        self.display = display
        width = display.width
        ascent = display.ascent
        descent = display.descent
    }

    static func make(latex: String, pointSize: CGFloat, typeface: ReaderTypeface, display: Bool) -> ReaderFormula? {
        let key = "\(typeface.rawValue)|\(pointSize)|\(display)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let label = MTMathUILabel()
        label.font = font(for: typeface, size: pointSize)
        label.labelMode = display ? .display : .text
        label.textAlignment = .left
        label.latex = latex
        guard label.error == nil else { return nil }
        let size = label.intrinsicContentSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        // Laying the label out at its own size puts the formula's baseline at its descent, as drawing expects.
        label.frame = CGRect(origin: .zero, size: size)
        label.setNeedsLayout()
        label.layoutIfNeeded()
        guard let list = label.displayList else { return nil }
        let formula = ReaderFormula(display: list)
        cache.setObject(formula, forKey: key)
        return formula
    }

    /// Math fonts that sit well beside the reading fonts: TeX Gyre Termes (a Times) by serif text, Noto Sans Math by the system font.
    private static func font(for typeface: ReaderTypeface, size: CGFloat) -> MTFont? {
        // The font methods load from SwiftMath's shared manager, whichever instance they are called on.
        let fonts = MTFontManager()
        return typeface == .system ? fonts.notoSansRegularFont(withSize: size) : fonts.termesFont(withSize: size)
    }

    func image(size: CGSize, color: UIColor) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        if let drawn, drawn.size == size, drawn.color == color { return drawn.image }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let black: UIImage
        if let shape, shape.size == size {
            black = shape.image
        } else {
            let scale = min(size.width / width, size.height / (ascent + descent))
            black = UIGraphicsImageRenderer(size: size, format: format).image { context in
                // SwiftMath draws with y up and the baseline at the descent; UIKit images have y down.
                let cg = context.cgContext
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: scale, y: -scale)
                display.draw(cg)
            }
            shape = (size, black)
        }
        // The text colour through the formula's shape, so the typesetting is done once for both appearances.
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            black.draw(in: CGRect(origin: .zero, size: size), blendMode: .destinationIn, alpha: 1)
        }
        drawn = (size, color, image)
        return image
    }
}

/// A horizontal rule (`hr`): a short centered line, the usual mark of a scene break.
final class ReaderRuleAttachment: NSTextAttachment {
    private let color: UIColor
    private let pointSize: CGFloat

    init(color: UIColor, pointSize: CGFloat) {
        self.color = color
        self.pointSize = pointSize
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: min(160, max(1, lineFrag.width * 0.3)).rounded(), height: (pointSize * 0.8).rounded())
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        let ink = color.resolvedColor(with: UITraitCollection.current).withAlphaComponent(0.4)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: imageBounds.size, format: format).image { _ in
            ink.setFill()
            UIRectFill(CGRect(x: 0, y: (imageBounds.height / 2).rounded() - 0.5, width: imageBounds.width, height: 1))
        }
    }
}
