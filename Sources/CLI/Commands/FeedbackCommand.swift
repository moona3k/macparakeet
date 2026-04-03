import ArgumentParser
import Foundation
import MacParakeetCore

enum FeedbackCategoryArg: String, ExpressibleByArgument, CaseIterable {
    case bug
    case feature
    case other

    var toFeedbackCategory: FeedbackCategory {
        switch self {
        case .bug: return .bug
        case .feature: return .featureRequest
        case .other: return .other
        }
    }
}

struct FeedbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "feedback",
        abstract: "Submit feedback from the CLI.",
        discussion: "Categories: bug, feature, other."
    )

    @Option(name: .shortAndLong, help: "Category: bug, feature, other.")
    var category: FeedbackCategoryArg = .other

    @Argument(help: "Feedback message.")
    var message: String

    @Option(name: .shortAndLong, help: "Your email (optional, for follow-up).")
    var email: String?

    func run() async throws {
        let systemInfo = SystemInfo.current

        let payload = FeedbackPayload(
            category: category.toFeedbackCategory,
            message: message,
            email: email,
            screenshotBase64: nil,
            screenshotFilename: nil,
            systemInfo: systemInfo
        )

        let service = FeedbackService()

        print("Submitting feedback...")
        try await service.submitFeedback(payload)
        print("Feedback submitted. Thank you!")
    }
}
