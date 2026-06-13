extension Int {
    /// Formats a number compactly: 999 -> "999", 1234 -> "1.2K", 1000000 -> "1M".
    public var compactFormatted: String {
        if self < 1000 {
            return "\(self)"
        } else if self < 1_000_000 {
            let k = Double(self) / 1000
            return k >= 100 ? "\(Int(k))K" : String(format: "%.1fK", k).replacingOccurrences(of: ".0K", with: "K")
        } else {
            let m = Double(self) / 1_000_000
            return m >= 100 ? "\(Int(m))M" : String(format: "%.1fM", m).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    /// Formats milliseconds as a friendly human-readable duration.
    /// e.g. 45000 -> "45 sec", 90000 -> "1.5 min", 8280000 -> "2.3 hr"
    public var friendlyDuration: String {
        let totalSeconds = Double(self) / 1000
        if totalSeconds < 60 {
            return "\(Int(totalSeconds)) sec"
        } else if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            if minutes == Double(Int(minutes)) {
                return "\(Int(minutes)) min"
            }
            return String(format: "%.1f min", minutes)
        } else {
            let hours = totalSeconds / 3600
            if hours == Double(Int(hours)) {
                return "\(Int(hours)) hr"
            }
            return String(format: "%.1f hr", hours)
        }
    }
}

extension Double {
    /// Formats a WPM value: 142.7 -> "143 WPM"
    public var formattedWPM: String {
        "\(Int(rounded())) WPM"
    }
}
