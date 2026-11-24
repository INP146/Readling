import SwiftUI
import UIKit

/// One place for the reader palette. Every color adapts to light/dark through
/// the trait collection, so views never branch on the color scheme themselves.
extension UIColor {
    private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let readerPaper = adaptive(light: 0xF7F4ED, dark: 0x191D1B)
    static let readerInk = adaptive(light: 0x292D28, dark: 0xECEFE6)
    static let readerAccent = adaptive(light: 0x286052, dark: 0x9CC7B0)
    static let readerCard = adaptive(light: 0xFDFBF6, dark: 0x232826)
    static let readerHighlight = adaptive(light: 0xE8D6A0, dark: 0x5C5132)
    static let readerCover = UIColor(hex: 0x314F44)
}

extension Color {
    static let paper = Color(uiColor: .readerPaper)
    static let ink = Color(uiColor: .readerInk)
    static let accent = Color(uiColor: .readerAccent)
    static let card = Color(uiColor: .readerCard)
    static let cover = Color(uiColor: .readerCover)
}

enum ReaderTypography {
    static let defaultSize = 20.0
    static let sizeRange = 15.0...30.0

    /// The reader body follows Dynamic Type on top of the in-app size, and the
    /// settings preview uses the same function so the two always match.
    static func pointSize(_ base: Double) -> CGFloat {
        let clamped = base.isFinite ? min(sizeRange.upperBound, max(sizeRange.lowerBound, base)) : defaultSize
        return min(56, UIFontMetrics(forTextStyle: .body).scaledValue(for: clamped))
    }

    static func serif(_ size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        let system = UIFont.systemFont(ofSize: size)
        let serif = system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor
        return UIFont(descriptor: serif.withSymbolicTraits(traits) ?? serif, size: size)
    }
}
