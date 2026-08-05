import Foundation
import Security

public struct BigrouteConfiguration: Equatable, Sendable {
    public var providers: [CustomQuotaProvider]
    public var refreshIntervalMinutes: Int
    public var sortOrder: AccountSortOrder

    public init(
        providers: [CustomQuotaProvider] = [],
        refreshIntervalMinutes: Int = 2,
        sortOrder: AccountSortOrder = .quotaDescending
    ) {
        self.providers = providers
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.sortOrder = sortOrder
    }

    public static let defaults = BigrouteConfiguration()
}

/// Stores provider metadata in UserDefaults and API keys in the Keychain.
public struct CredentialStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let envURL: URL
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
    }

    private struct LegacySettings: Codable {
        let nineRouterURL: String
        let omniURL: String
        let refreshIntervalMinutes: Int
    }

    public init(defaults: UserDefaults = .standard, envURL: URL? = nil) {
        self.defaults = defaults
        self.envURL = envURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.env")
    }

    public func load() -> BigrouteConfiguration {
        if let persisted = loadPersisted() {
            return BigrouteConfiguration(
                providers: persisted.providers.map { provider in
                    CustomQuotaProvider(
                        id: provider.id,
                        name: provider.name,
                        endpoint: provider.endpoint,
                        apiKey: Keychain.value(for: Self.keychainAccount(provider.id)) ?? "",
                        apiKind: provider.apiKind,
                        isEnabled: provider.isEnabled
                    )
                },
                refreshIntervalMinutes: min(60, max(1, persisted.refreshIntervalMinutes)),
                sortOrder: persisted.sortOrder ?? .quotaDescending
            )
        }

        let migrated = migrateLegacy()
        // Make migration one-time and idempotent. Secrets are copied before the
        // v2 metadata is written; old credentials are intentionally retained.
        try? save(migrated)
        return migrated
    }

    public func save(_ configuration: BigrouteConfiguration) throws {
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
            try Keychain.save(provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.keychainAccount(provider.id))
        }

        let settings = PersistedSettings(
            schemaVersion: 3,
            providers: providers,
            refreshIntervalMinutes: min(60, max(1, configuration.refreshIntervalMinutes)),
            sortOrder: configuration.sortOrder
        )
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: v2ConfigKey)

        let currentIDs = Set(providers.map(\.id))
        for removed in previousProviderIDs.subtracting(currentIDs) {
            Keychain.delete(for: Self.keychainAccount(removed))
        }
    }

    public static func keychainAccount(_ providerID: UUID) -> String {
        "provider.\(providerID.uuidString).apiKey"
    }

    private func loadPersisted() -> PersistedSettings? {
        guard let data = defaults.data(forKey: v2ConfigKey) else { return nil }
        return try? JSONDecoder().decode(PersistedSettings.self, from: data)
    }

    private func migrateLegacy() -> BigrouteConfiguration {
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

        var nineKey = Keychain.value(for: "nineRouterKey") ?? ""
        var omniKey = Keychain.value(for: "omniKey") ?? ""
        var omniQuotaToken = Keychain.value(for: "omniQuotaToken") ?? ""
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
                name: "9Router",
                endpoint: nineURL,
                apiKey: nineKey,
                apiKind: .nineRouter
            ))
        }
        if !omniURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            providers.append(CustomQuotaProvider(
                id: LegacyProviderID.omniRouter,
                name: "OmniRouter",
                endpoint: omniURL,
                apiKey: omniQuotaToken.isEmpty ? omniKey : omniQuotaToken,
                apiKind: .omniRouter
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

private enum Keychain {
    private static let service = "com.routerquota.credentials"

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, for account: String) throws {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            delete(for: account)
            return
        }
        let data = Data(value.utf8)
        let status: OSStatus
        if SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var create = lookup
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(create as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(for account: String) {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(lookup as CFDictionary)
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Unable to save secure credentials to Keychain."
    }
}
