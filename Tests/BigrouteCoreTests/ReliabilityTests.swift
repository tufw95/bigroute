import Foundation
import Testing
@testable import BigrouteCore

private enum TestCredentialError: Error { case denied }

@Test(arguments: [4, 5]) func keychainDenialPreservesProviderMetadata(schema: Int) throws {
    let suite = "BigrouteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = Data("""
    {"schemaVersion":\(schema),"providers":[{"id":"\(UUID())","name":"Work","endpoint":"https://router.example","apiKind":"nineRouter","isEnabled":true}],"refreshIntervalMinutes":2}
    """.utf8)
    defaults.set(original, forKey: "routerQuota.configuration.v2")
    let store = CredentialStore(defaults: defaults, envURL: URL(fileURLWithPath: "/nonexistent"), keychain: CredentialKeychain(
        read: { _ in throw TestCredentialError.denied },
        save: { _, _ in Issue.record("A denied read must not write a credential") },
        delete: { _ in Issue.record("A denied read must not delete a credential") }
    ))
    #expect(throws: TestCredentialError.self) { try store.load() }
    #expect(defaults.data(forKey: "routerQuota.configuration.v2") == original)
}

@Test func settingsOnlySaveDoesNotTouchKeychain() throws {
    let suite = "BigrouteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let previous = BigrouteConfiguration(providers: [.init(name: "Work", endpoint: "https://router.example", apiKey: "kept-key")])
    let store = CredentialStore(defaults: defaults, envURL: URL(fileURLWithPath: "/nonexistent"), keychain: CredentialKeychain(
        read: { _ in Issue.record("No Keychain read for settings changes"); return nil },
        save: { _, _ in Issue.record("No Keychain write for settings changes") },
        delete: { _ in Issue.record("No Keychain delete for settings changes") }
    ))
    var updated = previous
    updated.sortOrder = .nameAscending
    updated.antigravityBridge.modelMode = .custom
    try store.save(updated, previous: previous)
    #expect(store.loadMetadata().sortOrder == .nameAscending)
    #expect(store.loadMetadata().antigravityBridge.modelMode == .custom)
}

@Test func corruptConfigurationDoesNotOverwriteExistingSettings() throws {
    let suite = "BigrouteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let invalid = Data("partial write".utf8)
    defaults.set(invalid, forKey: "routerQuota.configuration.v2")
    let store = CredentialStore(defaults: defaults)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(defaults.data(forKey: "routerQuota.configuration.v2") == invalid)
}

@Test func onePercentIsNotMistakenForOneHundredPercent() throws {
    for percent in [0.0, 0.5, 1, 50, 100] {
        let data = Data("""
        {"providers":[{"id":"work","name":"Work","quota":{"percentRemaining":\(percent),"quotaMeasured":true}}]}
        """.utf8)
        #expect(try OmniQuotaService.decodeResponse(data).accounts.first?.primaryQuota?.remaining == percent)
    }
    let fraction = Data(#"{"providers":[{"id":"work","quota":{"remainingFraction":0.25}}]}"#.utf8)
    #expect(try OmniQuotaService.decodeResponse(fraction).accounts.first?.primaryQuota?.remaining == 25)
}

@Test func invalidNumericQuotaNeverCrashesOrLooksAvailable() throws {
    #expect(QuotaIndicatorBand(remaining: .greatestFiniteMagnitude) == .healthy)
    let huge = Data(#"{"key":"session","used":0,"total":100,"remaining":1e200,"unlimited":false}"#.utf8)
    #expect(try JSONDecoder().decode(CodexQuotaWindow.self, from: huge).remaining == 100)
    let invalid = Data(#"{"providers":[{"id":"work","quota":{"percentRemaining":true}}]}"#.utf8)
    #expect(try OmniQuotaService.decodeResponse(invalid).accounts.first?.quotas.isEmpty == true)
    for credits in ["1e200", "-10", "true"] {
        let input = Data("{\"providers\":[{\"id\":\"work\",\"bankedResetCredits\":\(credits)}]}".utf8)
        #expect(try OmniQuotaService.decodeResponse(input).accounts.first?.resetCredits.availableCount == 0)
    }
}

private func account(remaining: Double = 50, status: String = "available", plan: String = "plus", active: Bool = true, weekly: Double = 50) -> CodexQuotaAccount {
    CodexQuotaAccount(id: "one", provider: "antigravity", label: "Work", plan: plan, limitReached: false,
        quotas: [CodexQuotaWindow(key: "session", used: 50, total: 100, remaining: remaining, resetAt: nil, unlimited: false),
                 CodexQuotaWindow(key: "weekly", used: 50, total: 100, remaining: weekly, resetAt: nil, unlimited: false)],
        resetCredits: .init(availableCount: 0), status: status, errorCode: nil, isActive: active)
}

@Test func sourceNamespacePreservesAccountTypeAndDoesNotDoublePrefix() {
    let id = UUID()
    let result = account().sourced(providerID: id)
    #expect(result.provider == "antigravity")
    #expect(result.isGoogleAntigravity)
    #expect(result.sourced(providerID: id).id == result.id)
}

@Test func availabilityRequiresUsableQuotaAndActiveAccount() {
    #expect(account().canServeRequests)
    #expect(!account(active: false).canServeRequests)
    #expect(!account(weekly: 0).canServeRequests)
    #expect(!account(status: "expired").canServeRequests)
    #expect(account(plan: "free").canServeRequests)
    let snapshot = BigrouteSnapshot(accounts: [account(), account(active: false), account(weekly: 0)])
    #expect(snapshot.summary.availableAccounts == 1)
}

@Test func bridgeEndpointMatchingIsExact() {
    #expect(AntigravityBridgeManager.isBridgeEndpoint("http://127.0.0.1:50999\n"))
    #expect(AntigravityBridgeManager.isBridgeEndpoint("http://localhost:50999/"))
    #expect(!AntigravityBridgeManager.isBridgeEndpoint("https://example.com/127.0.0.1:50999"))
    #expect(!AntigravityBridgeManager.isBridgeEndpoint("http://127.0.0.1:509999"))
    #expect(!AntigravityBridgeManager.isBridgeEndpoint("http://user:pass@127.0.0.1:50999"))
}

@Test func deniedCredentialDeletionPreservesProviderSettings() throws {
    let suite = "BigrouteTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let previous = BigrouteConfiguration(providers: [.init(name: "Work", endpoint: "https://router.example", apiKey: "key")])
    let store = CredentialStore(defaults: defaults, envURL: URL(fileURLWithPath: "/nonexistent"), keychain: CredentialKeychain(
        read: { _ in "key" }, save: { _, _ in }, delete: { _ in throw TestCredentialError.denied }
    ))
    try store.save(previous)
    let original = defaults.data(forKey: "routerQuota.configuration.v2")
    #expect(throws: TestCredentialError.self) { try store.save(.init(providers: []), previous: previous) }
    #expect(defaults.data(forKey: "routerQuota.configuration.v2") == original)
}
