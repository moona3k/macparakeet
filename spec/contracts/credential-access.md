# Credential access

## Purpose

MacParakeet's shared Keychain store must not open system authentication dialogs
from reads, writes, or deletes. This includes startup, status rendering, AI
requests, retained licensing I/O, and share maintenance. An inaccessible item
returns an error; only `errSecItemNotFound` means no saved item.

## Producers

- `KeychainKeyValueStore` (`getString`, `setString`, `delete`) owns every
  file-based Keychain call and the noninteractive scope.
- `LLMConfigStore` reads and writes per-provider API keys through that store and
  separates route metadata (`loadConfigMetadata`, `loadTaskOverrideMetadata`,
  `loadRouteMetadata`) from credential hydration (`loadConfig`, `loadAPIKey`).

## Consumers

- App startup and configuration: `AppEnvironment`, `AppEnvironmentConfigurer`,
  and `AppDelegate`.
- AI settings and prompts: `LLMSettingsViewModel`, `LLMSettingsView`,
  `PromptsViewModel`, `PromptResultsViewModel`, and model discovery.
- Other Keychain users of the same store: the CLI, `ShareCredentialStore`,
  licensing, and Voice Control credentials.

## Stable behavior

The existing services, account names, and app/dev/CLI sharing stay unchanged.
This change does not migrate, clear, or weaken access controls on stored keys.
File-based Keychain calls run with user interaction disabled inside a serialized
scope that restores the previous process-wide setting, including when the call
fails. The scope covers each whole read, write, or delete.

Provider presence, task routes, and displayed provider/model names use metadata
without reading credential values. A credential read failure must not hide or
clear the configured provider, endpoint, model, or task overrides. Only Keychain
failures are reported as credential errors; route-store failures are not.
Providers that cannot use an API key do not read one.

AI settings show credential access errors with an explicit Open Keychain Access
action and Retry access action. The user can grant the current app access to the
`com.macparakeet.llm` item in Keychain Access. Retry is noninteractive and keeps
unsaved model and key edits, including task-only routes; it does not save,
rotate, or remove a key. If the key field has not been edited, a successful
retry restores the saved value. Task-only validation uses cached key presence
from setup, route selection, or Retry; Save still reads current credentials.
Saved-provider health stays separate from unsaved provider errors.
Authorization changes occur only in the system Keychain Access app.

Existing save transactions must still stop on credential errors before changing
route metadata or removing an unreadable optional API key. Actual AI requests
continue to resolve credentials at execution time, preserving cross-process key
rotation behavior.

## Non-stable details

Error copy, the Settings banner layout, and the exact set of status codes
grouped as "access blocked" (currently `errSecInteractionNotAllowed`,
`errSecAuthFailed`, and `errSecUserCanceled`) may change.

## Versioning and compatibility

Keychain service and account names are persisted identifiers shared by the
stable app, dev builds, and the CLI. Renaming them, adding
`kSecUseDataProtectionKeychain`, or changing item attributes requires a
migration plan that keeps existing saved keys readable.

## Tests that enforce this

`KeychainInteractionTests`, `LLMConfigStoreTests`, `LLMSettingsViewModelTests`,
`PromptsViewModelTests`, `PromptResultsViewModelTests`, and
`AppEnvironmentTests`. Runtime verification uses synthetic credentials; never
reproduce by reading, changing, or deleting a user's saved API keys.

## When this changes

Update this document, the focused tests above, the Licensing README, and
`Sources/CLI/CHANGELOG.md` when CLI-visible credential behavior changes.
