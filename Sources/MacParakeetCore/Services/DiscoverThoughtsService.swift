import Foundation
import OSLog

public protocol DiscoverThoughtsServiceProtocol: Sendable {
    func submitThought(_ message: String) async throws
}

public final class DiscoverThoughtsService: DiscoverThoughtsServiceProtocol {
    private let endpoint: URL
    private let session: URLSession
    private let log = Logger(subsystem: "com.macparakeet.app", category: "DiscoverThoughts")

    public init(
        endpoint: URL? = nil,
        session: URLSession = .shared
    ) {
        if let endpoint {
            self.endpoint = endpoint
        } else if let envURL = ProcessInfo.processInfo.environment["MACPARAKEET_DISCOVER_THOUGHTS_URL"],
                  let url = URL(string: envURL) {
            self.endpoint = url
        } else {
            self.endpoint = URL(string: "https://macparakeet.com/api/discover-thoughts")!
        }
        self.session = session
    }

    public func submitThought(_ message: String) async throws {
        let sysInfo = SystemInfo.current
        let payload: [String: Any] = [
            "message": message,
            "system_info": [
                "app_version": sysInfo.appVersion,
                "build_number": sysInfo.buildNumber,
                "mac_os_version": sysInfo.macOSVersion,
                "chip_type": sysInfo.chipType,
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw DiscoverThoughtsError.encodingFailed
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DiscoverThoughtsError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            log.warning("Discover thought submission failed: \(snippet)")
            throw DiscoverThoughtsError.serverError
        }
    }
}

public enum DiscoverThoughtsError: Error, LocalizedError {
    case encodingFailed
    case network(String)
    case serverError

    public var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to encode thought."
        case .network(let detail): return "Network error: \(detail)"
        case .serverError: return "Server error. Please try again."
        }
    }
}
