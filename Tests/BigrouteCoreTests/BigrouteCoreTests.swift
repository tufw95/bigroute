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

@Test func routerEndpointAllowsHTTPAndNormalizesValidURLs() throws {
    let httpLocal = try RouterEndpoint.normalizedURL(from: "http://ai.local")
    #expect(httpLocal.absoluteString == "http://ai.local")

    let httpPort = try RouterEndpoint.normalizedURL(from: "http://local.ai:8080/v1/")
    #expect(httpPort.absoluteString == "http://local.ai:8080")

    let httpSubpath = try RouterEndpoint.normalizedURL(from: "http://local.ai:8080/sub/v1")
    #expect(httpSubpath.absoluteString == "http://local.ai:8080/sub")

    let httpsRemote = try RouterEndpoint.normalizedURL(from: "https://router.example.com/")
    #expect(httpsRemote.absoluteString == "https://router.example.com")

    #expect(throws: RouterEndpointError.unsupportedScheme) {
        try RouterEndpoint.normalizedURL(from: "ftp://router.example.com")
    }
    #expect(throws: RouterEndpointError.embeddedCredentials) {
        try RouterEndpoint.normalizedURL(from: "http://user:pass@ai.local")
    }
    #expect(throws: RouterEndpointError.queryOrFragmentNotAllowed) {
        try RouterEndpoint.normalizedURL(from: "http://ai.local?key=val")
    }
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

@Test func accountDecoderPreservesOptionalRoutingState() throws {
    let inactiveJSON = Data(#"{"id":"nine-6","provider":"codex","name":"Office","isActive":false,"plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let inactive = try JSONDecoder().decode(CodexQuotaAccount.self, from: inactiveJSON)
    #expect(inactive.isActive == false)

    let legacyJSON = Data(#"{"id":"nine-7","provider":"codex","name":"Legacy","plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}"#.utf8)
    let legacy = try JSONDecoder().decode(CodexQuotaAccount.self, from: legacyJSON)
    #expect(legacy.isActive == nil)
}

@Test func accountRoutingVisibilityHidesOnlyExplicitlyInactiveAccounts() {
    let account = CodexQuotaAccount(
        id: "nine-8",
        provider: "codex",
        label: "Office",
        plan: "plus",
        limitReached: false,
        quotas: [],
        resetCredits: .init(availableCount: 0),
        status: "available",
        errorCode: nil
    )

    #expect(account.isRoutingActive)
    #expect(account.withActiveState(true).isRoutingActive)
    #expect(!account.withActiveState(false).isRoutingActive)
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
        resetCredits: .init(availableCount: 0), status: "valid", errorCode: nil, isActive: false
    )
    let snapshot = BigrouteSnapshot(
        accounts: [account],
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        sortOrder: .nameAscending
    )
    try store.save(snapshot)
    #expect(store.load() == snapshot)
    #expect(store.load()?.sortOrder == .nameAscending)
    #expect(store.load()?.accounts.first?.isActive == false)
    try? FileManager.default.removeItem(at: directory)
}

@Test func snapshotPrefersPrivateCacheAndOnlyReadsLegacyForMigration() throws {
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
    let originalLegacyBytes = try encoder.encode(newer)
    try originalLegacyBytes.write(to: legacyURL)
    #expect(store.load() == older)

    try Data("invalid snapshot".utf8).write(to: primaryURL)
    #expect(store.load() == newer)

    try store.save(latest)
    #expect(FileManager.default.fileExists(atPath: primaryURL.path))
    #expect(try Data(contentsOf: legacyURL) == originalLegacyBytes)
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

@Test func retiredAutomaticRoutingConfigurationIsNormalizedLocally() throws {
    let suiteName = "BigrouteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let providerID = UUID()
    let stateKey = "routerQuota.nineRouterAutomationState.\(providerID.uuidString).v1"
    let persisted = Data(#"{"schemaVersion":4,"providers":[{"id":"\#(providerID.uuidString)","name":"9Router","endpoint":"https://router.example.com","apiKind":"nineRouter","isEnabled":true,"isAutomaticAccountRoutingEnabled":true}],"refreshIntervalMinutes":2,"sortOrder":"quotaDescending"}"#.utf8)
    defaults.set(persisted, forKey: "routerQuota.configuration.v2")
    defaults.set(Data(#"{"autoDisabledConnectionIDs":["account-1"]}"#.utf8), forKey: stateKey)

    let configuration = try CredentialStore(defaults: defaults).load()
    #expect(configuration.providers.count == 1)
    #expect(configuration.providers[0].apiKind == .cliProxyAPI)
    #expect(defaults.data(forKey: stateKey) == nil)

    let normalized = try #require(defaults.data(forKey: "routerQuota.configuration.v2"))
    let normalizedObject = try #require(JSONSerialization.jsonObject(with: normalized) as? [String: Any])
    #expect(normalizedObject["schemaVersion"] as? Int == 5)
    let normalizedText = try #require(String(data: normalized, encoding: .utf8))
    #expect(!normalizedText.contains("isAutomaticAccountRoutingEnabled"))

    defaults.removePersistentDomain(forName: suiteName)
}

@Test func credentialMetadataLoadDoesNotRequireAPIKeys() throws {
    let suiteName = "BigrouteMetadataTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let providerID = UUID()
    let persisted = Data("""
    {"schemaVersion":5,"providers":[{"id":"\(providerID.uuidString)","name":"CLI Proxy API","endpoint":"https://router.example.com","apiKind":"cliProxyAPI","isEnabled":true}],"refreshIntervalMinutes":2,"sortOrder":"quotaDescending","antigravityBridge":{"isEnabled":true,"modelMode":"keep_official","customModelsText":""}}
    """.utf8)
    defaults.set(persisted, forKey: "routerQuota.configuration.v2")

    let configuration = CredentialStore(defaults: defaults).loadMetadata()
    #expect(configuration.providers.count == 1)
    #expect(configuration.providers[0].apiKey.isEmpty)
    #expect(configuration.providers[0].endpoint == "https://router.example.com")
    #expect(configuration.antigravityBridge.isEnabled)

    defaults.removePersistentDomain(forName: suiteName)
}

@Test func customQuotaServiceFetchesFromCLIProxyAPI() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadOnlyQuotaURLProtocol.self]
    let session = URLSession(configuration: configuration)
    ReadOnlyQuotaURLProtocol.reset(response: Data(#"{"files":[{"name":"antigravity-plus-1.json","provider":"antigravity","email":"user@gmail.com","disabled":false,"status":"available","success":100,"failed":2}]}"#.utf8))

    let provider = CustomQuotaProvider(
        name: "CLI Proxy API",
        endpoint: "https://router.example.com/internal",
        apiKey: "test-key",
        apiKind: .cliProxyAPI
    )
    let accounts = try await CustomQuotaService(session: session).fetch(
        provider: provider,
        forceRefresh: true
    )
    #expect(accounts.count == 1)
    #expect(accounts[0].provider == "antigravity")
    #expect(accounts[0].label == "user@gmail.com")
    #expect(accounts[0].isRoutingActive)

    let requests = ReadOnlyQuotaURLProtocol.requestsSnapshot()
    #expect(requests.count == 1)
    #expect(requests[0].httpMethod == "GET")
    #expect(requests[0].url?.path == "/internal/v0/management/auth-files")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
}

@Test func quotaServiceStopsAStalledRequestBeforeTheURLSessionTimeout() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StalledQuotaURLProtocol.self]
    let service = QuotaService(
        session: URLSession(configuration: configuration),
        timeoutInterval: 0.05
    )
    let endpoint = URL(string: "https://router.example.com")!

    await #expect(throws: QuotaServiceError.requestTimedOut) {
        try await service.fetch(apiKey: "test-key", targetBaseURL: endpoint)
    }
}

@Test func cliProxyAPISetsAccountDisabledStatus() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PreviewRoutingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    PreviewRoutingURLProtocol.reset(responses: [
        Data(#"{"status":"ok"}"#.utf8)
    ])
    let cli = CLIProxyAPIService(session: session)
    let endpoint = URL(string: "https://router.example.com/internal")!
    try await cli.setAccountDisabled(name: "test-account.json", disabled: true, endpoint: endpoint, managementKey: "sec-key")

    let requests = PreviewRoutingURLProtocol.requestsSnapshot()
    #expect(requests.count == 1)
    #expect(requests[0].request.httpMethod == "PATCH")
    #expect(requests[0].request.url?.path == "/internal/v0/management/auth-files/status")
    #expect(requests[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer sec-key")

    let body = try #require(requests[0].body)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["name"] as? String == "test-account.json")
    #expect(json["disabled"] as? Bool == true)
}

@Test func cliProxyManualRoutingAppliesActionToTargetAccounts() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CachedRoutingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    CachedRoutingURLProtocol.reset(responses: [
        Data(#"{"status":"ok"}"#.utf8),
        Data(#"{"status":"ok"}"#.utf8)
    ])

    let provider = CustomQuotaProvider(
        name: "CLI Proxy API",
        endpoint: "https://router.example.com/internal",
        apiKey: "test-key",
        apiKind: .cliProxyAPI
    )

    let activeAccount = CodexQuotaAccount(
        id: "acc-1.json",
        provider: "antigravity",
        label: "Account 1",
        plan: "Plus",
        limitReached: false,
        quotas: [],
        resetCredits: .init(availableCount: 0),
        status: "available",
        errorCode: nil,
        isActive: true
    )

    let inactiveAccount = CodexQuotaAccount(
        id: "acc-2.json",
        provider: "antigravity",
        label: "Account 2",
        plan: "Plus",
        limitReached: true,
        quotas: [],
        resetCredits: .init(availableCount: 0),
        status: "rate_limited",
        errorCode: "rate_limit",
        isActive: true
    )

    let service = CLIProxyManualRoutingService(session: session)
    let result = try await service.apply(
        action: .disableInactive,
        provider: provider,
        accounts: [activeAccount, inactiveAccount]
    )

    #expect(result.changedCount == 1)
    #expect(result.changed[0].id == "acc-2.json")
    #expect(result.changed[0].isActive == false)

    let requests = CachedRoutingURLProtocol.requestsSnapshot()
    #expect(requests.count == 1)
    #expect(requests[0].request.httpMethod == "PATCH")
    let body = try #require(requests[0].body)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["name"] as? String == "acc-2.json")
    #expect(json["disabled"] as? Bool == true)
}

@Test func cliProxyAccountImportUploadsMultipartFile() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AccountImportURLProtocol.self]
    let session = URLSession(configuration: configuration)
    AccountImportURLProtocol.reset(
        response: Data(#"{"status":"ok"}"#.utf8)
    )

    let provider = CustomQuotaProvider(
        name: "CLI Proxy API",
        endpoint: "https://router.example.com/internal",
        apiKey: "test-key",
        apiKind: .cliProxyAPI
    )

    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("import-account.json")
    try Data(#"{"email":"test@example.com"}"#.utf8).write(to: fileURL)

    let result = try await CLIProxyAccountImportService(session: session).importFiles(
        [fileURL],
        provider: provider
    )
    #expect(result.importedCount == 1)
    #expect(result.failedCount == 0)

    let captured = try #require(AccountImportURLProtocol.requestSnapshot())
    #expect(captured.request.httpMethod == "POST")
    #expect(captured.request.url?.path == "/internal/v0/management/auth-files")
    #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    let contentType = captured.request.value(forHTTPHeaderField: "Content-Type") ?? ""
    #expect(contentType.contains("multipart/form-data"))
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
    let legacyDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: legacyDirectory) }
    for filename in ["nineRouter-quota-cache.json", "omni-quota-cache.json"] {
        let cache = Data(#"{"savedAt":"2026-08-01T00:00:00Z","accounts":[{"id":"one","provider":"codex","label":"Work","plan":"plus","limitReached":false,"quotas":[],"resetCredits":{"availableCount":0},"status":"available"}]}"#.utf8)
        try cache.write(to: legacyDirectory.appending(path: filename))
    }
    let imported = try #require(SharedQuotaStore().loadLegacySnapshot(directory: legacyDirectory))
    #expect(!imported.accounts.isEmpty)
    #expect(!imported.accounts(for: LegacyProviderID.nineRouter).isEmpty)
    #expect(!imported.accounts(for: LegacyProviderID.omniRouter).isEmpty)
}

private final class ReadOnlyQuotaURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var response = Data()
    private static let lock = NSLock()

    static func reset(response: Data) {
        lock.withLock {
            requests = []
            self.response = response
        }
    }

    static func requestsSnapshot() -> [URLRequest] {
        lock.withLock { requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var responseData = Data()
        Self.lock.withLock {
            Self.requests.append(request)
            responseData = Self.response
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class StalledQuotaURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}

private final class PreviewRoutingURLProtocol: URLProtocol {
    private struct CapturedRequest: Sendable {
        let request: URLRequest
        let body: Data?
    }

    nonisolated(unsafe) private static var requests: [CapturedRequest] = []
    nonisolated(unsafe) private static var responses: [Data] = []
    private static let lock = NSLock()

    static func reset(responses: [Data]) {
        lock.withLock {
            requests = []
            self.responses = responses
        }
    }

    static func requestsSnapshot() -> [(request: URLRequest, body: Data?)] {
        lock.withLock { requests }
            .map { (request: $0.request, body: $0.body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var responseData = Data()
        Self.lock.withLock {
            Self.requests.append(CapturedRequest(
                request: request,
                body: request.httpBody ?? requestBody(from: request.httpBodyStream)
            ))
            if !Self.responses.isEmpty {
                responseData = Self.responses.removeFirst()
            }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class CachedRoutingURLProtocol: URLProtocol {
    private struct CapturedRequest: Sendable {
        let request: URLRequest
        let body: Data?
    }

    nonisolated(unsafe) private static var requests: [CapturedRequest] = []
    nonisolated(unsafe) private static var responses: [Data] = []
    private static let lock = NSLock()

    static func reset(responses: [Data]) {
        lock.withLock {
            requests = []
            self.responses = responses
        }
    }

    static func requestsSnapshot() -> [(request: URLRequest, body: Data?)] {
        lock.withLock { requests }
            .map { (request: $0.request, body: $0.body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var responseData = Data()
        Self.lock.withLock {
            Self.requests.append(CapturedRequest(
                request: request,
                body: request.httpBody ?? requestBody(from: request.httpBodyStream)
            ))
            if !Self.responses.isEmpty { responseData = Self.responses.removeFirst() }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class FallbackCachedRoutingURLProtocol: URLProtocol {
    private struct CapturedRequest: Sendable {
        let request: URLRequest
        let body: Data?
    }

    nonisolated(unsafe) private static var requests: [CapturedRequest] = []
    nonisolated(unsafe) private static var responses: [(statusCode: Int, data: Data)] = []
    private static let lock = NSLock()

    static func reset(statusResponses: [(statusCode: Int, data: Data)]) {
        lock.withLock {
            requests = []
            self.responses = statusResponses
        }
    }

    static func requestsSnapshot() -> [(request: URLRequest, body: Data?)] {
        lock.withLock { requests }
            .map { (request: $0.request, body: $0.body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var responseData = Data()
        var statusCode = 200
        Self.lock.withLock {
            Self.requests.append(CapturedRequest(
                request: request,
                body: request.httpBody ?? requestBody(from: request.httpBodyStream)
            ))
            if !Self.responses.isEmpty {
                let item = Self.responses.removeFirst()
                statusCode = item.statusCode
                responseData = item.data
            }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class AccountImportURLProtocol: URLProtocol {
    private struct CapturedRequest: Sendable {
        let request: URLRequest
        let body: Data?
    }

    nonisolated(unsafe) private static var captured: CapturedRequest?
    nonisolated(unsafe) private static var response = Data()
    private static let lock = NSLock()

    static func reset(response: Data) {
        lock.withLock {
            captured = nil
            self.response = response
        }
    }

    static func requestSnapshot() -> (request: URLRequest, body: Data?)? {
        lock.withLock { captured }
            .map { (request: $0.request, body: $0.body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var responseData = Data()
        Self.lock.withLock {
            Self.captured = CapturedRequest(
                request: request,
                body: request.httpBody ?? requestBody(from: request.httpBodyStream)
            )
            responseData = Self.response
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}
