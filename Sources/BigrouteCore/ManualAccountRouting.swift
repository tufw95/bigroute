import Foundation

public enum AccountAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case enableAll = "enable_all"
    case disableAll = "disable_all"
    case disableInactive = "disable_inactive"
    case turnOnAvailable = "turn_on_available"
    case turnOffEmpty = "turn_off_empty"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .enableAll, .turnOnAvailable: "Enable All"
        case .disableAll: "Disable All"
        case .disableInactive, .turnOffEmpty: "Disable Inactive"
        }
    }

    public var systemImage: String {
        switch self {
        case .enableAll, .turnOnAvailable: "play.circle"
        case .disableAll: "pause.circle"
        case .disableInactive, .turnOffEmpty: "xmark.circle"
        }
    }
}

public typealias NineRouterAccountAction = AccountAction

public struct CLIProxyRoutingChange: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let isActive: Bool

    public init(id: String, label: String, isActive: Bool) {
        self.id = id
        self.label = label
        self.isActive = isActive
    }
}

public struct CLIProxyRoutingResult: Codable, Equatable, Sendable {
    public let action: AccountAction
    public let changedCount: Int
    public let skippedCount: Int
    public let changed: [CLIProxyRoutingChange]

    public init(
        action: AccountAction,
        changedCount: Int,
        skippedCount: Int,
        changed: [CLIProxyRoutingChange]
    ) {
        self.action = action
        self.changedCount = changedCount
        self.skippedCount = skippedCount
        self.changed = changed
    }

    public func accountStates(providerID: UUID) -> [String: Bool] {
        changed.reduce(into: [String: Bool]()) { states, change in
            states[change.id] = change.isActive
            states["\(providerID.uuidString):\(change.id)"] = change.isActive
        }
    }
}

public typealias NineRouterRoutingResult = CLIProxyRoutingResult

public enum CLIProxyManualRoutingError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case unauthorized
    case invalidEndpoint
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "This provider does not support account management."
        case .unauthorized:
            return "Management key is invalid or required."
        case .invalidEndpoint:
            return "Invalid provider endpoint URL."
        case let .serverError(status):
            return "CLI Proxy API returned HTTP \(status)."
        }
    }
}

public typealias NineRouterManualRoutingError = CLIProxyManualRoutingError

public final class CLIProxyManualRoutingService: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func apply(
        action: AccountAction,
        provider: CustomQuotaProvider,
        accounts: [CodexQuotaAccount]
    ) async throws -> CLIProxyRoutingResult {
        guard let url = try? RouterEndpoint.normalizedURL(from: provider.endpoint) else {
            throw CLIProxyManualRoutingError.invalidEndpoint
        }
        let key = provider.effectiveManagementKey
        let cliService = CLIProxyAPIService(session: session)

        let targetAccounts: [(account: CodexQuotaAccount, makeActive: Bool)]
        switch action {
        case .enableAll, .turnOnAvailable:
            targetAccounts = accounts.filter { !$0.isRoutingActive }.map { ($0, true) }
        case .disableAll:
            targetAccounts = accounts.filter { $0.isRoutingActive }.map { ($0, false) }
        case .disableInactive, .turnOffEmpty:
            targetAccounts = accounts.filter {
                $0.isRoutingActive && ($0.limitReached || $0.status == "rate_limited" || $0.status == "expired" || $0.status == "unavailable")
            }.map { ($0, false) }
        }

        var changed: [CLIProxyRoutingChange] = []
        for item in targetAccounts {
            let rawID = item.account.id.contains(":") ? String(item.account.id.split(separator: ":").last!) : item.account.id
            do {
                try await cliService.setAccountDisabled(
                    name: rawID,
                    disabled: !item.makeActive,
                    endpoint: url,
                    managementKey: key
                )
                changed.append(CLIProxyRoutingChange(id: rawID, label: item.account.label, isActive: item.makeActive))
            } catch {
                // Continue with remaining accounts
            }
        }

        let skipped = accounts.count - changed.count
        return CLIProxyRoutingResult(
            action: action,
            changedCount: changed.count,
            skippedCount: max(0, skipped),
            changed: changed
        )
    }

    public func toggleSingleAccount(
        account: CodexQuotaAccount,
        provider: CustomQuotaProvider,
        active: Bool
    ) async throws {
        guard let url = try? RouterEndpoint.normalizedURL(from: provider.endpoint) else {
            throw CLIProxyManualRoutingError.invalidEndpoint
        }
        let key = provider.effectiveManagementKey
        let rawID = account.id.contains(":") ? String(account.id.split(separator: ":").last!) : account.id
        let cliService = CLIProxyAPIService(session: session)
        try await cliService.setAccountDisabled(
            name: rawID,
            disabled: !active,
            endpoint: url,
            managementKey: key
        )
    }

    public func applyCached(
        action: AccountAction,
        provider: CustomQuotaProvider
    ) async throws -> CLIProxyRoutingResult {
        // Fallback or preview
        let accounts = (try? await CLIProxyAPIService(session: session).fetchAccounts(
            endpoint: try RouterEndpoint.normalizedURL(from: provider.endpoint),
            managementKey: provider.effectiveManagementKey
        )) ?? []
        return try await apply(action: action, provider: provider, accounts: accounts)
    }

    public func preview(
        action: AccountAction,
        provider: CustomQuotaProvider
    ) async throws -> CLIProxyRoutingResult {
        try await applyCached(action: action, provider: provider)
    }
}

public typealias NineRouterManualRoutingService = CLIProxyManualRoutingService
