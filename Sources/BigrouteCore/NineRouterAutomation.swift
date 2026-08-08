import CryptoKit
import Foundation

public enum NineRouterAutomationChangeKind: String, Codable, Equatable, Sendable {
    case activated
    case deactivated
}

public struct NineRouterAutomationChange: Codable, Equatable, Sendable {
    public let connectionID: String
    public let publicAccountID: String
    public let kind: NineRouterAutomationChangeKind
    public let remaining: Double

    public init(
        connectionID: String,
        publicAccountID: String,
        kind: NineRouterAutomationChangeKind,
        remaining: Double
    ) {
        self.connectionID = connectionID
        self.publicAccountID = publicAccountID
        self.kind = kind
        self.remaining = remaining
    }
}

/// A quota observation paired with its raw 9Router connection ID. This keeps
/// inactive, Bigroute-owned accounts visible to the monitor even though the
/// public quota endpoint omits inactive connections.
public struct NineRouterAccountObservation: Equatable, Sendable {
    public let connectionID: String
    public let publicAccountID: String
    public let wasActive: Bool
    public let measurement: NineRouterQuotaMeasurement

    public init(
        connectionID: String,
        publicAccountID: String,
        wasActive: Bool,
        measurement: NineRouterQuotaMeasurement
    ) {
        self.connectionID = connectionID
        self.publicAccountID = publicAccountID
        self.wasActive = wasActive
        self.measurement = measurement
    }
}

public enum NineRouterAutomationOperation: String, Codable, Equatable, Sendable {
    case usage
    case update
}

public enum NineRouterAutomationError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint
    case missingManagementPassword
    case unauthorized
    case forbidden
    case invalidAuthenticationResponse
    case mustChangePassword
    case rateLimited
    case notFound
    case methodNotAllowed
    case clientError(Int)
    case serverError(Int)
    case invalidResponse
    case staleQuota
    case quotaUnavailable
    case statePersistenceFailed
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The 9Router endpoint is invalid."
        case .missingManagementPassword:
            "Enter the 9Router dashboard password before enabling account automation."
        case .unauthorized:
            "9Router rejected the dashboard password or the management session expired."
        case .forbidden:
            "The 9Router management session cannot change provider accounts."
        case .invalidAuthenticationResponse:
            "9Router returned an invalid dashboard login response."
        case .mustChangePassword:
            "Change the 9Router dashboard password before enabling automatic routing."
        case .rateLimited:
            "9Router temporarily rate-limited account automation."
        case .notFound:
            "The requested 9Router management resource was not found."
        case .methodNotAllowed:
            "This 9Router version does not support the requested management operation."
        case let .clientError(statusCode):
            "9Router rejected the account-routing request (HTTP \(statusCode))."
        case let .serverError(statusCode):
            "9Router account automation failed (HTTP \(statusCode))."
        case .invalidResponse:
            "9Router returned an invalid management response."
        case .staleQuota:
            "9Router returned quota data that is stale or came from an unverified cache."
        case .quotaUnavailable:
            "9Router could not provide a complete, available quota measurement."
        case .statePersistenceFailed:
            "Bigroute could not persist account-routing ownership safely. No account was changed."
        case let .transport(message):
            "Could not reach 9Router: \(message)"
        }
    }

    fileprivate var shouldStopReconciliation: Bool {
        switch self {
        case .unauthorized, .forbidden, .invalidAuthenticationResponse,
             .mustChangePassword, .rateLimited, .clientError, .staleQuota,
             .quotaUnavailable, .statePersistenceFailed, .transport:
            true
        default:
            false
        }
    }
}

public struct NineRouterAutomationWarning: Equatable, Sendable {
    public let connectionID: String
    public let operation: NineRouterAutomationOperation
    public let error: NineRouterAutomationError

    public init(
        connectionID: String,
        operation: NineRouterAutomationOperation,
        error: NineRouterAutomationError
    ) {
        self.connectionID = connectionID
        self.operation = operation
        self.error = error
    }
}

public struct NineRouterAutomationReport: Equatable, Sendable {
    public let updatedState: NineRouterAutomationState
    public let observations: [NineRouterAccountObservation]
    public let changes: [NineRouterAutomationChange]
    public let warnings: [NineRouterAutomationWarning]
    public let inspectedConnectionCount: Int
    public let ignoredConnectionCount: Int

    public init(
        updatedState: NineRouterAutomationState,
        observations: [NineRouterAccountObservation] = [],
        changes: [NineRouterAutomationChange] = [],
        warnings: [NineRouterAutomationWarning] = [],
        inspectedConnectionCount: Int = 0,
        ignoredConnectionCount: Int = 0
    ) {
        self.updatedState = updatedState
        self.observations = observations
        self.changes = changes
        self.warnings = warnings
        self.inspectedConnectionCount = inspectedConnectionCount
        self.ignoredConnectionCount = ignoredConnectionCount
    }
}

public struct NineRouterQuotaMeasurement: Equatable, Sendable {
    public let remaining: Double
    public let unlimited: Bool
    public let windows: [NineRouterQuotaWindowMeasurement]

    public init(
        remaining: Double,
        unlimited: Bool,
        windows: [NineRouterQuotaWindowMeasurement] = []
    ) {
        self.remaining = remaining
        self.unlimited = unlimited
        self.windows = windows
    }
}

public struct NineRouterQuotaWindowMeasurement: Equatable, Sendable {
    public let key: String
    public let remaining: Double
    public let resetAt: String?

    public init(key: String, remaining: Double, resetAt: String?) {
        self.key = key
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

public enum NineRouterAutomationPolicy {
    /// Returns a desired active state only when a real state transition is needed.
    public static func desiredActiveState(
        currentlyActive: Bool,
        measurement: NineRouterQuotaMeasurement?
    ) -> Bool? {
        guard let measurement,
              measurement.remaining.isFinite,
              measurement.remaining >= 0,
              measurement.remaining <= 100,
              !measurement.unlimited else {
            return nil
        }
        if currentlyActive, measurement.remaining == 0 {
            return false
        }
        if !currentlyActive, measurement.remaining > 0 {
            return true
        }
        return nil
    }

    public static func authoritativeMeasurement(
        for account: CodexQuotaAccount
    ) -> NineRouterQuotaMeasurement? {
        guard account.status.caseInsensitiveCompare("available") == .orderedSame,
              account.errorCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              !account.quotas.isEmpty else {
            return nil
        }

        var measuredRemainings: [Double] = []
        var windows: [NineRouterQuotaWindowMeasurement] = []
        var seenKeys: Set<String> = []
        var finiteKeys: Set<String> = []
        for quota in account.quotas {
            let normalizedKey = quota.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty, seenKeys.insert(normalizedKey).inserted else {
                return nil
            }
            if quota.unlimited { continue }
            finiteKeys.insert(normalizedKey)
            guard quota.total.isFinite,
                  quota.total > 0,
                  quota.used.isFinite,
                  quota.used >= 0,
                  quota.used <= quota.total,
                  quota.remaining.isFinite,
                  quota.remaining >= 0,
                  quota.remaining <= 100 else {
                return nil
            }
            let tolerance = max(0.5, quota.total * 0.01)
            guard abs((quota.used + quota.remaining / 100 * quota.total) - quota.total) <= tolerance else {
                return nil
            }
            if quota.remaining == 0,
               !isFreshResetDate(quota.resetAt, now: Date()) {
                // A zero quota without a trustworthy reset epoch can be safely
                // displayed, but it cannot be used to change routing state.
                return nil
            }
            measuredRemainings.append(quota.remaining)
            windows.append(NineRouterQuotaWindowMeasurement(
                key: normalizedKey,
                remaining: quota.remaining,
                resetAt: quota.resetAt
            ))
        }
        guard finiteKeys.contains("session"), finiteKeys.contains("weekly") else {
            return nil
        }
        guard let remaining = measuredRemainings.min() else { return nil }
        if account.limitReached && remaining > 0 { return nil }
        return NineRouterQuotaMeasurement(
            remaining: remaining,
            unlimited: false,
            windows: windows
        )
    }

    /// Saves reset epochs for exhausted windows so a later positive reading can
    /// prove that the quota actually crossed a reset boundary.
    public static func deactivationResetMarkers(
        from measurement: NineRouterQuotaMeasurement
    ) -> [String: String] {
        Dictionary(
            measurement.windows.compactMap { window -> (String, String)? in
                guard window.remaining == 0,
                      let resetAt = window.resetAt,
                      isFreshResetDate(resetAt, now: Date()) else { return nil }
                return (window.key, resetAt)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// A positive reading is allowed to reactivate an owned account only after
    /// every previously exhausted window has advanced to a new reset epoch.
    public static func canReactivate(
        measurement: NineRouterQuotaMeasurement,
        after markers: [String: String],
        now: Date = Date()
    ) -> Bool {
        guard measurement.remaining > 0,
              !measurement.unlimited,
              !markers.isEmpty,
              measurement.windows.allSatisfy({
                  $0.remaining.isFinite && $0.remaining > 0
                      && isFreshResetDate($0.resetAt, now: now)
              }) else {
            return false
        }

        let windows = Dictionary(
            measurement.windows.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let clockSkew: TimeInterval = 60
        for (key, oldRawResetAt) in markers {
            guard let window = windows[key],
                  let oldResetAt = parseResetDate(oldRawResetAt),
                  let newResetAt = parseResetDate(window.resetAt),
                  oldResetAt <= now.addingTimeInterval(clockSkew),
                  newResetAt > oldResetAt,
                  newResetAt > now.addingTimeInterval(-clockSkew),
                  newResetAt <= now.addingTimeInterval(90 * 24 * 60 * 60) else {
                return false
            }
        }
        return true
    }

    private static func isFreshResetDate(_ raw: String?, now: Date) -> Bool {
        guard let raw,
              let date = parseResetDate(raw) else { return false }
        return date > now.addingTimeInterval(-60)
            && date <= now.addingTimeInterval(90 * 24 * 60 * 60)
    }

    private static func parseResetDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw) {
            let timestamp = seconds > 10_000_000_000 ? seconds / 1000 : seconds
            return Date(timeIntervalSince1970: timestamp)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

public struct NineRouterHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol NineRouterHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse
}

public final class NineRouterURLSessionTransport: NineRouterHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // ManagementSession captures and attaches the single expected cookie
        // explicitly; URLSession must not add stale or unrelated cookies.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NineRouterAutomationError.invalidResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        return NineRouterHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data
        )
    }
}

public actor NineRouterAutomationService {
    private let transport: any NineRouterHTTPTransport
    private var cachedSession: ManagementSession?
    private var cachedSessionIdentity: ManagementSessionIdentity?
    private var reconciliationInProgress = false
    private var reconciliationWaiters: [CheckedContinuation<Void, Never>] = []

    public typealias StatePersistence = @Sendable (NineRouterAutomationState) throws -> Void

    public init(transport: any NineRouterHTTPTransport = NineRouterURLSessionTransport()) {
        self.transport = transport
    }

    public func reconcile(
        baseURL: URL,
        managementPassword: String,
        activeQuota: [CodexQuotaAccount],
        state initialState: NineRouterAutomationState = NineRouterAutomationState(),
        persistState: StatePersistence? = nil
    ) async throws -> NineRouterAutomationReport {
        await acquireReconciliation()
        defer { releaseReconciliation() }
        try Task.checkCancellation()
        let rootURL: URL
        do {
            rootURL = try Self.managementBaseURL(from: baseURL)
        } catch {
            throw NineRouterAutomationError.invalidEndpoint
        }
        guard !managementPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NineRouterAutomationError.missingManagementPassword
        }

        let sessionIdentity = ManagementSessionIdentity(
            rootURL: rootURL,
            password: managementPassword
        )
        let session: ManagementSession
        if cachedSessionIdentity == sessionIdentity, let cachedSession {
            session = cachedSession
        } else {
            session = ManagementSession(
                rootURL: rootURL,
                password: managementPassword,
                transport: transport
            )
            cachedSession = session
            cachedSessionIdentity = sessionIdentity
        }
        try await session.ensureAuthenticated()
        try Task.checkCancellation()
        let allConnections = try await loadConnections(session: session)
        try Task.checkCancellation()
        let managedConnections = allConnections.filter(\.isCodexOAuth)
        var quotaByPublicID: [String: CodexQuotaAccount] = [:]
        var ambiguousQuotaIDs: Set<String> = []
        for account in activeQuota {
            guard let publicID = Self.publicID(from: account.id) else { continue }
            guard !ambiguousQuotaIDs.contains(publicID) else { continue }
            if quotaByPublicID.updateValue(account, forKey: publicID) != nil {
                quotaByPublicID.removeValue(forKey: publicID)
                ambiguousQuotaIDs.insert(publicID)
            }
        }

        let endpointIdentity = rootURL.absoluteString
        var updatedState = initialState.managementEndpointIdentity == endpointIdentity
            ? initialState
            : NineRouterAutomationState(managementEndpointIdentity: endpointIdentity)
        var observations: [NineRouterAccountObservation] = []
        var changes: [NineRouterAutomationChange] = []
        var warnings: [NineRouterAutomationWarning] = []
        var ignoredCount = allConnections.count - managedConnections.count

        // A complete inventory is authoritative for connection existence and
        // provider/auth type. Retire ownership for deleted or repurposed IDs so
        // a later ID reuse can never inherit Bigroute's old activation rights.
        let managedConnectionIDs = Set(managedConnections.map(\.id))
        let retiredConnectionIDs = updatedState.autoDisabledConnectionIDs
            .subtracting(managedConnectionIDs)
        if !retiredConnectionIDs.isEmpty {
            updatedState.autoDisabledConnectionIDs.subtract(retiredConnectionIDs)
            for connectionID in retiredConnectionIDs {
                updatedState.deactivationWindows.removeValue(forKey: connectionID)
            }
            if let persistState {
                do {
                    try persistState(updatedState)
                } catch {
                    throw NineRouterAutomationError.statePersistenceFailed
                }
            }
        }

        for connection in managedConnections {
            try Task.checkCancellation()
            let publicID = Self.publicAccountID(for: connection.id)
            let activeQuotaMeasurement = quotaByPublicID[publicID]
                .flatMap(NineRouterAutomationPolicy.authoritativeMeasurement(for:))

            if connection.isActive,
               updatedState.autoDisabledConnectionIDs.contains(connection.id) {
                let markers = updatedState.deactivationWindows[connection.id] ?? [:]
                if let activeQuotaMeasurement,
                   NineRouterAutomationPolicy.canReactivate(
                       measurement: activeQuotaMeasurement,
                       after: markers
                   ) {
                    // A fresh positive reading after every recorded reset is
                    // strong evidence that another actor reactivated it.
                    updatedState.autoDisabledConnectionIDs.remove(connection.id)
                    updatedState.deactivationWindows.removeValue(forKey: connection.id)
                    if let persistState {
                        do {
                            try persistState(updatedState)
                        } catch {
                            throw NineRouterAutomationError.statePersistenceFailed
                        }
                    }
                } else if activeQuotaMeasurement == nil || (activeQuotaMeasurement?.remaining ?? 0) > 0 {
                    // Do not release ownership from an inventory read alone:
                    // an async write or a stale quota response may still be
                    // settling. Wait for a complete reset-qualified reading.
                    ignoredCount += 1
                    continue
                }
            }

            let measurement: NineRouterQuotaMeasurement?
            if connection.isActive {
                measurement = activeQuotaMeasurement
            } else if updatedState.autoDisabledConnectionIDs.contains(connection.id) {
                do {
                    measurement = try await loadUsage(
                        connectionID: connection.id,
                        session: session
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let automationError = Self.automationError(from: error)
                    warnings.append(NineRouterAutomationWarning(
                        connectionID: connection.id,
                        operation: .usage,
                        error: automationError
                    ))
                    if automationError.shouldStopReconciliation { break }
                    continue
                }
            } else {
                // Inactive accounts not owned by Bigroute are considered manually disabled.
                ignoredCount += 1
                continue
            }

            guard let desiredActive = NineRouterAutomationPolicy.desiredActiveState(
                currentlyActive: connection.isActive,
                measurement: measurement
            ), let measurement else {
                if let measurement {
                    observations.append(NineRouterAccountObservation(
                        connectionID: connection.id,
                        publicAccountID: publicID,
                        wasActive: connection.isActive,
                        measurement: measurement
                    ))
                }
                ignoredCount += 1
                continue
            }

            if desiredActive,
               !NineRouterAutomationPolicy.canReactivate(
                   measurement: measurement,
                   after: updatedState.deactivationWindows[connection.id] ?? [:]
               ) {
                observations.append(NineRouterAccountObservation(
                    connectionID: connection.id,
                    publicAccountID: publicID,
                    wasActive: connection.isActive,
                    measurement: measurement
                ))
                ignoredCount += 1
                continue
            }

            observations.append(NineRouterAccountObservation(
                connectionID: connection.id,
                publicAccountID: publicID,
                wasActive: connection.isActive,
                measurement: measurement
            ))

            var persistedPendingDeactivation = false
            do {
                try Task.checkCancellation()
                if !desiredActive {
                    // Persist ownership before the remote write. If the process
                    // dies after 9Router commits but before the response arrives,
                    // the next run can still safely recover the account.
                    var pendingState = updatedState
                    pendingState.autoDisabledConnectionIDs.insert(connection.id)
                    pendingState.deactivationWindows[connection.id] =
                        NineRouterAutomationPolicy.deactivationResetMarkers(from: measurement)
                    if let persistState {
                        do {
                            try persistState(pendingState)
                        } catch {
                            throw NineRouterAutomationError.statePersistenceFailed
                        }
                    }
                    updatedState = pendingState
                    persistedPendingDeactivation = true
                }
                try await updateConnection(
                    connectionID: connection.id,
                    isActive: desiredActive,
                    session: session
                )
                if desiredActive {
                    updatedState.autoDisabledConnectionIDs.remove(connection.id)
                    updatedState.deactivationWindows.removeValue(forKey: connection.id)
                }
                changes.append(NineRouterAutomationChange(
                    connectionID: connection.id,
                    publicAccountID: publicID,
                    kind: desiredActive ? .activated : .deactivated,
                    remaining: measurement.remaining
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as NineRouterMutationFailure {
                if persistedPendingDeactivation, failure.isDefinitelyNotApplied {
                    updatedState.autoDisabledConnectionIDs.remove(connection.id)
                    updatedState.deactivationWindows.removeValue(forKey: connection.id)
                    if let persistState {
                        do {
                            try persistState(updatedState)
                        } catch {
                            warnings.append(NineRouterAutomationWarning(
                                connectionID: connection.id,
                                operation: .update,
                                error: .statePersistenceFailed
                            ))
                            break
                        }
                    }
                }
                warnings.append(NineRouterAutomationWarning(
                    connectionID: connection.id,
                    operation: .update,
                    error: failure.error
                ))
                // An unresolved mutation must stop the batch. Continuing would
                // issue more writes while the first account's remote state is
                // still unknown.
                break
            } catch {
                let automationError = Self.automationError(from: error)
                warnings.append(NineRouterAutomationWarning(
                    connectionID: connection.id,
                    operation: .update,
                    error: automationError
                ))
                if automationError.shouldStopReconciliation { break }
            }
        }

        return NineRouterAutomationReport(
            updatedState: updatedState,
            observations: observations,
            changes: changes,
            warnings: warnings,
            inspectedConnectionCount: managedConnections.count,
            ignoredConnectionCount: ignoredCount
        )
    }

    private func acquireReconciliation() async {
        guard reconciliationInProgress else {
            reconciliationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            reconciliationWaiters.append(continuation)
        }
    }

    private func releaseReconciliation() {
        guard !reconciliationWaiters.isEmpty else {
            reconciliationInProgress = false
            return
        }
        reconciliationWaiters.removeFirst().resume()
    }

    public static func publicAccountID(for rawConnectionID: String) -> String {
        let digest = SHA256.hash(data: Data(rawConnectionID.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func conflictingAutomationProviderIDs(
        in providers: [CustomQuotaProvider]
    ) -> Set<UUID> {
        var providerIDsByEndpoint: [String: [UUID]] = [:]
        for provider in providers where provider.isEnabled
            && provider.apiKind == .nineRouter
            && provider.isAutomaticAccountRoutingEnabled {
            guard let endpoint = try? RouterEndpoint.normalizedURL(from: provider.endpoint),
                  let managementURL = try? managementBaseURL(from: endpoint) else {
                continue
            }
            providerIDsByEndpoint[managementURL.absoluteString, default: []].append(provider.id)
        }
        return Set(providerIDsByEndpoint.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    public static func managementBaseURL(from endpoint: URL) throws -> URL {
        let normalized = try RouterEndpoint.normalizedURL(from: endpoint.absoluteString)
        guard var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else {
            throw NineRouterAutomationError.invalidEndpoint
        }
        var pathParts = components.path.split(separator: "/").map(String.init)
        let knownSuffixes = [
            ["api", "providers", "client"],
            ["api", "usage", "quota"],
            ["api", "v1", "quota"],
            ["api", "auth", "login"],
            ["api", "providers"],
            ["v1", "quota"]
        ]
        if let suffix = knownSuffixes.first(where: { pathParts.hasCaseInsensitiveSuffix($0) }) {
            pathParts.removeLast(suffix.count)
        }
        components.path = pathParts.isEmpty ? "" : "/\(pathParts.joined(separator: "/"))"
        components.query = nil
        components.fragment = nil
        if (components.scheme?.lowercased() == "https" && components.port == 443)
            || (components.scheme?.lowercased() == "http" && components.port == 80) {
            components.port = nil
        }
        guard let url = components.url else {
            throw NineRouterAutomationError.invalidEndpoint
        }
        return url
    }

    private func loadConnections(session: ManagementSession) async throws -> [ManagedConnection] {
        do {
            return try await loadPaginatedConnections(session: session)
        } catch NineRouterAutomationError.notFound, NineRouterAutomationError.methodNotAllowed {
            var components = URLComponents(
                url: Self.url(root: session.rootURL, path: ["api", "providers"]),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "bigroute_inventory", value: UUID().uuidString)
            ]
            guard let url = components?.url else {
                throw NineRouterAutomationError.invalidEndpoint
            }
            let request = Self.request(method: "GET", url: url)
            let response = try await session.sendAuthorized(request)
            try Self.validate(response)
            guard response.statusCode == 200 else {
                throw NineRouterAutomationError.invalidResponse
            }
            try Self.validateFreshManagementHeaders(response)
            let decoded = try Self.decodeConnections(response.body, expectedPage: nil)
            guard decoded.totalPages.map({ $0 == 1 }) ?? true,
                  decoded.totalItems.map({ $0 == decoded.connections.count }) ?? true else {
                throw NineRouterAutomationError.invalidResponse
            }
            return decoded.connections
        }
    }

    private func loadPaginatedConnections(session: ManagementSession) async throws -> [ManagedConnection] {
        var page = 1
        var results: [ManagedConnection] = []
        var seenIDs: Set<String> = []
        var expectedTotalPages: Int?
        var expectedTotalItems: Int?

        while page <= 100 {
            var components = URLComponents(
                url: Self.url(root: session.rootURL, path: ["api", "providers", "client"]),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "provider", value: "codex"),
                URLQueryItem(name: "accountStatus", value: "all"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: "500"),
                // Older builds called this parameter `limit`; sending both is
                // harmless and avoids silently truncating an older response.
                URLQueryItem(name: "limit", value: "500"),
                URLQueryItem(name: "bigroute_inventory", value: UUID().uuidString)
            ]
            guard let url = components?.url else {
                throw NineRouterAutomationError.invalidEndpoint
            }
            let response = try await session.sendAuthorized(Self.request(method: "GET", url: url))
            try Self.validate(response)
            guard response.statusCode == 200 else {
                throw NineRouterAutomationError.invalidResponse
            }
            try Self.validateFreshManagementHeaders(response)
            let decoded = try Self.decodeConnections(response.body, expectedPage: page)
            if let totalPages = decoded.totalPages {
                guard expectedTotalPages.map({ $0 == totalPages }) ?? true else {
                    throw NineRouterAutomationError.invalidResponse
                }
                expectedTotalPages = totalPages
            }
            if let totalItems = decoded.totalItems {
                guard expectedTotalItems.map({ $0 == totalItems }) ?? true else {
                    throw NineRouterAutomationError.invalidResponse
                }
                expectedTotalItems = totalItems
            }
            for connection in decoded.connections {
                guard seenIDs.insert(connection.id).inserted else {
                    // A repeated ID across pages is ambiguous even when the
                    // visible fields happen to match; fail closed.
                    throw NineRouterAutomationError.invalidResponse
                }
                results.append(connection)
            }
            if let totalPages = decoded.totalPages {
                guard page < totalPages else {
                    guard expectedTotalItems.map({ $0 == results.count }) ?? true else {
                        throw NineRouterAutomationError.invalidResponse
                    }
                    return results
                }
            } else if decoded.connections.count < 500 {
                guard expectedTotalItems.map({ $0 == results.count }) ?? true else {
                    throw NineRouterAutomationError.invalidResponse
                }
                return results
            }
            page += 1
        }
        throw NineRouterAutomationError.invalidResponse
    }

    private func loadUsage(
        connectionID: String,
        session: ManagementSession
    ) async throws -> NineRouterQuotaMeasurement {
        try Task.checkCancellation()
        var components = URLComponents(
            url: Self.url(
            root: session.rootURL,
            path: ["api", "usage", connectionID]
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "bigroute_refresh", value: UUID().uuidString)
        ]
        guard Self.isSafeConnectionID(connectionID), let url = components?.url else {
            throw NineRouterAutomationError.invalidEndpoint
        }
        let response = try await session.sendAuthorized(Self.request(method: "GET", url: url))
        try Self.validate(response)
        guard response.statusCode == 200 else {
            throw NineRouterAutomationError.invalidResponse
        }
        try Task.checkCancellation()
        return try Self.decodeUsage(response)
    }

    private func updateConnection(
        connectionID: String,
        isActive: Bool,
        session: ManagementSession
    ) async throws {
        try Task.checkCancellation()
        guard Self.isSafeConnectionID(connectionID) else {
            throw NineRouterAutomationError.invalidEndpoint
        }
        let url = Self.url(
            root: session.rootURL,
            path: ["api", "providers", connectionID]
        )
        let body = try JSONSerialization.data(withJSONObject: ["isActive": isActive])
        let outcomeError: NineRouterAutomationError
        var verificationMismatchIsDefinitive = false
        do {
            let response = try await session.sendAuthorized(Self.request(
                method: "PUT",
                url: url,
                body: body
            ))
            try Self.validate(response)
            if [200, 201].contains(response.statusCode),
               let state = Self.decodeTrustedConnectionState(response.body),
               state.id == connectionID,
               state.isActive == isActive {
                return
            }
            if [200, 201].contains(response.statusCode) {
                let explicitError = Self.explicitMutationError(response.body)
                verificationMismatchIsDefinitive = explicitError != nil
                outcomeError = explicitError ?? .invalidResponse
            } else {
                outcomeError = .invalidResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcomeError = Self.automationError(from: error)
            verificationMismatchIsDefinitive = !outcomeError.requiresMutationVerification
        }

        guard outcomeError.requiresMutationVerification else {
            throw NineRouterMutationFailure(
                error: outcomeError,
                isDefinitelyNotApplied: verificationMismatchIsDefinitive
            )
        }
        // A timeout, 5xx, 204, or malformed success may still follow a
        // committed write. Verify once before deciding the mutation failed.
        try Task.checkCancellation()
        do {
            if try await verifyConnectionState(
                connectionID: connectionID,
                isActive: isActive,
                session: session
            ) {
                return
            }
            throw NineRouterMutationFailure(
                error: outcomeError,
                isDefinitelyNotApplied: verificationMismatchIsDefinitive
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as NineRouterMutationFailure {
            throw failure
        } catch {
            throw NineRouterMutationFailure(
                error: outcomeError,
                isDefinitelyNotApplied: false
            )
        }
    }

    private func verifyConnectionState(
        connectionID: String,
        isActive: Bool,
        session: ManagementSession
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard Self.isSafeConnectionID(connectionID) else {
            throw NineRouterAutomationError.invalidEndpoint
        }
        let url = Self.url(
            root: session.rootURL,
            path: ["api", "providers", connectionID]
        )
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "bigroute_verify", value: UUID().uuidString)]
        guard let requestURL = components?.url else {
            throw NineRouterAutomationError.invalidEndpoint
        }
        let response = try await session.sendAuthorized(Self.request(method: "GET", url: requestURL))
        try Self.validate(response)
        guard response.statusCode == 200 else {
            throw NineRouterAutomationError.invalidResponse
        }
        try Self.validateFreshManagementHeaders(response)
        guard let state = Self.decodeTrustedConnectionState(response.body),
              state.id == connectionID else {
            throw NineRouterAutomationError.invalidResponse
        }
        return state.isActive == isActive
    }

    private static func request(method: String, url: URL, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("0", forHTTPHeaderField: "Expires")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func url(root: URL, path: [String]) -> URL {
        path.reduce(root) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private static func validate(_ response: NineRouterHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw NineRouterAutomationError.unauthorized
        case 403:
            throw NineRouterAutomationError.forbidden
        case 404:
            throw NineRouterAutomationError.notFound
        case 405:
            throw NineRouterAutomationError.methodNotAllowed
        case 429:
            throw NineRouterAutomationError.rateLimited
        case 400..<500:
            throw NineRouterAutomationError.clientError(response.statusCode)
        default:
            throw NineRouterAutomationError.serverError(response.statusCode)
        }
    }

    private static func decodeConnections(
        _ data: Data,
        expectedPage: Int?
    ) throws -> ConnectionPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawConnections = root["connections"] as? [[String: Any]] else {
            throw NineRouterAutomationError.invalidResponse
        }
        try validateSuccessfulEnvelope(root)
        for candidate in try metadataCandidates(
            in: root,
            nestedKeys: ["cache", "meta", "metadata"]
        ) {
            try validateUsageCandidate(candidate, allowFreshCacheState: false)
        }
        let connections = rawConnections.compactMap { item -> ManagedConnection? in
            guard let id = nonEmptyString(item["id"]),
                  isSafeConnectionID(id),
                  let provider = nonEmptyString(item["provider"]),
                  let authType = nonEmptyString(item["authType"]) else {
                return nil
            }
            guard let isActive = bool(item["isActive"]) else {
                // Unknown state is never safe to treat as active: doing so can
                // claim a manually disabled legacy connection.
                return nil
            }
            return ManagedConnection(
                id: id,
                provider: provider,
                authType: authType,
                isActive: isActive
            )
        }
        guard connections.count == rawConnections.count else {
            throw NineRouterAutomationError.invalidResponse
        }
        guard Set(connections.map(\.id)).count == connections.count else {
            throw NineRouterAutomationError.invalidResponse
        }

        let pagination: [String: Any]?
        if let rawPagination = root["pagination"] {
            guard let decodedPagination = rawPagination as? [String: Any] else {
                throw NineRouterAutomationError.invalidResponse
            }
            pagination = decodedPagination
        } else {
            pagination = nil
        }

        let totalPageValues = [pagination?["totalPages"], pagination?["total_pages"]]
            .compactMap { $0 }
        let parsedTotalPages = totalPageValues.compactMap(int)
        guard parsedTotalPages.count == totalPageValues.count,
              Set(parsedTotalPages).count <= 1 else {
            throw NineRouterAutomationError.invalidResponse
        }
        let totalPages = parsedTotalPages.first
        if expectedPage != nil {
            guard pagination != nil, totalPages != nil else {
                throw NineRouterAutomationError.invalidResponse
            }
        }
        if let totalPages, !(1...100).contains(totalPages) {
            throw NineRouterAutomationError.invalidResponse
        }

        let totalItemValues = [pagination?["total"], pagination?["totalItems"], pagination?["total_items"]]
            .compactMap { $0 }
        let parsedTotalItems = totalItemValues.compactMap(int)
        guard parsedTotalItems.count == totalItemValues.count,
              Set(parsedTotalItems).count <= 1 else {
            throw NineRouterAutomationError.invalidResponse
        }
        let totalItems = parsedTotalItems.first

        if let expectedPage {
            let currentPageValues = [pagination?["page"], pagination?["currentPage"], pagination?["current_page"]]
                .compactMap { $0 }
            let parsedCurrentPages = currentPageValues.compactMap(int)
            guard parsedCurrentPages.count == currentPageValues.count,
                  Set(parsedCurrentPages).count <= 1,
                  parsedCurrentPages.first.map({ $0 == expectedPage }) ?? true,
                  totalPages.map({ expectedPage <= $0 }) ?? true else {
                throw NineRouterAutomationError.invalidResponse
            }
        }
        return ConnectionPage(
            connections: connections,
            totalPages: totalPages,
            totalItems: totalItems
        )
    }

    private static func decodeConnectionState(_ data: Data) -> (id: String, isActive: Bool)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidate = (root["connection"] as? [String: Any])
            ?? (root["data"] as? [String: Any])
            ?? root
        guard let id = nonEmptyString(candidate["id"]),
              isSafeConnectionID(id),
              let isActive = bool(candidate["isActive"]) else {
            return nil
        }
        return (id, isActive)
    }

    private static func decodeTrustedConnectionState(
        _ data: Data
    ) -> (id: String, isActive: Bool)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidates: [[String: Any]] = [
            root,
            root["connection"] as? [String: Any],
            root["data"] as? [String: Any]
        ].compactMap { $0 }
        var expectedActiveState: Bool?
        for candidate in candidates {
            if let rawSuccess = candidate["success"] {
                guard bool(rawSuccess) == true else { return nil }
            }
            for key in ["error", "errorCode", "error_code"] {
                if hasExplicitFailureValue(candidate[key]) { return nil }
            }
            if let rawMessage = candidate["message"] {
                guard rawMessage is NSNull || nonEmptyString(rawMessage) != nil else { return nil }
                if let message = nonEmptyString(rawMessage), isFailureMessage(message) {
                    return nil
                }
            }
            if let rawStatus = candidate["status"] {
                guard let status = nonEmptyString(rawStatus)?.lowercased(),
                      ["ok", "success", "updated", "active", "inactive", "available", "connected"].contains(status) else {
                    return nil
                }
                if status == "active" || status == "inactive" {
                    let candidateExpectation = status == "active"
                    if let expectedActiveState, expectedActiveState != candidateExpectation {
                        return nil
                    }
                    expectedActiveState = candidateExpectation
                }
            }
        }
        guard let state = decodeConnectionState(data),
              expectedActiveState.map({ $0 == state.isActive }) ?? true else {
            return nil
        }
        return state
    }

    private static func explicitMutationError(_ data: Data) -> NineRouterAutomationError? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidates: [[String: Any]] = [
            root,
            root["connection"] as? [String: Any],
            root["data"] as? [String: Any]
        ].compactMap { $0 }
        for candidate in candidates {
            if let rawSuccess = candidate["success"], bool(rawSuccess) == false {
                return mutationError(
                    for: candidate["message"]
                        ?? candidate["error"]
                        ?? candidate["errorCode"]
                        ?? candidate["error_code"]
                )
            }
            if ["error", "errorCode", "error_code"].contains(where: {
                hasExplicitFailureValue(candidate[$0])
            }) {
                return mutationError(
                    for: candidate["error"]
                        ?? candidate["errorCode"]
                        ?? candidate["error_code"]
                )
            }
            if let status = nonEmptyString(candidate["status"])?.lowercased(),
               ["error", "failed", "failure", "rejected", "denied", "forbidden", "unauthorized", "invalid"].contains(status) {
                return mutationError(for: status)
            }
            if let message = nonEmptyString(candidate["message"]), isFailureMessage(message) {
                return mutationError(for: message)
            }
        }
        return nil
    }

    private static func mutationError(for rawValue: Any?) -> NineRouterAutomationError {
        let message = nonEmptyString(rawValue) ?? "mutation rejected"
        let normalized = message.lowercased()
        if normalized.contains("429")
            || normalized.contains("rate limit")
            || normalized.contains("rate-limit")
            || normalized.contains("thrott") {
            return .rateLimited
        }
        if normalized.contains("unauthor") || normalized.contains("authentication") {
            return .unauthorized
        }
        if normalized.contains("forbidden") || normalized.contains("denied") {
            return .forbidden
        }
        return .invalidResponse
    }

    private static func decodeUsage(_ response: NineRouterHTTPResponse) throws -> NineRouterQuotaMeasurement {
        try validateUsageFreshness(response)
        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw NineRouterAutomationError.invalidResponse
        }
        let usage = (root["usage"] as? [String: Any])
            ?? (root["data"] as? [String: Any])
            ?? root

        guard let quotas = usage["quotas"] as? [String: Any], !quotas.isEmpty else {
            throw NineRouterAutomationError.quotaUnavailable
        }

        var finiteRemainings: [Double] = []
        var windows: [NineRouterQuotaWindowMeasurement] = []
        var normalizedKeys: Set<String> = []
        for key in quotas.keys.sorted() {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedKey.isEmpty, normalizedKeys.insert(normalizedKey).inserted else {
                throw NineRouterAutomationError.invalidResponse
            }
            guard let quota = quotas[key] as? [String: Any],
                  bool(quota["unlimited"]) == false,
                  let used = number(quota["used"] ?? quota["quotaUsed"] ?? quota["quota_used"]),
                  let total = number(quota["total"] ?? quota["quotaTotal"] ?? quota["quota_total"]),
                  let remaining = number(quota["remaining"] ?? quota["available"] ?? quota["left"]),
                  let resetAt = nonEmptyString(quota["resetAt"])
                      ?? nonEmptyString(quota["reset_at"])
                      ?? nonEmptyString(quota["resetsAt"])
                      ?? nonEmptyString(quota["resets_at"]),
                  parseUsageDate(resetAt) != nil,
                  used.isFinite,
                  total.isFinite,
                  remaining.isFinite,
                  total > 0,
                  used >= 0,
                  used <= total,
                  remaining >= 0,
                  remaining <= total else {
                throw NineRouterAutomationError.invalidResponse
            }
            let tolerance = max(0.5, total * 0.01)
            guard abs((used + remaining) - total) <= tolerance else {
                throw NineRouterAutomationError.invalidResponse
            }
            let percentage = remaining / total * 100
            guard percentage.isFinite, percentage >= 0, percentage <= 100 else {
                throw NineRouterAutomationError.invalidResponse
            }
            finiteRemainings.append(percentage)
            windows.append(NineRouterQuotaWindowMeasurement(
                key: normalizedKey,
                remaining: percentage,
                resetAt: resetAt
            ))
        }

        guard normalizedKeys.contains("session"), normalizedKeys.contains("weekly") else {
            throw NineRouterAutomationError.invalidResponse
        }
        guard let remaining = finiteRemainings.min() else {
            throw NineRouterAutomationError.quotaUnavailable
        }

        let limitValues = [root, usage].flatMap { candidate in
            ["limitReached", "limit_reached", "reviewLimitReached", "review_limit_reached"].compactMap {
                candidate[$0]
            }
        }
        let parsedLimitValues = try limitValues.map { raw -> Bool in
            guard let value = bool(raw) else {
                throw NineRouterAutomationError.invalidResponse
            }
            return value
        }
        guard Set(parsedLimitValues).count <= 1 else {
            throw NineRouterAutomationError.invalidResponse
        }
        let limitReached = parsedLimitValues.contains(true)
        if limitReached && remaining > 0 {
            throw NineRouterAutomationError.quotaUnavailable
        }
        return NineRouterQuotaMeasurement(
            remaining: remaining,
            unlimited: false,
            windows: windows
        )
    }

    private static func validateUsageFreshness(_ response: NineRouterHTTPResponse) throws {
        try validateFreshManagementHeaders(response)

        guard let root = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw NineRouterAutomationError.invalidResponse
        }
        let candidates = try metadataCandidates(
            in: root,
            nestedKeys: ["usage", "data", "cache", "meta", "metadata"]
        )
        for candidate in candidates {
            try validateUsageCandidate(candidate, allowFreshCacheState: false)
        }
    }

    private static func metadataCandidates(
        in root: [String: Any],
        nestedKeys: [String]
    ) throws -> [[String: Any]] {
        var candidates = [root]
        var frontier = [root]
        for _ in 0..<3 {
            var next: [[String: Any]] = []
            for candidate in frontier {
                for key in nestedKeys {
                    guard let rawNested = candidate[key] else { continue }
                    guard let nested = rawNested as? [String: Any] else {
                        throw NineRouterAutomationError.invalidResponse
                    }
                    candidates.append(nested)
                    next.append(nested)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return candidates
    }

    private static func validateUsageCandidate(
        _ candidate: [String: Any],
        allowFreshCacheState: Bool
    ) throws {
        if let rawAvailable = candidate["available"] {
            guard let available = bool(rawAvailable) else {
                throw NineRouterAutomationError.invalidResponse
            }
            if !available { throw NineRouterAutomationError.quotaUnavailable }
        }
        if let rawSuccess = candidate["success"] {
            guard let success = bool(rawSuccess) else {
                throw NineRouterAutomationError.invalidResponse
            }
            if !success { throw NineRouterAutomationError.quotaUnavailable }
        }
        if let rawStatus = candidate["status"] {
            guard let status = nonEmptyString(rawStatus)?.lowercased() else {
                throw NineRouterAutomationError.invalidResponse
            }
            switch status {
            case "available", "valid", "active", "inactive", "connected", "ok", "success", "updated", "fresh", "ready":
                break
            case "miss", "dynamic", "bypass", "uncached", "origin":
                break
            case "hit", "shared":
                if allowFreshCacheState { break }
                throw NineRouterAutomationError.staleQuota
            case "stale", "expired", "updating":
                throw NineRouterAutomationError.staleQuota
            case "throttled", "rate_limited", "rate-limited":
                throw NineRouterAutomationError.rateLimited
            case "error", "unavailable", "failed":
                throw NineRouterAutomationError.quotaUnavailable
            default:
                throw NineRouterAutomationError.invalidResponse
            }
        }
        if let rawState = candidate["state"] {
            guard let state = nonEmptyString(rawState)?.lowercased() else {
                throw NineRouterAutomationError.invalidResponse
            }
            switch state {
            case "miss", "fresh", "dynamic", "bypass", "uncached", "origin":
                break
            case "hit", "shared":
                if allowFreshCacheState { break }
                throw NineRouterAutomationError.staleQuota
            case "stale", "expired", "updating":
                throw NineRouterAutomationError.staleQuota
            case "throttled", "rate_limited", "rate-limited":
                throw NineRouterAutomationError.rateLimited
            case "error", "unavailable", "failed":
                throw NineRouterAutomationError.quotaUnavailable
            default:
                throw NineRouterAutomationError.invalidResponse
            }
        }
        for key in ["stale", "cached"] {
            guard let raw = candidate[key] else { continue }
            guard let flag = bool(raw) else {
                throw NineRouterAutomationError.invalidResponse
            }
            if flag { throw NineRouterAutomationError.staleQuota }
        }
        if let rawPartial = candidate["partial"] {
            guard let partial = bool(rawPartial) else {
                throw NineRouterAutomationError.invalidResponse
            }
            if partial { throw NineRouterAutomationError.quotaUnavailable }
        }
        for key in ["complete", "isComplete", "is_complete"] {
            guard let rawComplete = candidate[key] else { continue }
            guard let complete = bool(rawComplete) else {
                throw NineRouterAutomationError.invalidResponse
            }
            if !complete { throw NineRouterAutomationError.quotaUnavailable }
        }
        for key in ["generatedAt", "generated_at", "fetchedAt", "fetched_at"] {
            guard let raw = candidate[key] else { continue }
            guard let date = parseUsageDate(raw as? String ?? String(describing: raw)) else {
                throw NineRouterAutomationError.invalidResponse
            }
            let age = Date().timeIntervalSince(date)
            guard age >= -5 * 60, age <= 5 * 60 else {
                throw NineRouterAutomationError.staleQuota
            }
        }
        for key in ["error", "errorCode", "error_code"] {
            guard let raw = candidate[key], hasExplicitFailureValue(raw) else { continue }
            if let message = nonEmptyString(raw) {
                try throwUsageMessage(message)
            }
            throw NineRouterAutomationError.invalidResponse
        }
        if let rawMessage = candidate["message"] {
            guard rawMessage is NSNull || nonEmptyString(rawMessage) != nil else {
                throw NineRouterAutomationError.invalidResponse
            }
            if let message = nonEmptyString(rawMessage), isFailureMessage(message) {
                try throwUsageMessage(message)
            }
        }
    }

    private static func validateSuccessfulEnvelope(_ candidate: [String: Any]) throws {
        if let rawSuccess = candidate["success"] {
            guard bool(rawSuccess) == true else {
                throw NineRouterAutomationError.invalidResponse
            }
        }
        if let rawAvailable = candidate["available"] {
            guard bool(rawAvailable) == true else {
                throw NineRouterAutomationError.invalidResponse
            }
        }
        if let rawStatus = candidate["status"] {
            guard let status = nonEmptyString(rawStatus)?.lowercased(),
                  ["ok", "success", "updated", "available", "active", "inactive", "connected", "valid"].contains(status) else {
                throw NineRouterAutomationError.invalidResponse
            }
        }
        for key in ["error", "errorCode", "error_code"] {
            if hasExplicitFailureValue(candidate[key]) {
                throw NineRouterAutomationError.invalidResponse
            }
        }
        if let rawMessage = candidate["message"] {
            guard rawMessage is NSNull || nonEmptyString(rawMessage) != nil else {
                throw NineRouterAutomationError.invalidResponse
            }
            if let message = nonEmptyString(rawMessage), isFailureMessage(message) {
                throw NineRouterAutomationError.invalidResponse
            }
        }
    }

    private static func hasExplicitFailureValue(_ value: Any?) -> Bool {
        guard let value else { return false }
        if value is NSNull { return false }
        if let boolValue = value as? Bool { return boolValue }
        if let numberValue = value as? NSNumber {
            return numberValue.doubleValue != 0
        }
        if let stringValue = value as? String {
            return !stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private static func isFailureMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return [
            "error", "failed", "failure", "denied", "forbidden", "unauthorized",
            "invalid", "rate limit", "rate-limit", "throttl", "not found",
            "unavailable", "expired"
        ].contains { normalized.contains($0) }
    }

    private static func validateFreshManagementHeaders(
        _ response: NineRouterHTTPResponse
    ) throws {
        for name in ["Age", "X-Cache", "CF-Cache-Status", "X-Cache-Status"] {
            guard let rawValue = header(response.headers, named: name) else { continue }
            let value = rawValue.lowercased()
            if name == "Age" {
                guard let age = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                      age >= 0 else {
                    throw NineRouterAutomationError.invalidResponse
                }
                if age > 0 { throw NineRouterAutomationError.staleQuota }
                continue
            }
            let tokens = value.split { character in
                !character.isLetter && !character.isNumber
                    && character != "-" && character != "_"
            }.map(String.init)
            if tokens.contains(where: isStaleCacheToken) {
                throw NineRouterAutomationError.staleQuota
            }
        }
    }

    private static func isStaleCacheToken(_ token: String) -> Bool {
        let normalized = token.replacingOccurrences(of: "_", with: "-")
        return ["hit", "stale", "expired", "updating"].contains(normalized)
            || normalized.hasSuffix("-hit")
            || normalized.hasSuffix("-stale")
    }

    private static func throwUsageMessage(_ message: String) throws {
        let normalized = message.lowercased()
        if normalized.contains("429")
            || normalized.contains("rate limit")
            || normalized.contains("rate-limit")
            || normalized.contains("throttl") {
            throw NineRouterAutomationError.rateLimited
        }
        throw NineRouterAutomationError.quotaUnavailable
    }

    private static func parseUsageDate(_ raw: String) -> Date? {
        if let seconds = Double(raw) {
            let timestamp = seconds > 10_000_000_000 ? seconds / 1000 : seconds
            return Date(timeIntervalSince1970: timestamp)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func header(_ headers: [String: String], named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func isSafeConnectionID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128, value != ".", value != ".." else {
            return false
        }
        return bytes.allSatisfy {
            ($0 >= 48 && $0 <= 57)
                || ($0 >= 65 && $0 <= 90)
                || ($0 >= 97 && $0 <= 122)
                || $0 == 45
                || $0 == 95
        }
    }

    private static func publicID(from accountID: String) -> String? {
        let candidate = accountID.split(separator: ":").last.map(String.init) ?? accountID
        guard candidate.count == 16,
              candidate.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return candidate.lowercased()
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(
                string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "%", with: "")
            )
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value = number(value),
              value.isFinite,
              value.rounded() == value,
              value >= 0,
              value <= 1_000_000 else {
            return nil
        }
        return Int(value)
    }

    fileprivate static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber {
            let numeric = number.doubleValue
            guard numeric == 0 || numeric == 1 else { return nil }
            return numeric == 1
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func automationError(from error: Error) -> NineRouterAutomationError {
        if let error = error as? NineRouterAutomationError { return error }
        return .transport(error.localizedDescription)
    }
}

private extension NineRouterAutomationError {
    var requiresMutationVerification: Bool {
        switch self {
        case .transport, .serverError, .invalidResponse, .rateLimited:
            true
        case let .clientError(statusCode) where [408, 425, 499].contains(statusCode):
            true
        default:
            false
        }
    }
}

private struct ManagedConnection: Sendable {
    let id: String
    let provider: String
    let authType: String
    let isActive: Bool

    var isCodexOAuth: Bool {
        provider.caseInsensitiveCompare("codex") == .orderedSame
            && authType.caseInsensitiveCompare("oauth") == .orderedSame
    }
}

private struct ConnectionPage: Sendable {
    let connections: [ManagedConnection]
    let totalPages: Int?
    let totalItems: Int?
}

private struct NineRouterMutationFailure: Error {
    let error: NineRouterAutomationError
    let isDefinitelyNotApplied: Bool
}

private struct ManagementSessionIdentity: Equatable {
    let rootURL: String
    let passwordDigest: [UInt8]

    init(rootURL: URL, password: String) {
        self.rootURL = rootURL.absoluteString
        passwordDigest = Array(SHA256.hash(data: Data(password.utf8)))
    }
}

private actor ManagementSession {
    let rootURL: URL
    private let password: String
    private let transport: any NineRouterHTTPTransport
    private var cookieHeader: String?

    init(rootURL: URL, password: String, transport: any NineRouterHTTPTransport) {
        self.rootURL = rootURL
        self.password = password
        self.transport = transport
    }

    func ensureAuthenticated() async throws {
        guard cookieHeader == nil else { return }
        try await login()
    }

    private func login() async throws {
        cookieHeader = nil
        let url = ["api", "auth", "login"].reduce(rootURL) {
            $0.appendingPathComponent($1)
        }
        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let response = try await send(request)
        try validateAuthentication(response)
        captureCookies(from: response, url: url)
        guard cookieHeader != nil else {
            throw NineRouterAutomationError.invalidAuthenticationResponse
        }
    }

    func sendAuthorized(_ originalRequest: URLRequest) async throws -> NineRouterHTTPResponse {
        var request = originalRequest
        if let cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        var response = try await send(request)
        if response.statusCode == 401 {
            try await login()
            request = originalRequest
            if let cookieHeader {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            response = try await send(request)
        }
        return response
    }

    private func send(_ request: URLRequest) async throws -> NineRouterHTTPResponse {
        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let automationError = error as? NineRouterAutomationError {
                throw automationError
            }
            throw NineRouterAutomationError.transport(error.localizedDescription)
        }
    }

    private func validateAuthentication(_ response: NineRouterHTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  NineRouterAutomationService.bool(object["success"]) == true else {
                throw NineRouterAutomationError.invalidAuthenticationResponse
            }
            if NineRouterAutomationService.bool(object["mustChangePassword"]) == true {
                throw NineRouterAutomationError.mustChangePassword
            }
            return
        case 401:
            throw NineRouterAutomationError.unauthorized
        case 403:
            throw NineRouterAutomationError.forbidden
        case 429:
            throw NineRouterAutomationError.rateLimited
        default:
            throw NineRouterAutomationError.serverError(response.statusCode)
        }
    }

    private func captureCookies(from response: NineRouterHTTPResponse, url: URL) {
        let cookieFields = response.headers.reduce(into: [String: String]()) { result, entry in
            if entry.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                result["Set-Cookie"] = entry.value
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: cookieFields, for: url)
        guard !cookies.isEmpty else { return }
        cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

private extension Array where Element == String {
    func hasCaseInsensitiveSuffix(_ suffix: [String]) -> Bool {
        guard count >= suffix.count else { return false }
        return zip(self[(count - suffix.count)...], suffix).allSatisfy {
            $0.0.caseInsensitiveCompare($0.1) == .orderedSame
        }
    }
}
