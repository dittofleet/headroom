import Foundation

public enum Format {
    /// Rounded down, so 100 only ever means actually out.
    public static func wholePercent(_ value: Double) -> Int {
        Int(value.rounded(.down))
    }

    public static func percent(_ value: Double) -> String {
        "\(wholePercent(value))%"
    }

    /// "1h 44m", "5d 7h", "12m", "now".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    /// "Resets 9:40 PM · in 1h 44m" or "Resets Thu 3:00 AM · in 5d 7h".
    public static func reset(_ resetsAt: Date?, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let resetsAt else { return "No active window" }
        guard resetsAt > now else { return "Window reset" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(resetsAt, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return "Resets \(formatter.string(from: resetsAt)) · in \(duration(resetsAt.timeIntervalSince(now)))"
    }

    /// An id with no name of its own, readable anyway: "edu_plus" is "Edu Plus".
    public static func title(_ id: String) -> String {
        // Not `capitalized`, which would make "4o" "4O".
        id.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    public static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 90 ? "just now" : "\(duration(seconds)) ago"
    }
}
