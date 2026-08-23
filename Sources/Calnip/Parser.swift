import Foundation

enum RecurrenceSpec: Equatable {
    case daily(interval: Int)
    case weekdays
    case week(interval: Int)                    // weekly on the start date's weekday
    case weekly(weekday: Int, interval: Int)    // 1 = Sunday … 7 = Saturday
    case monthly(interval: Int)
    case yearly(interval: Int)

    var label: String {
        let names = Calendar.current.weekdaySymbols
        switch self {
        case .daily(interval: 1): return "Every day"
        case .daily: return "Every other day"
        case .weekdays: return "Every weekday"
        case .week(interval: 1): return "Every week"
        case .week: return "Every other week"
        case .weekly(let weekday, let interval):
            let name = names[weekday - 1]
            return interval == 1 ? "Every \(name)" : "Every other \(name)"
        case .monthly(interval: 1): return "Every month"
        case .monthly: return "Every other month"
        case .yearly(interval: 1): return "Every year"
        case .yearly: return "Every other year"
        }
    }
}

/// A recognized chip in the input string.
struct Token: Equatable {
    enum Kind: Equatable {
        /// Minutes from midnight; end may exceed 24h (crosses into next day).
        case time(startMinute: Int, endMinute: Int?)
        case day(offset: Int)   // 0 = today, 1 = tomorrow
        case repeatRule(RecurrenceSpec)
        case calendar(query: String)
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
    var hasExplicitEnd: Bool = false
    var dayOffset: Int = 0
    var recurrence: RecurrenceSpec?
    var calendarQuery: String?
}

enum Parser {

    // "2-4", "2-4pm", "2:30pm-4", "14:00-15:30"
    private static let rangeRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w:.-])(\d{1,2})(?::(\d{2}))?\s*(am|pm|a|p)?\s*[-–—]\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a|p)?(?![\w:-])"#
    )

    // "2pm", "2 pm", "2:30pm", "14:00", "4a" — a bare number is NOT a time…
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w:.])(?:(\d{1,2}):(\d{2})\s*(am|pm|a|p)?|(\d{1,2})\s*(am|pm)|(\d{1,2})(a|p))(?![\w:])"#
    )

    // …unless it follows "at": "gym every weekday at 4" → 4pm.
    private static let atBareRegex = try! NSRegularExpression(
        pattern: #"(?i)\bat\s+(\d{1,2})(?::(\d{2}))?(?![\w:-])"#
    )

    private static let dayRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:(tod(?:ay)?)|(tom(?:orrow)?))\b"#
    )

    // "every weekday", "every other monday", "every day/week/month/year"
    private static let repeatRegex = try! NSRegularExpression(
        pattern: #"(?i)\bevery\s+(other\s+)?(weekday|day|week|month|year|monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun)s?\b"#
    )

    // ">work", ">Personal"
    private static let calendarRegex = try! NSRegularExpression(
        pattern: #"(?<!\S)>([^\s>]+)"#
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

        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func overlapsExisting(_ range: NSRange) -> Bool {
            tokens.contains { NSIntersectionRange($0.range, range).length > 0 }
        }
        func timeToken(kind: Token.Kind, matchRange: NSRange) -> Token {
            var removal = matchRange
            let prefix = NSRange(location: 0, length: matchRange.location)
            if let at = atPrefixRegex.firstMatch(in: input, range: prefix) {
                removal = NSRange(location: at.range.location,
                                  length: NSMaxRange(matchRange) - at.range.location)
            }
            return Token(kind: kind, range: matchRange, removalRange: removal,
                         text: ns.substring(with: matchRange))
        }

        // --- time: range first, then single, then bare "at N" ---
        if let m = rangeRegex.firstMatch(in: input, range: full),
           let rawS = Int(group(m, 1) ?? ""), let rawE = Int(group(m, 4) ?? ""),
           rawS <= 23, rawE <= 23 {
            let minS = Int(group(m, 2) ?? "0") ?? 0
            let minE = Int(group(m, 5) ?? "0") ?? 0
            if minS <= 59, minE <= 59,
               let (start, end) = resolveRange(rawS: rawS, minS: minS, merS: meridiem(group(m, 3)),
                                               rawE: rawE, minE: minE, merE: meridiem(group(m, 6))) {
                tokens.append(timeToken(kind: .time(startMinute: start, endMinute: end), matchRange: m.range))
            }
        }
        if tokens.isEmpty, let m = timeRegex.firstMatch(in: input, range: full) {
            var raw = 0, minute = 0
            var mer: Character?
            if let h = group(m, 1) {                       // "2:30", "2:30pm", "14:00"
                raw = Int(h) ?? 0
                minute = Int(group(m, 2) ?? "0") ?? 0
                mer = meridiem(group(m, 3))
            } else if let h = group(m, 4) {                // "2pm", "2 pm"
                raw = Int(h) ?? 0
                mer = meridiem(group(m, 5))
            } else if let h = group(m, 6) {                // "4a", "4p"
                raw = Int(h) ?? 0
                mer = meridiem(group(m, 7))
            }
            if raw <= 23, minute <= 59 {
                let start = resolveSingle(raw: raw, minute: minute, mer: mer)
                tokens.append(timeToken(kind: .time(startMinute: start, endMinute: nil), matchRange: m.range))
            }
        }
        if tokens.isEmpty, let m = atBareRegex.firstMatch(in: input, range: full),
           let raw = Int(group(m, 1) ?? ""), raw <= 23 {
            let minute = Int(group(m, 2) ?? "0") ?? 0
            if minute <= 59 {
                let start = resolveSingle(raw: raw, minute: minute, mer: nil)
                // Chip the whole "at 4" — reads better than a bare number.
                tokens.append(Token(kind: .time(startMinute: start, endMinute: nil),
                                    range: m.range, removalRange: m.range,
                                    text: ns.substring(with: m.range)))
            }
        }

        // --- day ---
        for m in dayRegex.matches(in: input, range: full) where !overlapsExisting(m.range) {
            let offset = m.range(at: 2).location == NSNotFound ? 0 : 1
            tokens.append(Token(kind: .day(offset: offset), range: m.range,
                                removalRange: m.range, text: ns.substring(with: m.range)))
            break
        }

        // --- recurrence ---
        if let m = repeatRegex.firstMatch(in: input, range: full), !overlapsExisting(m.range),
           let spec = recurrenceSpec(word: group(m, 2) ?? "", other: group(m, 1) != nil) {
            tokens.append(Token(kind: .repeatRule(spec), range: m.range,
                                removalRange: m.range, text: ns.substring(with: m.range)))
        }

        // --- calendar ---
        if let m = calendarRegex.firstMatch(in: input, range: full), !overlapsExisting(m.range),
           let query = group(m, 1) {
            tokens.append(Token(kind: .calendar(query: query), range: m.range,
                                removalRange: m.range, text: ns.substring(with: m.range)))
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

        // --- pull structured values out of tokens ---
        var timeMinutes: (start: Int, end: Int?)?
        for token in tokens {
            switch token.kind {
            case .time(let s, let e): timeMinutes = (s, e)
            case .day(let offset): entry.dayOffset = offset
            case .repeatRule(let spec): entry.recurrence = spec
            case .calendar(let query): entry.calendarQuery = query
            }
        }

        // --- resolve dates ---
        var baseDay = calendar.date(byAdding: .day, value: entry.dayOffset, to: now) ?? now
        switch entry.recurrence {
        case .weekly(let weekday, _):
            // First occurrence lands on that weekday.
            while calendar.component(.weekday, from: baseDay) != weekday {
                baseDay = calendar.date(byAdding: .day, value: 1, to: baseDay) ?? baseDay
            }
        case .weekdays:
            while calendar.isDateInWeekend(baseDay) {
                baseDay = calendar.date(byAdding: .day, value: 1, to: baseDay) ?? baseDay
            }
        default:
            break
        }
        let dayStart = calendar.startOfDay(for: baseDay)

        if let (startMin, endMin) = timeMinutes {
            entry.hasExplicitTime = true
            entry.start = dayStart.addingTimeInterval(TimeInterval(startMin * 60))
            if let endMin {
                entry.hasExplicitEnd = true
                entry.end = dayStart.addingTimeInterval(TimeInterval(endMin * 60))
            } else {
                entry.end = entry.start?.addingTimeInterval(3600)
            }
        } else {
            // Default: next full hour.
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: baseDay)
            let start = calendar.date(from: comps).flatMap { calendar.date(byAdding: .hour, value: 1, to: $0) } ?? baseDay
            entry.start = start
            entry.end = start.addingTimeInterval(3600)
        }

        return entry
    }

    // MARK: - Time resolution

    private static func meridiem(_ s: String?) -> Character? {
        s?.lowercased().first
    }

    private static func apply(raw: Int, minute: Int, mer: Character) -> Int {
        var hour = raw
        if mer == "p", hour < 12 { hour += 12 }
        if mer == "a", hour == 12 { hour = 0 }
        return hour * 60 + minute
    }

    /// No am/pm: 24h values pass through; small hours lean afternoon
    /// (IDEA.md: "Gym every weekday at 4" chips to 4pm).
    private static func inferBare(raw: Int, minute: Int) -> Int {
        let hour = (1...7).contains(raw) ? raw + 12 : raw
        return hour * 60 + minute
    }

    private static func resolveSingle(raw: Int, minute: Int, mer: Character?) -> Int {
        if let mer { return apply(raw: raw, minute: minute, mer: mer) }
        return inferBare(raw: raw, minute: minute)
    }

    /// Possible clock readings of an ambiguous hour, ascending.
    private static func candidates(raw: Int, minute: Int) -> [Int] {
        switch raw {
        case 0: return [minute]
        case 1...11: return [raw * 60 + minute, (raw + 12) * 60 + minute]
        case 12: return [12 * 60 + minute, 24 * 60 + minute]   // noon or midnight
        default: return [raw * 60 + minute]
        }
    }

    private static func resolveRange(rawS: Int, minS: Int, merS: Character?,
                                     rawE: Int, minE: Int, merE: Character?) -> (Int, Int)? {
        let start: Int
        if let merS {
            start = apply(raw: rawS, minute: minS, mer: merS)
        } else if let merE {
            // "11-1pm" → pick the latest reading that still precedes the end.
            let end = apply(raw: rawE, minute: minE, mer: merE)
            start = candidates(raw: rawS, minute: minS).filter { $0 < end }.max()
                ?? inferBare(raw: rawS, minute: minS)
        } else {
            start = inferBare(raw: rawS, minute: minS)
        }

        let end: Int
        if let merE {
            let e = apply(raw: rawE, minute: minE, mer: merE)
            end = e > start ? e : e + 24 * 60   // "11pm-1am" crosses midnight
        } else {
            // Earliest reading after the start; else assume next day.
            let cands = candidates(raw: rawE, minute: minE)
            end = cands.first { $0 > start } ?? (cands[0] + 24 * 60)
        }
        guard end > start else { return nil }
        return (start, end)
    }

    // MARK: - Recurrence

    private static func recurrenceSpec(word: String, other: Bool) -> RecurrenceSpec? {
        let interval = other ? 2 : 1
        let weekdays = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        switch word.lowercased() {
        case "day": return .daily(interval: interval)
        case "weekday": return .weekdays
        case "week": return .week(interval: interval)
        case "month": return .monthly(interval: interval)
        case "year": return .yearly(interval: interval)
        default:
            guard let weekday = weekdays[String(word.lowercased().prefix(3))] else { return nil }
            return .weekly(weekday: weekday, interval: interval)
        }
    }
}
