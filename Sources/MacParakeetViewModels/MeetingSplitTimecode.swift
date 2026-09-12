import Foundation

/// Manual elapsed-time entry, independent of locale and wall-clock dates.
public enum MeetingSplitTimecode {
    public static func parse(_ text: String) -> Int? {
        let components = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        func number(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(value)
        }
        let secondsParts = components.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard secondsParts.count <= 2, let seconds = number(secondsParts[0]), seconds < 60 else { return nil }
        var fraction = 0
        if secondsParts.count == 2 {
            guard secondsParts[1].count <= 3, let value = number(secondsParts[1]) else { return nil }
            fraction = value * (secondsParts[1].count == 1 ? 100 : secondsParts[1].count == 2 ? 10 : 1)
        }
        guard let first = number(components[0]) else { return nil }
        var minutes = first
        if components.count == 3 {
            guard let remainder = number(components[1]), remainder < 60 else { return nil }
            let hours = first.multipliedReportingOverflow(by: 60)
            let total = hours.partialValue.addingReportingOverflow(remainder)
            guard !hours.overflow, !total.overflow else { return nil }
            minutes = total.partialValue
        }
        let base = minutes.multipliedReportingOverflow(by: 60_000)
        let result = base.partialValue.addingReportingOverflow(seconds * 1_000 + fraction)
        return base.overflow || result.overflow ? nil : result.partialValue
    }

    public static func format(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        let seconds = value / 1_000
        let clock = seconds >= 3_600
            ? String(format: "%lld:%02lld:%02lld", Int64(seconds / 3_600), Int64(seconds / 60 % 60), Int64(seconds % 60))
            : String(format: "%lld:%02lld", Int64(seconds / 60), Int64(seconds % 60))
        guard value % 1_000 != 0 else { return clock }
        return clock + String(format: ".%03lld", Int64(value % 1_000))
    }
}
