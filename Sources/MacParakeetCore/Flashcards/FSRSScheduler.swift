import Foundation

public struct FSRSMemoryState: Equatable, Sendable {
    public var stability: Double
    public var difficulty: Double
    public var phase: FlashcardPhase
    public var learningStep: Int
    public var lastReview: Date

    public init(stability: Double, difficulty: Double, phase: FlashcardPhase, learningStep: Int, lastReview: Date) {
        self.stability = stability
        self.difficulty = difficulty
        self.phase = phase
        self.learningStep = learningStep
        self.lastReview = lastReview
    }
}

public struct FSRSSchedule: Equatable, Sendable {
    public let state: FSRSMemoryState
    public let dueAt: Date
    public let scheduledDays: Double
    public let elapsedDays: Double
}

/// Deterministic FSRS-6 scheduler with the canonical 21 default parameters.
/// Ported from LinguaBrain-AI (`PrototypeFSRS6Scheduler`); formulas and
/// defaults follow open-spaced-repetition/swift-fsrs FSRS-6.0.
public struct FSRSScheduler: Sendable {
    public static let version = "FSRS-6.0/default-21"
    public static let desiredRetention = 0.9

    private let w: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133,
        0.8334, 3.0194, 0.001, 1.8722, 0.1666,
        0.796, 1.4835, 0.0614, 0.2629, 1.6483,
        0.6014, 1.8729, 0.5425, 0.0912, 0.0658,
        0.1542,
    ]

    public init() {}

    public func schedule(previous: FSRSMemoryState?, grade: FlashcardGrade, now: Date) -> FSRSSchedule {
        let elapsedDays = previous.map { calendarDayDifference(from: $0.lastReview, to: now) } ?? 0
        let memory = nextMemoryState(previous: previous, elapsedDays: elapsedDays, grade: grade)
        let timing = nextTiming(
            previousPhase: previous?.phase ?? .new,
            previousStep: previous?.learningStep ?? 0,
            grade: grade,
            stability: memory.stability
        )
        let state = FSRSMemoryState(
            stability: memory.stability,
            difficulty: memory.difficulty,
            phase: timing.phase,
            learningStep: timing.learningStep,
            lastReview: now
        )
        return FSRSSchedule(
            state: state,
            dueAt: now.addingTimeInterval(timing.seconds),
            scheduledDays: timing.seconds / 86_400,
            elapsedDays: elapsedDays
        )
    }

    public func retrievability(state: FSRSMemoryState, at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(state.lastReview) / 86_400)
        return forgettingCurve(elapsedDays: elapsed, stability: state.stability)
    }

    private func nextMemoryState(
        previous: FSRSMemoryState?,
        elapsedDays: Double,
        grade: FlashcardGrade
    ) -> (stability: Double, difficulty: Double) {
        guard let previous, previous.stability >= 0.001, previous.difficulty >= 1 else {
            return (initialStability(grade), initialDifficulty(grade))
        }

        let rating = Double(grade.rawValue)
        let retrievability = forgettingCurve(elapsedDays: elapsedDays, stability: previous.stability)
        let difficulty = nextDifficulty(previous.difficulty, grade: grade)
        // FSRS-6 treats all reviews in the same UTC calendar day as t = 0.
        let stability: Double

        if elapsedDays == 0 {
            let increase = pow(previous.stability, -w[19]) * exp(w[17] * (rating - 3 + w[18]))
            let bounded = grade == .again ? increase : max(increase, 1)
            stability = clamp(previous.stability * bounded, 0.001, 36_500)
        } else if grade == .again {
            let failed =
                w[11]
                * pow(previous.difficulty, -w[12])
                * (pow(previous.stability + 1, w[13]) - 1)
                * exp(w[14] * (1 - retrievability))
            let minimum = previous.stability / exp(w[17] * w[18])
            stability = clamp(minimum, 0.001, failed)
        } else {
            let hardPenalty = grade == .hard ? w[15] : 1
            let easyBonus = grade == .easy ? w[16] : 1
            let recalled =
                previous.stability
                * (1
                    + exp(w[8])
                    * (11 - previous.difficulty)
                    * pow(previous.stability, -w[9])
                    * (exp((1 - retrievability) * w[10]) - 1)
                    * hardPenalty
                    * easyBonus)
            stability = clamp(recalled, 0.001, 36_500)
        }

        return (stability, difficulty)
    }

    private func nextTiming(
        previousPhase: FlashcardPhase,
        previousStep: Int,
        grade: FlashcardGrade,
        stability: Double
    ) -> (seconds: TimeInterval, phase: FlashcardPhase, learningStep: Int) {
        switch previousPhase {
        case .new:
            switch grade {
            case .again: return (60, .learning, 0)
            case .hard: return (6 * 60, .learning, 0)
            case .good: return (10 * 60, .learning, 1)
            case .easy: return (daysInterval(stability), .review, 0)
            }
        case .learning:
            switch grade {
            case .again: return (60, .learning, 0)
            case .hard: return (6 * 60, .learning, previousStep)
            case .good where previousStep == 0: return (10 * 60, .learning, 1)
            case .good, .easy: return (daysInterval(stability), .review, 0)
            }
        case .review:
            if grade == .again { return (10 * 60, .relearning, 0) }
            return (daysInterval(stability), .review, 0)
        case .relearning:
            switch grade {
            case .again: return (10 * 60, .relearning, 0)
            case .hard: return (15 * 60, .relearning, 0)
            case .good, .easy: return (daysInterval(stability), .review, 0)
            }
        }
    }

    private func initialStability(_ grade: FlashcardGrade) -> Double {
        max(w[grade.rawValue - 1], 0.1)
    }

    private func initialDifficulty(_ grade: FlashcardGrade) -> Double {
        clamp(w[4] - exp(Double(grade.rawValue - 1) * w[5]) + 1, 1, 10)
    }

    private func nextDifficulty(_ difficulty: Double, grade: FlashcardGrade) -> Double {
        let delta = -w[6] * Double(grade.rawValue - 3)
        let damped = delta * (10 - difficulty) / 9
        let initialEasy = w[4] - exp(3 * w[5]) + 1
        return clamp(w[7] * initialEasy + (1 - w[7]) * (difficulty + damped), 1, 10)
    }

    private func forgettingCurve(elapsedDays: Double, stability: Double) -> Double {
        let decay = -w[20]
        let factor = exp(log(0.9) / decay) - 1
        return pow(1 + factor * elapsedDays / stability, decay)
    }

    private func daysInterval(_ stability: Double) -> TimeInterval {
        let decay = -w[20]
        let factor = exp(log(0.9) / decay) - 1
        let modifier = (pow(Self.desiredRetention, 1 / decay) - 1) / factor
        let days = min(max(1, (stability * modifier).rounded()), 36_500)
        return days * 86_400
    }

    private func calendarDayDifference(from start: Date, to end: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return max(0, floor(endDay.timeIntervalSince(startDay) / 86_400))
    }

    private func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}

extension FSRSSchedule {
    /// Short label for a rating button, e.g. "1m", "10m", "3d", "2mo".
    public var intervalLabel: String {
        let seconds = scheduledDays * 86_400
        if seconds < 3_600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 86_400 { return "\(Int((seconds / 3_600).rounded()))h" }
        if scheduledDays < 30 { return "\(Int(scheduledDays.rounded()))d" }
        if scheduledDays < 365 { return "\(Int((scheduledDays / 30).rounded()))mo" }
        return String(format: "%.1fy", scheduledDays / 365)
    }
}
