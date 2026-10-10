import Foundation

/// Five numeric fields: minute, hour, month day, month, weekday (0/7 Sunday).
/// Wildcards, lists, ranges and positive steps are supported. Restricted month
/// day and weekday fields use OR. DST gaps are skipped; a repeated wall time
/// occurs once (the first instance), with its actual UTC occurrence identity.
public struct CronExpression: Sendable {
    private let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    private let dayWildcard: Bool, weekdayWildcard: Bool
    public init(_ expression: String) throws {
        guard expression.utf8.count <= 256 else { throw ScheduleError.invalid("Cron expression exceeds 256 bytes.") }
        let fields = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { throw ScheduleError.invalid("Use five numeric cron fields: minute hour month-day month weekday.") }
        minutes = try Self.field(fields[0], range: 0...59); hours = try Self.field(fields[1], range: 0...23)
        days = try Self.field(fields[2], range: 1...31); months = try Self.field(fields[3], range: 1...12)
        weekdays = Set(try Self.field(fields[4], range: 0...7).map { $0 == 7 ? 0 : $0 })
        dayWildcard = fields[2].hasPrefix("*"); weekdayWildcard = fields[4].hasPrefix("*")
    }
    private static func field(_ text: String, range: ClosedRange<Int>) throws -> Set<Int> {
        var result: Set<Int> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let segments = part.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(segments.count), !segments[0].isEmpty else { throw ScheduleError.invalid("Invalid cron field.") }
            let step: Int
            if segments.count == 2 { guard let value = Int(segments[1]), (1...range.count).contains(value) else { throw ScheduleError.invalid("Invalid cron step.") }; step = value } else { step = 1 }
            let lower: Int, upper: Int
            if segments[0] == "*" { lower = range.lowerBound; upper = range.upperBound }
            else {
                let bounds = segments[0].split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(bounds.count), let first = Int(bounds[0]), range.contains(first) else { throw ScheduleError.invalid("Cron field is out of range.") }
                lower = first
                if bounds.count == 2 { guard let last = Int(bounds[1]), range.contains(last), last >= first else { throw ScheduleError.invalid("Invalid cron range.") }; upper = last }
                else { upper = segments.count == 2 ? range.upperBound : first }
            }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        guard !result.isEmpty else { throw ScheduleError.invalid("Empty cron field.") }; return result
    }
    public func next(after: Date, timezone: TimeZone) throws -> Date {
        guard after.timeIntervalSince1970.isFinite else { throw ScheduleError.invalid("Invalid occurrence time.") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        var day = calendar.startOfDay(for: after)
        let sortedHours = hours.sorted(), sortedMinutes = minutes.sorted()
        for _ in 0..<3660 {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let dom = days.contains(parts.day!), dow = weekdays.contains(parts.weekday! - 1)
            let matchesDay = dayWildcard ? dow && dom : weekdayWildcard ? dom && dow : dom || dow
            if months.contains(parts.month!), matchesDay {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        var desired = parts; desired.weekday = nil; desired.hour = hour; desired.minute = minute; desired.second = 0
                        if let value = calendar.nextDate(after: day.addingTimeInterval(-1), matching: desired, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
                           calendar.isDate(value, inSameDayAs: day), value > after { return value }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }; day = next
        }
        throw ScheduleError.invalid("This cron expression has no occurrence in the next ten years.")
    }
}
