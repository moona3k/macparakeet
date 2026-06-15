import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Calendar auto-start — the "Start recording automatically" half of the
/// Meeting Recording card's Automatic recording group. A single adaptive row
/// requests Calendar access in context (so the user opts into auto-start and
/// *that* prompts for access), then exposes all three modes — `.off`,
/// `.notify`, `.autoStart` per ADR-017 Phases 1+2 — with disclosed reminder,
/// event-filter, and per-calendar controls.
struct CalendarSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var availableCalendars: [CalendarInfo] = []
    @State private var isRequestingPermission = false
    @State private var calendarsExpanded = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            startRow

            if viewModel.calendarPermissionGranted && viewModel.calendarAutoStartMode != .off {
                if !viewModel.calendarNotificationsAuthorized {
                    Divider()
                    notificationWarningRow
                }
                Divider()
                reminderLeadRow
                Divider()
                triggerFilterRow

                if !availableCalendars.isEmpty {
                    Divider()
                    includedCalendarsRow
                }
            }
        }
        .onAppear {
            reloadCalendars()
            refreshNotificationAuth()
        }
        .onChange(of: viewModel.calendarPermissionGranted) { _, _ in reloadCalendars() }
        .onChange(of: viewModel.calendarAutoStartMode) { _, _ in refreshNotificationAuth() }
    }

    // MARK: - Notification permission warning

    /// macOS notifications are a separate TCC scope from Calendar. When they're
    /// off, `.notify` reminders (and the `.autoStart` pre-meeting reminder) are
    /// silently dropped — surface that instead of letting the feature look on
    /// but do nothing.
    @ViewBuilder
    private var notificationWarningRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            // Match the established warning treatment used for provider
            // validation and hotkey conflicts.
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignSystem.Colors.warningAmber)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off")
                    .font(DesignSystem.Typography.body)
                Text("Calendar reminders won't appear until you allow MacParakeet notifications in System Settings.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Button("Open System Settings") {
                viewModel.openNotificationSystemSettings()
            }
            .controlSize(.small)
        }
    }

    private func refreshNotificationAuth() {
        Task { await viewModel.refreshCalendarNotificationAuthorization() }
    }

    // MARK: - Start (adaptive permission + mode)

    /// Single adaptive row that frames calendar auto-start as the "start" half
    /// of the Automatic recording group. The trailing control follows Calendar
    /// permission: a one-tap enable button before access is granted (so the
    /// user opts into auto-start and *that* triggers the access prompt), the
    /// mode picker once granted, and a System Settings deep-link if denied.
    @ViewBuilder
    private var startRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start recording automatically")
                    .font(DesignSystem.Typography.body)
                Text(startDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            startControl
        }
    }

    private var startDetail: String {
        switch viewModel.calendarPermissionStatus {
        case .granted:
            return modeDetail
        case .denied:
            // macOS only shows the EventKit prompt once. Once denied, the
            // only path back is System Settings — a button that can't actually
            // re-prompt would mystify the user, so point them there explicitly.
            return "Calendar access is blocked. Re-enable it in System Settings → Privacy & Security → Calendars to start meetings automatically."
        case .notDetermined:
            return "Start a recording when a scheduled meeting begins. Needs Calendar access — your events stay on your Mac and are never uploaded."
        }
    }

    @ViewBuilder
    private var startControl: some View {
        switch viewModel.calendarPermissionStatus {
        case .granted:
            Picker("", selection: $viewModel.calendarAutoStartMode) {
                Text("Off").tag(CalendarAutoStartMode.off)
                Text("Notify me").tag(CalendarAutoStartMode.notify)
                Text("Start automatically").tag(CalendarAutoStartMode.autoStart)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 200)
            // macOS VoiceOver focuses each control independently and does NOT
            // auto-associate the adjacent title with the picker — without this
            // the control announces only its value ("Off, pop up button"). The
            // visible title is mirrored so the accessible name matches it.
            .accessibilityLabel("Start recording automatically")
        case .denied:
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
                    Text("Turn On…")
                }
            }
            .controlSize(.small)
            .disabled(isRequestingPermission)
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
            .accessibilityLabel("Remind me")
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
            .accessibilityLabel("Which events count")
        }
    }

    // MARK: - Per-calendar include list

    @ViewBuilder
    private var includedCalendarsRow: some View {
        DisclosureGroup(isExpanded: $calendarsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Uncheck calendars to ignore (personal calendars, holidays, etc.).")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)

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
            .padding(.top, DesignSystem.Spacing.sm)
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calendars")
                        .font(DesignSystem.Typography.body)
                    Text(calendarSelectionSummary)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DesignSystem.Spacing.md)
            }
        }
    }

    private var calendarSelectionSummary: String {
        let total = availableCalendars.count
        let included = availableCalendars.filter {
            !viewModel.calendarExcludedIdentifiers.contains($0.id)
        }.count
        return "\(included) of \(total) selected"
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
