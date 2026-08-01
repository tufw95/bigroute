import Foundation

public enum RouterEndpointError: Error, LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case insecureRemoteURL
    case embeddedCredentials
    case queryOrFragmentNotAllowed

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a complete router URL, for example https://router.example.com."
        case .unsupportedScheme:
            return "Router URL must use HTTPS. HTTP is allowed only for localhost development."
        case .insecureRemoteURL:
            return "Remote router URLs must use HTTPS so the API key is encrypted in transit."
        case .embeddedCredentials:
            return "Do not include a username or password in the router URL."
        case .queryOrFragmentNotAllowed:
            return "Router URL cannot contain a query string or fragment."
        }
    }
}

public enum RouterEndpoint {
    public static func normalizedURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw RouterEndpointError.invalidURL
        }

        guard scheme == "https" || scheme == "http" else {
            throw RouterEndpointError.unsupportedScheme
        }
        if scheme == "http", !isLoopbackHost(host) {
            throw RouterEndpointError.insecureRemoteURL
        }
        guard components.user == nil, components.password == nil else {
            throw RouterEndpointError.embeddedCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw RouterEndpointError.queryOrFragmentNotAllowed
        }

        components.scheme = scheme
        components.host = host
        var pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        if pathParts.count >= 2,
           pathParts[pathParts.count - 2].caseInsensitiveCompare("v1") == .orderedSame,
           pathParts.last?.caseInsensitiveCompare("models") == .orderedSame {
            pathParts.removeLast(2)
        } else if pathParts.last?.caseInsensitiveCompare("v1") == .orderedSame {
            pathParts.removeLast()
        }
        components.path = pathParts.isEmpty ? "" : "/\(pathParts.joined(separator: "/"))"

        guard let url = components.url else {
            throw RouterEndpointError.invalidURL
        }
        return url
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }
}
