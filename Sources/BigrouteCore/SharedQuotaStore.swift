import Foundation

public struct ProviderQuotaSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let accounts: [CodexQuotaAccount]
    public let updatedAt: Date?
    public let lastError: String?

    public init(
        id: UUID,
        name: String,
        accounts: [CodexQuotaAccount],
        updatedAt: Date?,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.accounts = accounts
        self.updatedAt = updatedAt
        self.lastError = lastError
    }

}

public struct BigrouteSnapshot: Codable, Equatable, Sendable {
    public let providers: [ProviderQuotaSnapshot]
    public let generatedAt: Date
    public let sortOrder: AccountSortOrder

    public init(
        providers: [ProviderQuotaSnapshot],
        generatedAt: Date = Date(),
        sortOrder: AccountSortOrder = .quotaDescending
    ) {
        self.providers = providers
        self.generatedAt = generatedAt
        self.sortOrder = sortOrder
    }

    /// Compatibility initializer used by previews and legacy cache imports.
    public init(
        accounts: [CodexQuotaAccount],
        generatedAt: Date = Date(),
        lastError: String? = nil,
        sortOrder: AccountSortOrder = .quotaDescending
    ) {
        self.providers = Self.legacyProviders(accounts: accounts, updatedAt: generatedAt, lastError: lastError)
        self.generatedAt = generatedAt
        self.sortOrder = sortOrder
    }

    public var accounts: [CodexQuotaAccount] { providers.flatMap(\.accounts) }
    public var lastError: String? { providers.compactMap(\.lastError).first }

    public var summary: CodexQuotaSummary {
        let accounts = accounts
        let available = accounts.filter(\.canServeRequests).count
        return CodexQuotaSummary(
            accounts: accounts.count,
            availableAccounts: available,
            unavailableAccounts: max(0, accounts.count - available),
            lowestRemaining: accounts.compactMap { $0.primaryQuota?.remaining }.min()
        )
    }

    public func provider(id: UUID) -> ProviderQuotaSnapshot? {
        providers.first { $0.id == id }
    }

    public func accounts(for providerID: UUID) -> [CodexQuotaAccount] {
        provider(id: providerID)?.accounts ?? []
    }

    public func withSortOrder(_ sortOrder: AccountSortOrder) -> BigrouteSnapshot {
        BigrouteSnapshot(providers: providers, generatedAt: generatedAt, sortOrder: sortOrder)
    }

    private enum CodingKeys: String, CodingKey {
        case providers, generatedAt, sortOrder, accounts, lastError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        if let providers = try container.decodeIfPresent([ProviderQuotaSnapshot].self, forKey: .providers) {
            self.providers = providers
        } else {
            let accounts = try container.decodeIfPresent([CodexQuotaAccount].self, forKey: .accounts) ?? []
            let error = try container.decodeIfPresent(String.self, forKey: .lastError)
            providers = Self.legacyProviders(accounts: accounts, updatedAt: generatedAt, lastError: error)
        }
        sortOrder = try container.decodeIfPresent(AccountSortOrder.self, forKey: .sortOrder) ?? .quotaDescending
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers, forKey: .providers)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(sortOrder, forKey: .sortOrder)
    }

    private static func legacyProviders(
        accounts: [CodexQuotaAccount],
        updatedAt: Date,
        lastError: String?
    ) -> [ProviderQuotaSnapshot] {
        let omni = accounts.filter { $0.provider.lowercased().contains("omni") }
        let nine = accounts.filter { !$0.provider.lowercased().contains("omni") }
        var result: [ProviderQuotaSnapshot] = []
        if !omni.isEmpty {
            result.append(ProviderQuotaSnapshot(
                id: LegacyProviderID.omniRouter,
                name: "OmniRouter",
                accounts: omni,
                updatedAt: updatedAt,
                lastError: lastError
            ))
        }
        if !nine.isEmpty {
            result.append(ProviderQuotaSnapshot(
                id: LegacyProviderID.nineRouter,
                name: "9Router",
                accounts: nine,
                updatedAt: updatedAt,
                lastError: lastError
            ))
        }
        return result
    }
}

/// Local snapshot persistence for Bigroute menu-bar app.
/// Credentials never cross this boundary.
public struct SharedQuotaStore: Sendable {
    public let fileURL: URL
    private let legacyFileURLs: [URL]

    public init(fileURL: URL? = nil, legacyFileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            self.legacyFileURLs = legacyFileURL.map { [$0] } ?? []
        } else {
            self.fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Bigroute", isDirectory: true)
                .appendingPathComponent("quota-snapshot.json")
            self.legacyFileURLs = ["Bigroute", "RouterQuota"].map {
                URL(fileURLWithPath: "/Users/Shared/\($0)/quota-snapshot.json")
            }
        }
    }

    public func load() -> BigrouteSnapshot? {
        if let snapshot = Self.decodeSnapshot(at: fileURL) { return snapshot }
        let snapshots = legacyFileURLs
            .compactMap(Self.decodeSnapshot(at:))
        return snapshots.max { $0.generatedAt < $1.generatedAt }
    }

    private static func decodeSnapshot(at url: URL) -> BigrouteSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BigrouteSnapshot.self, from: data)
    }

    public func loadLegacySnapshot(directory: URL? = nil) -> BigrouteSnapshot? {
        struct Legacy: Decodable {
            let accounts: [CodexQuotaAccount]
            let savedAt: Date
        }
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Model Switcher", isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sources: [(UUID, String, String)] = [
            (LegacyProviderID.nineRouter, "9Router", "nineRouter-quota-cache.json"),
            (LegacyProviderID.omniRouter, "OmniRouter", "omni-quota-cache.json")
        ]
        let providers = sources.compactMap { providerID, name, filename -> ProviderQuotaSnapshot? in
            let url = directory.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url),
                  let cache = try? decoder.decode(Legacy.self, from: data) else { return nil }
            return ProviderQuotaSnapshot(
                id: providerID,
                name: name,
                accounts: cache.accounts.map { $0.sourced(providerID: providerID) },
                updatedAt: cache.savedAt,
                lastError: "Cached data - save the provider to resume updates."
            )
        }
        guard !providers.isEmpty else { return nil }
        return BigrouteSnapshot(
            providers: providers,
            generatedAt: providers.compactMap(\.updatedAt).max() ?? Date()
        )
    }

    public func save(_ snapshot: BigrouteSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try Self.write(data, to: fileURL)

    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
