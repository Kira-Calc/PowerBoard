import Foundation
import Testing
@testable import ElectricityCore

@Suite struct LocalPeriodTests {
    private func calendar(_ timeZone: String, firstWeekday: Int = 1) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func utc(_ string: String) -> Date {
        try! Date(string, strategy: Date.ISO8601FormatStyle())
    }

    @Test func dayCrossesMidnightInLocalTime() {
        let shanghai = calendar("Asia/Shanghai")
        // 23:30 and 00:30 local time on consecutive days.
        let lateEvening = utc("2026-10-11T15:30:00Z")
        let afterMidnight = utc("2026-10-11T16:30:00Z")
        let day = LocalPeriod.day.interval(containing: lateEvening, calendar: shanghai)
        #expect(day.start == utc("2026-10-10T16:00:00Z"))
        #expect(day.end == utc("2026-10-11T16:00:00Z"))
        #expect(day.contains(lateEvening))
        #expect(!(afterMidnight >= day.start && afterMidnight < day.end))
    }

    @Test func sameInstantFallsOnDifferentDaysByTimeZone() {
        let instant = utc("2026-10-12T02:00:00Z")
        let shanghaiDay = LocalPeriod.day.interval(containing: instant, calendar: calendar("Asia/Shanghai"))
        let losAngelesDay = LocalPeriod.day.interval(containing: instant, calendar: calendar("America/Los_Angeles"))
        #expect(shanghaiDay.start == utc("2026-10-11T16:00:00Z"))
        #expect(losAngelesDay.start == utc("2026-10-11T07:00:00Z"))
    }

    @Test func dayAcrossDaylightSavingChangeIsNot24Hours() {
        // US daylight saving ends on 2026-11-01.
        let day = LocalPeriod.day.interval(containing: utc("2026-11-01T12:00:00Z"), calendar: calendar("America/New_York"))
        #expect(day.duration == 25 * 3600)
    }

    @Test func weekFollowsFirstWeekday() {
        // 2026-10-12 is a Monday.
        let monday = utc("2026-10-12T12:00:00Z")
        let sundayStart = LocalPeriod.week.interval(containing: monday, calendar: calendar("UTC", firstWeekday: 1))
        let mondayStart = LocalPeriod.week.interval(containing: monday, calendar: calendar("UTC", firstWeekday: 2))
        #expect(sundayStart.start == utc("2026-10-11T00:00:00Z"))
        #expect(mondayStart.start == utc("2026-10-12T00:00:00Z"))
        #expect(mondayStart.duration == 7 * 86400)
    }

    @Test func monthAndYear() {
        let date = utc("2026-02-15T12:00:00Z")
        let month = LocalPeriod.month.interval(containing: date, calendar: calendar("UTC"))
        #expect(month.start == utc("2026-02-01T00:00:00Z"))
        #expect(month.duration == 28 * 86400)
        let year = LocalPeriod.year.interval(containing: date, calendar: calendar("UTC"))
        #expect(year.start == utc("2026-01-01T00:00:00Z"))
    }
}
