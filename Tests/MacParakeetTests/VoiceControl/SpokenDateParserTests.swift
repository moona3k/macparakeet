import XCTest
@testable import MacParakeetCore

final class SpokenDateParserTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// Sunday, 2026-09-20 at noon Pacific.
    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 12))!
    }

    private func parse(_ text: String) -> String? {
        SpokenDateParser.firstDate(in: text, today: today, calendar: calendar).map {
            SpokenDateParser.iso($0, calendar: calendar)
        }
    }

    func testAbsoluteMonthDayYear() {
        XCTAssertEqual(parse("Find flights to London on September 20 2026"), "2026-09-20")
        XCTAssertEqual(parse("Saturday, September 20, 2026, $412"), "2026-09-20")
    }

    func testDayMonth() {
        XCTAssertEqual(parse("leave on 20 Sep"), "2026-09-20")
        XCTAssertEqual(parse("leave on 3 October 2026"), "2026-10-03")
    }

    func testISO() {
        XCTAssertEqual(parse("2026-09-20"), "2026-09-20")
    }

    func testUSNumeric() {
        XCTAssertEqual(parse("on 9/20/2026"), "2026-09-20")
    }

    func testMissingYearRollsForwardWhenMoreThanSixtyDaysPast() {
        XCTAssertEqual(parse("March 5"), "2027-03-05")
        XCTAssertEqual(parse("August 1"), "2026-08-01")  // within 60 days past: keep current year
        XCTAssertEqual(parse("December 25"), "2026-12-25")
    }

    func testTodayAndTomorrow() {
        XCTAssertEqual(parse("book it for today"), "2026-09-20")
        XCTAssertEqual(parse("Tomorrow please"), "2026-09-21")
    }

    func testNextFridayLandsOnAFridayAfterToday() {
        let date = SpokenDateParser.firstDate(in: "next Friday", today: today, calendar: calendar)!
        XCTAssertEqual(calendar.component(.weekday, from: date), 6)
        XCTAssertGreaterThan(date, today)
        XCTAssertEqual(SpokenDateParser.iso(date, calendar: calendar), "2026-09-25")
        XCTAssertEqual(parse("Friday"), "2026-09-25")
        XCTAssertEqual(parse("this Sunday"), "2026-09-27")  // strictly after today
    }

    func testTheTwentieth() {
        XCTAssertEqual(parse("the 20th"), "2026-09-20")
        XCTAssertEqual(parse("the 3rd"), "2026-10-03")
        XCTAssertEqual(parse("the 25th"), "2026-09-25")
    }

    func testInThreeDays() {
        XCTAssertEqual(parse("in 3 days"), "2026-09-23")
    }

    func testDescribe() {
        let future = calendar.date(byAdding: .day, value: 25, to: today)!
        let past = calendar.date(byAdding: .day, value: -3, to: today)!
        XCTAssertEqual(SpokenDateParser.describe(today, today: today, calendar: calendar), "2026-09-20 (today)")
        XCTAssertEqual(SpokenDateParser.describe(future, today: today, calendar: calendar), "2026-10-15 (in 25 days)")
        XCTAssertEqual(SpokenDateParser.describe(past, today: today, calendar: calendar), "2026-09-17 (3 days ago)")
    }

    func testNoDateReturnsNil() {
        XCTAssertNil(parse("London"))
        XCTAssertNil(parse("Search flights"))
        XCTAssertNil(parse("Where from?"))
    }
}
