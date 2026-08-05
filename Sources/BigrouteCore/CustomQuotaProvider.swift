import Foundation

/// A user-configured quota source. The API kind is normally automatic so the
/// settings surface only needs the provider name, endpoint, and API key.
public enum QuotaAPIKind: String, Codable, CaseIterable, Sendable {
    case automatic
    case nineRouter
    case omniRouter

    public var displayName: String {
        switch self {
        case .automatic: "Auto-detect"
        case .nineRouter: "9Router"
        case .omniRouter: "OmniRouter"
        }
    }
}

public struct CustomQuotaProvider: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: String
    public var apiKey: String
    public var apiKind: QuotaAPIKind
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        endpoint: String = "",
        apiKey: String = "",
        apiKind: QuotaAPIKind = .automatic,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.apiKind = apiKind
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, apiKind, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        apiKey = ""
        apiKind = try container.decodeIfPresent(QuotaAPIKind.self, forKey: .apiKind) ?? .automatic
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(apiKind, forKey: .apiKind)
        try container.encode(isEnabled, forKey: .isEnabled)
    }
}

/// Sanitized provider metadata written beside the quota snapshot for WidgetKit.
public struct QuotaProviderDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum LegacyProviderID {
    public static let nineRouter = UUID(uuidString: "6F66E771-9C74-4B3B-9B1D-9B0A57D6AF91")!
    public static let omniRouter = UUID(uuidString: "9F3AA02E-C6DB-4C80-9BA4-10C2DD6C0B72")!
}
