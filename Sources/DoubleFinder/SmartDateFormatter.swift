import Foundation

/// Renders dates in a Finder-like, time-of-day-aware style:
///   - Today        →  "Today 14:32"
///   - Yesterday    →  "Yesterday 14:32"
///   - This week    →  "Mon 14:32"
///   - This year    →  "17 May"
///   - Older        →  "17 May 2024"
///
/// Cached `DateFormatter` instances keep the call cheap when rendering long
/// listings. The cache is invalidated whenever the user's locale changes.
enum SmartDateFormatter {
    static func string(from date: Date, relativeTo reference: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today \(timeOnly.string(from: date))"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday \(timeOnly.string(from: date))"
        }
        let now = reference
        let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        // Recent (last 6 days) → "Mon 14:32".
        if daysAgo >= 0, daysAgo < 7 {
            return "\(weekdayShort.string(from: date)) \(timeOnly.string(from: date))"
        }
        // Same year → drop the year.
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dayMonth.string(from: date)
        }
        return dayMonthYear.string(from: date)
    }

    // MARK: - Cached formatters
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEE"
        return f
    }()
    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()
    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        return f
    }()
}
