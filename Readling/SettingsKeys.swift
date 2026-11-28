import Foundation

/// Every UserDefaults key the app uses, in one place (see docs/data-versioning.md).
///
/// Settings are source data: a released key keeps its name and the meaning of its values. Renaming a key, changing
/// what its values mean or dropping it is done by the migration step of the version in development.
enum SettingsKeys {
    // Reader (shared by the reader's own panels and the 设置 tab).
    static let readerFont = "readerFont"
    static let readerTypeface = "readerTypeface"
    static let readerLineSpacing = "readerLineSpacing"
    static let readerParagraphSpacing = "readerParagraphSpacing"
    static let readerMargin = "readerMargin"
    static let readerAppearance = "readerAppearance"
    static let readerDayTheme = "readerDayTheme"
    static let readerNightTheme = "readerNightTheme"
    static let readerBackdrop = "readerBackdrop"
    /// Counts changes of the custom background picture, so cached images refresh.
    static let readerBackdropVersion = "readerBackdropVersion"
    static let readerPageTurn = "readerPageTurn"
    static let readerEyeCare = "readerEyeCare"
    static let readerAutoSpeed = "readerAutoSpeed"
    static let readerKeepAwake = "readerKeepAwake"
    static let readerTipSeen = "readerTipSeen"
    static let lastReadBookID = "lastReadBookID"

    // Dictionary.
    static let dictionaryExpandByDefault = "dictionaryExpandByDefault"
    static let dictionaryAccent = "dictionaryAccent"
    /// Only ever set as a launch argument (`-dictionaryManifestURL <url>`), never saved.
    static let dictionaryManifestURL = "dictionaryManifestURL"

    // Translation and AI.
    static let translationEngine = "translationEngine"
    static let translationAutomatic = "translationAutomatic"
    static let translationDeepLAddress = "translationDeepLAddress"
    static let translationPromptTranslate = "translationPromptTranslate"
    static let translationPromptExplain = "translationPromptExplain"
    /// JSON of `[AIEndpoint]`; their API keys are in the Keychain (`APIKeychain.ai`), by endpoint id.
    static let aiEndpoints = "aiEndpoints"

    static let all: Set<String> = [
        readerFont, readerTypeface, readerLineSpacing, readerParagraphSpacing, readerMargin, readerAppearance,
        readerDayTheme, readerNightTheme, readerBackdrop, readerBackdropVersion, readerPageTurn, readerEyeCare,
        readerAutoSpeed, readerKeepAwake, readerTipSeen, lastReadBookID, dictionaryExpandByDefault, dictionaryAccent,
        dictionaryManifestURL, translationEngine, translationAutomatic, translationDeepLAddress,
        translationPromptTranslate, translationPromptExplain, aiEndpoints,
    ]
}
