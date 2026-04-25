import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Calendar auto-start section. Slotted into Settings between Meeting
/// Recording and Transcription. Phase D — only `.off` and `.notify` modes
/// are exposed; `.autoStart` ships in Phase E (ADR-017).
struct CalendarSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var availableCalendars: [CalendarInfo] = []
    @State private var isRequestingPermission = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            permissionRow

            if viewModel.calendarPermissionGranted {
                Divider()
                modeRow

                if viewModel.calendarAutoStartMode != .off {
                    Divider()
                    reminderLeadRow
                    Divider()
                    triggerFilterRow

                    if viewModel.calendarAutoStartMode == .autoStart {
                        Divider()
                        autoStopRow
                    }

                    if !availableCalendars.isEmpty {
                        Divider()
                        includedCalendarsRow
                    }
                }
            }
        }
        .onAppear { reloadCalendars() }
        .onChange(of: viewModel.calendarPermissionGranted) { _, _ in reloadCalendars() }
    }

    // MARK: - Permission

    @ViewBuilder
    private var permissionRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar access")
                    .font(DesignSystem.Typography.body)
                Text(permissionDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            permissionAction
        }
    }

    private var permissionDetail: String {
        switch viewModel.calendarPermissionStatus {
        case .granted:
            return "Granted. Events stay on your Mac — MacParakeet never uploads them."
        case .denied:
            // macOS only shows the EventKit prompt once. Once denied, the
            // only path back is System Settings — telling the user to
            // "grant access" via a button that can't actually re-prompt
            // would mystify them.
            return "Calendar access is blocked. Re-enable it in System Settings → Privacy & Security → Calendars to use reminders."
        case .notDetermined:
            return "Reads your macOS calendar so MacParakeet can remind you before a meeting starts. Events stay on your Mac."
        }
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch viewModel.calendarPermissionStatus {
        case .granted, .denied:
            Button("Open System Settings") {
                viewModel.openCalendarSystemSettings()
            }
            .controlSize(.small)
        case .notDetermined:
            Button {
                requestPermission()
            } label: {
                if isRequestingPermission {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Grant Calendar Access")
                }
            }
            .controlSize(.small)
            .disabled(isRequestingPermission)
        }
    }

    // MARK: - Mode

    @ViewBuilder
    private var modeRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar behavior")
                    .font(DesignSystem.Typography.body)
                Text(modeDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("", selection: $viewModel.calendarAutoStartMode) {
                Text("Off").tag(CalendarAutoStartMode.off)
                Text("Notify before meetings").tag(CalendarAutoStartMode.notify)
                Text("Start recording automatically").tag(CalendarAutoStartMode.autoStart)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 240)
        }
    }

    private var modeDetail: String {
        switch viewModel.calendarAutoStartMode {
        case .off:
            return "MacParakeet ignores your calendar."
        case .notify:
            return "Quietly notifies you before each meeting starts."
        case .autoStart:
            return "Shows a 5-second cancellable countdown, then starts recording. You can keep the recording past the meeting end."
        }
    }

    // MARK: - Reminder lead time

    @ViewBuilder
    private var reminderLeadRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remind me")
                    .font(DesignSystem.Typography.body)
                Text("How long before the meeting starts to send the reminder.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("", selection: $viewModel.calendarReminderMinutes) {
                Text("At start time").tag(0)
                Text("1 minute before").tag(1)
                Text("5 minutes before").tag(5)
                Text("10 minutes before").tag(10)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 200)
        }
    }

    // MARK: - Trigger filter

    @ViewBuilder
    private var triggerFilterRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Which events count")
                    .font(DesignSystem.Typography.body)
                Text("Higher precision filters skip personal blocks and solo focus time.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("", selection: $viewModel.meetingTriggerFilter) {
                Text("With video link").tag(MeetingTriggerFilter.withLink)
                Text("With participants").tag(MeetingTriggerFilter.withParticipants)
                Text("All events").tag(MeetingTriggerFilter.allEvents)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 200)
        }
    }

    // MARK: - Auto-stop toggle (only when mode == .autoStart)

    @ViewBuilder
    private var autoStopRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stop recording at meeting end")
                    .font(DesignSystem.Typography.body)
                Text("Shows a 30-second countdown when the meeting is scheduled to end. Click \"Keep Recording\" if it runs over.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Toggle("", isOn: $viewModel.calendarAutoStopEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    // MARK: - Per-calendar include list

    @ViewBuilder
    private var includedCalendarsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendars")
                        .font(DesignSystem.Typography.body)
                    Text("Uncheck calendars to ignore (personal calendars, holidays, etc.).")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(availableCalendars) { calendar in
                    Toggle(isOn: bindingForCalendar(calendar)) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(calendar.title)
                                .font(DesignSystem.Typography.body)
                            if let source = calendar.sourceTitle {
                                Text(source)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.leading, DesignSystem.Spacing.sm)
        }
    }

    private func bindingForCalendar(_ calendar: CalendarInfo) -> Binding<Bool> {
        // Key on `calendar.id` (EKCalendar.calendarIdentifier), not title —
        // titles aren't unique across accounts and rename silently breaks the
        // exclude list. ID is stable across both.
        Binding(
            get: { !viewModel.calendarExcludedIdentifiers.contains(calendar.id) },
            set: { isIncluded in
                if isIncluded {
                    viewModel.calendarExcludedIdentifiers.remove(calendar.id)
                } else {
                    viewModel.calendarExcludedIdentifiers.insert(calendar.id)
                }
            }
        )
    }

    // MARK: - Helpers

    private func requestPermission() {
        isRequestingPermission = true
        Task {
            _ = await viewModel.requestCalendarPermission()
            isRequestingPermission = false
            reloadCalendars()
        }
    }

    private func reloadCalendars() {
        guard viewModel.calendarPermissionGranted else {
            availableCalendars = []
            return
        }
        // CalendarService is an actor (EventKit isn't thread-safe), so this
        // hops off main. Cheap — typically <5ms with permission already
        // granted — but worth keeping off the main thread on principle.
        Task {
            let calendars = await CalendarService.shared.availableCalendars()
            await MainActor.run { self.availableCalendars = calendars }
        }
    }
}
