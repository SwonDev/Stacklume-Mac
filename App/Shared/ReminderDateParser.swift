import Foundation

/// Parser acotado de expresiones temporales del asistente. Los máximos evitan
/// desbordamientos y recordatorios absurdamente lejanos procedentes de tool calls.
enum ReminderDateParser {
    private static let maximumHours = 24 * 365 * 10
    private static let maximumDays = 365 * 10
    private static let maximumWeeks = 52 * 10
    private static let maximumMonths = 12 * 10

    static func date(
        for rawValue: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let value = rawValue.lowercased()
        func add(_ component: Calendar.Component, _ amount: Int) -> Date {
            calendar.date(byAdding: component, value: amount, to: now) ?? now
        }
        func atMorning(_ date: Date) -> Date {
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        }

        let number = firstPositiveInteger(in: value)
        if let number, value.contains("hora") {
            return add(.hour, min(number, maximumHours))
        }
        if let number, value.contains("semana") {
            let weeks = min(number, maximumWeeks)
            return atMorning(add(.day, weeks * 7))
        }
        if let number, value.contains("mes") {
            return atMorning(add(.month, min(number, maximumMonths)))
        }
        if let number, value.contains("día") || value.contains("dia") {
            return atMorning(add(.day, min(number, maximumDays)))
        }
        if value.contains("pasado") { return atMorning(add(.day, 2)) }
        if value.contains("mañana") || value.contains("manana") { return atMorning(add(.day, 1)) }
        if value.contains("semana") { return atMorning(add(.day, 7)) }
        if value.contains("mes") { return atMorning(add(.month, 1)) }
        if value.contains("hoy") || value.contains("tarde") || value.contains("luego") {
            return add(.hour, 3)
        }
        return atMorning(add(.day, 1))
    }

    private static func firstPositiveInteger(in value: String) -> Int? {
        let words: [String: Int] = [
            "un": 1, "una": 1, "uno": 1, "dos": 2, "tres": 3, "cuatro": 4,
            "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9, "diez": 10,
        ]
        let tokens = value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for token in tokens {
            if let word = words[token] { return word }
            if let number = Int(token), number > 0 { return number }
        }
        return nil
    }
}
