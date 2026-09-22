# Voice Control qualification fixtures

`QualificationApp.swift` is an isolated native app with synthetic flight fields.
It never accesses real accounts, flight services, user documents or payments.
Compile it with `swiftc -framework AppKit QualificationApp.swift -o <temporary bundle>/Contents/MacOS/VoiceControlFixture`,
and give that temporary bundle identifier `com.macparakeet.voice-control-fixture`.
Only drive this window during automated native qualification. The application is
not shipped inside MacParakeet and is not a substitute for browser qualification.

Live Jev tests require explicit opt-in and use synthetic context only. Never put
an API key in a test fixture, command argument, console output or tracked file.
