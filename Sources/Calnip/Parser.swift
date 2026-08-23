import Foundation

/// A recognized chip in the input string.
struct Token: Equatable {
    enum Kind: Equatable {
        case time(hour: Int, minute: Int)
        case day(offset: Int)   // 0 = today, 1 = tomorrow
    }

    let kind: Kind
    /// UTF-16 range in the original string (for NSTextStorage highlighting).
    let range: NSRange
    /// Range to cut when deriving the title (may include a preceding "at ").
    let removalRange: NSRange
    let text: String
}

/// Result of parsing one line of quick-entry input.
struct ParsedEntry: Equatable {
    var title: String = ""
    var tokens: [Token] = []
    var start: Date?
    var end: Date?
    var hasExplicitTime: Bool = false
    var dayOffset: Int = 0

    var timeToken: Token? {
        tokens.first { if case .time = $0.kind { return true }; return false }
    }
    var dayToken: Token? {
        tokens.first { if case .day = $0.kind { return true }; return false }
    }
}

enum Parser {

    // Time: "2pm", "2 pm", "2:30pm", "14:00", "4a" — a bare number is NOT a time.
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w:.])(?:(\d{1,2}):(\d{2})\s*(am|pm|a|p)?|(\d{1,2})\s*(am|pm)|(\d{1,2})(a|p))(?![\w:])"#
    )

    // Day words: tod / today / tom / tomorrow
    private static let dayRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:(tod(?:ay)?)|(tom(?:orrow)?))\b"#
    )

    // A trailing "at " directly before a time token gets absorbed into the chip cut.
    private static let atPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)\bat\s+$"#
    )

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedEntry {
        let ns = input as NSString
        let full = NSRange(location: 0, length: ns.length)
        var entry = ParsedEntry()
        var tokens: [Token] = []

        // --- time (first match wins) ---
        if let m = timeRegex.firstMatch(in: input, range: full) {
            var hour = 0, minute = 0
            var meridiem: String?

            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }

            if let h = group(1) {                       // "2:30", "2:30pm", "14:00"
                hour = Int(h) ?? 0
                minute = Int(group(2) ?? "0") ?? 0
                meridiem = group(3)
            } else if let h = group(4) {                // "2pm", "2 pm"
                hour = Int(h) ?? 0
                meridiem = group(5)
            } else if let h = group(6) {                // "4a", "4p"
                hour = Int(h) ?? 0
                meridiem = group(7)
            }

            switch meridiem?.lowercased().first {
            case "p": if hour < 12 { hour += 12 }
            case "a": if hour == 12 { hour = 0 }
            default:
                // No am/pm: 24h values pass through; small hours lean afternoon
                // (IDEA.md: "Gym every weekday at 4" chips to 4pm).
                if (1...7).contains(hour) { hour += 12 }
            }

            if hour <= 23, minute <= 59 {
                var removal = m.range
                let prefix = NSRange(location: 0, length: m.range.location)
                if let at = atPrefixRegex.firstMatch(in: input, range: prefix) {
                    removal = NSRange(location: at.range.location,
                                      length: NSMaxRange(m.range) - at.range.location)
                }
                tokens.append(Token(kind: .time(hour: hour, minute: minute),
                                    range: m.range,
                                    removalRange: removal,
                                    text: ns.substring(with: m.range)))
            }
        }

        // --- day (first match not overlapping a time token) ---
        for m in dayRegex.matches(in: input, range: full) {
            guard !tokens.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
            let offset = m.range(at: 2).location == NSNotFound ? 0 : 1
            tokens.append(Token(kind: .day(offset: offset),
                                range: m.range,
                                removalRange: m.range,
                                text: ns.substring(with: m.range)))
            break
        }

        entry.tokens = tokens

        // --- title = input minus chips ---
        var title = input as NSString
        for token in tokens.sorted(by: { $0.removalRange.location > $1.removalRange.location }) {
            title = title.replacingCharacters(in: token.removalRange, with: " ") as NSString
        }
        entry.title = (title as String)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // --- resolve dates ---
        if case let .day(offset)? = entry.dayToken?.kind { entry.dayOffset = offset }
        let baseDay = calendar.date(byAdding: .day, value: entry.dayOffset, to: now) ?? now

        var start: Date
        if case let .time(hour, minute)? = entry.timeToken?.kind {
            entry.hasExplicitTime = true
            start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDay) ?? baseDay
        } else {
            // Default: next full hour.
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: baseDay)
            start = calendar.date(from: comps).flatMap { calendar.date(byAdding: .hour, value: 1, to: $0) } ?? baseDay
        }
        entry.start = start
        entry.end = start.addingTimeInterval(3600)

        return entry
    }
}
