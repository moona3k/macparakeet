import Foundation

public struct DiarizationOptions: Sendable, Equatable {
    public var speakerCountHint: SpeakerCountHint?

    public static let `default` = Self()

    public init(speakerCountHint: SpeakerCountHint? = nil) {
        self.speakerCountHint = speakerCountHint
    }

    public func validate() throws {
        try speakerCountHint?.validate()
    }
}

public struct SpeakerCountHint: Sendable, Codable, Equatable {
    public var exact: Int?
    public var minimum: Int?
    public var maximum: Int?

    public init(exact: Int? = nil, minimum: Int? = nil, maximum: Int? = nil) {
        self.exact = exact
        self.minimum = minimum
        self.maximum = maximum
    }

    public func validate() throws {
        if let exact, exact < 1 {
            throw DiarizationOptionsValidationError.nonPositive(field: "exact", value: exact)
        }
        if let minimum, minimum < 1 {
            throw DiarizationOptionsValidationError.nonPositive(field: "minimum", value: minimum)
        }
        if let maximum, maximum < 1 {
            throw DiarizationOptionsValidationError.nonPositive(field: "maximum", value: maximum)
        }
        if exact != nil && (minimum != nil || maximum != nil) {
            throw DiarizationOptionsValidationError.exactCannotCombineWithRange
        }
        if let minimum, let maximum, minimum > maximum {
            throw DiarizationOptionsValidationError.minimumGreaterThanMaximum(
                minimum: minimum,
                maximum: maximum
            )
        }
    }
}

public enum DiarizationOptionsValidationError: LocalizedError, Equatable, Sendable {
    case nonPositive(field: String, value: Int)
    case exactCannotCombineWithRange
    case minimumGreaterThanMaximum(minimum: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .nonPositive(let field, let value):
            return "Speaker count hint \(field) must be positive; got \(value)."
        case .exactCannotCombineWithRange:
            return "Exact speaker count cannot be combined with minimum or maximum speaker counts."
        case .minimumGreaterThanMaximum(let minimum, let maximum):
            return "Minimum speaker count \(minimum) cannot be greater than maximum speaker count \(maximum)."
        }
    }
}
