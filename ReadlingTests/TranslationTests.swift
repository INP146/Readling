import Foundation
import Testing
@testable import Readling

@Suite("Translation endpoints, fallback and caching") @MainActor
struct TranslationTests {
    /// Answers with a fixed text, or fails; counts how often it was asked.
    final class FakeEngine: TranslationEngine, @unchecked Sendable {
        let title: String
        let capabilities: Set<TranslationCapability>
        let answer: String?
        var failure: TranslationFailure = .failed("boom")
        var requests: [TranslationRequest] = []

        init(_ title: String, capabilities: Set<TranslationCapability> = [.translate], answer: String?,
             failure: TranslationFailure = .failed("boom")) {
            self.title = title
            self.capabilities = capabilities
            self.answer = answer
            self.failure = failure
        }

        func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
            requests.append(request)
            let answer = answer, failure = failure
            return AsyncThrowingStream { continuation in
                if let answer {
                    continuation.yield(String(answer.prefix(2)))
                    continuation.yield(answer)
                    continuation.finish()
                } else {
                    continuation.finish(throwing: failure)
                }
            }
        }
    }

    private func cleanDefaults(_ name: String = UUID().uuidString) throws -> UserDefaults {
        let suite = "TranslationTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func cleanKeychain() -> APIKeychain {
        APIKeychain(service: "com.inp146.readling.tests.\(UUID().uuidString)")
    }

    private func cleanStore(_ defaults: UserDefaults) -> AIEndpointStore {
        AIEndpointStore(defaults: defaults, keychain: cleanKeychain())
    }

    /// A service whose AI endpoints live in their own store, choosing `endpoint` when given.
    private func service(_ defaults: UserDefaults, choosing endpoint: AIEndpoint? = nil,
                         engines: ((TranslationProviderID) -> any TranslationEngine)? = nil) throws -> TranslationService {
        let store = cleanStore(defaults)
        let service = TranslationService(defaults: defaults, keychain: cleanKeychain(), endpoints: store, engines: engines)
        if let endpoint {
            try store.save(endpoint)
            service.selection = .ai(endpoint.id)
        }
        return service
    }

    private func results(_ service: TranslationService, _ request: TranslationRequest) async throws -> [TranslationService.Result] {
        var all: [TranslationService.Result] = []
        for try await result in service.run(request) { all.append(result) }
        return all
    }

    @Test func streamsThenFinishesAndCaches() async throws {
        let stub = FakeEngine("测试引擎", capabilities: [.translate, .explain], answer: "你好世界")
        let defaults = try cleanDefaults()
        defaults.set("stub", forKey: TranslationService.engineKey)
        let service = try service(defaults, engines: { $0 == .stub ? stub : FakeEngine("Apple 本机翻译", answer: nil) })
        let first = try await results(service, .translate("hello world"))
        #expect(first.map(\.text) == ["你好", "你好世界", "你好世界"])
        #expect(first.last?.isFinal == true && first.dropLast().allSatisfy { !$0.isFinal })
        let again = try await results(service, .translate("hello world"))
        #expect(again == [TranslationService.Result(text: "你好世界", provider: .stub, providerTitle: "测试引擎", canExplain: true, isFinal: true)])
        #expect(stub.requests.count == 1)
    }

    @Test func editingTheChosenEndpointBypassesTheCache() async throws {
        let defaults = try cleanDefaults()
        var endpoint = AIEndpoint(name: "Ollama", format: .openAI, baseURL: "http://192.168.1.2:11434/v1", model: "qwen2.5:7b")
        let engine = FakeEngine("Ollama", capabilities: [.translate, .explain], answer: "译文")
        let service = try service(defaults, choosing: endpoint, engines: { _ in engine })
        _ = try await results(service, .translate("hello"))
        _ = try await results(service, .translate("hello"))
        #expect(engine.requests.count == 1)
        endpoint.model = "qwen2.5:14b"
        try service.endpoints.save(endpoint)
        _ = try await results(service, .translate("hello"))
        #expect(engine.requests.count == 2)
    }

    @Test func fallsBackToAppleWhenChosenEndpointFails() async throws {
        let endpoint = AIEndpoint(name: "DeepSeek", format: .openAI, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        let apple = FakeEngine("Apple 本机翻译", answer: "苹果译文")
        let service = try service(try cleanDefaults(), choosing: endpoint, engines: {
            $0 == .apple ? apple : FakeEngine(endpoint.displayName, capabilities: [.translate, .explain], answer: nil)
        })
        let all = try await results(service, .translate("hello"))
        #expect(all.last == TranslationService.Result(text: "苹果译文", provider: .apple, providerTitle: "Apple 本机翻译",
                                                      canExplain: false, isFinal: true, notice: "DeepSeek：boom"))
    }

    @Test func fallsBackQuietlyWhenEndpointIsUnsetOrOffline() async throws {
        for failure in [TranslationFailure.notConfigured, .offline] {
            let endpoint = AIEndpoint(name: "Claude 中转", format: .claude, baseURL: "https://relay.example.com", model: "claude-sonnet")
            let apple = FakeEngine("Apple 本机翻译", answer: "苹果译文")
            let service = try service(try cleanDefaults(), choosing: endpoint, engines: {
                $0 == .apple ? apple : FakeEngine(endpoint.displayName, answer: nil, failure: failure)
            })
            let all = try await results(service, .translate("hello"))
            #expect(all.last == TranslationService.Result(text: "苹果译文", provider: .apple, providerTitle: "Apple 本机翻译",
                                                          canExplain: false, isFinal: true))
        }
    }

    @Test func reportsChosenEndpointsFailureOverFallbacks() async throws {
        let endpoint = AIEndpoint(name: "Gemini", format: .gemini, baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-2.5-flash")
        let service = try service(try cleanDefaults(), choosing: endpoint, engines: {
            $0 == .apple ? FakeEngine("Apple 本机翻译", answer: nil, failure: .needsLanguagePack)
                         : FakeEngine(endpoint.displayName, answer: nil, failure: .failed("API Key 无效。"))
        })
        await #expect(throws: TranslationFailure.failed("API Key 无效。")) { _ = try await results(service, .translate("hello")) }

        let offline = try self.service(try cleanDefaults(), choosing: endpoint, engines: {
            $0 == .apple ? FakeEngine("Apple 本机翻译", answer: nil, failure: .needsLanguagePack)
                         : FakeEngine(endpoint.displayName, answer: nil, failure: .offline)
        })
        await #expect(throws: TranslationFailure.needsLanguagePack) { _ = try await results(offline, .translate("hello")) }
    }

    @Test func mapsOnlineFailuresForTheCard() async throws {
        struct Throwing: TranslationEngine {
            var title = "AI"
            var capabilities: Set<TranslationCapability> = [.translate]
            var error: Error
            func run(_ request: TranslationRequest) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { $0.finish(throwing: error) }
            }
        }
        let endpoint = AIEndpoint(name: "AI", format: .openAI, baseURL: "https://api.example.com/v1", model: "m")
        let service = try service(try cleanDefaults(), choosing: endpoint, engines: {
            $0 == .apple ? FakeEngine("Apple 本机翻译", answer: nil, failure: .needsLanguagePack) as any TranslationEngine
                         : Throwing(error: OnlineFailure.failed("API Key 无效。"))
        })
        await #expect(throws: TranslationFailure.failed("API Key 无效。")) { _ = try await results(service, .translate("hello")) }
    }

    @Test func enginesThatCannotExplainTranslateTheWordWithContext() async throws {
        let defaults = try cleanDefaults()
        let deepL = FakeEngine("DeepL", capabilities: [.translate], answer: "爱丽丝")
        let service = try service(defaults, engines: { _ in deepL })
        service.selection = .deepL
        _ = try await results(service, .explain(word: "Alice", sentence: "Alice was tired."))
        _ = try await results(service, .explain(word: "Alice", sentence: ""))
        #expect(deepL.requests == [.translate("Alice", context: "Alice was tired."), .translate("Alice", context: nil)])
    }

    @Test func aRemovedEndpointMeansApple() throws {
        let defaults = try cleanDefaults()
        let endpoint = AIEndpoint(name: "Ollama", format: .openAI, baseURL: "http://192.168.1.2:11434/v1", model: "qwen2.5:7b")
        let service = try service(defaults, choosing: endpoint)
        #expect(service.effectiveSelection == .ai(endpoint.id))
        #expect(service.title(of: .ai(endpoint.id)) == "Ollama")
        service.endpoints.remove(endpoint.id)
        #expect(service.effectiveSelection == .apple)
        let reloaded = TranslationService(defaults: defaults, keychain: cleanKeychain(), endpoints: cleanStore(defaults))
        #expect(reloaded.selection == .ai(endpoint.id))
        #expect(reloaded.effectiveSelection == .apple)
    }

    @Test func storesDeepLAddressAndKey() throws {
        let defaults = try cleanDefaults()
        let keychain = cleanKeychain()
        let service = TranslationService(defaults: defaults, keychain: keychain, endpoints: cleanStore(defaults))
        #expect(service.deepLAddress == DeepLEngine.defaultBaseURL)
        #expect(!service.isDeepLConfigured)
        try service.saveDeepL(address: "http://192.168.1.5:1188", keyChange: .unchanged)
        #expect(service.isDeepLConfigured)
        try service.saveDeepL(address: DeepLEngine.defaultBaseURL, keyChange: .set("dl-key:fx"))
        let reloaded = TranslationService(defaults: defaults, keychain: keychain, endpoints: cleanStore(defaults))
        #expect(reloaded.deepLAddress == DeepLEngine.defaultBaseURL)
        #expect(reloaded.deepLKey == "dl-key:fx")
        #expect(reloaded.isDeepLConfigured)
    }

    @Test func storesEndpointsAndTheirKeys() throws {
        let defaults = try cleanDefaults()
        let keychain = cleanKeychain()
        let store = AIEndpointStore(defaults: defaults, keychain: keychain)
        var first = AIEndpoint(name: "Ollama", format: .openAI, baseURL: "http://192.168.1.2:11434/v1", model: "qwen2.5:7b")
        try store.save(first, keyChange: .set("sk-one"))
        #expect(store.key(for: first.id) == "sk-one")
        #expect(store.client(for: first.id) != nil)

        first.model = "qwen2.5:14b"
        try store.save(first)
        #expect(store.endpoints == [first])
        #expect(store.key(for: first.id) == "sk-one")

        let reloaded = AIEndpointStore(defaults: defaults, keychain: keychain)
        #expect(reloaded.endpoints == [first])
        reloaded.remove(first.id)
        #expect(reloaded.endpoints.isEmpty)
        #expect(reloaded.client(for: first.id) == nil)
        #expect(keychain.key(account: first.id.uuidString) == nil)
    }

    @Test func aiEngineSendsTheTranslationPrompts() async throws {
        final class Recorder: AIClient, @unchecked Sendable {
            var prompts: [AIPrompt] = []
            func complete(_ prompt: AIPrompt) -> AsyncThrowingStream<String, Error> {
                prompts.append(prompt)
                return AsyncThrowingStream { $0.yield("好"); $0.finish() }
            }
        }
        let client = Recorder()
        let engine = AITranslationEngine(title: "AI", client: client)
        for try await _ in engine.run(.translate("Hello there.")) {}
        for try await _ in engine.run(.explain(word: "hare", sentence: "The March Hare said.")) {}
        #expect(client.prompts.map(\.user) == ["<text>\nHello there.\n</text>",
                                               "<word>hare</word>\n<sentence>The March Hare said.</sentence>"])
        #expect(client.prompts.allSatisfy { !$0.system.isEmpty })
    }

    @Test func customPromptsPersistAndReachTheEndpoint() throws {
        let suite = "prompts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(TranslationPrompts(defaults: defaults) == .default)
        var prompts = TranslationPrompts.default
        prompts.translate = "  翻译成文言文。 "
        prompts.save(to: defaults)
        #expect(defaults.string(forKey: TranslationPrompts.translateKey) == "翻译成文言文。")
        #expect(defaults.object(forKey: TranslationPrompts.explainKey) == nil)
        #expect(TranslationPrompts(defaults: defaults).translate == "翻译成文言文。")

        let custom = AITranslationEngine.prompt(for: .translate("Hi."), prompts: prompts)
        #expect(custom.system.hasPrefix("翻译成文言文。\n"))
        #expect(custom.system.contains("<text>"))
        // A prompt cleared while editing falls back to the default rather than sending only the data note.
        let blank = AITranslationEngine.prompt(for: .explain(word: "hare", sentence: "A hare."),
                                               prompts: TranslationPrompts(translate: "", explain: "  "))
        #expect(blank.system.hasPrefix(TranslationPrompts.defaultExplain))
    }
}
