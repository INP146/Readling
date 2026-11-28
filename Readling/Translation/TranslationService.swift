import Foundation
import Observation

/// What the lookup card asks for when the dictionary has nothing.
enum TranslationRequest: Hashable, Sendable {
    /// A sentence or any run of words, optionally with the surrounding sentence for context.
    case translate(String, context: String? = nil)
    /// A word the dictionary lacks, read in its sentence: what it means right here.
    case explain(word: String, sentence: String)
}

enum TranslationCapability: Sendable { case translate, explain }

/// Which service is chosen to answer translation requests: one of the built-in
/// translators, or one of the user's AI endpoints.
enum TranslationProviderID: Hashable, Sendable {
    case apple
    case deepL
    case ai(UUID)
    /// Answers instantly with canned text; picked by UI tests with `-translationEngine stub`.
    case stub

    static let appleTitle = "Apple 本机翻译"
    static let deepLTitle = "DeepL"
    static let stubTitle = "测试引擎"

    var rawValue: String {
        switch self {
        case .apple: "apple"
        case .deepL: "deepL"
        case .ai(let id): id.uuidString
        case .stub: "stub"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "apple": self = .apple
        case "deepL": self = .deepL
        case "stub": self = .stub
        default:
            guard let id = UUID(uuidString: rawValue) else { return nil }
            self = .ai(id)
        }
    }
}

enum TranslationFailure: LocalizedError, Equatable {
    /// Apple's on-device model for English → Chinese isn't downloaded yet.
    case needsLanguagePack
    case unsupported
    /// An online service without a usable address, key or model yet.
    case notConfigured
    case offline
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsLanguagePack: String(localized: "需要先下载英语到简体中文的翻译语言包。")
        case .unsupported: String(localized: "这台设备不支持英语到简体中文的本机翻译。")
        case .notConfigured: String(localized: "这个翻译服务还没有配置完整。")
        case .offline: String(localized: "没有网络连接。")
        case .failed(let message): message
        }
    }

    /// Whatever an engine threw, as something the card can show; cancellation stays cancellation.
    static func from(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is TranslationFailure: error
        case OnlineFailure.notConfigured: TranslationFailure.notConfigured
        case OnlineFailure.offline: TranslationFailure.offline
        case OnlineFailure.failed(let message): TranslationFailure.failed(message)
        default: TranslationFailure.failed(error.localizedDescription)
        }
    }
}

protocol TranslationEngine: Sendable {
    var title: String { get }
    var capabilities: Set<TranslationCapability> { get }
    /// The result so far, growing with each element; engines that don't stream yield once.
    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error>
}

/// Picks the service that translates (Apple, DeepL, or one of the AI endpoints),
/// falls back to Apple's on-device engine when the chosen one fails, and caches
/// finished results for this launch.
@Observable @MainActor
final class TranslationService {
    static let shared = TranslationService()

    struct Result: Equatable, Sendable {
        var text: String
        var provider: TranslationProviderID
        var providerTitle: String
        var canExplain = false
        var isFinal: Bool
        /// Why the chosen service didn't answer, when another one did.
        var notice: String?
    }

    static let engineKey = SettingsKeys.translationEngine
    static let automaticKey = SettingsKeys.translationAutomatic
    static let deepLAddressKey = SettingsKeys.translationDeepLAddress
    static let deepLAccount = "deepL"
    nonisolated static let source = Locale.Language(identifier: "en")
    nonisolated static let target = Locale.Language(identifier: "zh-Hans")

    private struct CacheKey: Hashable {
        var provider: TranslationProviderID
        /// Editing an endpoint (another model, another server) changes its answers.
        var endpoint: AIEndpoint?
        /// So do the user's prompts; nil for services that don't take prompts.
        var prompts: TranslationPrompts?
        var request: TranslationRequest
    }

    /// What the user picked; may name an AI endpoint since removed, see `effectiveSelection`.
    var selection: TranslationProviderID {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: Self.engineKey)
        }
    }

    private(set) var deepLAddress: String

    /// The instructions sent to AI endpoints, editable in Settings › AI 服务 › 提示词.
    var prompts: TranslationPrompts {
        didSet {
            guard prompts != oldValue else { return }
            prompts.save(to: defaults)
        }
    }

    let endpoints: AIEndpointStore
    private let defaults: UserDefaults
    private let keychain: APIKeychain
    private let customEngine: ((TranslationProviderID) -> any TranslationEngine)?
    private var cache: [CacheKey: String] = [:]

    init(defaults: UserDefaults = .standard,
         keychain: APIKeychain = .translation,
         endpoints: AIEndpointStore? = nil,
         engines: ((TranslationProviderID) -> any TranslationEngine)? = nil) {
        self.defaults = defaults
        self.keychain = keychain
        self.endpoints = endpoints ?? .shared
        self.customEngine = engines
        self.deepLAddress = defaults.string(forKey: Self.deepLAddressKey) ?? DeepLEngine.defaultBaseURL
        self.prompts = TranslationPrompts(defaults: defaults)
        self.selection = defaults.string(forKey: Self.engineKey).flatMap(TranslationProviderID.init(rawValue:)) ?? .apple
    }

    /// The service actually asked first: a removed AI endpoint means Apple.
    var effectiveSelection: TranslationProviderID {
        if case .ai(let id) = selection, endpoints.endpoint(id) == nil { return .apple }
        return selection
    }

    // MARK: DeepL

    var deepLKey: String? { keychain.key(account: Self.deepLAccount) }

    var isDeepLConfigured: Bool { DeepLEngine.configuration(address: deepLAddress, key: deepLKey) != nil }

    func saveDeepL(address: String, keyChange: KeyChange = .unchanged) throws {
        try keychain.apply(keyChange, account: Self.deepLAccount)
        deepLAddress = address
        defaults.set(address, forKey: Self.deepLAddressKey)
        cache = cache.filter { $0.key.provider != .deepL }
    }

    // MARK: Translating

    func title(of provider: TranslationProviderID) -> String {
        switch provider {
        case .apple: TranslationProviderID.appleTitle
        case .deepL: TranslationProviderID.deepLTitle
        case .stub: TranslationProviderID.stubTitle
        case .ai(let id): endpoints.endpoint(id)?.displayName ?? String(localized: "已删除的 AI 服务")
        }
    }

    func engine(for provider: TranslationProviderID) -> any TranslationEngine {
        if let customEngine { return customEngine(provider) }
        switch provider {
        case .apple:
            return AppleTranslationEngine()
        case .stub:
            return StubTranslationEngine()
        case .deepL:
            return DeepLEngine(configuration: DeepLEngine.configuration(address: deepLAddress, key: deepLKey))
        case .ai(let id):
            guard let client = endpoints.client(for: id) else { return UnconfiguredEngine(title: title(of: provider)) }
            return AITranslationEngine(title: title(of: provider), client: client, prompts: prompts)
        }
    }

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<Result, Error> {
        let chain = [effectiveSelection, .apple].reduce(into: [TranslationProviderID]()) { if !$0.contains($1) { $0.append($1) } }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var errors: [(title: String, error: Error)] = []
                func notice() -> String? {
                    guard let first = errors.first, !Self.isExpected(first.error) else { return nil }
                    return "\(first.title)：\(first.error.localizedDescription)"
                }
                for provider in chain {
                    let instance = engine(for: provider)
                    let canExplain = instance.capabilities.contains(.explain)
                    let asked = Self.request(request, for: instance)
                    var endpoint: AIEndpoint?
                    var prompts: TranslationPrompts?
                    if case .ai(let id) = provider { endpoint = endpoints.endpoint(id); prompts = self.prompts.resolved }
                    let key = CacheKey(provider: provider, endpoint: endpoint, prompts: prompts, request: asked)
                    if let cached = cache[key] {
                        continuation.yield(Result(text: cached, provider: provider, providerTitle: instance.title,
                                                  canExplain: canExplain, isFinal: true, notice: notice()))
                        continuation.finish()
                        return
                    }
                    var latest: String?
                    do {
                        for try await text in instance.run(asked) {
                            latest = text
                            continuation.yield(Result(text: text, provider: provider, providerTitle: instance.title,
                                                      canExplain: canExplain, isFinal: false, notice: notice()))
                        }
                        let text = latest?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !text.isEmpty else { throw TranslationFailure.failed(String(localized: "没有得到译文。")) }
                        cache[key] = text
                        continuation.yield(Result(text: text, provider: provider, providerTitle: instance.title,
                                                  canExplain: canExplain, isFinal: true, notice: notice()))
                        continuation.finish()
                        return
                    } catch {
                        let error = TranslationFailure.from(error)
                        if error is CancellationError { continuation.finish(throwing: error); return }
                        // Once an engine has shown part of its answer, switching engines would replace it mid-read.
                        if latest != nil { continuation.finish(throwing: error); return }
                        errors.append((instance.title, error))
                    }
                }
                // The chosen service's own failure says more than the fallback's, unless it was only unset or offline.
                let reported = errors.first { !Self.isExpected($0.error) } ?? errors.last
                continuation.finish(throwing: reported?.error ?? TranslationFailure.failed(String(localized: "没有得到译文。")))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func isExpected(_ error: Error) -> Bool {
        error as? TranslationFailure == .notConfigured || error as? TranslationFailure == .offline
    }

    /// Engines that can't explain a word in context translate the word instead, keeping the sentence as context.
    private static func request(_ request: TranslationRequest, for engine: any TranslationEngine) -> TranslationRequest {
        guard case .explain(let word, let sentence) = request, !engine.capabilities.contains(.explain) else { return request }
        return .translate(word, context: sentence.isEmpty || sentence == word ? nil : sentence)
    }
}

private struct UnconfiguredEngine: TranslationEngine {
    var title: String
    let capabilities: Set<TranslationCapability> = []
    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: TranslationFailure.notConfigured) }
    }
}

struct StubTranslationEngine: TranslationEngine {
    let title = TranslationProviderID.stubTitle
    let capabilities: Set<TranslationCapability> = [.translate, .explain]

    func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            switch request {
            case .translate(let text, _): continuation.yield("译文：\(text)")
            case .explain(let word, _): continuation.yield("释义：\(word)")
            }
            continuation.finish()
        }
    }
}
