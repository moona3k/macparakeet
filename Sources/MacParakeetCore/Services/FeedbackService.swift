import Foundation

// MARK: - Feedback Types

public enum FeedbackCategory: String, Sendable, Codable, CaseIterable {
    case bug
    case featureRequest
    case other

    public var displayName: String {
        switch self {
        case .bug: return "Bug Report"
        case .featureRequest: return "Feature Request"
        case .other: return "Other"
        }
    }
}

public struct FeedbackPayload: Sendable, Encodable {
    public let category: FeedbackCategory
    public let message: String
    public let email: String?
    public let screenshotBase64: String?
    public let screenshotFilename: String?
    public let screenshots: [FeedbackScreenshot]
    public let diagnosticLog: FeedbackDiagnosticLog?
    public let systemInfo: SystemInfo

    public init(
        category: FeedbackCategory,
        message: String,
        email: String?,
        screenshotBase64: String?,
        screenshotFilename: String?,
        screenshots: [FeedbackScreenshot] = [],
        diagnosticLog: FeedbackDiagnosticLog? = nil,
        systemInfo: SystemInfo
    ) {
        let normalizedScreenshots: [FeedbackScreenshot]
        if screenshots.isEmpty,
           let screenshotBase64,
           let screenshotFilename {
            normalizedScreenshots = [
                FeedbackScreenshot(filename: screenshotFilename, base64: screenshotBase64),
            ]
        } else {
            normalizedScreenshots = screenshots
        }

        self.category = category
        self.message = message
        self.email = email
        self.screenshotBase64 = normalizedScreenshots.first?.base64 ?? screenshotBase64
        self.screenshotFilename = normalizedScreenshots.first?.filename ?? screenshotFilename
        self.screenshots = normalizedScreenshots
        self.diagnosticLog = diagnosticLog
        self.systemInfo = systemInfo
    }
}

public struct FeedbackScreenshot: Sendable, Encodable, Equatable {
    public let filename: String
    public let base64: String

    public init(filename: String, base64: String) {
        self.filename = filename
        self.base64 = base64
    }
}

public struct FeedbackDiagnosticLog: Sendable, Encodable, Equatable {
    public let filename: String
    public let base64: String

    public init(filename: String, base64: String) {
        self.filename = filename
        self.base64 = base64
    }
}

// MARK: - Errors

public enum FeedbackError: Error, LocalizedError, Sendable, Equatable {
    case emptyMessage
    case network(String)
    case serverError(Int, String)
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .emptyMessage:
            return "Please enter a message before submitting."
        case .network(let detail):
            return "Network error: \(detail)"
        case .serverError(let code, let detail):
            return "Server error (\(code)): \(detail)"
        case .encodingFailed:
            return "Failed to encode feedback payload."
        }
    }
}

// MARK: - Protocol

public protocol FeedbackServiceProtocol: Sendable {
    func submitFeedback(_ feedback: FeedbackPayload) async throws
}

// MARK: - Implementation

public final class FeedbackService: FeedbackServiceProtocol {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL? = nil,
        session: URLSession = .shared
    ) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let envURL = ProcessInfo.processInfo.environment["MACPARAKEET_FEEDBACK_URL"],
                  let url = URL(string: envURL) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://macparakeet.com/api")!
        }
        self.session = session
    }

    public func submitFeedback(_ feedback: FeedbackPayload) async throws {
        let trimmed = feedback.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FeedbackError.emptyMessage
        }

        let normalizedFeedback = FeedbackPayload(
            category: feedback.category,
            message: trimmed,
            email: feedback.email,
            screenshotBase64: feedback.screenshotBase64,
            screenshotFilename: feedback.screenshotFilename,
            screenshots: feedback.screenshots,
            diagnosticLog: feedback.diagnosticLog,
            systemInfo: feedback.systemInfo
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        guard let body = try? encoder.encode(normalizedFeedback) else {
            throw FeedbackError.encodingFailed
        }

        let url = baseURL.appendingPathComponent("feedback")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedbackError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedbackError.network("Invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw FeedbackError.serverError(http.statusCode, snippet)
        }
    }
}
