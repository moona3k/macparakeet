# Credential access

MacParakeet's shared Keychain store must not open system authentication dialogs
from reads, writes, or deletes. This includes startup, status rendering, AI
requests, retained licensing I/O, and share maintenance. An inaccessible item
returns an error; only `errSecItemNotFound` means no saved item.

The existing services, account names, and app/dev/CLI sharing stay unchanged.
This change does not migrate, clear, or weaken access controls on stored keys.
File-based Keychain calls run with user interaction disabled inside a serialized
scope that restores the previous process-wide setting. Each query also disables
Local Authentication interaction. The legacy switch remains necessary while
SwiftPM builds use the file-based Keychain.

Provider presence, task routes, and displayed provider/model names use metadata
without reading credential values. A credential read failure must not hide or
clear the configured provider, endpoint, model, or task overrides. Providers
that cannot use an API key do not read one.

AI settings show credential access errors with an explicit Open Keychain Access
action and Retry access action. The user can grant the current app access to the
`com.macparakeet.llm` item in Keychain Access. Retry is noninteractive and keeps
unsaved model and key edits, including task-only routes; it does not save,
rotate, or remove a key. If the
key field has not been edited, a successful retry restores the saved value.
Authorization changes occur only in the system Keychain Access app.

Existing save transactions must still stop on credential errors before changing
route metadata or removing an unreadable optional API key. Actual AI requests
continue to resolve credentials at execution time, preserving cross-process key
rotation behavior.

Verification: `KeychainInteractionTests`, `LLMConfigStoreTests`, and
`LLMSettingsViewModelTests`. Runtime verification uses synthetic credentials;
never reproduce by reading, changing, or deleting a user's saved API keys.
