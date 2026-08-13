import Foundation

public enum NineRouterAccountAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case turnOffEmpty = "turn_off_empty"
    case turnOnAvailable = "turn_on_available"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .turnOffEmpty: "Turn Off Empty"
        case .turnOnAvailable: "Turn On Available"
        }
    }

    public var systemImage: String {
        switch self {
        case .turnOffEmpty: "pause.circle"
        case .turnOnAvailable: "play.circle"
        }
    }
}

public struct NineRouterRoutingCandidate: Codable, Equatable, Sendable {
    public let label: String
    public let currentIsActive: Bool
    public let remainingPercent: Int
}

public struct NineRouterRoutingPreview: Codable, Equatable, Identifiable, Sendable {
    public var id: String { previewToken }
    public let action: NineRouterAccountAction
    public let previewToken: String
    public let createdAt: String
    public let expiresAt: String
    public let thresholdPercent: Int
    public let inspectedCount: Int
    public let skippedCount: Int
    public let candidateCount: Int
    public let candidates: [NineRouterRoutingCandidate]
}

public struct NineRouterRoutingChange: Codable, Equatable, Sendable {
    public let label: String
    public let isActive: Bool
}

public struct NineRouterRoutingSkip: Codable, Equatable, Sendable {
    public let label: String
    public let reason: String
}

public struct NineRouterRoutingResult: Codable, Equatable, Sendable {
    public let action: NineRouterAccountAction
    public let changedCount: Int
    public let skippedCount: Int
    public let changed: [NineRouterRoutingChange]
    public let skipped: [NineRouterRoutingSkip]
}

public enum NineRouterManualRoutingError: Error, LocalizedError, Equatable {
    case unsupportedProvider
    case invalidResponse
    case unauthorized
    case serverError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "Manual account actions are available only for providers configured as 9Router."
        case .invalidResponse:
            return "9Router returned an invalid account action response."
        case .unauthorized:
            return "The saved API key cannot perform this 9Router account action."
        case let .serverError(status, message):
            return message ?? "9Router could not complete the account action (HTTP \(status))."
        }
    }
}

public final class NineRouterManualRoutingService: @unchecked Sendable {
    private struct RequestBody: Encodable {
        let operation: String
        let action: NineRouterAccountAction
        let previewToken: String?
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func preview(
        action: NineRouterAccountAction,
        provider: CustomQuotaProvider
    ) async throws -> NineRouterRoutingPreview {
        try validate(provider)
        let data = try await send(
            provider: provider,
            body: RequestBody(
                operation: "preview",
                action: action,
                previewToken: nil
            )
        )
        do {
            return try JSONDecoder().decode(NineRouterRoutingPreview.self, from: data)
        } catch {
            throw NineRouterManualRoutingError.invalidResponse
        }
    }

    public func apply(
        preview: NineRouterRoutingPreview,
        provider: CustomQuotaProvider
    ) async throws -> NineRouterRoutingResult {
        try validate(provider)
        let data = try await send(
            provider: provider,
            body: RequestBody(
                operation: "apply",
                action: preview.action,
                previewToken: preview.previewToken
            )
        )
        do {
            return try JSONDecoder().decode(NineRouterRoutingResult.self, from: data)
        } catch {
            throw NineRouterManualRoutingError.invalidResponse
        }
    }

    public func applyCached(
        action: NineRouterAccountAction,
        provider: CustomQuotaProvider
    ) async throws -> NineRouterRoutingResult {
        try validate(provider)
        let data = try await send(
            provider: provider,
            body: RequestBody(
                operation: "apply_cached",
                action: action,
                previewToken: nil
            ),
            timeoutInterval: 15
        )
        do {
            return try JSONDecoder().decode(NineRouterRoutingResult.self, from: data)
        } catch {
            throw NineRouterManualRoutingError.invalidResponse
        }
    }

    private func validate(_ provider: CustomQuotaProvider) throws {
        guard provider.apiKind == .nineRouter else {
            throw NineRouterManualRoutingError.unsupportedProvider
        }
        guard !provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NineRouterManualRoutingError.unauthorized
        }
    }

    private func send(
        provider: CustomQuotaProvider,
        body: RequestBody,
        timeoutInterval: TimeInterval = 180
    ) async throws -> Data {
        let baseURL = try RouterEndpoint.normalizedURL(from: provider.endpoint)
        var request = URLRequest(
            url: QuotaService.quotaURL(from: baseURL),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeoutInterval

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NineRouterManualRoutingError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw NineRouterManualRoutingError.unauthorized
        default:
            let message = try? JSONDecoder().decode(ErrorBody.self, from: data).error
            throw NineRouterManualRoutingError.serverError(http.statusCode, message ?? nil)
        }
    }
}
