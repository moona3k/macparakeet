import XCTest
@testable import MacParakeetViewModels

@MainActor
final class MeetingCountdownToastViewModelTests: XCTestCase {
    func testMinimalAutoStartHasNoCalendarContext() {
        let vm = MeetingCountdownToastViewModel(
            style: .autoStart,
            title: "Standup",
            body: "Recording will start automatically.",
            duration: 5
        )

        XCTAssertNil(vm.calendarContext)
        XCTAssertNil(vm.contextSummary, "Manual-trigger toasts must not show the rich context row (ADR-020 §10)")
        XCTAssertEqual(vm.primaryActionLabel, "Cancel")
        XCTAssertEqual(vm.secondaryActionLabel, "Start Now")
    }

    func testRichAutoStartFormatsAttendeesAndService() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 4,
            serviceName: "Zoom",
            steeringHint: "Take notes to shape the summary."
        )
        let vm = MeetingCountdownToastViewModel(
            style: .autoStart,
            title: "Q2 Planning",
            body: "Recording will start automatically — joining Zoom?",
            duration: 5,
            calendarContext: context
        )

        XCTAssertEqual(vm.contextSummary, "4 attendees · Zoom")
    }

    func testRichAutoStartUsesSingularAttendee() {
        let context = MeetingCountdownToastViewModel.CalendarContext(
            attendeeCount: 1,
            serviceName: "Google Meet",
            steeringHint: "Take notes to shape the summary."
        )
        let vm = MeetingCountdownToastViewModel(
            style: .autoStart,
            title: "1:1",
            body: "Recording will start automatically.",
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
            style: .autoStart,
            title: "Solo",
            body: "Recording will start automatically.",
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
            style: .autoStart,
            title: "Hallway sync",
            body: "Recording will start automatically.",
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
            style: .autoStart,
            title: "Empty",
            body: "Recording will start automatically.",
            duration: 5,
            calendarContext: context
        )

        XCTAssertNil(vm.contextSummary, "An empty context yields nil so the view skips the row entirely")
    }

    func testAutoStopStyleHasNoSecondaryAction() {
        let vm = MeetingCountdownToastViewModel(
            style: .autoStop,
            title: "Wrap ending",
            body: "Stop recording?",
            duration: 30
        )

        XCTAssertEqual(vm.primaryActionLabel, "Keep Recording")
        XCTAssertNil(vm.secondaryActionLabel)
    }
}
