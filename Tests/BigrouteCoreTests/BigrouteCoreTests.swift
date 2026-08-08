import Foundation
import Testing
@testable import BigrouteCore

@Test func endpointConstruction() throws {
    let base = try #require(URL(string: "https://router.example.com/internal"))
    #expect(QuotaService.quotaURL(from: base).absoluteString == "https://router.example.com/internal/v1/quota")
    #expect(OmniQuotaService.quotaURL(from: base).absoluteString == "https://router.example.com/internal/api/usage/quota")

    let nineEndpoint = try #require(URL(string: "https://router.example.com/v1/quota"))
    let omniEndpoint = try #require(URL(string: "https://router.example.com/api/usage/quota"))
    #expect(QuotaService.quotaURL(from: nineEndpoint) == nineEndpoint)
    #expect(OmniQuotaService.quotaURL(from: omniEndpoint) == omniEndpoint)
    #expect(OmniQuotaService.providerLimitsURL(from: omniEndpoint).absoluteString == "https://router.example.com/api/usage/provider-limits")
}

@Test func omniParserReadsQuotaAndReset() throws {
    let json = Data(#"{"providers":[{"connectionId":"omni-1","provider":"omni","name":"Work","status":"valid","quota":{"percentRemaining":64,"resetAt":"2026-08-02T00:00:00Z"}}]}"#.utf8)
    let response = try OmniQuotaService.decodeResponse(json)
    #expect(response.accounts.count == 1)
    #expect(response.accounts.first?.primaryQuota?.remaining == 64)
    #expect(response.accounts.first?.primaryQuota?.resetAt == "2026-08-02T00:00:00Z")
}

@Test func accountNameTakesPrecedenceOverEmailLabel() throws {
    let json = Data(#"{"id":"nine-1","label":"person@example.com","name":"Office Mac","provider":"codex","plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let account = try JSONDecoder().decode(CodexQuotaAccount.self, from: json)
    #expect(account.label == "Office Mac")
}

@Test func accountIdentitySupportsNestedNamesAndLegacyLabels() throws {
    let nestedJSON = Data(#"{"id":"nine-2","provider":"codex","label":"person@example.com","metadata":{"display_name":"Design Mac"},"plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let nested = try JSONDecoder().decode(CodexQuotaAccount.self, from: nestedJSON)
    #expect(nested.label == "Design Mac")

    let legacyJSON = Data(#"{"id":"nine-3","provider":"codex","label":"legacy@example.com","plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let legacy = try JSONDecoder().decode(CodexQuotaAccount.self, from: legacyJSON)
    #expect(legacy.label == "legacy@example.com")
}

@Test func accountIdentityUsesNestedConnectionNameBeforeEmailLabel() throws {
    let json = Data(#"{"id":"nine-4","provider":"codex","label":"person@example.com","connection":{"name":"Design Mac"},"plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let account = try JSONDecoder().decode(CodexQuotaAccount.self, from: json)
    #expect(account.label == "Design Mac")
}

@Test func accountIdentityAcceptsNicknameField() throws {
    let json = Data(#"{"id":"nine-5","provider":"codex","label":"person@example.com","nickname":"Design Mac","plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let account = try JSONDecoder().decode(CodexQuotaAccount.self, from: json)
    #expect(account.label == "Design Mac")
}

@Test func accountDecoderRejectsIncompleteQuotaRecords() {
    let incomplete = Data(#"{"id":"nine-4","name":"Incomplete"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(CodexQuotaAccount.self, from: incomplete)
    }
}

@Test func accountSortOrdersKeepMissingValuesLast() {
    let make: (String, Double?, String?) -> CodexQuotaAccount = { id, remaining, resetAt in
        CodexQuotaAccount(
            id: id,
            provider: "9router",
            label: id,
            plan: "",
            limitReached: false,
            quotas: remaining.map {
                [CodexQuotaWindow(
                    key: "session",
                    used: 100 - $0,
                    total: 100,
                    remaining: $0,
                    resetAt: resetAt,
                    unlimited: false
                )]
            } ?? [],
            resetCredits: .init(availableCount: 0),
            status: "available",
            errorCode: nil
        )
    }
    let accounts = [
        make("No quota", nil, nil),
        make("Low", 20, "2026-08-05T00:00:00Z"),
        make("High", 80, "2026-08-03T00:00:00Z")
    ]
    #expect(AccountSortOrder.quotaDescending.sorted(accounts).map(\.label) == ["High", "Low", "No quota"])
    #expect(AccountSortOrder.quotaAscending.sorted(accounts).map(\.label) == ["Low", "High", "No quota"])
    #expect(AccountSortOrder.nameAscending.sorted(accounts).map(\.label) == ["High", "Low", "No quota"])
    #expect(AccountSortOrder.nameDescending.sorted(accounts).map(\.label) == ["No quota", "Low", "High"])
    #expect(AccountSortOrder.refreshSoonest.sorted(accounts).map(\.label) == ["High", "Low", "No quota"])
    #expect(AccountSortOrder.refreshLatest.sorted(accounts).map(\.label) == ["Low", "High", "No quota"])
}

@Test func sharedSnapshotRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SharedQuotaStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    let account = CodexQuotaAccount(
        id: "9r-1", provider: "9router", label: "Primary", plan: "Pro", limitReached: false,
        quotas: [CodexQuotaWindow(key: "session", used: 25, total: 100, remaining: 75, resetAt: nil, unlimited: false)],
        resetCredits: .init(availableCount: 0), status: "valid", errorCode: nil
    )
    let snapshot = BigrouteSnapshot(
        accounts: [account],
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        sortOrder: .nameAscending
    )
    try store.save(snapshot)
    #expect(store.load() == snapshot)
    #expect(store.load()?.sortOrder == .nameAscending)
    try? FileManager.default.removeItem(at: directory)
}

@Test func sharedSnapshotFallsBackToLegacyAndDualWrites() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let primaryURL = directory.appendingPathComponent("Bigroute/quota-snapshot.json")
    let legacyURL = directory.appendingPathComponent("RouterQuota/quota-snapshot.json")
    let store = SharedQuotaStore(fileURL: primaryURL, legacyFileURL: legacyURL)
    let older = BigrouteSnapshot(providers: [], generatedAt: Date(timeIntervalSince1970: 100))
    let newer = BigrouteSnapshot(providers: [], generatedAt: Date(timeIntervalSince1970: 200))
    let latest = BigrouteSnapshot(providers: [], generatedAt: Date(timeIntervalSince1970: 300))

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try FileManager.default.createDirectory(at: primaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(older).write(to: primaryURL)
    try encoder.encode(newer).write(to: legacyURL)
    #expect(store.load() == newer)

    try Data("invalid snapshot".utf8).write(to: primaryURL)
    #expect(store.load() == newer)

    try store.save(latest)
    #expect(FileManager.default.fileExists(atPath: primaryURL.path))
    #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(store.load() == latest)
    try? FileManager.default.removeItem(at: directory)
}

@Test func providerFilteringSeparatesSources() {
    let make: (String, String) -> CodexQuotaAccount = { id, provider in
        CodexQuotaAccount(id: id, provider: provider, label: id, plan: "", limitReached: false, quotas: [], resetCredits: .init(availableCount: 0), status: "valid", errorCode: nil)
    }
    let snapshot = BigrouteSnapshot(accounts: [make("a", "9router"), make("b", "omni")])
    #expect(snapshot.accounts(for: LegacyProviderID.nineRouter).map(\.id) == ["a"])
    #expect(snapshot.accounts(for: LegacyProviderID.omniRouter).map(\.id) == ["b"])
}

@Test func customProviderEncodingNeverContainsAPIKey() throws {
    let provider = CustomQuotaProvider(
        name: "Private Router",
        endpoint: "https://router.example.com",
        apiKey: "super-secret-value",
        dashboardPassword: "dashboard-secret",
        isAutomaticAccountRoutingEnabled: true
    )
    let data = try JSONEncoder().encode(provider)
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(!encoded.contains("super-secret-value"))
    #expect(!encoded.contains("dashboard-secret"))

    let decoded = try JSONDecoder().decode(CustomQuotaProvider.self, from: data)
    #expect(decoded.apiKey.isEmpty)
    #expect(decoded.dashboardPassword.isEmpty)
    #expect(decoded.name == provider.name)
    #expect(decoded.isAutomaticAccountRoutingEnabled)
}

@Test func customProviderBackwardDecodingKeepsAutomationOff() throws {
    let data = Data(#"{"id":"CE54A6AF-C623-480B-8C8A-87833C47F67E","name":"9Router","endpoint":"https://router.example.com","apiKind":"nineRouter","isEnabled":true}"#.utf8)
    let provider = try JSONDecoder().decode(CustomQuotaProvider.self, from: data)
    #expect(!provider.isAutomaticAccountRoutingEnabled)
    #expect(provider.dashboardPassword.isEmpty)
}

@Test func credentialStoreBackwardDecodingKeepsAutomationOff() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let providerID = UUID()
    let data = Data(#"{"schemaVersion":3,"providers":[{"id":"\#(providerID.uuidString)","name":"9Router","endpoint":"https://router.example.com","apiKind":"nineRouter","isEnabled":true}],"refreshIntervalMinutes":2,"sortOrder":"quotaDescending"}"#.utf8)
    defaults.set(data, forKey: "routerQuota.configuration.v2")

    let provider = try #require(CredentialStore(defaults: defaults).load().providers.first)
    #expect(!provider.isAutomaticAccountRoutingEnabled)
    #expect(provider.dashboardPassword.isEmpty)
}

@Test func nineRouterAutomationStateRoundTripIsProviderScoped() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    let firstProviderID = UUID()
    let secondProviderID = UUID()
    let state = NineRouterAutomationState(autoDisabledConnectionIDs: ["connection-a", "connection-b"])

    try store.saveNineRouterAutomationState(state, for: firstProviderID)
    #expect(store.loadNineRouterAutomationState(for: firstProviderID) == state)
    #expect(store.loadNineRouterAutomationState(for: secondProviderID) == .empty)

    try store.saveNineRouterAutomationState(.empty, for: firstProviderID)
    #expect(store.loadNineRouterAutomationState(for: firstProviderID) == .empty)
}

@Test func nineRouterAutomationStateKeepsResetMarkersAndReadsLegacyState() throws {
    let state = NineRouterAutomationState(
        autoDisabledConnectionIDs: ["connection-a"],
        managementEndpointIdentity: "https://router.example.com",
        deactivationWindows: ["connection-a": ["session": "2026-08-08T16:00:00Z"]]
    )
    let encoded = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(NineRouterAutomationState.self, from: encoded) == state)

    let legacy = Data(#"{"autoDisabledConnectionIDs":["connection-a"],"managementEndpointIdentity":"https://router.example.com"}"#.utf8)
    let decodedLegacy = try JSONDecoder().decode(NineRouterAutomationState.self, from: legacy)
    #expect(decodedLegacy.autoDisabledConnectionIDs == ["connection-a"])
    #expect(decodedLegacy.deactivationWindows.isEmpty)
}

@Test func removingProviderDeletesNineRouterAutomationState() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let providerID = UUID()
    let persisted = Data(#"{"schemaVersion":3,"providers":[{"id":"\#(providerID.uuidString)","name":"9Router","endpoint":"https://router.example.com","apiKind":"nineRouter","isEnabled":true}],"refreshIntervalMinutes":2,"sortOrder":"quotaDescending"}"#.utf8)
    defaults.set(persisted, forKey: "routerQuota.configuration.v2")
    let store = CredentialStore(defaults: defaults)
    try store.saveNineRouterAutomationState(
        NineRouterAutomationState(autoDisabledConnectionIDs: ["connection-a"]),
        for: providerID
    )

    try store.save(.defaults)

    #expect(store.loadNineRouterAutomationState(for: providerID) == .empty)
}

@Test func disablingAutomaticRoutingRelinquishesNineRouterAutomationState() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    var provider = automaticRoutingProvider()

    try store.save(BigrouteConfiguration(providers: [provider]))
    try store.saveNineRouterAutomationState(
        NineRouterAutomationState(autoDisabledConnectionIDs: ["connection-a"]),
        for: provider.id
    )
    provider.isAutomaticAccountRoutingEnabled = false

    try store.save(BigrouteConfiguration(providers: [provider]))

    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)
}

@Test func disablingProviderRelinquishesNineRouterAutomationState() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    var provider = automaticRoutingProvider()

    try store.save(BigrouteConfiguration(providers: [provider]))
    try store.saveNineRouterAutomationState(
        NineRouterAutomationState(autoDisabledConnectionIDs: ["connection-a"]),
        for: provider.id
    )
    provider.isEnabled = false

    try store.save(BigrouteConfiguration(providers: [provider]))

    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)
}

@Test func changingRouterEndpointRelinquishesNineRouterAutomationState() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    var provider = automaticRoutingProvider(
        endpoint: "https://router.example.com/team/api/v1/quota"
    )

    try store.save(BigrouteConfiguration(providers: [provider]))
    let state = NineRouterAutomationState(autoDisabledConnectionIDs: ["connection-a"])
    try store.saveNineRouterAutomationState(state, for: provider.id)

    provider.endpoint = "https://router.example.com/team/v1/quota"
    try store.save(BigrouteConfiguration(providers: [provider]))
    #expect(store.loadNineRouterAutomationState(for: provider.id) == state)

    provider.endpoint = "https://other-router.example.com/team/v1/quota"
    try store.save(BigrouteConfiguration(providers: [provider]))
    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)
}

@Test func changingProviderCredentialsRelinquishesNineRouterAutomationState() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    var provider = automaticRoutingProvider()
    provider.apiKey = "api-key-a"
    provider.dashboardPassword = "dashboard-password-a"
    defer { try? store.save(.defaults) }

    try store.save(BigrouteConfiguration(providers: [provider]))
    let state = NineRouterAutomationState(
        autoDisabledConnectionIDs: ["connection-a"],
        managementEndpointIdentity: "https://router.example.com",
        deactivationWindows: ["connection-a": ["session": "2026-08-08T16:00:00Z"]]
    )
    try store.saveNineRouterAutomationState(state, for: provider.id)

    provider.name = "Renamed"
    try store.save(BigrouteConfiguration(providers: [provider]))
    #expect(store.loadNineRouterAutomationState(for: provider.id) == state)

    provider.apiKey = "api-key-b"
    try store.save(BigrouteConfiguration(providers: [provider]))
    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)

    try store.saveNineRouterAutomationState(state, for: provider.id)
    provider.dashboardPassword = "dashboard-password-b"
    try store.save(BigrouteConfiguration(providers: [provider]))
    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)
}

@Test func duplicateProviderIdentifiersFailClosed() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let providerID = UUID()
    let persisted = Data(
        #"{"schemaVersion":4,"providers":[{"id":"\#(providerID.uuidString)","name":"First","endpoint":"https://router.example.com","apiKind":"nineRouter","isEnabled":true,"isAutomaticAccountRoutingEnabled":false},{"id":"\#(providerID.uuidString)","name":"Duplicate","endpoint":"https://other.example.com","apiKind":"nineRouter","isEnabled":true,"isAutomaticAccountRoutingEnabled":false}],"refreshIntervalMinutes":2,"sortOrder":"quotaDescending"}"#.utf8
    )
    defaults.set(persisted, forKey: "routerQuota.configuration.v2")
    let store = CredentialStore(defaults: defaults)

    #expect(store.load().providers.map(\.name) == ["First"])

    let duplicate = CustomQuotaProvider(
        id: providerID,
        name: "Duplicate",
        endpoint: "https://other.example.com",
        apiKind: .nineRouter
    )
    #expect(throws: CredentialStoreError.duplicateProviderID) {
        try store.save(BigrouteConfiguration(providers: [
            automaticRoutingProvider(),
            duplicate,
            CustomQuotaProvider(
                id: duplicate.id,
                name: "Same ID",
                endpoint: "https://third.example.com",
                apiKind: .nineRouter
            )
        ]))
    }
}

@Test func staleRefreshCannotRestoreOwnershipAfterAutomationIsDisabled() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    var provider = automaticRoutingProvider()

    try store.save(BigrouteConfiguration(providers: [provider]))
    let staleProvider = provider
    provider.isAutomaticAccountRoutingEnabled = false
    try store.save(BigrouteConfiguration(providers: [provider]))

    #expect(throws: NineRouterAutomationError.statePersistenceFailed) {
        try store.saveNineRouterAutomationState(
            NineRouterAutomationState(
                autoDisabledConnectionIDs: ["connection-a"],
                managementEndpointIdentity: "https://router.example.com"
            ),
            for: staleProvider.id,
            expectedProvider: staleProvider
        )
    }
    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)
}

@Test func mismatchedAutomationStateCannotBePersistedForAnEndpoint() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    let provider = automaticRoutingProvider()
    try store.save(BigrouteConfiguration(providers: [provider]))

    #expect(throws: NineRouterAutomationError.statePersistenceFailed) {
        try store.saveNineRouterAutomationState(
            NineRouterAutomationState(
                autoDisabledConnectionIDs: ["connection-a"],
                managementEndpointIdentity: "https://other-router.example.com"
            ),
            for: provider.id,
            expectedProvider: provider
        )
    }
    #expect(store.loadNineRouterAutomationState(for: provider.id) == .empty)
}

@Test func staleRefreshCannotDeleteOwnershipFromANewerEndpoint() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CredentialStore(defaults: defaults)
    let staleProvider = automaticRoutingProvider(endpoint: "https://old-router.example.com")
    var currentProvider = staleProvider
    currentProvider.endpoint = "https://new-router.example.com"

    try store.save(BigrouteConfiguration(providers: [staleProvider]))
    try store.save(BigrouteConfiguration(providers: [currentProvider]))
    let currentState = NineRouterAutomationState(
        autoDisabledConnectionIDs: ["new-connection"],
        managementEndpointIdentity: "https://new-router.example.com"
    )
    try store.saveNineRouterAutomationState(
        currentState,
        for: currentProvider.id,
        expectedProvider: currentProvider
    )

    #expect(throws: NineRouterAutomationError.statePersistenceFailed) {
        try store.saveNineRouterAutomationState(
            NineRouterAutomationState(
                managementEndpointIdentity: "https://old-router.example.com"
            ),
            for: staleProvider.id,
            expectedProvider: staleProvider
        )
    }
    #expect(store.loadNineRouterAutomationState(for: currentProvider.id) == currentState)
}

@Test func quotaIndicatorBandsMatchDisplayedPercentages() {
    #expect(QuotaIndicatorBand(remaining: nil) == .unavailable)
    #expect(QuotaIndicatorBand(remaining: .nan) == .unavailable)
    #expect(QuotaIndicatorBand(remaining: 20.4) == .critical)
    #expect(QuotaIndicatorBand(remaining: 20.5) == .warning)
    #expect(QuotaIndicatorBand(remaining: 70.4) == .warning)
    #expect(QuotaIndicatorBand(remaining: 70.5) == .healthy)
}

private func automaticRoutingProvider(
    endpoint: String = "https://router.example.com"
) -> CustomQuotaProvider {
    CustomQuotaProvider(
        name: "9Router",
        endpoint: endpoint,
        apiKind: .nineRouter,
        isAutomaticAccountRoutingEnabled: true
    )
}

@Test func providerSnapshotKeepsIndependentFreshness() {
    let first = ProviderQuotaSnapshot(
        id: UUID(), name: "First", accounts: [],
        updatedAt: Date(timeIntervalSince1970: 100), lastError: nil
    )
    let second = ProviderQuotaSnapshot(
        id: UUID(), name: "Second", accounts: [],
        updatedAt: Date(timeIntervalSince1970: 50), lastError: "Offline"
    )
    let snapshot = BigrouteSnapshot(providers: [first, second])
    #expect(snapshot.provider(id: first.id)?.updatedAt == first.updatedAt)
    #expect(snapshot.provider(id: second.id)?.lastError == "Offline")
}

@Test func importsLegacyProviderCaches() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let legacyDirectory = home.appendingPathComponent("Library/Application Support/Codex Model Switcher")
    guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return }
    let imported = try #require(SharedQuotaStore().loadLegacySnapshot())
    #expect(!imported.accounts.isEmpty)
    #expect(!imported.accounts(for: LegacyProviderID.nineRouter).isEmpty)
    #expect(!imported.accounts(for: LegacyProviderID.omniRouter).isEmpty)
}
