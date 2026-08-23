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
        case until(Date)
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
    var isAllDay: Bool = false
    var hasExplicitTime: Bool = false
    var hasExplicitEnd: Bool = false
    var dayOffset: Int = 0
    var recurrence: RecurrenceSpec?
    var recurrenceEnd: Date?
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

    // "every day", "everyday", "everyd" (partial), "every other monday"
    private static let repeatRegex = try! NSRegularExpression(
        pattern: #"(?i)\bevery\s*(other\s+)?([a-z]+)\b"#
    )

    // "till 29 nov" / "until nov 29th"
    private static let untilDayMonthRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:till|until|til)\s+(?:(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,})|([a-z]{3,})\s+(\d{1,2})(?:st|nd|rd|th)?)(?!\w)"#
    )

    // "till tue"
    private static let untilWordRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:till|until|til)\s+([a-z]{3,})\b"#
    )

    // "till 29th"
    private static let untilBareDayRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:till|until|til)\s+(\d{1,2})(?:st|nd|rd|th)?(?![\w:])"#
    )

    // ">work", ">Personal"
    private static let calendarRegex = try! NSRegularExpression(
        pattern: #"(?<!\S)>([^\s>]+)"#
    )

    // A trailing "at " directly before a time token gets absorbed into the chip cut.
    private static let atPrefixRegex = try! NSRegularExpression(
        pattern: #"(?i)\bat\s+$"#
    )

    /// Recurrence units in ambiguity-priority order: a typed prefix chips the
    /// first unit it matches, so "everyd" → day, "everyw" → week, "everyweekd" → weekday.
    private static let repeatUnits: [(name: String, make: (Int) -> RecurrenceSpec)] = [
        ("day", { .daily(interval: $0) }),
        ("week", { .week(interval: $0) }),
        ("weekday", { _ in .weekdays }),
        ("month", { .monthly(interval: $0) }),
        ("year", { .yearly(interval: $0) }),
        ("monday", { .weekly(weekday: 2, interval: $0) }),
        ("tuesday", { .weekly(weekday: 3, interval: $0) }),
        ("wednesday", { .weekly(weekday: 4, interval: $0) }),
        ("thursday", { .weekly(weekday: 5, interval: $0) }),
        ("friday", { .weekly(weekday: 6, interval: $0) }),
        ("saturday", { .weekly(weekday: 7, interval: $0) }),
        ("sunday", { .weekly(weekday: 1, interval: $0) }),
    ]

    private static let weekdayNames = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static let monthNames = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
        "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
    ]

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current,
                      defaultDurationMinutes: Int = 60) -> ParsedEntry {
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
        func append(_ kind: Token.Kind, _ range: NSRange, removal: NSRange? = nil) {
            tokens.append(Token(kind: kind, range: range, removalRange: removal ?? range,
                                text: ns.substring(with: range)))
        }
        func timeToken(kind: Token.Kind, matchRange: NSRange) {
            var removal = matchRange
            let prefix = NSRange(location: 0, length: matchRange.location)
            if let at = atPrefixRegex.firstMatch(in: input, range: prefix) {
                removal = NSRange(location: at.range.location,
                                  length: NSMaxRange(matchRange) - at.range.location)
            }
            append(kind, matchRange, removal: removal)
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
                timeToken(kind: .time(startMinute: start, endMinute: end), matchRange: m.range)
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
                timeToken(kind: .time(startMinute: start, endMinute: nil), matchRange: m.range)
            }
        }
        if tokens.isEmpty, let m = atBareRegex.firstMatch(in: input, range: full),
           let raw = Int(group(m, 1) ?? ""), raw <= 23 {
            let minute = Int(group(m, 2) ?? "0") ?? 0
            if minute <= 59 {
                let start = resolveSingle(raw: raw, minute: minute, mer: nil)
                // Chip the whole "at 4" — reads better than a bare number.
                append(.time(startMinute: start, endMinute: nil), m.range)
            }
        }

        // --- day ---
        for m in dayRegex.matches(in: input, range: full) where !overlapsExisting(m.range) {
            let offset = m.range(at: 2).location == NSNotFound ? 0 : 1
            append(.day(offset: offset), m.range)
            break
        }

        // --- recurrence ---
        for m in repeatRegex.matches(in: input, range: full) where !overlapsExisting(m.range) {
            let word = (group(m, 2) ?? "").lowercased()
            guard let make = resolveUnit(word) else { continue }
            append(.repeatRule(make(group(m, 1) == nil ? 1 : 2)), m.range)
            break
        }

        entry.tokens = tokens

        // (recurrence end and dates are resolved after tokens below)

        // --- calendar ---
        if let m = calendarRegex.firstMatch(in: input, range: full), !overlapsExisting(m.range),
           let query = group(m, 1) {
            append(.calendar(query: query), m.range)
            entry.tokens = tokens
        }

        // --- pull structured values out of tokens ---
        var timeMinutes: (start: Int, end: Int?)?
        for token in tokens {
            switch token.kind {
            case .time(let s, let e): timeMinutes = (s, e)
            case .day(let offset): entry.dayOffset = offset
            case .repeatRule(let spec): entry.recurrence = spec
            case .calendar(let query): entry.calendarQuery = query
            case .until: break
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
                entry.end = entry.start?.addingTimeInterval(TimeInterval(defaultDurationMinutes * 60))
            }
        } else {
            // No time → all-day event.
            entry.isAllDay = true
            entry.start = dayStart
            entry.end = calendar.date(byAdding: .day, value: 1, to: dayStart)
        }

        // --- recurrence end: "till tue", "until 29th", "till 29 nov" ---
        if entry.recurrence != nil,
           let (date, range) = scanUntil(input, ns: ns, full: full, after: dayStart,
                                         calendar: calendar, overlaps: overlapsExisting, group: group) {
            append(.until(date), range)
            entry.tokens = tokens
            entry.recurrenceEnd = date
            // Re-derive title below with the extra token included.
        }

        // --- title = input minus chips ---
        var title = input as NSString
        for token in tokens.sorted(by: { $0.removalRange.location > $1.removalRange.location }) {
            title = title.replacingCharacters(in: token.removalRange, with: " ") as NSString
        }
        entry.title = (title as String)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return entry
    }

    // MARK: - Until

    private static func scanUntil(
        _ input: String, ns: NSString, full: NSRange, after start: Date, calendar: Calendar,
        overlaps: (NSRange) -> Bool, group: (NSTextCheckingResult, Int) -> String?
    ) -> (Date, NSRange)? {
        func endOfDay(_ date: Date) -> Date {
            calendar.startOfDay(for: date).addingTimeInterval(86399)
        }
        func next(matching comps: DateComponents) -> Date? {
            calendar.nextDate(after: start, matching: comps, matchingPolicy: .nextTime)
        }

        // "till 29 nov" / "until nov 29th"
        if let m = untilDayMonthRegex.firstMatch(in: input, range: full), !overlaps(m.range) {
            let dayStr = group(m, 1) ?? group(m, 4)
            let monthWord = (group(m, 2) ?? group(m, 3) ?? "").lowercased()
            if let dayStr, let day = Int(dayStr), (1...31).contains(day),
               let month = monthNames.first(where: { $0.key.hasPrefix(monthWord) })?.value,
               let date = next(matching: DateComponents(month: month, day: day)) {
                return (endOfDay(date), m.range)
            }
        }
        // "till tue"
        if let m = untilWordRegex.firstMatch(in: input, range: full), !overlaps(m.range) {
            let word = (group(m, 1) ?? "").lowercased()
            if let weekday = weekdayNames.first(where: { $0.key.hasPrefix(word) })?.value,
               let date = next(matching: DateComponents(weekday: weekday)) {
                return (endOfDay(date), m.range)
            }
        }
        // "till 29th"
        if let m = untilBareDayRegex.firstMatch(in: input, range: full), !overlaps(m.range),
           let day = Int(group(m, 1) ?? ""), (1...31).contains(day),
           let date = next(matching: DateComponents(day: day)) {
            return (endOfDay(date), m.range)
        }
        return nil
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

    private static func resolveUnit(_ word: String) -> ((Int) -> RecurrenceSpec)? {
        var w = word
        if let unit = repeatUnits.first(where: { $0.name.hasPrefix(w) }) { return unit.make }
        if w.hasSuffix("s") {   // "mondays", "weekdays"
            w.removeLast()
            if let unit = repeatUnits.first(where: { $0.name.hasPrefix(w) }) { return unit.make }
        }
        return nil
    }
}
