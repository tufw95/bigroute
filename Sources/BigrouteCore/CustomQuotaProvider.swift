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
    public var dashboardPassword: String
    public var apiKind: QuotaAPIKind
    public var isEnabled: Bool
    public var isAutomaticAccountRoutingEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        endpoint: String = "",
        apiKey: String = "",
        dashboardPassword: String = "",
        apiKind: QuotaAPIKind = .automatic,
        isEnabled: Bool = true,
        isAutomaticAccountRoutingEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.dashboardPassword = dashboardPassword
        self.apiKind = apiKind
        self.isEnabled = isEnabled
        self.isAutomaticAccountRoutingEnabled = isAutomaticAccountRoutingEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, endpoint, apiKind, isEnabled, isAutomaticAccountRoutingEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        apiKey = ""
        dashboardPassword = ""
        apiKind = try container.decodeIfPresent(QuotaAPIKind.self, forKey: .apiKind) ?? .automatic
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isAutomaticAccountRoutingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .isAutomaticAccountRoutingEnabled
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(apiKind, forKey: .apiKind)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isAutomaticAccountRoutingEnabled, forKey: .isAutomaticAccountRoutingEnabled)
    }
}

/// Tracks only connections Bigroute disabled, so automatic reactivation never
/// overrides an account that a user disabled manually in 9Router.
public struct NineRouterAutomationState: Codable, Equatable, Sendable {
    public var autoDisabledConnectionIDs: Set<String>
    public var managementEndpointIdentity: String?
    public var deactivationWindows: [String: [String: String]]

    public init(
        autoDisabledConnectionIDs: Set<String> = [],
        managementEndpointIdentity: String? = nil,
        deactivationWindows: [String: [String: String]] = [:]
    ) {
        self.autoDisabledConnectionIDs = autoDisabledConnectionIDs
        self.managementEndpointIdentity = managementEndpointIdentity
        self.deactivationWindows = deactivationWindows
    }

    public static let empty = NineRouterAutomationState()

    private enum CodingKeys: String, CodingKey {
        case autoDisabledConnectionIDs, managementEndpointIdentity, deactivationWindows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoDisabledConnectionIDs = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .autoDisabledConnectionIDs
        ) ?? []
        managementEndpointIdentity = try container.decodeIfPresent(
            String.self,
            forKey: .managementEndpointIdentity
        )
        deactivationWindows = try container.decodeIfPresent(
            [String: [String: String]].self,
            forKey: .deactivationWindows
        ) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(autoDisabledConnectionIDs, forKey: .autoDisabledConnectionIDs)
        try container.encodeIfPresent(managementEndpointIdentity, forKey: .managementEndpointIdentity)
        if !deactivationWindows.isEmpty {
            try container.encode(deactivationWindows, forKey: .deactivationWindows)
        }
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
