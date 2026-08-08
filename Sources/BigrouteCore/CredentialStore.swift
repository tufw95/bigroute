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

public enum CredentialStoreError: Error, LocalizedError, Equatable {
    case duplicateProviderID
    case credentialRollbackFailed

    public var errorDescription: String? {
        switch self {
        case .duplicateProviderID:
            "Each provider must have a unique identifier."
        case .credentialRollbackFailed:
            "Bigroute could not restore the previous Keychain credentials after a save failure. Review the provider credentials before enabling automatic routing."
        }
    }
}

/// Stores provider metadata in UserDefaults and provider secrets in the Keychain.
public struct CredentialStore: @unchecked Sendable {
    private static let persistenceLock = NSLock()

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
        let isAutomaticAccountRoutingEnabled: Bool?
    }

    private struct PersistedSettings: Codable {
        let schemaVersion: Int
        let providers: [PersistedProvider]
        let refreshIntervalMinutes: Int
        let sortOrder: AccountSortOrder?
    }

    private struct PersistedSecrets {
        let apiKey: String
        let dashboardPassword: String
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
            var seenProviderIDs: Set<UUID> = []
            return BigrouteConfiguration(
                providers: persisted.providers.compactMap { provider in
                    guard seenProviderIDs.insert(provider.id).inserted else { return nil }
                    return CustomQuotaProvider(
                        id: provider.id,
                        name: provider.name,
                        endpoint: provider.endpoint,
                        apiKey: Keychain.value(for: Self.keychainAccount(provider.id)) ?? "",
                        dashboardPassword: Keychain.value(
                            for: Self.dashboardPasswordKeychainAccount(provider.id)
                        ) ?? "",
                        apiKind: provider.apiKind,
                        isEnabled: provider.isEnabled,
                        isAutomaticAccountRoutingEnabled: provider.isAutomaticAccountRoutingEnabled ?? false
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
        try Self.persistenceLock.withLock {
            try saveLocked(configuration)
        }
    }

    private func saveLocked(_ configuration: BigrouteConfiguration) throws {
        guard Set(configuration.providers.map(\.id)).count == configuration.providers.count else {
            throw CredentialStoreError.duplicateProviderID
        }
        let previousProviders = loadPersisted()?.providers ?? []
        let previousProvidersByID = Dictionary(
            previousProviders.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previousProviderIDs = Set(previousProviders.map(\.id))
        let previousSecretsByID = Dictionary(
            uniqueKeysWithValues: previousProviderIDs.map { providerID in
                (providerID, PersistedSecrets(
                    apiKey: Keychain.value(for: Self.keychainAccount(providerID)) ?? "",
                    dashboardPassword: Keychain.value(
                        for: Self.dashboardPasswordKeychainAccount(providerID)
                    ) ?? ""
                ))
            }
        )
        let currentProvidersByID = Dictionary(
            configuration.providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let providers = configuration.providers.map {
            PersistedProvider(
                id: $0.id,
                name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                endpoint: $0.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKind: $0.apiKind,
                isEnabled: $0.isEnabled,
                isAutomaticAccountRoutingEnabled: $0.isAutomaticAccountRoutingEnabled
            )
        }

        let settings = PersistedSettings(
            schemaVersion: 4,
            providers: providers,
            refreshIntervalMinutes: min(60, max(1, configuration.refreshIntervalMinutes)),
            sortOrder: configuration.sortOrder
        )
        let data = try JSONEncoder().encode(settings)

        // Prepare all throwable metadata work before touching Keychain, then
        // roll back any credentials already changed if a later write fails.
        var changedAPIKeyProviderIDs: [UUID] = []
        var changedPasswordProviderIDs: [UUID] = []
        do {
            for provider in configuration.providers {
                let previousSecrets = previousSecretsByID[provider.id]
                    ?? PersistedSecrets(apiKey: "", dashboardPassword: "")
                let newAPIKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if previousSecrets.apiKey != newAPIKey {
                    try Keychain.save(newAPIKey, for: Self.keychainAccount(provider.id))
                    changedAPIKeyProviderIDs.append(provider.id)
                }
                if previousSecrets.dashboardPassword != provider.dashboardPassword {
                    try Keychain.save(
                        provider.dashboardPassword,
                        for: Self.dashboardPasswordKeychainAccount(provider.id)
                    )
                    changedPasswordProviderIDs.append(provider.id)
                }
            }
        } catch {
            var rollbackFailed = false
            for providerID in changedPasswordProviderIDs.reversed() {
                do {
                    try Keychain.save(
                        previousSecretsByID[providerID]?.dashboardPassword ?? "",
                        for: Self.dashboardPasswordKeychainAccount(providerID)
                    )
                } catch {
                    rollbackFailed = true
                }
            }
            for providerID in changedAPIKeyProviderIDs.reversed() {
                do {
                    try Keychain.save(
                        previousSecretsByID[providerID]?.apiKey ?? "",
                        for: Self.keychainAccount(providerID)
                    )
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed { throw CredentialStoreError.credentialRollbackFailed }
            throw error
        }

        defaults.set(data, forKey: v2ConfigKey)

        let currentIDs = Set(providers.map(\.id))
        for removed in previousProviderIDs.subtracting(currentIDs) {
            Keychain.delete(for: Self.keychainAccount(removed))
            Keychain.delete(for: Self.dashboardPasswordKeychainAccount(removed))
            defaults.removeObject(forKey: Self.automationStateKey(removed))
        }
        for provider in providers {
            guard let currentProvider = currentProvidersByID[provider.id] else { continue }
            if Self.shouldRelinquishAutomationOwnership(
                previous: previousProvidersByID[provider.id],
                current: provider,
                previousSecrets: previousSecretsByID[provider.id],
                currentAPIKey: currentProvider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                currentDashboardPassword: currentProvider.dashboardPassword
            ) {
                defaults.removeObject(forKey: Self.automationStateKey(provider.id))
            }
        }
    }

    public static func keychainAccount(_ providerID: UUID) -> String {
        "provider.\(providerID.uuidString).apiKey"
    }

    public static func dashboardPasswordKeychainAccount(_ providerID: UUID) -> String {
        "provider.\(providerID.uuidString).dashboardPassword"
    }

    public func loadNineRouterAutomationState(for providerID: UUID) -> NineRouterAutomationState {
        Self.persistenceLock.withLock {
            guard let data = defaults.data(forKey: Self.automationStateKey(providerID)),
                  let state = try? JSONDecoder().decode(NineRouterAutomationState.self, from: data) else {
                return .empty
            }
            return state
        }
    }

    public func saveNineRouterAutomationState(
        _ state: NineRouterAutomationState,
        for providerID: UUID,
        expectedProvider: CustomQuotaProvider? = nil
    ) throws {
        try Self.persistenceLock.withLock {
            let key = Self.automationStateKey(providerID)
            if let expectedProvider {
                guard let persisted = loadPersisted()?.providers.first(where: { $0.id == providerID }),
                      Self.matchesAutomationScope(
                          persisted,
                          expected: expectedProvider,
                          state: state
                      ) else {
                    // A cancelled refresh must never delete or overwrite state
                    // written by a newer provider configuration.
                    throw NineRouterAutomationError.statePersistenceFailed
                }
            }
            guard !state.autoDisabledConnectionIDs.isEmpty else {
                defaults.removeObject(forKey: key)
                return
            }
            defaults.set(try JSONEncoder().encode(state), forKey: key)
        }
    }

    private static func automationStateKey(_ providerID: UUID) -> String {
        "routerQuota.nineRouterAutomationState.\(providerID.uuidString).v1"
    }

    private static func shouldRelinquishAutomationOwnership(
        previous: PersistedProvider?,
        current: PersistedProvider,
        previousSecrets: PersistedSecrets?,
        currentAPIKey: String,
        currentDashboardPassword: String
    ) -> Bool {
        guard current.isEnabled,
              current.apiKind == .nineRouter,
              current.isAutomaticAccountRoutingEnabled == true,
              let previous,
              let previousSecrets,
              previous.isEnabled,
              previous.apiKind == .nineRouter,
              previous.isAutomaticAccountRoutingEnabled == true,
              previousSecrets.apiKey == currentAPIKey,
              previousSecrets.dashboardPassword == currentDashboardPassword,
              let previousIdentity = managementEndpointIdentity(for: previous.endpoint),
              let currentIdentity = managementEndpointIdentity(for: current.endpoint) else {
            return true
        }
        return previousIdentity != currentIdentity
    }

    private static func matchesAutomationScope(
        _ persisted: PersistedProvider,
        expected: CustomQuotaProvider,
        state: NineRouterAutomationState
    ) -> Bool {
        guard persisted.id == expected.id,
              persisted.isEnabled,
              expected.isEnabled,
              persisted.apiKind == .nineRouter,
              expected.apiKind == .nineRouter,
              persisted.isAutomaticAccountRoutingEnabled == true,
              expected.isAutomaticAccountRoutingEnabled,
              let persistedIdentity = managementEndpointIdentity(for: persisted.endpoint),
              let expectedIdentity = managementEndpointIdentity(for: expected.endpoint),
              persistedIdentity == expectedIdentity,
              state.managementEndpointIdentity == expectedIdentity else {
            return false
        }
        return (Keychain.value(for: keychainAccount(expected.id)) ?? "")
            == expected.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            && (Keychain.value(for: dashboardPasswordKeychainAccount(expected.id)) ?? "")
            == expected.dashboardPassword
    }

    private static func managementEndpointIdentity(for endpoint: String) -> String? {
        guard let normalized = try? RouterEndpoint.normalizedURL(from: endpoint),
              let management = try? NineRouterAutomationService.managementBaseURL(from: normalized) else {
            return nil
        }
        return management.absoluteString
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
