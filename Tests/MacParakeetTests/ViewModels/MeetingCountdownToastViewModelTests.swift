import XCTest
@testable import MacParakeetViewModels

@MainActor
final class MeetingCountdownToastViewModelTests: XCTestCase {
    func testMinimalAutoStartHasNoCalendarContext() {
        let vm = MeetingCountdownToastViewModel(
            title: "Standup",
            duration: 5
        )

        XCTAssertNil(vm.calendarContext)
        XCTAssertNil(vm.contextSummary, "Manual-trigger toasts must not show the rich context row (ADR-020 §10)")
    }

    func testRichAutoStartFormatsAttendeesAndService() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 4,
            serviceName: "Zoom",
            steeringHint: "Take notes during the meeting."
        )
        let vm = MeetingCountdownToastViewModel(
            title: "Q2 Planning",
            duration: 5,
            calendarContext: context
        )

        XCTAssertEqual(vm.contextSummary, "4 attendees · Zoom")
    }

    func testRichAutoStartUsesSingularAttendee() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 1,
            serviceName: "Google Meet",
            steeringHint: "Take notes during the meeting."
        )
        let vm = MeetingCountdownToastViewModel(
            title: "1:1",
            duration: 5,
            calendarContext: context
        )

        XCTAssertEqual(vm.contextSummary, "1 attendee · Google Meet")
    }

    func testContextSummaryOmitsAttendeesWhenZero() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 0,
            serviceName: "Zoom",
            steeringHint: "Take notes."
        )
        let vm = MeetingCountdownToastViewModel(
            title: "Solo",
            duration: 5,
            calendarContext: context
        )

        XCTAssertEqual(vm.contextSummary, "Zoom")
    }

    func testContextSummaryOmitsServiceWhenNil() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 3,
            serviceName: nil,
            steeringHint: "Take notes."
        )
        let vm = MeetingCountdownToastViewModel(
            title: "Hallway sync",
            duration: 5,
            calendarContext: context
        )

        XCTAssertEqual(vm.contextSummary, "3 attendees")
    }

    func testContextSummaryNilWhenContextEmpty() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 0,
            serviceName: nil,
            steeringHint: "Take notes."
        )
        let vm = MeetingCountdownToastViewModel(
            title: "Empty",
            duration: 5,
            calendarContext: context
        )

        XCTAssertNil(vm.contextSummary, "An empty context yields nil so the view skips the row entirely")
    }
}
