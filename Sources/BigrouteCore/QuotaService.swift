import Foundation
import OSLog

/// Shared quota bands keep the app and widget aligned with the rounded value shown to users.
public enum QuotaIndicatorBand: Equatable, Sendable {
    case unavailable
    case critical
    case warning
    case healthy

    public init(remaining: Double?) {
        guard let remaining, remaining.isFinite else {
            self = .unavailable
            return
        }

        switch Int(remaining.rounded()) {
        case ...20: self = .critical
        case ...70: self = .warning
        default: self = .healthy
        }
    }
}

/// The account ordering preference shared by the app and its widget.
public enum AccountSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case quotaDescending
    case quotaAscending
    case nameAscending
    case nameDescending
    case refreshSoonest
    case refreshLatest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quotaDescending: "Quota: Highest first"
        case .quotaAscending: "Quota: Lowest first"
        case .nameAscending: "Account name: A-Z"
        case .nameDescending: "Account name: Z-A"
        case .refreshSoonest: "Refresh: Soonest first"
        case .refreshLatest: "Refresh: Latest first"
        }
    }

    public func sorted(_ accounts: [CodexQuotaAccount]) -> [CodexQuotaAccount] {
        accounts.sorted { lhs, rhs in
            let comparison: Bool?
            switch self {
            case .quotaDescending:
                comparison = compare(lhs.primaryQuota?.remaining, rhs.primaryQuota?.remaining, descending: true)
            case .quotaAscending:
                comparison = compare(lhs.primaryQuota?.remaining, rhs.primaryQuota?.remaining, descending: false)
            case .nameAscending:
                comparison = compareNames(lhs.label, rhs.label, descending: false)
            case .nameDescending:
                comparison = compareNames(lhs.label, rhs.label, descending: true)
            case .refreshSoonest:
                comparison = compare(resetDate(for: lhs), resetDate(for: rhs), descending: false)
            case .refreshLatest:
                comparison = compare(resetDate(for: lhs), resetDate(for: rhs), descending: true)
            }
            if let comparison { return comparison }
            let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
        }
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, descending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?) where left == right: return nil
        case let (left?, right?): return descending ? left > right : left < right
        }
    }

    private func compareNames(_ lhs: String, _ rhs: String, descending: Bool) -> Bool? {
        let result = lhs.localizedCaseInsensitiveCompare(rhs)
        guard result != .orderedSame else { return nil }
        return descending ? result == .orderedDescending : result == .orderedAscending
    }

    private func resetDate(for account: CodexQuotaAccount) -> Date? {
        guard let raw = account.primaryQuota?.resetAt else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

public struct CodexQuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let used: Double
    public let total: Double
    public let remaining: Double
    public let resetAt: String?
    public let unlimited: Bool

    public init(
        key: String,
        used: Double,
        total: Double,
        remaining: Double,
        resetAt: String?,
        unlimited: Bool
    ) {
        self.key = key
        self.used = used
        self.total = total
        self.remaining = remaining
        self.resetAt = resetAt
        self.unlimited = unlimited
    }
}

public struct CodexQuotaAccount: Codable, Equatable, Identifiable, Sendable {
    public struct ResetCredits: Codable, Equatable, Sendable {
        public let availableCount: Int

        public init(availableCount: Int) {
            self.availableCount = availableCount
        }
    }

    public let id: String
    public let provider: String
    public let label: String
    public let plan: String
    public let limitReached: Bool
    public let quotas: [CodexQuotaWindow]
    public let resetCredits: ResetCredits
    public let status: String
    public let errorCode: String?
    public let isActive: Bool?

    public init(
        id: String,
        provider: String,
        label: String,
        plan: String,
        limitReached: Bool,
        quotas: [CodexQuotaWindow],
        resetCredits: ResetCredits,
        status: String,
        errorCode: String?,
        isActive: Bool? = nil
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.plan = plan
        self.limitReached = limitReached
        self.quotas = quotas
        self.resetCredits = resetCredits
        self.status = status
        self.errorCode = errorCode
        self.isActive = isActive
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, label, name, nickname, accountName, displayName, username, userName, email
        case accountNameSnake = "account_name"
        case displayNameSnake = "display_name"
        case userNameSnake = "user_name"
        case account, user, metadata, connection
        case plan, limitReached, quotas, resetCredits, status, errorCode, isActive
    }

    private enum IdentityKeys: String, CodingKey {
        case label, name, nickname, accountName, displayName, username, userName, email
        case accountNameSnake = "account_name"
        case displayNameSnake = "display_name"
        case userNameSnake = "user_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(String.self, forKey: .provider)
        guard let identity = Self.firstIdentity(in: container) else {
            throw DecodingError.keyNotFound(
                CodingKeys.label,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "The quota account does not include an identity field."
                )
            )
        }
        label = identity
        plan = try container.decode(String.self, forKey: .plan)
        limitReached = try container.decode(Bool.self, forKey: .limitReached)
        quotas = try container.decode([CodexQuotaWindow].self, forKey: .quotas)
        resetCredits = try container.decode(ResetCredits.self, forKey: .resetCredits)
        status = try container.decode(String.self, forKey: .status)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encode(plan, forKey: .plan)
        try container.encode(limitReached, forKey: .limitReached)
        try container.encode(quotas, forKey: .quotas)
        try container.encode(resetCredits, forKey: .resetCredits)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(errorCode, forKey: .errorCode)
        try container.encodeIfPresent(isActive, forKey: .isActive)
    }

    private static func firstIdentity(in container: KeyedDecodingContainer<CodingKeys>) -> String? {
        let direct: [String?] = [
            (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .nickname)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .accountName)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .accountNameSnake)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .displayNameSnake)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .username)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .userName)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .userNameSnake)) ?? nil
        ]
        if let value = direct.compactMap(Self.nonEmpty).first { return value }

        // Some router deployments keep the user-editable account name beside
        // the quota payload instead of flattening it onto the account object.
        for key in [CodingKeys.connection, .account, .user, .metadata] {
            guard let nested = try? container.nestedContainer(keyedBy: IdentityKeys.self, forKey: key) else { continue }
            let values: [String?] = [
                (try? nested.decodeIfPresent(String.self, forKey: .name)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .nickname)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .accountName)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .accountNameSnake)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .displayName)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .displayNameSnake)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .username)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .userName)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .userNameSnake)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .label)) ?? nil,
                (try? nested.decodeIfPresent(String.self, forKey: .email)) ?? nil
            ]
            if let value = values.compactMap(Self.nonEmpty).first { return value }
        }
        return [
            (try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil,
            (try? container.decodeIfPresent(String.self, forKey: .email)) ?? nil
        ].compactMap(Self.nonEmpty).first
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public var primaryQuota: CodexQuotaWindow? {
        quotas.first(where: { $0.key == "session" }) ?? quotas.first
    }

    /// Providers that do not expose routing state remain visible.
    public var isRoutingActive: Bool {
        isActive != false
    }

    public func sourced(providerID: UUID) -> CodexQuotaAccount {
        let source = providerID.uuidString
        return CodexQuotaAccount(
            id: "\(source):\(id)",
            provider: source,
            label: label,
            plan: plan,
            limitReached: limitReached,
            quotas: quotas,
            resetCredits: resetCredits,
            status: status,
            errorCode: errorCode,
            isActive: isActive
        )
    }

    public func withActiveState(_ isActive: Bool) -> CodexQuotaAccount {
        CodexQuotaAccount(
            id: id,
            provider: provider,
            label: label,
            plan: plan,
            limitReached: limitReached,
            quotas: quotas,
            resetCredits: resetCredits,
            status: status,
            errorCode: errorCode,
            isActive: isActive
        )
    }
}

public struct CodexQuotaSummary: Codable, Equatable, Sendable {
    public let accounts: Int
    public let availableAccounts: Int
    public let unavailableAccounts: Int
    public let lowestRemaining: Double?
}

public struct CodexQuotaResponse: Codable, Equatable, Sendable {
    public let object: String
    public let generatedAt: String
    public let summary: CodexQuotaSummary
    public let data: [CodexQuotaAccount]
}

public enum QuotaServiceError: Error, LocalizedError, Equatable, Sendable {
    case unsupported
    case unauthorized
    case invalidResponse
    case requestTimedOut
    case serverError(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "This router does not provide quota tracking yet."
        case .unauthorized:
            return "The saved API key cannot access this quota endpoint."
        case .invalidResponse:
            return "The router returned an invalid quota response."
        case .requestTimedOut:
            return "9Router quota aggregation is unavailable; showing cached data."
        case let .serverError(statusCode):
            if [502, 503, 504].contains(statusCode) {
                return "9Router quota aggregation is unavailable (HTTP \(statusCode))."
            }
            return "Router quota is temporarily unavailable (HTTP \(statusCode))."
        }
    }
}

private enum QuotaRequestPolicy {
    static let timeoutInterval: TimeInterval = 25
}

private struct QuotaRequestDeadlineError: Error, Sendable {}

private func quotaData(
    session: URLSession,
    request: URLRequest,
    timeoutInterval: TimeInterval
) async throws -> (Data, URLResponse) {
    try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask {
            try await session.data(for: request)
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, timeoutInterval) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw QuotaRequestDeadlineError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw QuotaRequestDeadlineError()
        }
        return result
    }
}

private enum QuotaNetworkDiagnostics {
    static let logger = Logger(
        subsystem: "com.routerquota.app",
        category: "QuotaNetwork"
    )

    static func started(request: URLRequest, forceRefresh: Bool) {
        let path = request.url?.path ?? "unknown"
        logger.info(
            "Quota GET started path=\(path, privacy: .public) forced=\(forceRefresh, privacy: .public)"
        )
    }

    static func finished(
        request: URLRequest,
        response: HTTPURLResponse,
        bytes: Int,
        elapsed: TimeInterval
    ) {
        let path = request.url?.path ?? "unknown"
        let rawCacheState = response.value(forHTTPHeaderField: "X-9Router-Quota-Cache")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowedCacheStates = ["hit", "miss", "shared", "stale", "throttled"]
        let cacheState = rawCacheState.flatMap { allowedCacheStates.contains($0) ? $0 : nil } ?? "other"
        logger.info(
            "Quota GET finished path=\(path, privacy: .public) status=\(response.statusCode, privacy: .public) bytes=\(bytes, privacy: .public) elapsed=\(elapsed, privacy: .public)s cache=\(cacheState, privacy: .public)"
        )
    }

    static func failed(request: URLRequest, error: Error, elapsed: TimeInterval) {
        let path = request.url?.path ?? "unknown"
        let category: String
        if let urlError = error as? URLError {
            category = urlError.code.rawValue.description
        } else if let quotaError = error as? QuotaServiceError {
            category = String(describing: quotaError)
        } else {
            category = String(describing: type(of: error))
        }
        logger.error(
            "Quota GET failed path=\(path, privacy: .public) category=\(category, privacy: .public) elapsed=\(elapsed, privacy: .public)s"
        )
    }
}

public final class QuotaService: @unchecked Sendable {
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    public init(session: URLSession = .shared) {
        self.session = session
        self.timeoutInterval = QuotaRequestPolicy.timeoutInterval
    }

    init(session: URLSession, timeoutInterval: TimeInterval) {
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    public func fetch(
        apiKey: String,
        targetBaseURL: URL,
        forceRefresh: Bool = false
    ) async throws -> CodexQuotaResponse {
        let safeBaseURL = try RouterEndpoint.normalizedURL(from: targetBaseURL.absoluteString)
        var components = URLComponents(
            url: Self.quotaURL(from: safeBaseURL),
            resolvingAgainstBaseURL: false
        )
        if forceRefresh {
            components?.queryItems = [URLQueryItem(name: "refresh", value: "1")]
        }
        guard let url = components?.url else {
            throw QuotaServiceError.invalidResponse
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = timeoutInterval

        QuotaNetworkDiagnostics.started(request: request, forceRefresh: forceRefresh)
        let startedAt = Date()
        do {
            let (data, response) = try await quotaData(
                session: session,
                request: request,
                timeoutInterval: timeoutInterval
            )
            guard let http = response as? HTTPURLResponse else {
                throw QuotaServiceError.invalidResponse
            }
            QuotaNetworkDiagnostics.finished(
                request: request,
                response: http,
                bytes: data.count,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            switch http.statusCode {
            case 200..<300:
                break
            case 401, 403:
                throw QuotaServiceError.unauthorized
            case 404, 405:
                throw QuotaServiceError.unsupported
            default:
                throw QuotaServiceError.serverError(http.statusCode)
            }

            do {
                return try JSONDecoder().decode(CodexQuotaResponse.self, from: data)
            } catch {
                throw QuotaServiceError.invalidResponse
            }
        } catch let error as QuotaServiceError {
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        } catch let error as URLError where error.code == .timedOut {
            let timeout = QuotaServiceError.requestTimedOut
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: timeout,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw timeout
        } catch is QuotaRequestDeadlineError {
            let timeout = QuotaServiceError.requestTimedOut
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: timeout,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw timeout
        } catch {
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
    }

    public static func quotaURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.path.lowercased().hasSuffix("/v1/quota") == true {
            components?.query = nil
            components?.fragment = nil
            return components?.url ?? baseURL
        }
        let basePath = (components?.path ?? "")
            .split(separator: "/")
            .map(String.init)
            .joined(separator: "/")
        components?.path = basePath.isEmpty ? "/v1/quota" : "/\(basePath)/v1/quota"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent("v1/quota")
    }
}

public struct OmniQuotaResponse: Equatable, Sendable {
    public let accounts: [CodexQuotaAccount]

    public init(accounts: [CodexQuotaAccount]) {
        self.accounts = accounts
    }

    public var summary: CodexQuotaSummary {
        let available = accounts.filter { !$0.limitReached && $0.status != "expired" }.count
        let lowest = accounts
            .compactMap(\.primaryQuota?.remaining)
            .min()
        return CodexQuotaSummary(
            accounts: accounts.count,
            availableAccounts: available,
            unavailableAccounts: max(0, accounts.count - available),
            lowestRemaining: lowest
        )
    }
}

public final class OmniQuotaService: @unchecked Sendable {
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    public init(session: URLSession = .shared) {
        self.session = session
        self.timeoutInterval = QuotaRequestPolicy.timeoutInterval
    }

    init(session: URLSession, timeoutInterval: TimeInterval) {
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    public static func preferredCredential(
        quotaToken: String?,
        inferenceAPIKey: String?
    ) -> String? {
        for value in [quotaToken, inferenceAPIKey] {
            let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    public func fetch(
        apiKey: String,
        targetBaseURL: URL,
        forceRefresh: Bool = false
    ) async throws -> OmniQuotaResponse {
        let safeBaseURL = try RouterEndpoint.normalizedURL(from: targetBaseURL.absoluteString)
        let quotaRequest = try Self.request(
            apiKey: apiKey,
            url: Self.quotaURL(from: safeBaseURL),
            forceRefresh: forceRefresh,
            timeoutInterval: timeoutInterval
        )
        let providerLimitsRequest = try Self.request(
            apiKey: apiKey,
            url: Self.providerLimitsURL(from: safeBaseURL),
            forceRefresh: forceRefresh,
            timeoutInterval: timeoutInterval
        )

        async let quotaResult = load(request: quotaRequest)
        async let providerLimitsResult = load(request: providerLimitsRequest)

        // Identity/status comes from quota. Limits are best-effort for older Omni versions.
        let quotaData = try await quotaResult
        let providerLimitsData = try? await providerLimitsResult
        return try Self.decodeResponse(
            quotaData,
            providerLimitsData: providerLimitsData
        )
    }

    public static func decodeResponse(_ data: Data) throws -> OmniQuotaResponse {
        try decodeResponse(data, providerLimitsData: nil)
    }

    public static func decodeResponse(
        _ data: Data,
        providerLimitsData: Data?
    ) throws -> OmniQuotaResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProviders = object["providers"] as? [[String: Any]] else {
            throw QuotaServiceError.invalidResponse
        }

        let caches = providerLimitsData.flatMap(providerLimitsCaches(from:))
        let accounts = rawProviders.compactMap { provider in
            account(
                from: provider,
                providerLimits: caches?[connectionID(in: provider) ?? ""]
            )
        }
        return OmniQuotaResponse(accounts: accounts)
    }

    public static func sanitizedResponse(
        accounts: [CodexQuotaAccount]
    ) -> OmniQuotaResponse {
        OmniQuotaResponse(accounts: accounts.map(sanitizedAccount))
    }

    public static func quotaURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.path.lowercased().hasSuffix("/api/usage/quota") == true {
            components?.query = nil
            components?.fragment = nil
            return components?.url ?? baseURL
        }
        let basePath = (components?.path ?? "")
            .split(separator: "/")
            .map(String.init)
            .joined(separator: "/")
        components?.path = basePath.isEmpty ? "/api/usage/quota" : "/\(basePath)/api/usage/quota"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent("api/usage/quota")
    }

    public static func providerLimitsURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if components?.path.lowercased().hasSuffix("/api/usage/quota") == true {
            let path = components?.path ?? ""
            components?.path = String(path.dropLast("quota".count)) + "provider-limits"
            components?.query = nil
            components?.fragment = nil
            return components?.url ?? baseURL
        }
        let basePath = (components?.path ?? "")
            .split(separator: "/")
            .map(String.init)
            .joined(separator: "/")
        components?.path = basePath.isEmpty
            ? "/api/usage/provider-limits"
            : "/\(basePath)/api/usage/provider-limits"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent("api/usage/provider-limits")
    }

    private func load(request: URLRequest) async throws -> Data {
        QuotaNetworkDiagnostics.started(request: request, forceRefresh: false)
        let startedAt = Date()
        do {
            let (data, response) = try await quotaData(
                session: session,
                request: request,
                timeoutInterval: timeoutInterval
            )
            guard let http = response as? HTTPURLResponse else {
                throw QuotaServiceError.invalidResponse
            }
            QuotaNetworkDiagnostics.finished(
                request: request,
                response: http,
                bytes: data.count,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw QuotaServiceError.unauthorized
            case 404, 405:
                throw QuotaServiceError.unsupported
            default:
                throw QuotaServiceError.serverError(http.statusCode)
            }
        } catch let error as QuotaServiceError {
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        } catch let error as URLError where error.code == .timedOut {
            let timeout = QuotaServiceError.requestTimedOut
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: timeout,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw timeout
        } catch is QuotaRequestDeadlineError {
            let timeout = QuotaServiceError.requestTimedOut
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: timeout,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw timeout
        } catch {
            QuotaNetworkDiagnostics.failed(
                request: request,
                error: error,
                elapsed: Date().timeIntervalSince(startedAt)
            )
            throw error
        }
    }

    private static func request(
        apiKey: String,
        url: URL,
        forceRefresh: Bool = false,
        timeoutInterval: TimeInterval
    ) throws -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if forceRefresh {
            components?.queryItems = [URLQueryItem(name: "refresh", value: "1")]
        }
        guard let requestURL = components?.url else {
            throw QuotaServiceError.invalidResponse
        }

        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = timeoutInterval
        return request
    }

    private static func providerLimitsCaches(from data: Data) -> [String: [String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caches = object["caches"] as? [String: Any] else {
            return nil
        }
        return caches.compactMapValues { $0 as? [String: Any] }
    }

    private static func connectionID(in provider: [String: Any]) -> String? {
        firstString(in: provider, keys: [
            "connectionId", "connection_id", "id", "accountId", "account_id"
        ])
    }

    private static func account(
        from provider: [String: Any],
        providerLimits: [String: Any]? = nil
    ) -> CodexQuotaAccount? {
        let connectionID = connectionID(in: provider) ?? UUID().uuidString
        let name = firstString(in: provider, keys: [
            "name", "email", "label", "provider"
        ]) ?? connectionID
        let mergedProvider = merging(provider: provider, providerLimits: providerLimits)
        let quotaCandidates = quotaObjects(in: mergedProvider)
        let resolvedQuota = quotaCandidates
            .lazy
            .compactMap { quota -> ([String: Any], Double)? in
                remainingPercentage(provider: [:], quota: quota).map { (quota, $0) }
            }
            .first
        let effectiveQuotaSource = resolvedQuota?.0 ?? quotaCandidates.first ?? mergedProvider
        let remaining = resolvedQuota?.1 ?? remainingPercentage(
            provider: mergedProvider,
            quota: mergedProvider
        )
        let total = firstNumber(in: effectiveQuotaSource, keys: [
            "quotaTotal", "quota_total", "total", "limit", "max"
        ]) ?? firstNumber(in: mergedProvider, keys: ["quotaTotal", "quota_total"])
        let used = firstNumber(in: effectiveQuotaSource, keys: [
            "quotaUsed", "quota_used", "used", "usage", "consumed"
        ]) ?? firstNumber(in: mergedProvider, keys: ["quotaUsed", "quota_used"])
        let resetAt = firstString(in: effectiveQuotaSource, keys: [
            "resetAt", "reset_at", "resetsAt", "resets_at"
        ]) ?? firstString(in: mergedProvider, keys: [
            "resetAt", "reset_at", "resetsAt", "resets_at"
        ])
        let isMeasured = isMeasuredQuota(
            remaining: remaining,
            used: used,
            total: total,
            provider: mergedProvider,
            quota: effectiveQuotaSource
        )
        let quotas: [CodexQuotaWindow]
        if let remaining, isMeasured {
            quotas = [CodexQuotaWindow(
                key: "session",
                used: used ?? (100 - remaining),
                total: total ?? 100,
                remaining: remaining,
                resetAt: resetAt,
                unlimited: boolean(effectiveQuotaSource["unlimited"]) ?? false
            )]
        } else {
            // Unknown quota is intentionally represented by no window so the UI shows N/A.
            // Treating a missing value as 100% hid exhausted and unsupported accounts.
            quotas = []
        }
        let tokenStatus = firstString(in: mergedProvider, keys: [
            "tokenStatus", "token_status", "status"
        ]) ?? "valid"
        let explicitLimitReached = boolean(mergedProvider["limitReached"])
            ?? boolean(mergedProvider["limit_reached"])
            ?? boolean(effectiveQuotaSource["limitReached"])
            ?? boolean(effectiveQuotaSource["limit_reached"])
        return CodexQuotaAccount(
            id: connectionID,
            provider: string(mergedProvider["provider"]) ?? "omni",
            label: name,
            plan: firstString(in: mergedProvider, keys: ["plan", "tier"]) ?? "",
            limitReached: explicitLimitReached
                ?? (isMeasured ? (remaining.map { $0 <= 0 } ?? false) : false),
            quotas: quotas,
            resetCredits: .init(
                availableCount: Int(
                    firstNumber(in: mergedProvider, keys: [
                        "bankedResetCredits", "banked_reset_credits"
                    ])?.rounded() ?? 0
                )
            ),
            status: tokenStatus,
            errorCode: firstString(in: mergedProvider, keys: ["errorCode", "error_code"])
        )
    }

    private static func merging(
        provider: [String: Any],
        providerLimits: [String: Any]?
    ) -> [String: Any] {
        guard let providerLimits else {
            return provider
        }
        var merged = provider
        for key in ["quotas", "plan", "bankedResetCredits", "message"] {
            if let value = providerLimits[key] {
                merged[key] = value
            }
        }
        return merged
    }

    private static func sanitizedAccount(
        _ account: CodexQuotaAccount
    ) -> CodexQuotaAccount {
        guard let quota = account.primaryQuota,
              isUnmeasuredFullPlaceholder(
                  remaining: quota.remaining,
                  used: quota.used,
                  total: quota.total
              ) else {
            return account
        }
        return CodexQuotaAccount(
            id: account.id,
            provider: account.provider,
            label: account.label,
            plan: account.plan,
            limitReached: false,
            quotas: [],
            resetCredits: account.resetCredits,
            status: account.status,
            errorCode: account.errorCode,
            isActive: account.isActive
        )
    }

    private static func isMeasuredQuota(
        remaining: Double?,
        used: Double?,
        total: Double?,
        provider: [String: Any],
        quota: [String: Any]
    ) -> Bool {
        guard let remaining else { return false }

        if let total, total > 0 {
            return true
        }
        if let used, used > 0 {
            return true
        }
        let measurementKeys = [
            "quotaMeasured", "quota_measured", "usageMeasured", "usage_measured",
            "isMeasured", "is_measured"
        ]
        let explicitlyMeasured = measurementKeys.contains(where: {
            boolean(quota[$0]) == true || boolean(provider[$0]) == true
        })
        if explicitlyMeasured {
            return true
        }

        // Omni currently reports this placeholder for accounts whose provider does not
        // expose a measurable quota. Presenting it as a real 100% is misleading.
        return remaining != 100 || (used != nil && used != 0)
    }

    private static func isUnmeasuredFullPlaceholder(
        remaining: Double,
        used: Double?,
        total: Double?
    ) -> Bool {
        remaining == 100
            && (used == nil || used == 0)
            && (total == nil || total == 0 || total == 100)
    }

    private static func remainingPercentage(
        provider: [String: Any],
        quota: [String: Any]
    ) -> Double? {
        let remainingKeys = [
            "percentRemaining", "percent_remaining", "remainingPercent", "remaining_percent",
            "percentageRemaining", "percentage_remaining"
        ]
        if let value = firstNumber(in: quota, keys: remainingKeys)
            ?? firstNumber(in: provider, keys: remainingKeys) {
            return percentage(value)
        }

        let usedPercentageKeys = [
            "percentUsed", "percent_used", "usedPercent", "used_percent",
            "percentageUsed", "percentage_used"
        ]
        if let value = firstNumber(in: quota, keys: usedPercentageKeys)
            ?? firstNumber(in: provider, keys: usedPercentageKeys),
           let usedPercentage = percentage(value) {
            return 100 - usedPercentage
        }

        let remaining = firstNumber(in: quota, keys: [
            "quotaRemaining", "quota_remaining", "remaining", "available", "left"
        ]) ?? firstNumber(in: provider, keys: ["quotaRemaining", "quota_remaining"])
        let used = firstNumber(in: quota, keys: [
            "quotaUsed", "quota_used", "used", "usage", "consumed"
        ]) ?? firstNumber(in: provider, keys: ["quotaUsed", "quota_used"])
        let total = firstNumber(in: quota, keys: [
            "quotaTotal", "quota_total", "total", "limit", "max"
        ]) ?? firstNumber(in: provider, keys: ["quotaTotal", "quota_total"])

        if let remaining, let total, total > 0 {
            return clampedPercentage(remaining / total * 100)
        }
        if let used, let total, total > 0 {
            return clampedPercentage((total - used) / total * 100)
        }
        return nil
    }

    private static func percentage(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        // Some APIs encode percentages as fractions while others use 0...100.
        if value >= 0, value <= 1 {
            return clampedPercentage(value * 100)
        }
        return clampedPercentage(value)
    }

    private static func clampedPercentage(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(max(value, 0), 100)
    }

    private static func quotaObjects(in provider: [String: Any]) -> [[String: Any]] {
        let direct = ["quota", "quotas", "usage", "limits", "rateLimit", "rate_limit"]
            .compactMap { provider[$0] as? [String: Any] }
        let nested = direct.flatMap { object in
            ["quota", "quotas", "usage", "limits", "rateLimit", "rate_limit", "session", "primary"]
                .compactMap { object[$0] as? [String: Any] }
        }
        return direct + nested
    }

    private static func firstString(
        in object: [String: Any],
        keys: [String]
    ) -> String? {
        keys.lazy.compactMap { string(object[$0]) }.first
    }

    private static func firstNumber(
        in object: [String: Any],
        keys: [String]
    ) -> Double? {
        keys.lazy.compactMap { number(object[$0]) }.first
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            return Double(normalized)
        }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

/// Adapts the two supported quota response contracts behind one custom-provider
/// surface. Automatic mode tries 9Router first, then OmniRouter on the same host.
public final class CustomQuotaService: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(
        provider: CustomQuotaProvider,
        forceRefresh: Bool = false
    ) async throws -> [CodexQuotaAccount] {
        let endpoint = provider.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw RouterEndpointError.invalidURL
        }
        guard !key.isEmpty else { throw QuotaServiceError.unauthorized }

        switch provider.apiKind {
        case .nineRouter:
            return try await fetchNine(url: url, key: key, providerID: provider.id, forceRefresh: forceRefresh)
        case .omniRouter:
            return try await fetchOmni(url: url, key: key, providerID: provider.id, forceRefresh: forceRefresh)
        case .automatic:
            do {
                return try await fetchNine(url: url, key: key, providerID: provider.id, forceRefresh: forceRefresh)
            } catch let firstError {
                do {
                    return try await fetchOmni(url: url, key: key, providerID: provider.id, forceRefresh: forceRefresh)
                } catch let secondError {
                    if Self.isUnauthorized(firstError) || Self.isUnauthorized(secondError) {
                        throw QuotaServiceError.unauthorized
                    }
                    throw secondError
                }
            }
        }
    }

    private func fetchNine(
        url: URL,
        key: String,
        providerID: UUID,
        forceRefresh: Bool
    ) async throws -> [CodexQuotaAccount] {
        let response = try await QuotaService(session: session).fetch(
            apiKey: key,
            targetBaseURL: url,
            forceRefresh: forceRefresh
        )
        return response.data.map { $0.sourced(providerID: providerID) }
    }

    private func fetchOmni(
        url: URL,
        key: String,
        providerID: UUID,
        forceRefresh: Bool
    ) async throws -> [CodexQuotaAccount] {
        let response = try await OmniQuotaService(session: session).fetch(
            apiKey: key,
            targetBaseURL: url,
            forceRefresh: forceRefresh
        )
        return response.accounts.map { $0.sourced(providerID: providerID) }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        (error as? QuotaServiceError) == .unauthorized
    }
}
