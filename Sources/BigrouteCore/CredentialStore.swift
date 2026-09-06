import Foundation
import Security

public struct BigrouteConfiguration: Equatable, Sendable {
    public var providers: [CustomQuotaProvider]
    public var refreshIntervalMinutes: Int
    public var sortOrder: AccountSortOrder
    public var antigravityBridge: AntigravityBridgeConfig

    public init(
        providers: [CustomQuotaProvider] = [],
        refreshIntervalMinutes: Int = 2,
        sortOrder: AccountSortOrder = .quotaDescending,
        antigravityBridge: AntigravityBridgeConfig = AntigravityBridgeConfig()
    ) {
        self.providers = providers
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.sortOrder = sortOrder
        self.antigravityBridge = antigravityBridge
    }

    public static let defaults = BigrouteConfiguration()
}

/// Stores provider metadata in UserDefaults and API keys in the Keychain.
public struct CredentialStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let envURL: URL
    private let keychain: CredentialKeychain
    private let v2ConfigKey = "routerQuota.configuration.v2"
    private let legacyConfigKey = "routerQuota.configuration"

    private struct PersistedProvider: Codable {
        let id: UUID
        let name: String
        let endpoint: String
        let apiKind: QuotaAPIKind
        let isEnabled: Bool
    }

    private struct PersistedSettings: Codable {
        let schemaVersion: Int
        let providers: [PersistedProvider]
        let refreshIntervalMinutes: Int
        let sortOrder: AccountSortOrder?
        let antigravityBridge: AntigravityBridgeConfig?
    }

    private struct LegacySettings: Codable {
        let nineRouterURL: String
        let omniURL: String
        let refreshIntervalMinutes: Int
    }

    public init(defaults: UserDefaults = .standard, envURL: URL? = nil) {
        self.defaults = defaults
        self.keychain = .system
        self.envURL = envURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.env")
    }

    init(defaults: UserDefaults, envURL: URL, keychain: CredentialKeychain) {
        self.defaults = defaults
        self.envURL = envURL
        self.keychain = keychain
    }

    public func load() throws -> BigrouteConfiguration {
        if defaults.data(forKey: v2ConfigKey) != nil && loadPersisted() == nil {
            throw CredentialConfigurationError()
        }
        if let persisted = loadPersisted() {
            guard persisted.schemaVersion <= 5, Set(persisted.providers.map(\.id)).count == persisted.providers.count else {
                throw CredentialConfigurationError()
            }
            let configuration = BigrouteConfiguration(
                providers: try persisted.providers.map { provider in
                    CustomQuotaProvider(
                        id: provider.id,
                        name: provider.name,
                        endpoint: provider.endpoint,
                        apiKey: try keychain.read(Self.keychainAccount(provider.id)) ?? "",
                        apiKind: provider.apiKind,
                        isEnabled: provider.isEnabled
                    )
                },
                refreshIntervalMinutes: min(60, max(1, persisted.refreshIntervalMinutes)),
                sortOrder: persisted.sortOrder ?? .quotaDescending,
                antigravityBridge: persisted.antigravityBridge ?? AntigravityBridgeConfig(isEnabled: AntigravityBridgeManager.shared.isCurrentlyPointedToBridge)
            )
            removeRetiredAutomaticRoutingData(from: persisted)
            return configuration
        }

        let migrated = try migrateLegacy()
        // Make migration one-time and idempotent. Secrets are copied before the
        // v2 metadata is written; old credentials are intentionally retained.
        try save(migrated)
        return migrated
    }

    /// Loads only non-secret settings so app startup never waits on Keychain.
    /// Call `load()` off the main actor to hydrate provider API keys.
    public func loadMetadata() -> BigrouteConfiguration {
        guard let persisted = loadPersisted() else { return .defaults }
        return BigrouteConfiguration(
            providers: persisted.providers.map { provider in
                CustomQuotaProvider(
                    id: provider.id,
                    name: provider.name,
                    endpoint: provider.endpoint,
                    apiKey: "",
                    apiKind: provider.apiKind,
                    isEnabled: provider.isEnabled
                )
            },
            refreshIntervalMinutes: min(60, max(1, persisted.refreshIntervalMinutes)),
            sortOrder: persisted.sortOrder ?? .quotaDescending,
            antigravityBridge: persisted.antigravityBridge
                ?? AntigravityBridgeConfig(isEnabled: AntigravityBridgeManager.shared.isCurrentlyPointedToBridge)
        )
    }

    public func save(_ configuration: BigrouteConfiguration, previous: BigrouteConfiguration? = nil) throws {
        let previousProviderIDs = Set(loadPersisted()?.providers.map(\.id) ?? [])
        let providers = configuration.providers.map {
            PersistedProvider(
                id: $0.id,
                name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: $0.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKind: $0.apiKind,
                isEnabled: $0.isEnabled
            )
        }

        // Write credentials first so a failed metadata write never loses a key.
        for provider in configuration.providers {
            let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldKey = previous?.providers.first(where: { $0.id == provider.id })?.apiKey
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key != oldKey {
                try keychain.save(key, Self.keychainAccount(provider.id))
            }
        }

        let settings = PersistedSettings(
            schemaVersion: 5,
            providers: providers,
            refreshIntervalMinutes: min(60, max(1, configuration.refreshIntervalMinutes)),
            sortOrder: configuration.sortOrder,
            antigravityBridge: configuration.antigravityBridge
        )
        let data = try JSONEncoder().encode(settings)
        let currentIDs = Set(providers.map(\.id))
        for removed in previousProviderIDs.subtracting(currentIDs) {
            try keychain.delete(Self.keychainAccount(removed))
            try? keychain.delete(Self.retiredDashboardPasswordAccount(removed))
            defaults.removeObject(forKey: Self.retiredAutomationStateKey(removed))
        }
        defaults.set(data, forKey: v2ConfigKey)
    }

    public static func keychainAccount(_ providerID: UUID) -> String {
        "provider.\(providerID.uuidString).apiKey"
    }

    private func loadPersisted() -> PersistedSettings? {
        guard let data = defaults.data(forKey: v2ConfigKey) else { return nil }
        return try? JSONDecoder().decode(PersistedSettings.self, from: data)
    }

    /// Automatic routing was retired in 1.2.2. Normalize the persisted JSON
    /// before startup so even a later downgrade cannot silently re-enable it.
    private func removeRetiredAutomaticRoutingData(from persisted: PersistedSettings) {
        guard persisted.schemaVersion < 5 else { return }
        let normalized = PersistedSettings(
            schemaVersion: 5,
            providers: persisted.providers,
            refreshIntervalMinutes: min(60, max(1, persisted.refreshIntervalMinutes)),
            sortOrder: persisted.sortOrder,
            antigravityBridge: persisted.antigravityBridge
        )
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: v2ConfigKey)
        }
        for provider in persisted.providers {
            try? keychain.delete(Self.retiredDashboardPasswordAccount(provider.id))
            defaults.removeObject(forKey: Self.retiredAutomationStateKey(provider.id))
        }
    }

    private static func retiredDashboardPasswordAccount(_ providerID: UUID) -> String {
        "provider.\(providerID.uuidString).dashboardPassword"
    }

    private static func retiredAutomationStateKey(_ providerID: UUID) -> String {
        "routerQuota.nineRouterAutomationState.\(providerID.uuidString).v1"
    }

    private func migrateLegacy() throws -> BigrouteConfiguration {
        let legacySuite = UserDefaults(suiteName: "vn.bigroll.codex-model-switcher")
        var nineURL = defaults.string(forKey: "routerTargetURL.nineRouter")
            ?? defaults.string(forKey: "routerTargetURL")
            ?? legacySuite?.string(forKey: "routerTargetURL.nineRouter")
            ?? legacySuite?.string(forKey: "routerTargetURL")
            ?? ""
        var omniURL = defaults.string(forKey: "routerTargetURL.omni")
            ?? legacySuite?.string(forKey: "routerTargetURL.omni")
            ?? ""
        var refresh = 2

        if let data = defaults.data(forKey: legacyConfigKey),
           let settings = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            nineURL = settings.nineRouterURL
            omniURL = settings.omniURL
            refresh = settings.refreshIntervalMinutes
        }

        var nineKey = try keychain.read("nineRouterKey") ?? ""
        var omniKey = try keychain.read("omniKey") ?? ""
        var omniQuotaToken = try keychain.read("omniQuotaToken") ?? ""
        if let content = try? String(contentsOf: envURL) {
            let values = Self.parseEnv(content)
            if nineURL.isEmpty { nineURL = values["NINEROUTER_URL"] ?? values["NINEROUTER_BASE_URL"] ?? "" }
            if omniURL.isEmpty { omniURL = values["OMNIROUTE_URL"] ?? values["OMNIROUTE_BASE_URL"] ?? "" }
            if nineKey.isEmpty { nineKey = values["NINEROUTER_API_KEY"] ?? "" }
            if omniKey.isEmpty { omniKey = values["OMNIROUTE_API_KEY"] ?? "" }
            if omniQuotaToken.isEmpty { omniQuotaToken = values["OMNIROUTE_QUOTA_TOKEN"] ?? "" }
        }

        var providers: [CustomQuotaProvider] = []
        if !nineURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providers.append(CustomQuotaProvider(
                id: LegacyProviderID.nineRouter,
                name: "CLI Proxy API",
                endpoint: nineURL,
                apiKey: nineKey,
                apiKind: .cliProxyAPI
            ))
        }
        if !omniURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providers.append(CustomQuotaProvider(
                id: LegacyProviderID.omniRouter,
                name: "CLI Proxy API",
                endpoint: omniURL,
                apiKey: omniQuotaToken.isEmpty ? omniKey : omniQuotaToken,
                apiKind: .cliProxyAPI
            ))
        }
        return BigrouteConfiguration(
            providers: providers,
            refreshIntervalMinutes: refresh,
            sortOrder: .quotaDescending
        )
    }

    private static func parseEnv(_ content: String) -> [String: String] {
        content.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("#"), let equals = text.firstIndex(of: "=") else { return }
            let key = text[..<equals].trimmingCharacters(in: .whitespaces)
            var value = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { result[String(key)] = String(value) }
        }
    }
}

struct CredentialKeychain: Sendable {
    var read: @Sendable (String) throws -> String?
    var save: @Sendable (String, String) throws -> Void
    var delete: @Sendable (String) throws -> Void

    static let system = CredentialKeychain(read: Keychain.value, save: Keychain.save, delete: Keychain.delete)
}

private struct CredentialConfigurationError: LocalizedError {
    var errorDescription: String? { "Saved provider settings could not be read. Existing settings and credentials have been preserved." }
}

private enum Keychain {
    private static let service = "com.routerquota.credentials"

    static func value(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    static func save(_ value: String, for account: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            try delete(for: account)
            return
        }
        let data = Data(value.utf8)
        // Update in place to retain the item's ACL. Only create on not-found;
        // denial/locked Keychain must never masquerade as a missing credential.
        var status = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var create = lookup
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(create as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(for account: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(lookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Unable to save secure credentials to Keychain."
    }
}
