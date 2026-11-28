import Foundation
import Observation

/// The user's AI endpoints, shared by every feature that can use one. Which
/// endpoint a feature uses is that feature's own setting, not stored here.
@Observable @MainActor
final class AIEndpointStore {
    static let shared = AIEndpointStore()
    static let endpointsKey = SettingsKeys.aiEndpoints

    private(set) var endpoints: [AIEndpoint]

    private let defaults: UserDefaults
    private let keychain: APIKeychain

    init(defaults: UserDefaults = .standard, keychain: APIKeychain = .ai) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: Self.endpointsKey),
           let decoded = try? JSONDecoder().decode([AIEndpoint].self, from: data) {
            endpoints = decoded
        } else {
            endpoints = []
        }
    }

    func endpoint(_ id: UUID) -> AIEndpoint? { endpoints.first { $0.id == id } }

    func key(for id: UUID) -> String? { keychain.key(account: id.uuidString) }

    /// A client for the endpoint, or nil when it was removed or isn't fully configured.
    func client(for id: UUID, session: URLSession = .shared) -> (any AIClient)? {
        guard let endpoint = endpoint(id) else { return nil }
        return endpoint.format.client(for: endpoint, key: key(for: id), session: session)
    }

    func save(_ endpoint: AIEndpoint, keyChange: KeyChange = .unchanged) throws {
        try keychain.apply(keyChange, account: endpoint.id.uuidString)
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        persist()
    }

    func remove(_ id: UUID) {
        endpoints.removeAll { $0.id == id }
        try? keychain.deleteKey(account: id.uuidString)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(endpoints) {
            defaults.set(data, forKey: Self.endpointsKey)
        }
    }
}
