# Outlook Calendar Support for Issues #502 and #1013

Date: 2026-09-13

Repository revision inspected: `978238cb864009b36f36d1cbfb9f63c96236b74b`

**Research value: high** -- MacParakeet already has the correct provider-neutral implementation, and Apple and Microsoft both document the missing setup path for Exchange calendars; the remaining work is primarily in-product explanation and recovery, not a second calendar backend.

## Verdict

Outlook calendar support is feasible and mostly exists today. MacParakeet reads the macOS EventKit store, and EventKit explicitly represents Exchange calendar sources. A Microsoft 365 or Exchange calendar can therefore work when the same account is added to **System Settings > Internet Accounts** with **Calendar** enabled. The user may continue using Outlook as their calendar client.

The important boundary is that adding an account inside Outlook for Mac is separate from adding it to macOS Internet Accounts. The official Microsoft instructions describe Outlook setup and native Mac Mail/Calendar/Contacts setup as separate flows; Apple likewise says accounts must be added to Internet Accounts for Mac apps to use them. It is therefore reasonable to infer that an account configured only inside Outlook is not available to EventKit. MacParakeet currently explains neither that boundary nor how to fix it in the app.

The clean implementation is to keep EventKit as the only calendar backend and add a small Outlook/Microsoft 365 setup and troubleshooting affordance. Do **not** add Microsoft Graph/OAuth for these two reports. Graph is technically capable, but it would add a second event source, Microsoft app registration, authentication and token lifecycle, tenant-consent failure modes, network behavior, privacy documentation, calendar merging/deduplication, and substantially more testing. Neither issue contains evidence that the native Exchange route failed after correct setup.

## What the issues establish

- [Issue #502](https://github.com/moona3k/macparakeet/issues/502) asks for Outlook calendar integration rather than “the macOS calendar.” It was filed from stable app 0.6.22 on 2026-06-12.
- [Issue #1013](https://github.com/moona3k/macparakeet/issues/1013) repeats the request from stable app 0.7.3 on 2026-09-12.
- Neither issue has comments, logs, or a report that an Exchange account configured in macOS Calendar failed. They establish a recurring product-understanding gap, not a demonstrated EventKit compatibility defect.
- The second report arrived after the current calendar feature was already in the stable app. Repository-only documentation is therefore insufficient; the explanation belongs at the in-app connection point.

## Current MacParakeet implementation

MacParakeet already uses the architecture needed for Exchange:

- [`CalendarService`](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeetCore/Calendar/CalendarService.swift#L5-L17) is an EventKit wrapper. It deliberately avoids OAuth and describes the macOS store as the aggregator for iCloud, Google, and Exchange.
- It requests full event access, enumerates every event calendar returned by `EKEventStore.calendars(for: .event)`, exposes each calendar's title and source title, and queries all of them; there is no provider allowlist that could exclude Exchange ([permission and calendar enumeration](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeetCore/Calendar/CalendarService.swift#L50-L71), [available calendars](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeetCore/Calendar/CalendarService.swift#L101-L145)).
- Event conversion already retains title, time, location, attendee/organizer context, calendar identity, RSVP status, and external identity ([conversion](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeetCore/Calendar/CalendarService.swift#L173-L230)).
- The meeting-link parser explicitly recognizes `teams.microsoft.com` links in an event URL, location, or notes, with focused tests ([parser](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeetCore/Calendar/MeetingLinkParser.swift#L3-L17), [field precedence](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeetCore/Calendar/MeetingLinkParser.swift#L49-L65), [Teams test](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Tests/MacParakeetTests/Calendar/MeetingLinkParserTests.swift#L24-L27)).
- Settings already shows each visible calendar and its EventKit source title, but only when the returned list is nonempty. The empty state offers no account-setup help, and returning from System Settings has no explicit refresh action ([calendar list](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift#L290-L339), [reload behavior](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift#L357-L383)).
- The README accurately says that MacParakeet uses calendars configured in macOS Calendar and does not add Microsoft sign-ins, but the app's permission copy only says “Calendar access” ([README](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/README.md#L71-L84), [Settings copy](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/Sources/MacParakeet/Views/Settings/CalendarSettingsView.swift#L95-L132)).
- This is an intentional local-first decision in [ADR-017](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/spec/adr/017-calendar-meeting-auto-start.md#L17-L24), not an accidental omission.

## Platform facts and setup boundary

Apple's EventKit documentation defines both an [`EKSourceType.exchange`](https://developer.apple.com/documentation/eventkit/eksourcetype/exchange) (“Represents an Exchange source”) and an [`EKCalendarType.exchange`](https://developer.apple.com/documentation/eventkit/ekcalendartype). Apple's Calendar guide says Exchange calendars administered by Exchange Server appear in the native Calendar app, while its Internet Accounts guide says Exchange and other accounts must be added to the Mac for Mac apps to use them ([Exchange calendars](https://support.apple.com/en-ca/guide/calendar/icl28029/mac), [Internet Accounts](https://support.apple.com/en-gb/guide/mac-help/mh35565/mac)).

Microsoft independently documents that native Mac Mail, Calendar, and Contacts can connect to an Exchange account. Its setup flow is: add an Exchange account, authenticate, and choose which Mac apps to enable, including Calendar ([Microsoft Support](https://support.microsoft.com/en-us/outlook/set-up-email-in-mac-os-x-mail)). This lets a privacy-conscious user enable Calendar without requiring Mail or Contacts.

Microsoft also documents Outlook's own separate account setup under Outlook settings ([Outlook for Mac account setup](https://support.microsoft.com/en-US/Outlook/add-an-email-account-to-outlook-for-mac)). Taken together, these first-party flows support the key product explanation: **being signed into Outlook alone does not configure the account for EventKit; the account also needs Calendar enabled in macOS Internet Accounts.** This is an inference from the two documented, separate account stores rather than an explicit Microsoft statement about EventKit.

“Outlook” is a client, not one calendar-provider boundary. Outlook can also contain non-Microsoft accounts and local “On My Computer” data. A non-Exchange account must likewise be configured with its provider in macOS Internet Accounts; Outlook-only local calendar data is outside both the recommended EventKit route and Microsoft Graph.

Important limitations to communicate honestly:

- EventKit sees the Mac's locally synchronized state; MacParakeet cannot force an Exchange server refresh.
- Apple's Exchange guide says full calendar behavior is limited to the main Exchange calendar. Additional Exchange calendars can have stale invitation/attendee-response behavior. Shared/delegated calendars require separate visibility setup in Apple Calendar and should not be promised without an integration test ([Exchange limitations](https://support.apple.com/en-ca/guide/calendar/icl28029/mac), [delegated calendars](https://support.apple.com/guide/calendar/share-calendar-accounts-icl27527/mac)).
- Some organizations can prevent a user from adding third-party/native clients. A MacParakeet-specific Graph sign-in would not universally avoid enterprise policy: Entra administrators can restrict or disable user consent and require admin approval even for apps whose delegated permission does not intrinsically require admin consent ([Microsoft Entra consent controls](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/configure-user-consent)).
- EventKit exposes generic URL/location/notes fields, not Microsoft's strongly typed `onlineMeeting.joinUrl`. MacParakeet's Teams parsing is correct for the fields it receives, but a real Microsoft 365 account test is still required to prove that Apple Calendar exposes the Teams join URL and attendee status for representative meetings.

## EventKit versus Microsoft Graph

| Consideration | Existing EventKit aggregation | Microsoft Graph/OAuth |
|---|---|---|
| User setup | Add Microsoft/Exchange account in macOS Internet Accounts and enable Calendar; grant MacParakeet Calendar access | Add a separate “Sign in with Microsoft” flow and consent to MacParakeet |
| Coverage | All calendar providers configured on the Mac, including Exchange | Microsoft-hosted Outlook/Exchange data only |
| Calendar API | Existing `EKEventStore` implementation and tests | `GET /me/calendarView` (and per-calendar variants) returns occurrences for a time range ([Graph API](https://learn.microsoft.com/en-us/graph/api/user-list-calendarview?view=graph-rest-1.0)) |
| Meeting URL | Heuristic over EventKit URL/location/notes | Typed event `onlineMeeting.joinUrl` is available from Graph ([event resource](https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0)) |
| Authorization | macOS Calendar TCC permission; Apple/macOS owns account credentials | Microsoft app registration, redirect URI, MSAL/token cache, refresh/revocation, sign-out, tenant/personal-account behavior; Microsoft provides MSAL for macOS but requires app registration and project configuration ([MSAL](https://github.com/AzureAD/microsoft-authentication-library-for-objc)) |
| Permissions | MacParakeet receives the calendars exposed by EventKit | `Calendars.ReadBasic` can list a calendar view but excludes body; the current notes/link/attendee-derived behavior may require `Calendars.Read`, and shared/delegated calendar coverage requires the broader `Calendars.Read.Shared` scope ([permissions](https://learn.microsoft.com/en-us/graph/permissions-reference#calendarsreadbasic)) |
| Reliability surface | One local provider-neutral source; existing polling and `EKEventStoreChanged` handling | Network outages, throttling, token expiry/revocation, tenant consent, national-cloud endpoints, pagination/delta sync, plus merging/deduping with EventKit if both remain enabled |
| Product fit | Matches the local-first ADR and adds no new calendar data path | Explicit opt-in cloud surface requiring new privacy, security, support, and release gates |

Graph is a solved API problem, but it is not a small product integration. It becomes justified only if verified demand remains after users are given the native Exchange setup path—for example, tenants that permit a third-party Graph app but forbid macOS Internet Accounts, or recurring EventKit loss of required Teams meeting metadata.

## Recommended narrow PR

1. Keep `CalendarService` and meeting filtering unchanged.
2. In the Meeting Recording calendar settings, say plainly: “Microsoft 365 and Outlook calendars work through macOS Calendar. Add your Microsoft account in System Settings > Internet Accounts and turn on Calendar. You can keep using Outlook.” Do not label this “Connect Outlook,” because MacParakeet is not authenticating to Outlook.
3. When Calendar permission is granted but no event calendars are visible, show an actionable empty state instead of hiding the Calendars section. Include **Open Internet Accounts** and **Refresh Calendars** actions.
4. Make the same setup action available near the existing Calendars disclosure even when other calendars are present, so a user with iCloud but missing Exchange can discover it.
5. Refresh `availableCalendars` when MacParakeet becomes active again after System Settings, while retaining an explicit refresh button for deterministic recovery.
6. Open the current Internet Accounts pane using its System Settings extension identifier, with a generic System Settings fallback. On the inspected macOS 26.6.1 system, `/System/Library/ExtensionKit/Extensions/InternetAccountsSettingsExtension.appex` declares `com.apple.Internet-Accounts-Settings.extension` and allows the `x-apple.systempreferences` URL scheme. Because MacParakeet supports macOS 14.2+, verify the fallback on the oldest supported OS before release.
7. Avoid adding provider enums or source-type persistence unless UI conditionality later requires it. Existing `sourceTitle` is enough to identify the account in the calendar checklist.

This resolves the discoverability defect with a small, maintainable change and no change to the privacy model or calendar data contract.

## Verification and release claim

Automated coverage should verify any new settings action/state logic and preserve current CalendarService and Teams-link tests. The meaningful acceptance test is physical and requires a real Microsoft account:

1. Add Microsoft 365/Exchange to macOS Internet Accounts with Calendar enabled and other services optionally disabled.
2. Confirm the event appears in Apple Calendar.
3. Create an upcoming Teams meeting in Outlook, then verify MacParakeet's calendar list shows the Exchange source and `macparakeet-cli calendar upcoming --filter all --json` returns it.
4. Verify the join URL with the default link filter, attendee/RSVP behavior, a reschedule, and account Calendar disable/re-enable.
5. Repeat with the oldest supported macOS release; separately test a shared/delegated calendar before documenting that as supported.

Until that physical test passes, the accurate claim is: **the code and platform contracts support Exchange calendars through EventKit, and the proposed PR makes the required setup discoverable.** It is not yet a runtime certification of a particular Microsoft tenant, Outlook build, shared-calendar configuration, or Teams invitation shape.

## Sources

- [MacParakeet issue #502](https://github.com/moona3k/macparakeet/issues/502) and [issue #1013](https://github.com/moona3k/macparakeet/issues/1013) — two first-party user requests.
- [MacParakeet CalendarService and ADR-017](https://github.com/moona3k/macparakeet/blob/978238cb864009b36f36d1cbfb9f63c96236b74b/spec/adr/017-calendar-meeting-auto-start.md) — current implementation and local-first decision.
- [Apple EventKit source/calendar types](https://developer.apple.com/documentation/eventkit/eksourcetype) — official Exchange source support.
- [Apple Internet Accounts and Exchange Calendar guides](https://support.apple.com/en-gb/guide/mac-help/mh35565/mac) — native account setup and Exchange behavior.
- [Microsoft native Mac Exchange setup](https://support.microsoft.com/en-us/outlook/set-up-email-in-mac-os-x-mail) — Calendar can connect to Exchange through the Mac account flow.
- [Microsoft Graph calendar view, event, permissions, and Entra consent documentation](https://learn.microsoft.com/en-us/graph/api/user-list-calendarview?view=graph-rest-1.0) — the direct-cloud alternative and its authorization surface.
