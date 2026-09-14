import MacParakeetCore
import MacParakeetViewModels
import SwiftUI

/// Calendar auto-start — the "Start recording automatically" half of the
/// Meeting Recording card's Automatic recording group. A single adaptive row
/// requests Calendar access in context (so the user opts into auto-start and
/// *that* prompts for access). Once granted, the row is a plain on/off toggle —
/// matching its "Stop recording automatically" sibling and the "Auto-save
/// meetings to disk" toggle above — and turning it on reveals an elevated
/// sub-panel holding the `.notify` vs `.autoStart` mode fork (ADR-017
/// Phases 1+2) plus the reminder and event-filter controls. Calendar account
/// discovery and the per-calendar list stay visible independently of this mode.
/// `.off` is the toggle's unchecked state, so it no longer competes with the
/// mode choice the way the old three-value picker did.
struct CalendarSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var isRequestingPermission = false
    @State private var calendarsExpanded = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            startRow

            if viewModel.calendarPermissionGranted && viewModel.calendarAutoStartMode != .off {
                startOptionsPanel
            }

            Divider()
            calendarAccountsRow

            if viewModel.calendarPermissionGranted {
                Divider()
                calendarListRow
            }
        }
        .task {
            await viewModel.refreshCalendarAccess()
            await viewModel.refreshCalendarNotificationAuthorization()
        }
        .onChange(of: viewModel.calendarAutoStartMode) { _, _ in refreshNotificationAuth() }
    }

    // MARK: - Calendar accounts

    private var calendarAccountsRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar accounts")
                    .font(DesignSystem.Typography.body)
                Text(
                    "MacParakeet reads calendars added to this Mac, including Microsoft 365 and Exchange. Add accounts in System Settings → Internet Accounts; you can keep using Outlook."
                )
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.sm) {
                Button {
                    viewModel.openInternetAccountsSystemSettings()
                } label: {
                    Label("Manage Accounts", systemImage: "person.crop.circle.badge.plus")
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
                .help("Open System Settings → Internet Accounts")

                if viewModel.calendarPermissionGranted {
                    Button {
                        Task { await viewModel.refreshCalendarAccess() }
                    } label: {
                        if viewModel.isRefreshingCalendars {
                            ParakeetSpinner(.inline)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .parakeetAction(.secondary)
                    .controlSize(.small)
                    .disabled(viewModel.isRefreshingCalendars)
                    .help("Refresh calendars from this Mac")
                    .accessibilityLabel("Refresh calendars")
                }
            }
        }
    }

    @ViewBuilder
    private var calendarListRow: some View {
        switch viewModel.calendarListLoadState {
        case .notLoaded, .loading:
            HStack(spacing: DesignSystem.Spacing.sm) {
                ParakeetSpinner(.inline)
                Text("Loading calendars…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .loaded where viewModel.availableCalendars.isEmpty:
            VStack(alignment: .leading, spacing: 2) {
                Text("No calendars found")
                    .font(DesignSystem.Typography.body)
                Text("If you just added an account, allow macOS a moment to sync, then refresh.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded:
            includedCalendarsRow
        }
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
    /// user opts into auto-start and *that* triggers the access prompt), an
    /// on/off toggle once granted, and a System Settings deep-link if denied.
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
            // The per-mode explanation now lives on the segmented control inside
            // the revealed sub-panel; the master row keeps a stable description.
            return "Start a recording when a scheduled meeting begins."
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
            // On/off only — the `.notify` vs `.autoStart` choice moved into the
            // revealed sub-panel. This makes the control identical in idiom to
            // the "Stop recording automatically" toggle and the Auto-save
            // toggle above, and expresses "off" as the unchecked state rather
            // than a value buried in a dropdown.
            Toggle("", isOn: startEnabledBinding)
                .labelsHidden()
                .parakeetSwitch()
                // macOS VoiceOver focuses each control independently and does
                // NOT auto-associate the adjacent title — mirror it so the
                // switch isn't an orphaned "switch, off" announcement.
                .accessibilityLabel("Start recording automatically")
                .accessibilityHint(startDetail)
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
                    ParakeetSpinner(.inline)
                } else {
                    Text("Turn On…")
                }
            }
            .controlSize(.small)
            .disabled(isRequestingPermission)
        }
    }

    /// On/off binding for the granted-state master toggle. Off maps to
    /// `.off`; on restores the gentle `.notify` default (the sub-panel's
    /// segmented control then lets the user upgrade to `.autoStart`). Only
    /// rendered when permission is `.granted`, so it never has to drive the
    /// permission request itself.
    private var startEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.calendarAutoStartMode != .off },
            set: { isOn in
                viewModel.calendarAutoStartMode = isOn ? .notify : .off
            }
        )
    }

    // MARK: - Revealed options sub-panel

    /// Elevated container shown when auto-start is on, mirroring the Auto-save
    /// options sub-panel in the same card so the parent→children relationship
    /// reads visually instead of as a flat list of sibling rows.
    @ViewBuilder
    private var startOptionsPanel: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            modeRow

            if !viewModel.calendarNotificationsAuthorized {
                Divider()
                notificationWarningRow
            }

            Divider()
            reminderLeadRow
            Divider()
            triggerFilterRow
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    // MARK: - Mode (notify vs auto-start)

    /// The `.notify` vs `.autoStart` fork. A segmented control (rather than a
    /// menu) keeps both behaviors visible at a glance and visually distinct
    /// from the menu-style parameter pickers below it.
    @ViewBuilder
    private var modeRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("When a meeting starts")
                    .font(DesignSystem.Typography.body)
                Text(modeDetail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignSystem.Spacing.md)
            Picker("", selection: modeBinding) {
                Text("Notify me").tag(CalendarAutoStartMode.notify)
                Text("Start automatically").tag(CalendarAutoStartMode.autoStart)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityLabel("When a meeting starts")
        }
    }

    /// Drives the segmented control. The sub-panel (and thus this row) only
    /// renders while the mode is non-`.off`, so collapse anything non-`.autoStart`
    /// to `.notify` for a stable two-way selection.
    private var modeBinding: Binding<CalendarAutoStartMode> {
        Binding(
            get: { viewModel.calendarAutoStartMode == .autoStart ? .autoStart : .notify },
            set: { viewModel.calendarAutoStartMode = $0 }
        )
    }

    /// Caption for the mode segmented control. Only `.notify` / `.autoStart`
    /// are reachable here — the sub-panel that hosts the control is gated on
    /// `calendarAutoStartMode != .off` — so anything non-`.autoStart` reads as
    /// the notify default, matching `modeBinding`'s collapsing.
    private var modeDetail: String {
        viewModel.calendarAutoStartMode == .autoStart
            ? "Shows a 5-second cancellable countdown, then starts recording. You can keep the recording past the meeting end."
            : "Quietly notifies you before each meeting starts."
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
                    ForEach(viewModel.availableCalendars) { calendar in
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
        let total = viewModel.availableCalendars.count
        let included = viewModel.availableCalendars.filter {
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
            // On a successful grant the view model already defaults the mode to
            // the gentle `.notify` (and requests notification auth), so the row
            // lands in the on state and reveals the sub-panel — "Turn On…"
            // genuinely turns it on with nothing to set here.
            let granted = await viewModel.requestCalendarPermission()
            if granted {
                await viewModel.refreshCalendarAccess()
            }
            isRequestingPermission = false
        }
    }
}
