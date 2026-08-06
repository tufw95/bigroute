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
        apiKey: "super-secret-value"
    )
    let data = try JSONEncoder().encode(provider)
    let encoded = try #require(String(data: data, encoding: .utf8))
    #expect(!encoded.contains("super-secret-value"))

    let decoded = try JSONDecoder().decode(CustomQuotaProvider.self, from: data)
    #expect(decoded.apiKey.isEmpty)
    #expect(decoded.name == provider.name)
}

@Test func quotaIndicatorBandsMatchDisplayedPercentages() {
    #expect(QuotaIndicatorBand(remaining: nil) == .unavailable)
    #expect(QuotaIndicatorBand(remaining: .nan) == .unavailable)
    #expect(QuotaIndicatorBand(remaining: 20.4) == .critical)
    #expect(QuotaIndicatorBand(remaining: 20.5) == .warning)
    #expect(QuotaIndicatorBand(remaining: 70.4) == .warning)
    #expect(QuotaIndicatorBand(remaining: 70.5) == .healthy)
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
