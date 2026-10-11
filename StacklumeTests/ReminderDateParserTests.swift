import Foundation
import Testing

@Suite("Recordatorios — fechas acotadas")
struct ReminderDateParserTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test("Interpreta días y semanas normales")
    func parsesNormalIntervals() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twoDays = ReminderDateParser.date(for: "en 2 días", now: now, calendar: calendar)
        let twoWeeks = ReminderDateParser.date(for: "en dos semanas", now: now, calendar: calendar)
        let expectedTwoDays = calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: calendar.date(byAdding: .day, value: 2, to: now)!
        )
        let expectedTwoWeeks = calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: calendar.date(byAdding: .day, value: 14, to: now)!
        )

        #expect(twoDays == expectedTwoDays)
        #expect(twoWeeks == expectedTwoWeeks)
    }

    @Test("Un entero extremo no desborda ni crea una fecha ilimitada")
    func clampsExtremeIntervals() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let result = ReminderDateParser.date(
            for: "en \(Int.max) semanas",
            now: now,
            calendar: calendar
        )
        let days = calendar.dateComponents([.day], from: now, to: result).day ?? 0

        #expect(days > 0)
        #expect(days <= 52 * 10 * 7)
    }
}
